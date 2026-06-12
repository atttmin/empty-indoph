//
//  SyncSnapshot.swift
//  Empty
//

import CryptoKit
import Foundation
import SwiftData

nonisolated enum SyncSnapshotCodec {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

nonisolated struct SyncSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = Self.currentSchemaVersion
    var exportedAt: Date = Date()
    var books: [BookRecord] = []
    var highlights: [HighlightRecord] = []
    var sessions: [ReadingSessionRecord] = []
    var vocab: [VocabEntryRecord] = []
    var studyCards: [StudyCardRecord] = []
    var bookmarks: [BookmarkRecord] = []
    var memoryItems: [MemoryItemRecord] = []

    @MainActor
    static func capture(from modelContext: ModelContext) throws -> SyncSnapshot {
        SyncSnapshot(
            exportedAt: Date(),
            books: try modelContext.fetch(FetchDescriptor<Book>()).map(BookRecord.init).sorted { $0.addedAt < $1.addedAt },
            highlights: try modelContext.fetch(FetchDescriptor<Highlight>()).map(HighlightRecord.init).sorted { $0.createdAt < $1.createdAt },
            sessions: try modelContext.fetch(FetchDescriptor<ReadingSession>()).map(ReadingSessionRecord.init).sorted { $0.startedAt < $1.startedAt },
            vocab: try modelContext.fetch(FetchDescriptor<VocabEntry>()).map(VocabEntryRecord.init).sorted { $0.createdAt < $1.createdAt },
            studyCards: try modelContext.fetch(FetchDescriptor<StudyCardEntry>()).map(StudyCardRecord.init).sorted { $0.createdAt < $1.createdAt },
            bookmarks: try modelContext.fetch(FetchDescriptor<Bookmark>()).map(BookmarkRecord.init).sorted { $0.createdAt < $1.createdAt },
            memoryItems: try modelContext.fetch(FetchDescriptor<MemoryItem>()).map(MemoryItemRecord.init).sorted { $0.updatedAt < $1.updatedAt }
        )
    }

    func stableFingerprint() throws -> String {
        var fingerprintSnapshot = self
        fingerprintSnapshot.exportedAt = .distantPast
        let data = try SyncSnapshotCodec.makeEncoder().encode(fingerprintSnapshot)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    func merge(into modelContext: ModelContext) throws {
        var booksByID = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<Book>()).map { ($0.id, $0) })
        var highlightsByID = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<Highlight>()).map { ($0.id, $0) })
        var sessionsByID = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<ReadingSession>()).map { ($0.id, $0) })
        var vocabByID = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<VocabEntry>()).map { ($0.id, $0) })
        var cardsByID = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<StudyCardEntry>()).map { ($0.id, $0) })
        var bookmarksByID = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<Bookmark>()).map { ($0.id, $0) })
        var memoryByID = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<MemoryItem>()).map { ($0.id, $0) })

        for record in books {
            let book = booksByID[record.id] ?? {
                let new = Book(title: record.title, author: record.author, format: record.format)
                new.id = record.id
                modelContext.insert(new)
                booksByID[record.id] = new
                return new
            }()
            record.apply(to: book)
        }

        for record in highlights {
            let highlight = highlightsByID[record.id] ?? {
                let new = Highlight(anchor: record.anchor, textSnapshot: record.textSnapshot, color: record.color, note: record.note)
                new.id = record.id
                modelContext.insert(new)
                highlightsByID[record.id] = new
                return new
            }()
            record.apply(to: highlight, booksByID: booksByID)
        }

        for record in sessions {
            let session = sessionsByID[record.id] ?? {
                let new = ReadingSession(startPosition: record.startPosition, startedAt: record.startedAt)
                new.id = record.id
                modelContext.insert(new)
                sessionsByID[record.id] = new
                return new
            }()
            record.apply(to: session, booksByID: booksByID)
        }

        for record in vocab {
            let entry = vocabByID[record.id] ?? {
                let new = VocabEntry(
                    word: record.word,
                    meaning: record.meaning,
                    phonetic: record.phonetic,
                    partOfSpeech: record.partOfSpeech,
                    note: record.note,
                    sentence: record.sentence,
                    source: record.source
                )
                new.id = record.id
                modelContext.insert(new)
                vocabByID[record.id] = new
                return new
            }()
            record.apply(to: entry)
        }

        for record in studyCards {
            let card = cardsByID[record.id] ?? {
                let new = StudyCardEntry(
                    question: record.question,
                    answer: record.answer,
                    source: record.source,
                    highlightID: record.highlightID,
                    kind: record.kind
                )
                new.id = record.id
                modelContext.insert(new)
                cardsByID[record.id] = new
                return new
            }()
            record.apply(to: card, booksByID: booksByID)
        }

        for record in bookmarks {
            let bookmark = bookmarksByID[record.id] ?? {
                let new = Bookmark(
                    chapterIndex: record.chapterIndex,
                    utf16Offset: record.utf16Offset,
                    snippet: record.snippet
                )
                new.id = record.id
                modelContext.insert(new)
                bookmarksByID[record.id] = new
                return new
            }()
            record.apply(to: bookmark, booksByID: booksByID)
        }

        for record in memoryItems {
            let item = memoryByID[record.id] ?? {
                let new = MemoryItem(
                    kind: record.kind,
                    title: record.title,
                    body: record.body,
                    bookID: record.bookID,
                    chapterIndex: record.chapterIndex,
                    sourceLabel: record.sourceLabel,
                    tags: record.tags,
                    sourceRefID: record.sourceRefID,
                    sourceRefKind: record.sourceRefKind,
                    isUserConfirmed: record.isUserConfirmed
                )
                new.id = record.id
                modelContext.insert(new)
                memoryByID[record.id] = new
                return new
            }()
            record.apply(to: item)
        }

        try modelContext.save()
    }
}

