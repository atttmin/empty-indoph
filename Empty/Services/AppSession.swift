//
//  AppSession.swift
//  Empty
//

import Combine
import Foundation
import SwiftData
import SwiftUI

@MainActor
final class AppSession: ObservableObject {
    private static let syncCredentialService = "davirian.Empty.sync-provider"

    @Published private(set) var container: ModelContainer
    @Published private(set) var syncSettings: SyncSettings
    @Published private(set) var containerRevision = UUID()
    @Published private(set) var liveSyncStatuses: [LiveSyncProviderStatus] = []
    @Published private(set) var isRefreshingLiveSyncStatuses = false
    @Published private(set) var autoSyncRuntime = ServerAutoSyncRuntimeState()

    let isEphemeral: Bool

    private var currentScenePhase: ScenePhase = .active
    private var autoSyncTask: Task<Void, Never>?

    init(isEphemeral override: Bool? = nil) {
        let process = ProcessInfo.processInfo
        let inferredEphemeral = process.environment["XCTestConfigurationFilePath"] != nil
            || process.arguments.contains("-ScreenshotCleanRoom")
        isEphemeral = override ?? inferredEphemeral
        let loadedSettings = SyncSettings.load()
        syncSettings = loadedSettings
        let mode = isEphemeral ? SyncLiveMode.localOnly : loadedSettings.liveMode
        do {
            container = try AppStores.makeContainer(syncMode: mode, ephemeral: isEphemeral)
        } catch {
            fatalError("Failed to set up persistence: \(error)")
        }
        refreshAutoSyncRuntime()
        Task { @MainActor in
            await refreshLiveSyncStatuses()
        }
    }

    deinit {
        autoSyncTask?.cancel()
    }

    static var preview: AppSession {
        AppSession(isEphemeral: true)
    }

    var effectiveLiveMode: SyncLiveMode {
        isEphemeral ? .localOnly : syncSettings.liveMode
    }

    var serverAuthToken: String {
        KeychainStore.read(
            account: SyncSettings.serverTokenAccount,
            service: Self.syncCredentialService
        ) ?? ""
    }

    var serverLiveCursor: LiveSyncCursor? {
        syncSettings.serverTarget?.liveCursor
    }

    var serverAutoSyncEnabled: Bool {
        syncSettings.serverTarget?.autoSyncEnabled == true
    }

    var serverAutoSyncIntervalSeconds: Int {
        syncSettings.serverTarget?.clampedAutoSyncIntervalSeconds ?? 120
    }

    func handleScenePhase(_ phase: ScenePhase) {
        currentScenePhase = phase
        restartAutoSyncLoopIfNeeded()
        if phase == .background, serverAutoSyncEnabled {
            Task { @MainActor in
                do {
                    _ = try await runAutomaticServerSync(force: false, trigger: "background")
                } catch {
                    autoSyncRuntime.lastError = error.localizedDescription
                }
            }
        }
    }

    func refreshLiveSyncStatuses() async {
        isRefreshingLiveSyncStatuses = true
        defer {
            isRefreshingLiveSyncStatuses = false
            restartAutoSyncLoopIfNeeded()
        }

        var statuses: [LiveSyncProviderStatus] = []
        for provider in makeLiveSyncProviders() {
            let status = await provider.status(selectedMode: effectiveLiveMode)
            statuses.append(status)
        }
        liveSyncStatuses = statuses
    }

    func setLiveMode(_ mode: SyncLiveMode) throws {
        guard !isEphemeral else { return }
        guard syncSettings.liveMode != mode else { return }
        var updated = syncSettings
        updated.liveMode = mode
        let newContainer = try AppStores.makeContainer(syncMode: mode, ephemeral: false)
        updated.save()
        syncSettings = updated
        container = newContainer
        containerRevision = UUID()
        refreshAutoSyncRuntime()
        refreshLiveSyncStatusesSoon()
    }

