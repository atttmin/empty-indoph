//
//  LiveSyncContract.swift
//  Empty
//

import Foundation
import SwiftData

nonisolated enum LiveSyncFeature: String, Codable, CaseIterable, Sendable {
    case readerSnapshotsV1 = "reader-snapshots-v1"
    case readerLiveSyncV1 = "reader-live-sync-v1"
}

nonisolated enum LiveSyncRecordKind: String, Codable, CaseIterable, Sendable {
    case book
    case highlight
    case readingSession
    case vocabEntry
    case studyCard
    case bookmark
    case memoryItem
}

nonisolated struct LiveSyncCursor: Codable, Equatable, Sendable {
    var opaqueValue: String
    var serverTime: Date?

    init(opaqueValue: String, serverTime: Date? = nil) {
        self.opaqueValue = opaqueValue
        self.serverTime = serverTime
    }
}

nonisolated struct LiveSyncTombstone: Codable, Equatable, Sendable {
    var kind: LiveSyncRecordKind
    var recordID: UUID
    var deletedAt: Date

    init(kind: LiveSyncRecordKind, recordID: UUID, deletedAt: Date) {
        self.kind = kind
        self.recordID = recordID
        self.deletedAt = deletedAt
    }
}

nonisolated struct ReaderLiveSyncDelta: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = Self.currentSchemaVersion
    var emittedAt: Date = Date()
    var isFullSnapshot: Bool = false
    var books: [BookRecord] = []
    var highlights: [HighlightRecord] = []
    var sessions: [ReadingSessionRecord] = []
    var vocab: [VocabEntryRecord] = []
    var studyCards: [StudyCardRecord] = []
    var bookmarks: [BookmarkRecord] = []
    var memoryItems: [MemoryItemRecord] = []
    var tombstones: [LiveSyncTombstone] = []

    var recordCount: Int {
        books.count
            + highlights.count
            + sessions.count
            + vocab.count
            + studyCards.count
            + bookmarks.count
            + memoryItems.count
    }

    static func bootstrap(from snapshot: SyncSnapshot) -> ReaderLiveSyncDelta {
        ReaderLiveSyncDelta(
            schemaVersion: snapshot.schemaVersion,
            emittedAt: snapshot.exportedAt,
            isFullSnapshot: true,
            books: snapshot.books,
            highlights: snapshot.highlights,
            sessions: snapshot.sessions,
            vocab: snapshot.vocab,
            studyCards: snapshot.studyCards,
            bookmarks: snapshot.bookmarks,
            memoryItems: snapshot.memoryItems,
            tombstones: []
        )
    }

    var asSnapshot: SyncSnapshot {
        SyncSnapshot(
            schemaVersion: schemaVersion,
            exportedAt: emittedAt,
            books: books,
            highlights: highlights,
            sessions: sessions,
            vocab: vocab,
            studyCards: studyCards,
            bookmarks: bookmarks,
            memoryItems: memoryItems
        )
    }

    @MainActor
    func merge(into modelContext: ModelContext) throws {
        try asSnapshot.merge(into: modelContext)
        try applyTombstones(into: modelContext)
    }

    @MainActor
    func applyTombstones(into modelContext: ModelContext) throws {
        guard !tombstones.isEmpty else { return }

        let books = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<Book>()).map { ($0.id, $0) })
        let highlights = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<Highlight>()).map { ($0.id, $0) })
        let sessions = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<ReadingSession>()).map { ($0.id, $0) })
        let vocab = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<VocabEntry>()).map { ($0.id, $0) })
        let cards = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<StudyCardEntry>()).map { ($0.id, $0) })
        let bookmarks = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<Bookmark>()).map { ($0.id, $0) })
        let memoryItems = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<MemoryItem>()).map { ($0.id, $0) })

        for tombstone in tombstones {
            switch tombstone.kind {
            case .book:
                if let book = books[tombstone.recordID] { modelContext.delete(book) }
            case .highlight:
                if let highlight = highlights[tombstone.recordID] { modelContext.delete(highlight) }
            case .readingSession:
                if let session = sessions[tombstone.recordID] { modelContext.delete(session) }
            case .vocabEntry:
                if let entry = vocab[tombstone.recordID] { modelContext.delete(entry) }
            case .studyCard:
                if let card = cards[tombstone.recordID] { modelContext.delete(card) }
            case .bookmark:
                if let bookmark = bookmarks[tombstone.recordID] { modelContext.delete(bookmark) }
            case .memoryItem:
                if let item = memoryItems[tombstone.recordID] { modelContext.delete(item) }
            }
        }

        try modelContext.save()
    }
}

nonisolated struct ReaderLiveSyncPullRequest: Codable, Equatable, Sendable {
    var cursor: LiveSyncCursor?
    var wantsFullSnapshot: Bool
    var schemaVersion: Int

    init(cursor: LiveSyncCursor?, wantsFullSnapshot: Bool, schemaVersion: Int = ReaderLiveSyncDelta.currentSchemaVersion) {
        self.cursor = cursor
        self.wantsFullSnapshot = wantsFullSnapshot
        self.schemaVersion = schemaVersion
    }
}

nonisolated struct ReaderLiveSyncPullResponse: Codable, Equatable, Sendable {
    var delta: ReaderLiveSyncDelta
    var nextCursor: LiveSyncCursor?
    var resetRequired: Bool
}

nonisolated struct ReaderLiveSyncPushRequest: Codable, Equatable, Sendable {
    var baseCursor: LiveSyncCursor?
    var delta: ReaderLiveSyncDelta

    init(baseCursor: LiveSyncCursor?, delta: ReaderLiveSyncDelta) {
        self.baseCursor = baseCursor
        self.delta = delta
    }
}

nonisolated struct ReaderLiveSyncPushResponse: Codable, Equatable, Sendable {
    var acceptedCursor: LiveSyncCursor?
    var serverTime: Date?
    var resetRequired: Bool
}
