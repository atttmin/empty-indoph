//
//  ReaderNotesBackup.swift
//  Empty
//

import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let emptyNotes = UTType(filenameExtension: "empty-notes") ?? UTType(exportedAs: "app.empty.notes", conformingTo: .json)
}

nonisolated struct ReaderNotesRecordCounts: Codable, Equatable, Sendable {
    var books = 0
    var highlights = 0
    var readingSessions = 0
    var vocabEntries = 0
    var bookmarks = 0
    var studyCards = 0
    var memoryItems = 0

    var total: Int {
        books + highlights + readingSessions + vocabEntries
            + bookmarks + studyCards + memoryItems
    }
}

nonisolated struct ReaderNotesBackupPackage: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var manifest: Manifest
    var books: [BookRecord]
    var highlights: [HighlightRecord]
    var readingSessions: [ReadingSessionRecord]
    var vocabEntries: [VocabEntryRecord]
    var bookmarks: [BookmarkRecord]
    var studyCards: [StudyCardRecord]
    var memoryItems: [MemoryItemRecord]

    var counts: ReaderNotesRecordCounts {
        ReaderNotesRecordCounts(
            books: books.count,
            highlights: highlights.count,
            readingSessions: readingSessions.count,
            vocabEntries: vocabEntries.count,
            bookmarks: bookmarks.count,
            studyCards: studyCards.count,
            memoryItems: memoryItems.count
        )
    }

    nonisolated struct Manifest: Codable, Equatable, Sendable {
        var schemaVersion: Int
        var exportedAt: Date
        var appVersion: String
        var recordCounts: ReaderNotesRecordCounts
    }

    nonisolated struct BookRecord: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var title: String
        var author: String
        var languageTag: String?
        var format: BookFormat
        var fileRelativePath: String?
        var coverThumbnailData: Data?
        var addedAt: Date
        var lastOpenedAt: Date?
        var positionChapterIndex: Int
        var positionUTF16Offset: Int
        var progressFraction: Double
        var cachedHeroRecap: String?
        var cachedHeroRecapChapterIndex: Int?
    }

    nonisolated struct HighlightRecord: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var bookID: UUID?
        var chapterIndex: Int
        var startUTF16: Int
        var endUTF16: Int
        var textSnapshot: String
        var note: String?
        var color: HighlightColor
        var createdAt: Date
    }

    nonisolated struct ReadingSessionRecord: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var bookID: UUID?
        var startedAt: Date
        var endedAt: Date?
        var activeSeconds: Double
        var startChapterIndex: Int
        var startUTF16Offset: Int
        var endChapterIndex: Int
        var endUTF16Offset: Int
    }

    nonisolated struct VocabEntryRecord: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var bookID: UUID?
        var word: String
        var phonetic: String?
        var partOfSpeech: String?
        var meaning: String
        var note: String?
        var sentence: String?
        var source: String?
        var sourceChapterIndex: Int?
        var sourceUTF16Offset: Int?
        var stage: Int
        var dueAt: Date
        var createdAt: Date
        var lastReviewedAt: Date?
    }

    nonisolated struct BookmarkRecord: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var bookID: UUID?
        var chapterIndex: Int
        var utf16Offset: Int
        var snippet: String
        var createdAt: Date
    }

    nonisolated struct StudyCardRecord: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var bookID: UUID?
        var question: String
        var answer: String
        var source: String?
        var highlightID: UUID?
        var sourceChapterIndex: Int?
        var sourceUTF16Offset: Int?
        var kind: StudyCardKind
        var stage: Int
        var dueAt: Date
        var createdAt: Date
        var lastReviewedAt: Date?
    }

    nonisolated struct MemoryItemRecord: Codable, Equatable, Identifiable, Sendable {
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
    }
}

nonisolated struct ReaderNotesImportSummary: Equatable, Sendable {
    var inserted = ReaderNotesRecordCounts()
    var updated = ReaderNotesRecordCounts()
    var skipped = ReaderNotesRecordCounts()

    var changedTotal: Int { inserted.total + updated.total }

    var displayText: String {
        if changedTotal == 0, skipped.total == 0 {
            return "没有可导入的读者笔记。"
        }
        var parts: [String] = []
        if inserted.total > 0 { parts.append("新增 \(inserted.total) 条") }
        if updated.total > 0 { parts.append("更新 \(updated.total) 条") }
        if skipped.total > 0 { parts.append("跳过 \(skipped.total) 条") }
        return parts.joined(separator: "，")
    }
}

