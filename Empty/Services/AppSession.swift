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

    let isEphemeral: Bool

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
        Task { @MainActor in
            await refreshLiveSyncStatuses()
        }
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

    func refreshLiveSyncStatuses() async {
        isRefreshingLiveSyncStatuses = true
        defer { isRefreshingLiveSyncStatuses = false }

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
            lastLivePushAt: previous?.lastLivePushAt
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

    private func makeLiveSyncProviders() -> [any LiveSyncProvider] {
        [
            CloudKitLiveSyncProvider(isEphemeral: isEphemeral),
            ServerLiveSyncProvider(
                target: syncSettings.serverTarget,
                bearerToken: serverAuthToken
            ),
        ]
    }

    private func refreshLiveSyncStatusesSoon() {
        Task { @MainActor in
            await refreshLiveSyncStatuses()
        }
    }

    private func persist(_ settings: SyncSettings) {
        settings.save()
        syncSettings = settings
    }
}