nonisolated struct BookRecord: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var author: String
    var languageTag: String?
    var format: BookFormat
    var fileRelativePath: String?
    var coverThumbnailData: Data?
    var addedAt: Date
    var lastOpenedAt: Date?
    var position: ReadingPosition
    var progressFraction: Double
    var cachedHeroRecap: String?
    var cachedHeroRecapChapterIndex: Int?

    init(_ book: Book) {
        id = book.id
        title = book.title
        author = book.author
        languageTag = book.languageTag
        format = book.format
        fileRelativePath = book.fileRelativePath
        coverThumbnailData = book.coverThumbnailData
        addedAt = book.addedAt
        lastOpenedAt = book.lastOpenedAt
        position = book.position
        progressFraction = book.progressFraction
        cachedHeroRecap = book.cachedHeroRecap
        cachedHeroRecapChapterIndex = book.cachedHeroRecapChapterIndex
    }

    func apply(to book: Book) {
        book.id = id
        book.title = title
        book.author = author
        book.languageTag = languageTag
        book.format = format
        book.fileRelativePath = fileRelativePath
        book.coverThumbnailData = coverThumbnailData
        book.addedAt = addedAt
        book.lastOpenedAt = lastOpenedAt
        book.position = position
        book.progressFraction = progressFraction
        book.cachedHeroRecap = cachedHeroRecap
        book.cachedHeroRecapChapterIndex = cachedHeroRecapChapterIndex
    }
}

nonisolated struct HighlightRecord: Codable, Equatable, Sendable {
    var id: UUID
    var bookID: UUID?
    var anchor: TextAnchor
    var textSnapshot: String
    var note: String?
    var color: HighlightColor
    var createdAt: Date

    init(_ highlight: Highlight) {
        id = highlight.id
        bookID = highlight.book?.id
        anchor = highlight.anchor
        textSnapshot = highlight.textSnapshot
        note = highlight.note
        color = highlight.color
        createdAt = highlight.createdAt
    }

    func apply(to highlight: Highlight, booksByID: [UUID: Book]) {
        highlight.id = id
        highlight.book = bookID.flatMap { booksByID[$0] }
        highlight.anchor = anchor
        highlight.textSnapshot = textSnapshot
        highlight.note = note
        highlight.color = color
        highlight.createdAt = createdAt
    }
}

nonisolated struct ReadingSessionRecord: Codable, Equatable, Sendable {
    var id: UUID
    var bookID: UUID?
    var startedAt: Date
    var endedAt: Date?
    var activeSeconds: Double
    var startPosition: ReadingPosition
    var endPosition: ReadingPosition

    init(_ session: ReadingSession) {
        id = session.id
        bookID = session.book?.id
        startedAt = session.startedAt
        endedAt = session.endedAt
        activeSeconds = session.activeSeconds
        startPosition = session.startPosition
        endPosition = session.endPosition
    }

    func apply(to session: ReadingSession, booksByID: [UUID: Book]) {
        session.id = id
        session.book = bookID.flatMap { booksByID[$0] }
        session.startedAt = startedAt
        session.endedAt = endedAt
        session.activeSeconds = activeSeconds
        session.startPosition = startPosition
        session.endPosition = endPosition
    }
}