nonisolated enum ReaderNotesBackupError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "这个读者笔记包版本不支持：\(version)。"
        case .unreadableFile:
            "无法读取这个读者笔记包。"
        }
    }
}

nonisolated enum ReaderNotesBackupCodec {
    static func encode(_ package: ReaderNotesBackupPackage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(package)
    }

    static func decode(_ data: Data) throws -> ReaderNotesBackupPackage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(ReaderNotesBackupPackage.self, from: data)
        guard package.manifest.schemaVersion == ReaderNotesBackupPackage.schemaVersion else {
            throw ReaderNotesBackupError.unsupportedSchema(package.manifest.schemaVersion)
        }
        return package
    }
}

struct ReaderNotesBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.emptyNotes, .json] }
    static var writableContentTypes: [UTType] { [.emptyNotes] }

    var package: ReaderNotesBackupPackage

    init(package: ReaderNotesBackupPackage) {
        self.package = package
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw ReaderNotesBackupError.unreadableFile
        }
        package = try ReaderNotesBackupCodec.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try ReaderNotesBackupCodec.encode(package))
    }

    static func empty(now: Date = Date()) -> ReaderNotesBackupDocument {
        let counts = ReaderNotesRecordCounts()
        return ReaderNotesBackupDocument(package: ReaderNotesBackupPackage(
            manifest: .init(
                schemaVersion: ReaderNotesBackupPackage.schemaVersion,
                exportedAt: now,
                appVersion: "dev",
                recordCounts: counts
            ),
            books: [],
            highlights: [],
            readingSessions: [],
            vocabEntries: [],
            bookmarks: [],
            studyCards: [],
            memoryItems: []
        ))
    }
}

@MainActor
struct ReaderNotesBackupStore {
    let modelContext: ModelContext

