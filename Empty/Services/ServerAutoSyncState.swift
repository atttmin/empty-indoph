//
//  ServerAutoSyncState.swift
//  Empty
//

import Foundation

nonisolated struct ServerAutoSyncRuntimeState: Equatable, Sendable {
    var isEnabled: Bool = false
    var isRunning: Bool = false
    var lastTrigger: String?
    var lastSyncedAt: Date?
    var lastError: String?
    var lastFingerprintPrefix: String?
    var pendingUpsertCount: Int = 0
    var pendingTombstoneCount: Int = 0
    var consecutiveFailureCount: Int = 0
    var nextRetryAt: Date?
    var backgroundScheduledAt: Date?
    var backgroundTrigger: ServerBackgroundSyncTrigger?

    var pendingChangeCount: Int {
        pendingUpsertCount + pendingTombstoneCount
    }

    var isRetryQueued: Bool {
        nextRetryAt != nil
    }

    var isBackgroundScheduled: Bool {
        backgroundScheduledAt != nil
    }
}
