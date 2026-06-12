//
//  ServerSyncCoordinator.swift
//  Empty
//

import Foundation
import SwiftData

nonisolated struct ServerSyncPullSummary: Equatable, Sendable {
    var appliedRecordCount: Int
    var tombstoneCount: Int
    var cursor: LiveSyncCursor?
    var pulledAt: Date
    var wasFullSnapshot: Bool
}

nonisolated struct ServerSyncPushSummary: Equatable, Sendable {
    var pushedRecordCount: Int
    var tombstoneCount: Int
    var cursor: LiveSyncCursor?
    var pushedAt: Date
    var wasFullSnapshot: Bool

    var changeCount: Int {
        pushedRecordCount + tombstoneCount
    }
}

nonisolated struct ServerSyncRoundTripSummary: Equatable, Sendable {
    var pull: ServerSyncPullSummary
    var push: ServerSyncPushSummary
    var conflict: ServerSyncConflictSummary?
}

@MainActor
struct ServerSyncCoordinator {
    let client: ServerLiveSyncClient

    func pull(into modelContext: ModelContext, cursor: LiveSyncCursor?, forceFullSnapshot: Bool = false) async throws -> ServerSyncPullSummary {
        var response = try await client.pull(cursor: cursor, wantsFullSnapshot: forceFullSnapshot)
        if response.resetRequired {
            response = try await client.pull(cursor: nil, wantsFullSnapshot: true)
        }
        try response.delta.merge(into: modelContext)
        return ServerSyncPullSummary(
            appliedRecordCount: response.delta.recordCount,
            tombstoneCount: response.delta.tombstones.count,
            cursor: response.nextCursor,
            pulledAt: response.nextCursor?.serverTime ?? response.delta.emittedAt,
            wasFullSnapshot: response.delta.isFullSnapshot
        )
    }

    func push(delta: ReaderLiveSyncDelta, baseCursor: LiveSyncCursor?) async throws -> ServerSyncPushSummary {
        let response = try await client.push(delta: delta, baseCursor: baseCursor)
        return ServerSyncPushSummary(
            pushedRecordCount: delta.recordCount,
            tombstoneCount: delta.tombstones.count,
            cursor: response.acceptedCursor,
            pushedAt: response.serverTime ?? delta.emittedAt,
            wasFullSnapshot: delta.isFullSnapshot
        )
    }
}