    static var currentAppVersion: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        guard let build, !build.isEmpty else { return marketing }
        return "\(marketing) (\(build))"
    }

    func exportPackage(now: Date = Date()) throws -> ReaderNotesBackupPackage {
        let books = try modelContext.fetch(FetchDescriptor<Book>())
        let highlights = try modelContext.fetch(FetchDescriptor<Highlight>())
        let sessions = try modelContext.fetch(FetchDescriptor<ReadingSession>())
        let vocab = try modelContext.fetch(FetchDescriptor<VocabEntry>())
        let bookmarks = try modelContext.fetch(FetchDescriptor<Bookmark>())
        let cards = try modelContext.fetch(FetchDescriptor<StudyCardEntry>())
        let memories = try modelContext.fetch(FetchDescriptor<MemoryItem>())

        let bookRecords = books.map(ReaderNotesBackupPackage.BookRecord.init)
        let highlightRecords = highlights.map(ReaderNotesBackupPackage.HighlightRecord.init)
        let sessionRecords = sessions.map(ReaderNotesBackupPackage.ReadingSessionRecord.init)
        let vocabRecords = vocab.map(ReaderNotesBackupPackage.VocabEntryRecord.init)
        let bookmarkRecords = bookmarks.map(ReaderNotesBackupPackage.BookmarkRecord.init)
        let cardRecords = cards.map(ReaderNotesBackupPackage.StudyCardRecord.init)
        let memoryRecords = memories.map(ReaderNotesBackupPackage.MemoryItemRecord.init)

        let counts = ReaderNotesRecordCounts(
            books: bookRecords.count,
            highlights: highlightRecords.count,
            readingSessions: sessionRecords.count,
            vocabEntries: vocabRecords.count,
            bookmarks: bookmarkRecords.count,
            studyCards: cardRecords.count,
            memoryItems: memoryRecords.count
        )

        let manifest = ReaderNotesBackupPackage.Manifest(
            schemaVersion: ReaderNotesBackupPackage.schemaVersion,
            exportedAt: now,
            appVersion: Self.currentAppVersion,
            recordCounts: counts
        )
        return ReaderNotesBackupPackage(
            manifest: manifest,
            books: bookRecords.sorted { $0.addedAt < $1.addedAt },
            highlights: highlightRecords.sorted { $0.createdAt < $1.createdAt },
            readingSessions: sessionRecords.sorted { $0.startedAt < $1.startedAt },
            vocabEntries: vocabRecords.sorted { $0.createdAt < $1.createdAt },
            bookmarks: bookmarkRecords.sorted { $0.createdAt < $1.createdAt },
            studyCards: cardRecords.sorted { $0.createdAt < $1.createdAt },
            memoryItems: memoryRecords.sorted { $0.createdAt < $1.createdAt }
        )
    }

    @discardableResult
    func importPackage(_ package: ReaderNotesBackupPackage) throws -> ReaderNotesImportSummary {
        guard package.manifest.schemaVersion == ReaderNotesBackupPackage.schemaVersion else {
            throw ReaderNotesBackupError.unsupportedSchema(package.manifest.schemaVersion)
        }

        var summary = ReaderNotesImportSummary()
        var booksByID: [UUID: Book] = [:]
        for book in try modelContext.fetch(FetchDescriptor<Book>()) {
            booksByID[book.id] = book
        }
        var highlightsByID: [UUID: Highlight] = [:]
        for highlight in try modelContext.fetch(FetchDescriptor<Highlight>()) {
            highlightsByID[highlight.id] = highlight
        }
        var sessionsByID: [UUID: ReadingSession] = [:]
        for session in try modelContext.fetch(FetchDescriptor<ReadingSession>()) {
            sessionsByID[session.id] = session
        }
        var vocabByID: [UUID: VocabEntry] = [:]
        for entry in try modelContext.fetch(FetchDescriptor<VocabEntry>()) {
            vocabByID[entry.id] = entry
        }
        var bookmarksByID: [UUID: Bookmark] = [:]
        for bookmark in try modelContext.fetch(FetchDescriptor<Bookmark>()) {
            bookmarksByID[bookmark.id] = bookmark
        }
        var cardsByID: [UUID: StudyCardEntry] = [:]
        for card in try modelContext.fetch(FetchDescriptor<StudyCardEntry>()) {
            cardsByID[card.id] = card
        }
        var memoriesByID: [UUID: MemoryItem] = [:]
        for memory in try modelContext.fetch(FetchDescriptor<MemoryItem>()) {
            memoriesByID[memory.id] = memory
        }

        for record in package.books {
            if let book = booksByID[record.id] {
                record.apply(to: book)
                summary.updated.books += 1
            } else {
                let book = record.makeModel()
                modelContext.insert(book)
                booksByID[book.id] = book
                summary.inserted.books += 1
            }
        }

        for record in package.highlights {
            let book = record.bookID.flatMap { booksByID[$0] }
            if let highlight = highlightsByID[record.id] {
                record.apply(to: highlight, book: book)
                summary.updated.highlights += 1
            } else {
                let highlight = record.makeModel()
                modelContext.insert(highlight)
                highlight.book = book
                highlightsByID[highlight.id] = highlight
                summary.inserted.highlights += 1
            }
        }

        for record in package.readingSessions {
            let book = record.bookID.flatMap { booksByID[$0] }
            if let session = sessionsByID[record.id] {
                record.apply(to: session, book: book)
                summary.updated.readingSessions += 1
            } else {
                let session = record.makeModel()
                modelContext.insert(session)
                session.book = book
                sessionsByID[session.id] = session
                summary.inserted.readingSessions += 1
            }
        }

        for record in package.vocabEntries {
            let book = record.bookID.flatMap { booksByID[$0] }
            if let entry = vocabByID[record.id] {
                record.apply(to: entry, book: book)
                summary.updated.vocabEntries += 1
            } else {
                let entry = record.makeModel(book: book)
                modelContext.insert(entry)
                vocabByID[entry.id] = entry
                summary.inserted.vocabEntries += 1
            }
        }

        for record in package.bookmarks {
            let book = record.bookID.flatMap { booksByID[$0] }
            if let bookmark = bookmarksByID[record.id] {
                record.apply(to: bookmark, book: book)
                summary.updated.bookmarks += 1
            } else {
                let bookmark = record.makeModel()
                modelContext.insert(bookmark)
                bookmark.book = book
                bookmarksByID[bookmark.id] = bookmark
                summary.inserted.bookmarks += 1
            }
        }

        for record in package.studyCards {
            let book = record.bookID.flatMap { booksByID[$0] }
            if let card = cardsByID[record.id] {
                record.apply(to: card, book: book)
                summary.updated.studyCards += 1
            } else {
                let card = record.makeModel()
                modelContext.insert(card)
                card.book = book
                cardsByID[card.id] = card
                summary.inserted.studyCards += 1
            }
        }

        for record in package.memoryItems {
            if let memory = memoriesByID[record.id] {
                if memory.updatedAt > record.updatedAt {
                    summary.skipped.memoryItems += 1
                } else {
                    record.apply(to: memory)
                    summary.updated.memoryItems += 1
                }
            } else {
                let memory = record.makeModel()
                modelContext.insert(memory)
                memoriesByID[memory.id] = memory
                summary.inserted.memoryItems += 1
            }
        }

        try modelContext.save()
        return summary
    }
}

