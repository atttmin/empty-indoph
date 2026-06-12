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
    private let mutationJournalStore = SyncMutationJournalStore()
    private let backgroundSyncScheduler = ServerBackgroundSyncScheduler()

    init(isEphemeral override: Bool? = nil) {
        let process = ProcessInfo.processInfo
        let inferredEphemeral =
            process.environment["XCTestConfigurationFilePath"] != nil
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
        backgroundSyncScheduler.installAction { [weak self] in
            guard let self else { return }
            await self.runScheduledBackgroundServerSync()
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

    var manualServerBearerToken: String {
        KeychainStore.read(
            account: SyncSettings.serverTokenAccount,
            service: Self.syncCredentialService
        ) ?? ""
    }

    var currentServerPasskeySession: ServerPasskeySession? {
        guard let target = syncSettings.serverTarget,
              target.authMode == .passkeySession,
              let accountID = target.accountID,
              let displayName = target.accountDisplayName
        else {
            return nil
        }
        return ServerPasskeySession(
            accountID: accountID,
            displayName: displayName,
            email: target.accountEmail,
            issuedAt: target.accountSignedInAt,
            expiresAt: target.accountSessionExpiresAt
        )
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

    var syncUsageSummary: SyncUsageSummary {
        SyncUsageSummaryBuilder.make(
            liveMode: effectiveLiveMode,
            folderTarget: syncSettings.folderTarget,
            serverTarget: syncSettings.serverTarget,
            cloudStatus: liveSyncStatuses.first { $0.kind == .cloudKit },
            serverStatus: liveSyncStatuses.first { $0.kind == .server },
            pendingServerChanges: autoSyncRuntime.pendingChangeCount,
            pendingServerRetryAt: autoSyncRuntime.nextRetryAt,
            backgroundScheduledAt: autoSyncRuntime.backgroundScheduledAt
        )
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
                refreshBackgroundSyncSchedule()
            }
        }
    }

    func runScheduledBackgroundServerSync() async {
        guard currentScenePhase != .active else { return }
        do {
            _ = try await runAutomaticServerSync(force: false, trigger: "background-scheduler")
        } catch {
            autoSyncRuntime.lastError = error.localizedDescription
        }
        refreshBackgroundSyncSchedule()
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

    func refreshServerPendingMutations() {
        guard let target = syncSettings.serverTarget else {
            autoSyncRuntime.pendingUpsertCount = 0
            autoSyncRuntime.pendingTombstoneCount = 0
            return
        }
        do {
            let summary = try currentServerMutationSummary(target: target)
            autoSyncRuntime.pendingUpsertCount = summary.upsertCount
            autoSyncRuntime.pendingTombstoneCount = summary.tombstoneCount
        } catch {
            autoSyncRuntime.pendingUpsertCount = 0
            autoSyncRuntime.pendingTombstoneCount = 0
        }
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
        let provisionalConfiguration = ServerSnapshotClient.Configuration(
            baseURLString: baseURLString,
            namespace: namespace,
            authMode: .none,
            bearerToken: ""
        )
        let normalizedBaseURL = try provisionalConfiguration.normalizedBaseURL().absoluteString
        let normalizedNamespace = try provisionalConfiguration.normalizedNamespace()

        let previous = syncSettings.serverTarget
        let identityChanged =
            previous?.baseURLString != normalizedBaseURL
            || previous?.namespace != normalizedNamespace
        let previousSessionToken = previous.flatMap(serverSessionToken(for:)) ?? ""
        let keepPasskeySession =
            trimmedToken.isEmpty
            && !identityChanged
            && previous?.authMode == .passkeySession
            && !previousSessionToken.isEmpty
        let authMode: ServerAuthMode
        if !trimmedToken.isEmpty {
            authMode = .bearer
        } else if keepPasskeySession {
            authMode = .passkeySession
        } else {
            authMode = .none
        }

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

        let shouldClearPreviousSession =
            previous != nil
            && (identityChanged || authMode != .passkeySession)
        if shouldClearPreviousSession, let previous {
            KeychainStore.delete(
                account: serverSessionAccount(for: previous),
                service: Self.syncCredentialService
            )
        }

        let nextTarget = SyncSettings.ServerBackupTarget(
            baseURLString: normalizedBaseURL,
            namespace: normalizedNamespace,
            authMode: authMode,
            accountID: keepPasskeySession ? previous?.accountID : nil,
            accountDisplayName: keepPasskeySession ? previous?.accountDisplayName : nil,
            accountEmail: keepPasskeySession ? previous?.accountEmail : nil,
            accountSignedInAt: keepPasskeySession ? previous?.accountSignedInAt : nil,
            accountSessionExpiresAt: keepPasskeySession ? previous?.accountSessionExpiresAt : nil,
            lastSnapshotAt: identityChanged ? nil : previous?.lastSnapshotAt,
            lastValidatedAt: identityChanged ? nil : previous?.lastValidatedAt,
            liveCursor: identityChanged ? nil : previous?.liveCursor,
            lastLivePullAt: identityChanged ? nil : previous?.lastLivePullAt,
            lastLivePushAt: identityChanged ? nil : previous?.lastLivePushAt,
            autoSyncEnabled: previous?.autoSyncEnabled ?? false,
            autoSyncIntervalSeconds: previous?.clampedAutoSyncIntervalSeconds ?? 120,
            conflictPolicy: previous?.conflictPolicy ?? .keepLocal,
            lastConflictResolvedAt: identityChanged ? nil : previous?.lastConflictResolvedAt,
            lastConflictCount: identityChanged ? 0 : previous?.lastConflictCount ?? 0,
            lastConflictPolicy: identityChanged ? nil : previous?.lastConflictPolicy,
            lastAutoSyncAt: identityChanged ? nil : previous?.lastAutoSyncAt,
            lastAutoSyncFingerprint: identityChanged ? nil : previous?.lastAutoSyncFingerprint,
            consecutiveAutoSyncFailures: identityChanged ? 0 : previous?.consecutiveAutoSyncFailures ?? 0,
            nextAutoRetryAt: identityChanged ? nil : previous?.nextAutoRetryAt,
            lastAutoSyncError: identityChanged ? nil : previous?.lastAutoSyncError
        )

        if identityChanged {
            if let previous {
                try? mutationJournalStore.clear(for: previous)
            }
            try? mutationJournalStore.clear(for: nextTarget)
        }

        var updated = syncSettings
        updated.serverTarget = nextTarget
        persist(updated)
        refreshLiveSyncStatusesSoon()
        restartAutoSyncLoopIfNeeded()
        refreshServerPendingMutations()
    }

    func clearServerTarget() {
        let previous = syncSettings.serverTarget
        KeychainStore.delete(
            account: SyncSettings.serverTokenAccount,
            service: Self.syncCredentialService
        )
        if let previous {
            KeychainStore.delete(
                account: serverSessionAccount(for: previous),
                service: Self.syncCredentialService
            )
            try? mutationJournalStore.clear(for: previous)
        }
        var updated = syncSettings
        updated.serverTarget = nil
        persist(updated)
        refreshLiveSyncStatusesSoon()
        restartAutoSyncLoopIfNeeded()
        refreshServerPendingMutations()
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
        target.lastAutoSyncFingerprint = nil
        target.consecutiveAutoSyncFailures = 0
        target.nextAutoRetryAt = nil
        target.lastAutoSyncError = nil
        var updated = syncSettings
        updated.serverTarget = target
        persist(updated)
        try? mutationJournalStore.clear(for: target)
        restartAutoSyncLoopIfNeeded()
        refreshServerPendingMutations()
    }

    func setServerAutoSyncEnabled(_ enabled: Bool) {
        guard var target = syncSettings.serverTarget else { return }
        target.autoSyncEnabled = enabled
        if !enabled {
            target.consecutiveAutoSyncFailures = 0
            target.nextAutoRetryAt = nil
            target.lastAutoSyncError = nil
        }
        var updated = syncSettings
        updated.serverTarget = target
        persist(updated)
        restartAutoSyncLoopIfNeeded()
    }

    func setServerAutoSyncIntervalSeconds(_ seconds: Int) {
        guard var target = syncSettings.serverTarget else { return }
        target.autoSyncIntervalSeconds = min(max(seconds, 30), 3600)
        var updated = syncSettings
        updated.serverTarget = target
        persist(updated)
        restartAutoSyncLoopIfNeeded()
    }

    func setServerConflictPolicy(_ policy: ServerSyncConflictPolicy) {
        guard var target = syncSettings.serverTarget else { return }
        target.conflictPolicy = policy
        var updated = syncSettings
        updated.serverTarget = target
        persist(updated)
    }

    private func markServerConflictResolved(_ summary: ServerSyncConflictSummary) {
        guard var target = syncSettings.serverTarget else { return }
        target.lastConflictResolvedAt = summary.resolvedAt
        target.lastConflictCount = summary.conflictCount
        target.lastConflictPolicy = summary.policy
        var updated = syncSettings
        updated.serverTarget = target
        persist(updated)
    }

    private func clearServerConflictResolved() {
        guard var target = syncSettings.serverTarget else { return }
        target.lastConflictResolvedAt = nil
        target.lastConflictCount = 0
        target.lastConflictPolicy = nil
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
                bearerToken: effectiveServerAuthorizationToken(for: target)
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
                bearerToken: effectiveServerAuthorizationToken(for: target)
            )
        )
    }

    func makeServerPasskeyClient(authMode: ServerAuthMode = .none) throws -> ServerPasskeyClient {
        guard let target = syncSettings.serverTarget else {
            throw ServerPasskeyClientError.providerError("先保存一个 Empty Cloud / 自建 Server 目标。")
        }
        return ServerPasskeyClient(
            configuration: .init(
                baseURLString: target.baseURLString,
                namespace: target.namespace,
                authMode: authMode,
                bearerToken: authMode == .passkeySession ? serverSessionToken(for: target) : ""
            )
        )
    }

    func makeServerSyncCoordinator() throws -> ServerSyncCoordinator {
        try ServerSyncCoordinator(client: makeServerLiveSyncClient())
    }

    func registerServerPasskeyAccount(displayName: String?) async throws -> ServerPasskeySession {
        let status: LiveSyncProviderStatus
        if let currentServerStatus {
            status = currentServerStatus
        } else {
            status = await probeServerLiveStatus()
        }
        guard status.features.contains(ServerPasskeyFeature.authV1.rawValue) else {
            throw ServerPasskeyClientError.unsupported
        }
        guard let target = syncSettings.serverTarget else {
            throw ServerPasskeyClientError.providerError("先保存一个 Empty Cloud / 自建 Server 目标。")
        }
        let client = try makeServerPasskeyClient(authMode: .none)
        let options = try await client.beginRegistration(displayName: displayName)
        let finish = try await PlatformPasskeyCoordinator().register(options: options)
        let result = try await client.completeRegistration(finish)
        try persistServerPasskeySession(result, for: target)
        refreshLiveSyncStatusesSoon()
        return result.session
    }

    func signInServerPasskeyAccount() async throws -> ServerPasskeySession {
        let status: LiveSyncProviderStatus
        if let currentServerStatus {
            status = currentServerStatus
        } else {
            status = await probeServerLiveStatus()
        }
        guard status.features.contains(ServerPasskeyFeature.authV1.rawValue) else {
            throw ServerPasskeyClientError.unsupported
        }
        guard let target = syncSettings.serverTarget else {
            throw ServerPasskeyClientError.providerError("先保存一个 Empty Cloud / 自建 Server 目标。")
        }
        let client = try makeServerPasskeyClient(authMode: .none)
        let options = try await client.beginAuthentication()
        let finish = try await PlatformPasskeyCoordinator().authenticate(options: options)
        let result = try await client.completeAuthentication(finish)
        try persistServerPasskeySession(result, for: target)
        refreshLiveSyncStatusesSoon()
        return result.session
    }

    func refreshServerPasskeySession() async throws -> ServerPasskeySession? {
        guard let target = syncSettings.serverTarget else { return nil }
        guard target.authMode == .passkeySession else { return nil }
        let client = try makeServerPasskeyClient(authMode: .passkeySession)
        let session = try await client.fetchSession()
        if let session {
            try persistServerPasskeySession(.init(sessionToken: serverSessionToken(for: target), session: session), for: target)
        } else {
            clearStoredServerPasskeySession(for: target, preserveTarget: true)
        }
        return session
    }

    func signOutServerPasskeyAccount() async throws {
        guard let target = syncSettings.serverTarget else { return }
        if target.authMode == .passkeySession {
            let client = try makeServerPasskeyClient(authMode: .passkeySession)
            try await client.signOut()
        }
        clearStoredServerPasskeySession(for: target, preserveTarget: true)
        refreshLiveSyncStatusesSoon()
    }
    func performServerLivePull(forceFullSnapshot: Bool = false) async throws -> ServerSyncPullSummary {
        guard let target = syncSettings.serverTarget else {
            throw ServerLiveSyncClientError.providerError("先保存一个 Empty Cloud / 自建 Server 目标。")
        }
        let summary = try await makeServerSyncCoordinator().pull(
            into: container.mainContext,
            cursor: target.liveCursor,
            forceFullSnapshot: forceFullSnapshot || target.liveCursor == nil
        )
        markServerLivePullCompleted(cursor: summary.cursor, at: summary.pulledAt)
        let activeTarget = syncSettings.serverTarget ?? target
        let pulledSnapshot = try SyncSnapshot.capture(from: container.mainContext)
        try persistServerMutationBaseline(pulledSnapshot, for: activeTarget)
        try updateServerAutoSyncFingerprint(using: pulledSnapshot)
        refreshServerPendingMutations()
        return summary
    }

    func performServerLivePush(forceFullSnapshot: Bool = false) async throws -> ServerSyncPushSummary {
        guard let target = syncSettings.serverTarget else {
            throw ServerLiveSyncClientError.providerError("先保存一个 Empty Cloud / 自建 Server 目标。")
        }
        let currentSnapshot = try SyncSnapshot.capture(from: container.mainContext)
        let delta: ReaderLiveSyncDelta
        if forceFullSnapshot {
            delta = .bootstrap(from: currentSnapshot)
        } else if let journal = try loadServerMutationJournal(for: target) {
            delta = journal.makeDelta(to: currentSnapshot)
        } else {
            delta = .bootstrap(from: currentSnapshot)
        }

        guard forceFullSnapshot || delta.hasChanges else {
            refreshServerPendingMutations()
            return ServerSyncPushSummary(
                pushedRecordCount: 0,
                tombstoneCount: 0,
                cursor: target.liveCursor,
                pushedAt: currentSnapshot.exportedAt,
                wasFullSnapshot: false
            )
        }

        let summary = try await makeServerSyncCoordinator().push(delta: delta, baseCursor: target.liveCursor)
        markServerLivePushCompleted(cursor: summary.cursor, at: summary.pushedAt)
        let activeTarget = syncSettings.serverTarget ?? target
        try persistServerMutationBaseline(currentSnapshot, for: activeTarget)
        try updateServerAutoSyncFingerprint(using: currentSnapshot)
        refreshServerPendingMutations()
        return summary
    }

    func performServerLiveSync(forcePush: Bool = false) async throws -> ServerSyncRoundTripSummary {
        guard let target = syncSettings.serverTarget else {
            throw ServerLiveSyncClientError.providerError("先保存一个 Empty Cloud / 自建 Server 目标。")
        }

        let localSnapshot = try SyncSnapshot.capture(from: container.mainContext)
        let localPendingDelta: ReaderLiveSyncDelta
        if let journal = try loadServerMutationJournal(for: target) {
            localPendingDelta = journal.makeDelta(to: localSnapshot)
        } else {
            localPendingDelta = .bootstrap(from: localSnapshot)
        }

        let pullSummary = try await makeServerSyncCoordinator().pull(
            into: container.mainContext,
            cursor: target.liveCursor,
            forceFullSnapshot: target.liveCursor == nil
        )
        markServerLivePullCompleted(cursor: pullSummary.cursor, at: pullSummary.pulledAt)
        let activeTarget = syncSettings.serverTarget ?? target
        let pulledSnapshot = try SyncSnapshot.capture(from: container.mainContext)
        try persistServerMutationBaseline(pulledSnapshot, for: activeTarget)

        let remoteAppliedDelta = SyncMutationJournal(baselineSnapshot: localSnapshot, savedAt: pullSummary.pulledAt)
            .makeDelta(to: pulledSnapshot)
        let resolution = ServerSyncConflictResolver.resolve(
            localDelta: localPendingDelta,
            remoteDelta: remoteAppliedDelta,
            policy: target.conflictPolicy,
            resolvedAt: pullSummary.pulledAt
        )
        if let summary = resolution.summary {
            markServerConflictResolved(summary)
        } else {
            clearServerConflictResolved()
        }

        if resolution.deltaToApplyLocally.hasChanges {
            try resolution.deltaToApplyLocally.merge(into: container.mainContext)
        }

        let reconciledSnapshot = resolution.deltaToApplyLocally.hasChanges
            ? try SyncSnapshot.capture(from: container.mainContext)
            : pulledSnapshot
        let deltaToPush: ReaderLiveSyncDelta?
        if forcePush {
            deltaToPush = .bootstrap(from: reconciledSnapshot)
        } else if resolution.deltaToPush.hasChanges {
            deltaToPush = resolution.deltaToPush
        } else {
            deltaToPush = nil
        }

        let pushSummary: ServerSyncPushSummary
        if let deltaToPush, forcePush || deltaToPush.hasChanges {
            pushSummary = try await makeServerSyncCoordinator().push(delta: deltaToPush, baseCursor: pullSummary.cursor)
            markServerLivePushCompleted(cursor: pushSummary.cursor, at: pushSummary.pushedAt)
            let latestTarget = syncSettings.serverTarget ?? activeTarget
            try persistServerMutationBaseline(reconciledSnapshot, for: latestTarget)
            try updateServerAutoSyncFingerprint(using: reconciledSnapshot)
        } else {
            pushSummary = ServerSyncPushSummary(
                pushedRecordCount: 0,
                tombstoneCount: 0,
                cursor: pullSummary.cursor,
                pushedAt: reconciledSnapshot.exportedAt,
                wasFullSnapshot: false
            )
            try updateServerAutoSyncFingerprint(using: pulledSnapshot)
        }

        refreshServerPendingMutations()
        return ServerSyncRoundTripSummary(
            pull: pullSummary,
            push: pushSummary,
            conflict: resolution.summary
        )
    }

    func runAutomaticServerSync(force: Bool, trigger: String) async throws -> String? {
        guard !isEphemeral else { return nil }
        guard let target = syncSettings.serverTarget else { return nil }
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

        do {
            let summary = try await performServerLiveSync(forcePush: force)
            let syncedAt = summary.push.changeCount > 0 ? summary.push.pushedAt : summary.pull.pulledAt
            markServerAutoSyncSucceeded(at: syncedAt)

            guard let refreshedTarget = syncSettings.serverTarget else {
                return nil
            }
            autoSyncRuntime.lastSyncedAt = refreshedTarget.lastAutoSyncAt
            autoSyncRuntime.lastFingerprintPrefix = refreshedTarget.shortFingerprint
            let action = summary.push.changeCount > 0 || (force && summary.push.wasFullSnapshot) ? "pull + push" : "pull only"
            let conflictSuffix = summary.conflict.map { "；\($0.conflictCount) 处冲突按\($0.policy.shortLabel)处理" } ?? ""
            return "自动同步完成（\(action)\(conflictSuffix)）。"
        } catch {
            if syncSettings.serverTarget?.autoSyncEnabled == true {
                markServerAutoSyncFailed(error)
            } else {
                autoSyncRuntime.lastError = error.localizedDescription
            }
            throw error
        }
    }

    private var currentServerStatus: LiveSyncProviderStatus? {
        liveSyncStatuses.first { $0.kind == .server }
    }

    var serverSupportsPasskeyAuth: Bool {
        currentServerStatus?.features.contains(ServerPasskeyFeature.authV1.rawValue) == true
    }

    private func probeServerLiveStatus() async -> LiveSyncProviderStatus {
        await ServerLiveSyncProvider(
            target: syncSettings.serverTarget,
            bearerToken: syncSettings.serverTarget.map { effectiveServerAuthorizationToken(for: $0) } ?? ""
        ).status(selectedMode: effectiveLiveMode)
    }

    private func makeLiveSyncProviders() -> [any LiveSyncProvider] {
        [
            CloudKitLiveSyncProvider(isEphemeral: isEphemeral),
            ServerLiveSyncProvider(
                target: syncSettings.serverTarget,
                bearerToken: syncSettings.serverTarget.map { effectiveServerAuthorizationToken(for: $0) } ?? ""
            ),
        ]
    }

    private func restartAutoSyncLoopIfNeeded() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        refreshAutoSyncRuntime()
        refreshBackgroundSyncSchedule()
        guard shouldRunAutoSyncLoop else { return }
        autoSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.shouldAttemptAutoSyncNow() {
                do {
                    _ = try await self.runAutomaticServerSync(force: false, trigger: "enabled")
                } catch {
                    self.autoSyncRuntime.lastError = error.localizedDescription
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.nextAutoSyncDelayNanoseconds())
                if Task.isCancelled || !self.shouldRunAutoSyncLoop { return }
                guard self.shouldAttemptAutoSyncNow() else { continue }
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
            currentServerStatus?.state == .contractReady
        else {
            return false
        }
        return true
    }

    private func shouldAttemptAutoSyncNow(at now: Date = Date()) -> Bool {
        guard shouldRunAutoSyncLoop else { return false }
        guard let retryAt = syncSettings.serverTarget?.nextAutoRetryAt else {
            return true
        }
        return retryAt <= now
    }

    private func nextAutoSyncDelayNanoseconds(now: Date = Date()) -> UInt64 {
        if let retryAt = syncSettings.serverTarget?.nextAutoRetryAt {
            let seconds = max(1, ceil(retryAt.timeIntervalSince(now)))
            return UInt64(seconds * 1_000_000_000)
        }
        return UInt64(max(serverAutoSyncIntervalSeconds, 1)) * 1_000_000_000
    }

    private func refreshLiveSyncStatusesSoon() {
        Task { @MainActor in
            await refreshLiveSyncStatuses()
        }
    }

    private func refreshBackgroundSyncSchedule(now: Date = Date()) {
        guard let plan = ServerBackgroundSyncPlanner.makePlan(
            isEphemeral: isEphemeral,
            autoSyncEnabled: serverAutoSyncEnabled,
            isContractReady: currentServerStatus?.state == .contractReady,
            retryAt: syncSettings.serverTarget?.nextAutoRetryAt,
            lastAutoSyncAt: syncSettings.serverTarget?.lastAutoSyncAt,
            intervalSeconds: serverAutoSyncIntervalSeconds,
            now: now
        ) else {
            autoSyncRuntime.backgroundScheduledAt = nil
            autoSyncRuntime.backgroundTrigger = nil
            backgroundSyncScheduler.cancel()
            return
        }
        autoSyncRuntime.backgroundScheduledAt = plan.earliestBeginDate
        autoSyncRuntime.backgroundTrigger = plan.trigger
        backgroundSyncScheduler.schedule(plan)
    }

    private func serverSessionAccount(for target: SyncSettings.ServerBackupTarget) -> String {
        "sync.server.session|\(target.baseURLString)|\(target.namespace)"
    }

    private func serverSessionToken(for target: SyncSettings.ServerBackupTarget) -> String {
        KeychainStore.read(
            account: serverSessionAccount(for: target),
            service: Self.syncCredentialService
        ) ?? ""
    }

    private func effectiveServerAuthorizationToken(for target: SyncSettings.ServerBackupTarget) -> String {
        switch target.authMode {
        case .none:
            ""
        case .bearer:
            manualServerBearerToken
        case .passkeySession:
            serverSessionToken(for: target)
        }
    }

    private func persistServerPasskeySession(_ result: ServerPasskeyAuthResult, for target: SyncSettings.ServerBackupTarget) throws {
        try KeychainStore.save(
            result.sessionToken,
            account: serverSessionAccount(for: target),
            service: Self.syncCredentialService
        )
        guard var current = syncSettings.serverTarget,
              current.baseURLString == target.baseURLString,
              current.namespace == target.namespace
        else {
            return
        }
        current.authMode = .passkeySession
        current.accountID = result.session.accountID
        current.accountDisplayName = result.session.displayName
        current.accountEmail = result.session.email
        current.accountSignedInAt = result.session.issuedAt ?? Date()
        current.accountSessionExpiresAt = result.session.expiresAt
        current.lastAutoSyncError = nil
        current.nextAutoRetryAt = nil
        current.consecutiveAutoSyncFailures = 0
        var updated = syncSettings
        updated.serverTarget = current
        persist(updated)
        restartAutoSyncLoopIfNeeded()
    }

    private func clearStoredServerPasskeySession(for target: SyncSettings.ServerBackupTarget, preserveTarget: Bool) {
        KeychainStore.delete(
            account: serverSessionAccount(for: target),
            service: Self.syncCredentialService
        )
        guard preserveTarget,
              var current = syncSettings.serverTarget,
              current.baseURLString == target.baseURLString,
              current.namespace == target.namespace
        else {
            return
        }
        current.authMode = manualServerBearerToken.isEmpty ? .none : .bearer
        current.accountID = nil
        current.accountDisplayName = nil
        current.accountEmail = nil
        current.accountSignedInAt = nil
        current.accountSessionExpiresAt = nil
        current.lastAutoSyncError = nil
        current.nextAutoRetryAt = nil
        current.consecutiveAutoSyncFailures = 0
        if manualServerBearerToken.isEmpty {
            current.autoSyncEnabled = false
        }
        var updated = syncSettings
        updated.serverTarget = current
        persist(updated)
        restartAutoSyncLoopIfNeeded()
    }

    private func loadServerMutationJournal(for target: SyncSettings.ServerBackupTarget) throws -> SyncMutationJournal? {
        if let journal = try mutationJournalStore.load(for: target) {
            return journal
        }
        guard target.liveCursor != nil else {
            return nil
        }
        let migrated = SyncMutationJournal(baselineSnapshot: try SyncSnapshot.capture(from: container.mainContext))
        try mutationJournalStore.save(migrated, for: target)
        return migrated
    }

    private func persistServerMutationBaseline(_ snapshot: SyncSnapshot, for target: SyncSettings.ServerBackupTarget) throws {
        try mutationJournalStore.save(
            SyncMutationJournal(baselineSnapshot: snapshot, savedAt: Date()),
            for: target
        )
    }

    private func markServerAutoSyncSucceeded(at date: Date) {
        guard var target = syncSettings.serverTarget else { return }
        target.lastAutoSyncAt = date
        target.consecutiveAutoSyncFailures = 0
        target.nextAutoRetryAt = nil
        target.lastAutoSyncError = nil
        var updated = syncSettings
        updated.serverTarget = target
        persist(updated)
        refreshAutoSyncRuntime()
        refreshBackgroundSyncSchedule(now: date)
    }

    private func markServerAutoSyncFailed(_ error: Error, at date: Date = Date()) {
        guard var target = syncSettings.serverTarget else {
            autoSyncRuntime.lastError = error.localizedDescription
            return
        }
        let nextFailureCount = target.autoSyncEnabled ? (target.consecutiveAutoSyncFailures + 1) : 0
        target.consecutiveAutoSyncFailures = nextFailureCount
        target.nextAutoRetryAt = target.autoSyncEnabled
            ? ServerSyncRetryPolicy.nextRetryDate(afterFailure: nextFailureCount, now: date)
            : nil
        target.lastAutoSyncError = error.localizedDescription
        var updated = syncSettings
        updated.serverTarget = target
        persist(updated)
        refreshAutoSyncRuntime()
        refreshBackgroundSyncSchedule(now: date)
    }

    private func updateServerAutoSyncFingerprint(using snapshot: SyncSnapshot) throws {
        guard var target = syncSettings.serverTarget else { return }
        target.lastAutoSyncFingerprint = try snapshot.stableFingerprint()
        var updated = syncSettings
        updated.serverTarget = target
        persist(updated)
    }

    private func currentServerMutationSummary(target: SyncSettings.ServerBackupTarget) throws -> SyncMutationSummary {
        let snapshot = try SyncSnapshot.capture(from: container.mainContext)
        if let journal = try loadServerMutationJournal(for: target) {
            return journal.pendingSummary(for: snapshot)
        }
        return SyncMutationSummary.bootstrap(from: snapshot)
    }

    private func refreshAutoSyncRuntime() {
        autoSyncRuntime.isEnabled = syncSettings.serverTarget?.autoSyncEnabled ?? false
        autoSyncRuntime.lastSyncedAt = syncSettings.serverTarget?.lastAutoSyncAt
        autoSyncRuntime.lastFingerprintPrefix = syncSettings.serverTarget?.shortFingerprint
        autoSyncRuntime.lastError = syncSettings.serverTarget?.lastAutoSyncError
        autoSyncRuntime.consecutiveFailureCount = syncSettings.serverTarget?.consecutiveAutoSyncFailures ?? 0
        autoSyncRuntime.nextRetryAt = syncSettings.serverTarget?.nextAutoRetryAt
        if autoSyncRuntime.isEnabled == false {
            autoSyncRuntime.lastTrigger = nil
            autoSyncRuntime.backgroundScheduledAt = nil
            autoSyncRuntime.backgroundTrigger = nil
        }
        refreshServerPendingMutations()
    }

    private func persist(_ settings: SyncSettings) {
        settings.save()
        syncSettings = settings
        refreshAutoSyncRuntime()
    }
}
