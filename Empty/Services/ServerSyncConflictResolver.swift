//
//  ServerSyncConflictResolver.swift
//  Empty
//

import Foundation

nonisolated enum ServerSyncConflictPolicy: String, Codable, CaseIterable, Sendable {
    case keepLocal
    case keepRemote

    var title: String {
        switch self {
        case .keepLocal:
            "保留这台设备的改动"
        case .keepRemote:
            "保留云端的改动"
        }
    }

    var detail: String {
        switch self {
        case .keepLocal:
            "同一条笔记、书签或记忆如果两边都改过，默认以这台设备的版本为准。"
        case .keepRemote:
            "同一条内容如果两边都改过，默认以云端刚拉回来的版本为准。"
        }
    }

    var shortLabel: String {
        switch self {
        case .keepLocal:
            "本机优先"
        case .keepRemote:
            "云端优先"
        }
    }
}

nonisolated struct LiveSyncChangeKey: Hashable, Sendable {
    var kind: LiveSyncRecordKind
    var recordID: UUID
}

nonisolated struct ServerSyncConflictSummary: Equatable, Sendable {
    var policy: ServerSyncConflictPolicy
    var conflictCount: Int
    var resolvedAt: Date
}

nonisolated struct ServerSyncConflictResolution: Equatable, Sendable {
    var deltaToApplyLocally: ReaderLiveSyncDelta
    var deltaToPush: ReaderLiveSyncDelta
    var summary: ServerSyncConflictSummary?
}

nonisolated enum ServerSyncConflictResolver {
    static func resolve(
        localDelta: ReaderLiveSyncDelta,
        remoteDelta: ReaderLiveSyncDelta,
        policy: ServerSyncConflictPolicy,
        resolvedAt: Date = Date()
    ) -> ServerSyncConflictResolution {
        let conflictKeys = localDelta.changeKeys.intersection(remoteDelta.changeKeys)
        guard !conflictKeys.isEmpty else {
            return ServerSyncConflictResolution(
                deltaToApplyLocally: localDelta,
                deltaToPush: localDelta,
                summary: nil
            )
        }

        let summary = ServerSyncConflictSummary(
            policy: policy,
            conflictCount: conflictKeys.count,
            resolvedAt: resolvedAt
        )

        switch policy {
        case .keepLocal:
            return ServerSyncConflictResolution(
                deltaToApplyLocally: localDelta,
                deltaToPush: localDelta,
                summary: summary
            )
        case .keepRemote:
            let filtered = localDelta.removingChanges(for: conflictKeys)
            return ServerSyncConflictResolution(
                deltaToApplyLocally: filtered,
                deltaToPush: filtered,
                summary: summary
            )
        }
    }
}

extension ReaderLiveSyncDelta {
    nonisolated var changeKeys: Set<LiveSyncChangeKey> {
        var keys = Set<LiveSyncChangeKey>()
        keys.formUnion(books.map { LiveSyncChangeKey(kind: .book, recordID: $0.id) })
        keys.formUnion(highlights.map { LiveSyncChangeKey(kind: .highlight, recordID: $0.id) })
        keys.formUnion(sessions.map { LiveSyncChangeKey(kind: .readingSession, recordID: $0.id) })
        keys.formUnion(vocab.map { LiveSyncChangeKey(kind: .vocabEntry, recordID: $0.id) })
        keys.formUnion(studyCards.map { LiveSyncChangeKey(kind: .studyCard, recordID: $0.id) })
        keys.formUnion(bookmarks.map { LiveSyncChangeKey(kind: .bookmark, recordID: $0.id) })
        keys.formUnion(memoryItems.map { LiveSyncChangeKey(kind: .memoryItem, recordID: $0.id) })
        keys.formUnion(tombstones.map { LiveSyncChangeKey(kind: $0.kind, recordID: $0.recordID) })
        return keys
    }

    nonisolated func removingChanges(for keys: Set<LiveSyncChangeKey>) -> ReaderLiveSyncDelta {
        ReaderLiveSyncDelta(
            schemaVersion: schemaVersion,
            emittedAt: emittedAt,
            isFullSnapshot: false,
            books: books.filter { !keys.contains(LiveSyncChangeKey(kind: .book, recordID: $0.id)) },
            highlights: highlights.filter { !keys.contains(LiveSyncChangeKey(kind: .highlight, recordID: $0.id)) },
            sessions: sessions.filter { !keys.contains(LiveSyncChangeKey(kind: .readingSession, recordID: $0.id)) },
            vocab: vocab.filter { !keys.contains(LiveSyncChangeKey(kind: .vocabEntry, recordID: $0.id)) },
            studyCards: studyCards.filter { !keys.contains(LiveSyncChangeKey(kind: .studyCard, recordID: $0.id)) },
            bookmarks: bookmarks.filter { !keys.contains(LiveSyncChangeKey(kind: .bookmark, recordID: $0.id)) },
            memoryItems: memoryItems.filter { !keys.contains(LiveSyncChangeKey(kind: .memoryItem, recordID: $0.id)) },
            tombstones: tombstones.filter { !keys.contains(LiveSyncChangeKey(kind: $0.kind, recordID: $0.recordID)) }
        )
    }
}