private extension ReaderNotesBackupPackage.BookRecord {
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
        positionChapterIndex = book.position.chapterIndex
        positionUTF16Offset = book.position.utf16Offset
        progressFraction = book.progressFraction
        cachedHeroRecap = book.cachedHeroRecap
        cachedHeroRecapChapterIndex = book.cachedHeroRecapChapterIndex
    }

    func makeModel() -> Book {
        let book = Book(title: title, author: author, format: format)
        apply(to: book)
        return book
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
        book.position = ReadingPosition(
            chapterIndex: positionChapterIndex,
            utf16Offset: positionUTF16Offset
        )
        book.progressFraction = progressFraction
        book.cachedHeroRecap = cachedHeroRecap
        book.cachedHeroRecapChapterIndex = cachedHeroRecapChapterIndex
    }
}

private extension ReaderNotesBackupPackage.HighlightRecord {
    init(_ highlight: Highlight) {
        id = highlight.id
        bookID = highlight.book?.id
        chapterIndex = highlight.chapterIndex
        startUTF16 = highlight.startUTF16
        endUTF16 = highlight.endUTF16
        textSnapshot = highlight.textSnapshot
        note = highlight.note
        color = highlight.color
        createdAt = highlight.createdAt
    }

    func makeModel() -> Highlight {
        let highlight = Highlight(
            anchor: TextAnchor(
                chapterIndex: chapterIndex,
                startUTF16: startUTF16,
                endUTF16: endUTF16
            ),
            textSnapshot: textSnapshot,
            color: color,
            note: note
        )
        apply(to: highlight, book: nil)
        return highlight
    }

    func apply(to highlight: Highlight, book: Book?) {
        highlight.id = id
        highlight.chapterIndex = chapterIndex
        highlight.startUTF16 = startUTF16
        highlight.endUTF16 = endUTF16
        highlight.textSnapshot = textSnapshot
        highlight.note = note
        highlight.color = color
        highlight.createdAt = createdAt
        highlight.book = book
    }
}

private extension ReaderNotesBackupPackage.ReadingSessionRecord {
    init(_ session: ReadingSession) {
        id = session.id
        bookID = session.book?.id
        startedAt = session.startedAt
        endedAt = session.endedAt
        activeSeconds = session.activeSeconds
        startChapterIndex = session.startChapterIndex
        startUTF16Offset = session.startUTF16Offset
        endChapterIndex = session.endChapterIndex
        endUTF16Offset = session.endUTF16Offset
    }

    func makeModel() -> ReadingSession {
        let session = ReadingSession(startPosition: ReadingPosition(
            chapterIndex: startChapterIndex,
            utf16Offset: startUTF16Offset
        ), startedAt: startedAt)
        apply(to: session, book: nil)
        return session
    }

    func apply(to session: ReadingSession, book: Book?) {
        session.id = id
        session.book = book
        session.startedAt = startedAt
        session.endedAt = endedAt
        session.activeSeconds = activeSeconds
        session.startChapterIndex = startChapterIndex
        session.startUTF16Offset = startUTF16Offset
        session.endChapterIndex = endChapterIndex
        session.endUTF16Offset = endUTF16Offset
    }
}

private extension ReaderNotesBackupPackage.VocabEntryRecord {
    init(_ entry: VocabEntry) {
        id = entry.id
        bookID = entry.book?.id
        word = entry.word
        phonetic = entry.phonetic
        partOfSpeech = entry.partOfSpeech
        meaning = entry.meaning
        note = entry.note
        sentence = entry.sentence
        source = entry.source
        sourceChapterIndex = entry.sourceChapterIndex
        sourceUTF16Offset = entry.sourceUTF16Offset
        stage = entry.stage
        dueAt = entry.dueAt
        createdAt = entry.createdAt
        lastReviewedAt = entry.lastReviewedAt
    }

    func makeModel(book: Book?) -> VocabEntry {
        let entry = VocabEntry(
            word: word,
            meaning: meaning,
            phonetic: phonetic,
            partOfSpeech: partOfSpeech,
            note: note,
            sentence: sentence,
            source: source
        )
        apply(to: entry, book: book)
        return entry
    }

