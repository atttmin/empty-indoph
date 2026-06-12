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
}
