//
//  ReaderNotesBackupTests.swift
//  EmptyTests
//

import Foundation
import SwiftData
import Testing
@testable import Empty

@MainActor
struct ReaderNotesBackupTests {
    @Test func exportIncludesReaderDataAndExcludesDerivedText() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        try seedReaderData(in: container.mainContext)

        let package = try ReaderNotesBackupStore(modelContext: container.mainContext)
            .exportPackage(now: fixedDate(100))
        let encoded = String(
            data: try ReaderNotesBackupCodec.encode(package),
            encoding: .utf8
        ) ?? ""

        #expect(package.manifest.schemaVersion == ReaderNotesBackupPackage.schemaVersion)
        #expect(package.manifest.recordCounts == package.counts)
        #expect(package.counts.books == 1)
        #expect(package.counts.highlights == 1)
        #expect(package.counts.readingSessions == 1)
        #expect(package.counts.vocabEntries == 1)
        #expect(package.counts.bookmarks == 1)
        #expect(package.counts.studyCards == 1)
        #expect(package.studyCards.first?.sourceChapterIndex == 0)
        #expect(package.studyCards.first?.sourceUTF16Offset == 3)
        #expect(package.vocabEntries.first?.bookID == package.books.first?.id)
        #expect(package.vocabEntries.first?.sourceChapterIndex == 0)
        #expect(package.vocabEntries.first?.sourceUTF16Offset == 5)
        #expect(package.counts.memoryItems == 1)
        #expect(encoded.contains("深读始于空白"))
        #expect(!encoded.contains("NEVER_EXPORT_FULL_TEXT"))
    }

    @Test func importRestoresReaderDataAndIsIdempotent() throws {
        let source = try AppStores.makeContainer(ephemeral: true)
        let sourceBook = try seedReaderData(in: source.mainContext)
        let package = try ReaderNotesBackupStore(modelContext: source.mainContext)
            .exportPackage(now: fixedDate(100))

        let target = try AppStores.makeContainer(ephemeral: true)
        let store = ReaderNotesBackupStore(modelContext: target.mainContext)

        let inserted = try store.importPackage(package)
        #expect(inserted.inserted.total == 7)
        #expect(inserted.updated.total == 0)

        let books = try target.mainContext.fetch(FetchDescriptor<Book>())
        let highlights = try target.mainContext.fetch(FetchDescriptor<Highlight>())
        let sessions = try target.mainContext.fetch(FetchDescriptor<ReadingSession>())
        let vocab = try target.mainContext.fetch(FetchDescriptor<VocabEntry>())
        let bookmarks = try target.mainContext.fetch(FetchDescriptor<Bookmark>())
        let cards = try target.mainContext.fetch(FetchDescriptor<StudyCardEntry>())
        let memories = try target.mainContext.fetch(FetchDescriptor<MemoryItem>())

        #expect(books.count == 1)
        #expect(books.first?.id == sourceBook.id)
        #expect(highlights.first?.book?.id == sourceBook.id)
        #expect(sessions.first?.book?.id == sourceBook.id)
        #expect(bookmarks.first?.book?.id == sourceBook.id)
        #expect(cards.first?.book?.id == sourceBook.id)
        #expect(cards.first?.sourcePosition == ReadingPosition(chapterIndex: 0, utf16Offset: 3))
        #expect(vocab.first?.word == "resignation")
        #expect(vocab.first?.book?.id == sourceBook.id)
        #expect(vocab.first?.sourcePosition == ReadingPosition(chapterIndex: 0, utf16Offset: 5))
        #expect(memories.first?.tags == ["空白", "深读"])

        let updated = try store.importPackage(package)
        #expect(updated.inserted.total == 0)
        #expect(updated.updated.total == 7)
        #expect(try target.mainContext.fetch(FetchDescriptor<Book>()).count == 1)
        #expect(try target.mainContext.fetch(FetchDescriptor<Highlight>()).count == 1)
        #expect(try target.mainContext.fetch(FetchDescriptor<MemoryItem>()).count == 1)
    }

    @Test func importKeepsNewerLocalMemory() throws {
        let source = try AppStores.makeContainer(ephemeral: true)
        try seedReaderData(in: source.mainContext)
        let package = try ReaderNotesBackupStore(modelContext: source.mainContext)
            .exportPackage(now: fixedDate(100))
        let record = try #require(package.memoryItems.first)

        let target = try AppStores.makeContainer(ephemeral: true)
        let local = MemoryItem(
            kind: record.kind,
            title: "本机更新",
            body: "不要被旧备份覆盖",
            tags: ["local"],
            isUserConfirmed: true
        )
        local.id = record.id
        local.createdAt = fixedDate(1)
        local.updatedAt = record.updatedAt.addingTimeInterval(60)
        target.mainContext.insert(local)
        try target.mainContext.save()

        let summary = try ReaderNotesBackupStore(modelContext: target.mainContext)
            .importPackage(package)
        let memories = try target.mainContext.fetch(FetchDescriptor<MemoryItem>())

        #expect(summary.skipped.memoryItems == 1)
        #expect(memories.count == 1)
        #expect(memories.first?.title == "本机更新")
    }

    @Test func codecRejectsUnsupportedSchemaVersion() throws {
        let package = ReaderNotesBackupPackage(
            manifest: .init(
                schemaVersion: 999,
                exportedAt: fixedDate(0),
                appVersion: "test",
                recordCounts: ReaderNotesRecordCounts()
            ),
            books: [],
            highlights: [],
            readingSessions: [],
            vocabEntries: [],
            bookmarks: [],
            studyCards: [],
            memoryItems: []
        )

        #expect(throws: ReaderNotesBackupError.unsupportedSchema(999)) {
            _ = try ReaderNotesBackupCodec.decode(try ReaderNotesBackupCodec.encode(package))
        }
    }

    @discardableResult
    private func seedReaderData(in context: ModelContext) throws -> Book {
        let book = Book(title: "思维之书", author: "测试作者", format: .epub)
        book.id = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        book.languageTag = "zh-Hans"
        book.fileRelativePath = "00000000-0000-0000-0000-000000000101/book.epub"
        book.coverThumbnailData = Data([1, 2, 3])
        book.addedAt = fixedDate(1)
        book.lastOpenedAt = fixedDate(2)
        book.position = ReadingPosition(chapterIndex: 2, utf16Offset: 20)
        book.progressFraction = 0.5
        book.cachedHeroRecap = "上次读到这里"
        book.cachedHeroRecapChapterIndex = 1
        context.insert(book)
        context.insert(Chapter(
            bookID: book.id,
            index: 0,
            title: "起 · 空白",
            text: "NEVER_EXPORT_FULL_TEXT"
        ))

        let highlight = Highlight(
            anchor: TextAnchor(chapterIndex: 0, startUTF16: 2, endUTF16: 8),
            textSnapshot: "深读始于空白",
            color: .vermilion,
            note: "第一条批注"
        )
        highlight.id = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        highlight.createdAt = fixedDate(3)
        context.insert(highlight)
        highlight.book = book

        let session = ReadingSession(
            startPosition: ReadingPosition(chapterIndex: 0, utf16Offset: 0),
            startedAt: fixedDate(4)
        )
        session.id = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        session.endPosition = ReadingPosition(chapterIndex: 0, utf16Offset: 8)
        session.endedAt = fixedDate(5)
        session.activeSeconds = 120
        context.insert(session)
        session.book = book

        let vocab = VocabEntry(
            word: "resignation",
            meaning: "听任 / 顺受",
            phonetic: "/ˌrezɪɡˈneɪʃn/",
            partOfSpeech: "n.",
            note: "不是辞职",
            sentence: "A kind of resignation.",
            source: "思维之书 · 起"
        )
        vocab.id = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        vocab.stage = 4
        vocab.dueAt = fixedDate(6)
        vocab.createdAt = fixedDate(7)
        vocab.lastReviewedAt = fixedDate(8)
        vocab.setSourcePosition(ReadingPosition(chapterIndex: 0, utf16Offset: 5))
        context.insert(vocab)
        vocab.book = book

        let bookmark = Bookmark(chapterIndex: 0, utf16Offset: 4, snippet: "一章正文")
        bookmark.id = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
        bookmark.createdAt = fixedDate(9)
        context.insert(bookmark)
        bookmark.book = book

        let card = StudyCardEntry(
            question: "为什么空白重要？",
            answer: "它让读者停下来。",
            source: "思维之书 · 起",
            highlightID: highlight.id,
            kind: .review
        )
        card.id = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
        card.stage = 3
        card.dueAt = fixedDate(10)
        card.createdAt = fixedDate(11)
        card.lastReviewedAt = fixedDate(12)
        card.setSourcePosition(ReadingPosition(chapterIndex: 0, utf16Offset: 3))
        context.insert(card)
        card.book = book

        let memory = MemoryItem(
            kind: .highlightNote,
            title: "空白与深读",
            body: "读者关注空白如何制造注意力。",
            bookID: book.id,
            chapterIndex: 0,
            sourceLabel: "思维之书 · 起",
            tags: ["空白", "深读"],
            sourceRefID: highlight.id,
            sourceRefKind: "highlight",
            isUserConfirmed: true
        )
        memory.id = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
        memory.createdAt = fixedDate(13)
        memory.updatedAt = fixedDate(14)
        context.insert(memory)

        try context.save()
        return book
    }

    private func fixedDate(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }
}
