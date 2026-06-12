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
    var cursor: LiveSyncCursor?
    var pushedAt: Date
    var wasFullSnapshot: Bool
}

nonisolated struct ServerSyncRoundTripSummary: Equatable, Sendable {
    var pull: ServerSyncPullSummary
    var push: ServerSyncPushSummary
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

    func push(from modelContext: ModelContext, baseCursor: LiveSyncCursor?) async throws -> ServerSyncPushSummary {
        let snapshot = try SyncSnapshot.capture(from: modelContext)
        let delta = ReaderLiveSyncDelta.bootstrap(from: snapshot)
        let response = try await client.push(delta: delta, baseCursor: baseCursor)
        return ServerSyncPushSummary(
            pushedRecordCount: delta.recordCount,
            cursor: response.acceptedCursor,
            pushedAt: response.serverTime ?? snapshot.exportedAt,
            wasFullSnapshot: delta.isFullSnapshot
        )
    }

    func sync(into modelContext: ModelContext, cursor: LiveSyncCursor?) async throws -> ServerSyncRoundTripSummary {
        let pullSummary = try await pull(into: modelContext, cursor: cursor)
        let pushSummary = try await push(from: modelContext, baseCursor: pullSummary.cursor)
        return ServerSyncRoundTripSummary(pull: pullSummary, push: pushSummary)
    }
}