    func rememberBackupFolder(_ url: URL) throws {
        try FolderBackupProvider.validateSelectionURL(url)
        let bookmarkData = try url.bookmarkData(
            options: FolderBackupProvider.bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let displayName = try url.resourceValues(forKeys: [.nameKey]).name ?? url.lastPathComponent
        var updated = syncSettings
        updated.folderTarget = .init(
            bookmarkData: bookmarkData,
            displayName: displayName,
            lastSnapshotAt: updated.folderTarget?.lastSnapshotAt
        )
        persist(updated)
    }

    func clearBackupFolder() {
        var updated = syncSettings
        updated.folderTarget = nil
        persist(updated)
    }

    func markBackupCompleted(at date: Date = Date()) {
        guard var target = syncSettings.folderTarget else { return }
        target.lastSnapshotAt = date
        var updated = syncSettings
        updated.folderTarget = target
        persist(updated)
    }

    func saveServerTarget(baseURLString: String, namespace: String, authToken: String) throws {
        let trimmedToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let authMode: ServerAuthMode = trimmedToken.isEmpty ? .none : .bearer
        let configuration = ServerSnapshotClient.Configuration(
            baseURLString: baseURLString,
            namespace: namespace,
            authMode: authMode,
            bearerToken: trimmedToken
        )
        let normalizedBaseURL = try configuration.normalizedBaseURL().absoluteString
        let normalizedNamespace = try configuration.normalizedNamespace()

        if trimmedToken.isEmpty {
            KeychainStore.delete(
                account: SyncSettings.serverTokenAccount,
                service: Self.syncCredentialService
            )
        } else {
            try KeychainStore.save(
                trimmedToken,
                account: SyncSettings.serverTokenAccount,
                service: Self.syncCredentialService
            )
        }

        let previous = syncSettings.serverTarget
        var updated = syncSettings
        updated.serverTarget = .init(
            baseURLString: normalizedBaseURL,
            namespace: normalizedNamespace,
            authMode: authMode,
            lastSnapshotAt: previous?.lastSnapshotAt,
            lastValidatedAt: previous?.lastValidatedAt,
            liveCursor: previous?.liveCursor,
            lastLivePullAt: previous?.lastLivePullAt,
            lastLivePushAt: previous?.lastLivePushAt,
            autoSyncEnabled: previous?.autoSyncEnabled ?? false,
            autoSyncIntervalSeconds: previous?.clampedAutoSyncIntervalSeconds ?? 120,
            lastAutoSyncAt: previous?.lastAutoSyncAt,
            lastAutoSyncFingerprint: previous?.lastAutoSyncFingerprint
        )
        persist(updated)
        refreshLiveSyncStatusesSoon()
    }

    func clearServerTarget() {
        KeychainStore.delete(
            account: SyncSettings.serverTokenAccount,
            service: Self.syncCredentialService
        )
        var updated = syncSettings
        updated.serverTarget = nil
        persist(updated)
        refreshLiveSyncStatusesSoon()
    }

    func markServerValidated(at date: Date = Date()) {
        guard var target = syncSettings.serverTarget else { return }
        target.lastValidatedAt = date
        var updated = syncSettings
        updated.serverTarget = target
        persist(updated)
        refreshLiveSyncStatusesSoon()
    }

    func markServerBackupCompleted(at date: Date = Date()) {
        guard var target = syncSettings.serverTarget else { return }
        target.lastSnapshotAt = date
        var updated = syncSettings
        updated.serverTarget = target
        persist(updated)
    }

    func markServerLivePullCompleted(cursor: LiveSyncCursor?, at date: Date = Date()) {
        guard var target = syncSettings.serverTarget else { return }
        target.liveCursor = cursor
        target.lastLivePullAt = date
        var updated = syncSettings
        updated.serverTarget = target
        persist(updated)
    }

    func markServerLivePushCompleted(cursor: LiveSyncCursor?, at date: Date = Date()) {
        guard var target = syncSettings.serverTarget else { return }
        target.liveCursor = cursor ?? target.liveCursor
        target.lastLivePushAt = date
        var updated = syncSettings
        updated.serverTarget = target
        persist(updated)
    }

    func resetServerLiveCursor() {
        guard var target = syncSettings.serverTarget else { return }
        target.liveCursor = nil
        var updated = syncSettings
        updated.serverTarget = target
        persist(updated)
    }

    func setServerAutoSyncEnabled(_ enabled: Bool) {
        guard var target = syncSettings.serverTarget else { return }
        target.autoSyncEnabled = enabled
        var updated = syncSettings
        updated.serverTarget = target
        persist(updated)
        refreshAutoSyncRuntime()
        restartAutoSyncLoopIfNeeded()
    }

    func setServerAutoSyncIntervalSeconds(_ seconds: Int) {
        guard var target = syncSettings.serverTarget else { return }
        target.autoSyncIntervalSeconds = min(max(seconds, 30), 3600)
        var updated = syncSettings
        updated.serverTarget = target
        persist(updated)
        refreshAutoSyncRuntime()
        restartAutoSyncLoopIfNeeded()
    }

    func makeServerSnapshotClient() throws -> ServerSnapshotClient {
        guard let target = syncSettings.serverTarget else {
            throw ServerSnapshotClientError.providerError("先保存一个 Empty Cloud / 自建 Server 目标。")
        }
        return ServerSnapshotClient(
            configuration: .init(
                baseURLString: target.baseURLString,
                namespace: target.namespace,
                authMode: target.authMode,
                bearerToken: serverAuthToken
            )
        )
    }

    func makeServerLiveSyncClient() throws -> ServerLiveSyncClient {
        guard let target = syncSettings.serverTarget else {
            throw ServerLiveSyncClientError.providerError("先保存一个 Empty Cloud / 自建 Server 目标。")
        }
        return ServerLiveSyncClient(
            configuration: .init(
                baseURLString: target.baseURLString,
                namespace: target.namespace,
                authMode: target.authMode,
                bearerToken: serverAuthToken
            )
        )
    }

    func makeServerSyncCoordinator() throws -> ServerSyncCoordinator {
        try ServerSyncCoordinator(client: makeServerLiveSyncClient())
    }

    func runAutomaticServerSync(force: Bool, trigger: String) async throws -> String? {
        guard !isEphemeral else { return nil }
        guard var target = syncSettings.serverTarget else { return nil }
        guard force || target.autoSyncEnabled else { return nil }

        let status: LiveSyncProviderStatus
        if let currentServerStatus {
            status = currentServerStatus
        } else {
            status = await probeServerLiveStatus()
        }
        guard status.state == .contractReady else {
            if force {
                throw ServerLiveSyncClientError.unsupported
            }
            return nil
        }

        autoSyncRuntime.isEnabled = target.autoSyncEnabled
        autoSyncRuntime.isRunning = true
        autoSyncRuntime.lastTrigger = trigger
        autoSyncRuntime.lastError = nil
        defer {
            autoSyncRuntime.isRunning = false
        }

        let coordinator = try makeServerSyncCoordinator()
        let pullSummary = try await coordinator.pull(
            into: container.mainContext,
            cursor: target.liveCursor,
            forceFullSnapshot: target.liveCursor == nil
        )
        markServerLivePullCompleted(cursor: pullSummary.cursor, at: pullSummary.pulledAt)
        target = syncSettings.serverTarget ?? target

        let snapshot = try SyncSnapshot.capture(from: container.mainContext)
        let fingerprint = try snapshot.stableFingerprint()
        let shouldPush = force || target.lastAutoSyncFingerprint != fingerprint

        if shouldPush {
            let pushSummary = try await coordinator.push(
                from: container.mainContext,
                baseCursor: pullSummary.cursor
            )
            markServerLivePushCompleted(cursor: pushSummary.cursor, at: pushSummary.pushedAt)
        }

        guard var refreshedTarget = syncSettings.serverTarget else {
            return nil
        }
        refreshedTarget.lastAutoSyncAt = Date()
        if shouldPush {
            refreshedTarget.lastAutoSyncFingerprint = fingerprint
        }
        var updated = syncSettings
        updated.serverTarget = refreshedTarget
        persist(updated)

        autoSyncRuntime.lastSyncedAt = refreshedTarget.lastAutoSyncAt
        autoSyncRuntime.lastFingerprintPrefix = refreshedTarget.shortFingerprint
        let action = shouldPush ? "pull + push" : "pull only"
        return "自动同步完成（\(action)）。"
    }

    private var currentServerStatus: LiveSyncProviderStatus? {
        liveSyncStatuses.first { $0.kind == .server }
    }

    private func probeServerLiveStatus() async -> LiveSyncProviderStatus {
        await ServerLiveSyncProvider(
            target: syncSettings.serverTarget,
            bearerToken: serverAuthToken
        ).status(selectedMode: effectiveLiveMode)
    }

    private func makeLiveSyncProviders() -> [any LiveSyncProvider] {
        [
            CloudKitLiveSyncProvider(isEphemeral: isEphemeral),
            ServerLiveSyncProvider(
                target: syncSettings.serverTarget,
                bearerToken: serverAuthToken
            ),
        ]
    }

    private func restartAutoSyncLoopIfNeeded() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        refreshAutoSyncRuntime()
        guard shouldRunAutoSyncLoop else { return }
        autoSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.runAutomaticServerSync(force: false, trigger: "enabled")
            } catch {
                self.autoSyncRuntime.lastError = error.localizedDescription
            }
            while !Task.isCancelled {
                let interval = UInt64(self.serverAutoSyncIntervalSeconds) * 1_000_000_000
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled || !self.shouldRunAutoSyncLoop { return }
                do {
                    _ = try await self.runAutomaticServerSync(force: false, trigger: "timer")
                } catch {
                    self.autoSyncRuntime.lastError = error.localizedDescription
                }
            }
        }
    }

    private var shouldRunAutoSyncLoop: Bool {
        guard !isEphemeral,
              currentScenePhase == .active,
              serverAutoSyncEnabled,
              currentServerStatus?.state == .contractReady else {
            return false
        }
        return true
    }

    private func refreshLiveSyncStatusesSoon() {
        Task { @MainActor in
            await refreshLiveSyncStatuses()
        }
    }

    private func refreshAutoSyncRuntime() {
        autoSyncRuntime.isEnabled = syncSettings.serverTarget?.autoSyncEnabled ?? false
        autoSyncRuntime.lastSyncedAt = syncSettings.serverTarget?.lastAutoSyncAt
        autoSyncRuntime.lastFingerprintPrefix = syncSettings.serverTarget?.shortFingerprint
        if autoSyncRuntime.isEnabled == false {
            autoSyncRuntime.lastTrigger = nil
        }
    }

    private func persist(_ settings: SyncSettings) {
        settings.save()
        syncSettings = settings
        refreshAutoSyncRuntime()
    }
}