    func apply(to entry: VocabEntry, book: Book?) {
        entry.id = id
        entry.word = word
        entry.phonetic = phonetic
        entry.partOfSpeech = partOfSpeech
        entry.meaning = meaning
        entry.note = note
        entry.sentence = sentence
        entry.source = source
        entry.sourceChapterIndex = sourceChapterIndex
        entry.sourceUTF16Offset = sourceUTF16Offset
        entry.book = book
        entry.stage = stage
        entry.dueAt = dueAt
        entry.createdAt = createdAt
        entry.lastReviewedAt = lastReviewedAt
    }
}

private extension ReaderNotesBackupPackage.BookmarkRecord {
    init(_ bookmark: Bookmark) {
        id = bookmark.id
        bookID = bookmark.book?.id
        chapterIndex = bookmark.chapterIndex
        utf16Offset = bookmark.utf16Offset
        snippet = bookmark.snippet
        createdAt = bookmark.createdAt
    }

    func makeModel() -> Bookmark {
        let bookmark = Bookmark(
            chapterIndex: chapterIndex,
            utf16Offset: utf16Offset,
            snippet: snippet
        )
        apply(to: bookmark, book: nil)
        return bookmark
    }

    func apply(to bookmark: Bookmark, book: Book?) {
        bookmark.id = id
        bookmark.book = book
        bookmark.chapterIndex = chapterIndex
        bookmark.utf16Offset = utf16Offset
        bookmark.snippet = snippet
        bookmark.createdAt = createdAt
    }
}

private extension ReaderNotesBackupPackage.StudyCardRecord {
    init(_ card: StudyCardEntry) {
        id = card.id
        bookID = card.book?.id
        question = card.question
        answer = card.answer
        source = card.source
        highlightID = card.highlightID
        sourceChapterIndex = card.sourceChapterIndex
        sourceUTF16Offset = card.sourceUTF16Offset
        kind = card.kind
        stage = card.stage
        dueAt = card.dueAt
        createdAt = card.createdAt
        lastReviewedAt = card.lastReviewedAt
    }

    func makeModel() -> StudyCardEntry {
        let card = StudyCardEntry(
            question: question,
            answer: answer,
            source: source,
            highlightID: highlightID,
            kind: kind
        )
        apply(to: card, book: nil)
        return card
    }

    func apply(to card: StudyCardEntry, book: Book?) {
        card.id = id
        card.question = question
        card.answer = answer
        card.source = source
        card.highlightID = highlightID
        card.sourceChapterIndex = sourceChapterIndex
        card.sourceUTF16Offset = sourceUTF16Offset
        card.kind = kind
        card.stage = stage
        card.dueAt = dueAt
        card.createdAt = createdAt
        card.lastReviewedAt = lastReviewedAt
        card.book = book
    }
}

private extension ReaderNotesBackupPackage.MemoryItemRecord {
    init(_ memory: MemoryItem) {
        id = memory.id
        kind = memory.kind
        title = memory.title
        body = memory.body
        bookID = memory.bookID
        chapterIndex = memory.chapterIndex
        sourceLabel = memory.sourceLabel
        tags = memory.tags
        sourceRefID = memory.sourceRefID
        sourceRefKind = memory.sourceRefKind
        createdAt = memory.createdAt
        updatedAt = memory.updatedAt
        isUserConfirmed = memory.isUserConfirmed
    }

    func makeModel() -> MemoryItem {
        let memory = MemoryItem(
            kind: kind,
            title: title,
            body: body,
            bookID: bookID,
            chapterIndex: chapterIndex,
            sourceLabel: sourceLabel,
            tags: tags,
            sourceRefID: sourceRefID,
            sourceRefKind: sourceRefKind,
            isUserConfirmed: isUserConfirmed
        )
        apply(to: memory)
        return memory
    }

    func apply(to memory: MemoryItem) {
        memory.id = id
        memory.kind = kind
        memory.title = title
        memory.body = body
        memory.bookID = bookID
        memory.chapterIndex = chapterIndex
        memory.sourceLabel = sourceLabel
        memory.tags = tags
        memory.sourceRefID = sourceRefID
        memory.sourceRefKind = sourceRefKind
        memory.createdAt = createdAt
        memory.updatedAt = updatedAt
        memory.isUserConfirmed = isUserConfirmed
    }
}
