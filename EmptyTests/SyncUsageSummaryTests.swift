//
//  SyncUsageSummaryTests.swift
//  EmptyTests
//

import Foundation
import Testing
@testable import Empty

struct SyncUsageSummaryTests {
    @Test func prefersContractReadyServerWithAutoSync() {
        let scheduledAt = Date(timeIntervalSince1970: 600)
        let summary = SyncUsageSummaryBuilder.make(
            liveMode: .localOnly,
            folderTarget: nil,
            serverTarget: .init(
                baseURLString: "https://sync.example.com",
                namespace: "reader-main",
                authMode: .bearer,
                lastSnapshotAt: nil,
                lastValidatedAt: nil,
                liveCursor: nil,
                lastLivePullAt: nil,
                lastLivePushAt: nil,
                autoSyncEnabled: true,
                autoSyncIntervalSeconds: 120,
                lastAutoSyncAt: nil,
                lastAutoSyncFingerprint: nil
            ),
            cloudStatus: nil,
            serverStatus: .init(
                kind: .server,
                title: "Empty Cloud",
                state: .contractReady,
                detail: "ready"
            ),
            backgroundScheduledAt: scheduledAt
        )

        #expect(summary.title == "自建同步已接好")
        #expect(summary.tone == .accent)
        #expect(summary.detail.contains("后台"))
    }
    @Test func mentionsPasskeyWhenServerAccountConnected() {
        let summary = SyncUsageSummaryBuilder.make(
            liveMode: .localOnly,
            folderTarget: nil,
            serverTarget: .init(
                baseURLString: "https://sync.example.com",
                namespace: "reader-main",
                authMode: .passkeySession,
                accountID: "user-1",
                accountDisplayName: "Davi",
                accountEmail: "davi@example.com",
                accountSignedInAt: Date(timeIntervalSince1970: 100),
                accountSessionExpiresAt: nil,
                lastSnapshotAt: nil,
                lastValidatedAt: nil,
                liveCursor: nil,
                lastLivePullAt: nil,
                lastLivePushAt: nil,
                autoSyncEnabled: true,
                autoSyncIntervalSeconds: 120,
                lastAutoSyncAt: nil,
                lastAutoSyncFingerprint: nil
            ),
            cloudStatus: nil,
            serverStatus: .init(
                kind: .server,
                title: "Empty Cloud",
                state: .contractReady,
                detail: "ready"
            )
        )

        #expect(summary.detail.contains("Passkey"))
    }

    @Test func surfacesQueuedRetryForAutoSyncServer() {
        let retryAt = Date(timeIntervalSince1970: 3600)
        let summary = SyncUsageSummaryBuilder.make(
            liveMode: .localOnly,
            folderTarget: nil,
            serverTarget: .init(
                baseURLString: "https://sync.example.com",
                namespace: "reader-main",
                authMode: .bearer,
                lastSnapshotAt: nil,
                lastValidatedAt: nil,
                liveCursor: nil,
                lastLivePullAt: nil,
                lastLivePushAt: nil,
                autoSyncEnabled: true,
                autoSyncIntervalSeconds: 120,
                lastAutoSyncAt: nil,
                lastAutoSyncFingerprint: nil,
                consecutiveAutoSyncFailures: 2,
                nextAutoRetryAt: retryAt,
                lastAutoSyncError: "timeout"
            ),
            cloudStatus: nil,
            serverStatus: .init(
                kind: .server,
                title: "Empty Cloud",
                state: .contractReady,
                detail: "ready"
            ),
            pendingServerChanges: 2,
            pendingServerRetryAt: retryAt
        )

        #expect(summary.title == "自建同步已排队重试")
        #expect(summary.detail.contains("2 处待同步变化"))
        #expect(summary.tone == .caution)
    }

    @Test func mentionsPendingServerChangesWhenAutoSyncHasWork() {
        let summary = SyncUsageSummaryBuilder.make(
            liveMode: .localOnly,
            folderTarget: nil,
            serverTarget: .init(
                baseURLString: "https://sync.example.com",
                namespace: "reader-main",
                authMode: .bearer,
                lastSnapshotAt: nil,
                lastValidatedAt: nil,
                liveCursor: nil,
                lastLivePullAt: nil,
                lastLivePushAt: nil,
                autoSyncEnabled: true,
                autoSyncIntervalSeconds: 120,
                lastAutoSyncAt: nil,
                lastAutoSyncFingerprint: nil
            ),
            cloudStatus: nil,
            serverStatus: .init(
                kind: .server,
                title: "Empty Cloud",
                state: .contractReady,
                detail: "ready"
            ),
            pendingServerChanges: 3
        )

        #expect(summary.detail.contains("3 处待同步变化"))
    }

    @Test func prefersWorkingCloudKitForSimpleUsage() {
        let summary = SyncUsageSummaryBuilder.make(
            liveMode: .cloudKit,
            folderTarget: nil,
            serverTarget: nil,
            cloudStatus: .init(
                kind: .cloudKit,
                title: "iCloud",
                state: .active,
                detail: "active"
            ),
            serverStatus: nil
        )

        #expect(summary.title == "最省心：iCloud 正在工作")
        #expect(summary.tone == .accent)
    }

    @Test func fallsBackToFolderBackupWhenLocalOnly() {
        let summary = SyncUsageSummaryBuilder.make(
            liveMode: .localOnly,
            folderTarget: .init(bookmarkData: Data(), displayName: "Dropbox", lastSnapshotAt: nil),
            serverTarget: nil,
            cloudStatus: nil,
            serverStatus: nil
        )

        #expect(summary.detail.contains("Dropbox"))
        #expect(summary.tone == .neutral)
    }

    @Test func defaultsToLocalOnlyMessage() {
        let summary = SyncUsageSummaryBuilder.make(
            liveMode: .localOnly,
            folderTarget: nil,
            serverTarget: nil,
            cloudStatus: nil,
            serverStatus: nil
        )

        #expect(summary.title == "当前只保存在本机")
        #expect(summary.recommendation.contains("iCloud"))
    }
}