nonisolated struct VocabEntryRecord: Codable, Equatable, Sendable {
    var id: UUID
    var word: String
    var phonetic: String?
    var partOfSpeech: String?
    var meaning: String
    var note: String?
    var sentence: String?
    var source: String?
    var stage: Int
    var dueAt: Date
    var createdAt: Date
    var lastReviewedAt: Date?

    init(_ entry: VocabEntry) {
        id = entry.id
        word = entry.word
        phonetic = entry.phonetic
        partOfSpeech = entry.partOfSpeech
        meaning = entry.meaning
        note = entry.note
        sentence = entry.sentence
        source = entry.source
        stage = entry.stage
        dueAt = entry.dueAt
        createdAt = entry.createdAt
        lastReviewedAt = entry.lastReviewedAt
    }

    func apply(to entry: VocabEntry) {
        entry.id = id
        entry.word = word
        entry.phonetic = phonetic
        entry.partOfSpeech = partOfSpeech
        entry.meaning = meaning
        entry.note = note
        entry.sentence = sentence
        entry.source = source
        entry.stage = stage
        entry.dueAt = dueAt
        entry.createdAt = createdAt
        entry.lastReviewedAt = lastReviewedAt
    }
}

nonisolated struct StudyCardRecord: Codable, Equatable, Sendable {
    var id: UUID
    var question: String
    var answer: String
    var source: String?
    var highlightID: UUID?
    var bookID: UUID?
    var kind: StudyCardKind
    var stage: Int
    var dueAt: Date
    var createdAt: Date
    var lastReviewedAt: Date?

    init(_ card: StudyCardEntry) {
        id = card.id
        question = card.question
        answer = card.answer
        source = card.source
        highlightID = card.highlightID
        bookID = card.book?.id
        kind = card.kind
        stage = card.stage
        dueAt = card.dueAt
        createdAt = card.createdAt
        lastReviewedAt = card.lastReviewedAt
    }

    func apply(to card: StudyCardEntry, booksByID: [UUID: Book]) {
        card.id = id
        card.question = question
        card.answer = answer
        card.source = source
        card.highlightID = highlightID
        card.book = bookID.flatMap { booksByID[$0] }
        card.kind = kind
        card.stage = stage
        card.dueAt = dueAt
        card.createdAt = createdAt
        card.lastReviewedAt = lastReviewedAt
    }
}

nonisolated struct BookmarkRecord: Codable, Equatable, Sendable {
    var id: UUID
    var bookID: UUID?
    var chapterIndex: Int
    var utf16Offset: Int
    var snippet: String
    var createdAt: Date

    init(_ bookmark: Bookmark) {
        id = bookmark.id
        bookID = bookmark.book?.id
        chapterIndex = bookmark.chapterIndex
        utf16Offset = bookmark.utf16Offset
        snippet = bookmark.snippet
        createdAt = bookmark.createdAt
    }

    func apply(to bookmark: Bookmark, booksByID: [UUID: Book]) {
        bookmark.id = id
        bookmark.book = bookID.flatMap { booksByID[$0] }
        bookmark.chapterIndex = chapterIndex
        bookmark.utf16Offset = utf16Offset
        bookmark.snippet = snippet
        bookmark.createdAt = createdAt
    }
}

nonisolated struct MemoryItemRecord: Codable, Equatable, Sendable {
    var id: UUID
    var kind: MemoryKind
    var title: String
    var body: String
    var bookID: UUID?
    var chapterIndex: Int?
    var sourceLabel: String?
    var tags: [String]
    var sourceRefID: UUID?
    var sourceRefKind: String?
    var createdAt: Date
    var updatedAt: Date
    var isUserConfirmed: Bool

    init(_ item: MemoryItem) {
        id = item.id
        kind = item.kind
        title = item.title
        body = item.body
        bookID = item.bookID
        chapterIndex = item.chapterIndex
        sourceLabel = item.sourceLabel
        tags = item.tags
        sourceRefID = item.sourceRefID
        sourceRefKind = item.sourceRefKind
        createdAt = item.createdAt
        updatedAt = item.updatedAt
        isUserConfirmed = item.isUserConfirmed
    }

    func apply(to item: MemoryItem) {
        item.id = id
        item.kind = kind
        item.title = title
        item.body = body
        item.bookID = bookID
        item.chapterIndex = chapterIndex
        item.sourceLabel = sourceLabel
        item.tags = tags
        item.sourceRefID = sourceRefID
        item.sourceRefKind = sourceRefKind
        item.createdAt = createdAt
        item.updatedAt = updatedAt
        item.isUserConfirmed = isUserConfirmed
    }
}
