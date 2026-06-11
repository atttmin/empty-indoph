//
//  PersistenceTests.swift
//  EmptyTests
//

import Foundation
import SwiftData
import Testing
@testable import Empty

@MainActor
struct PersistenceTests {
    @Test func containerHostsBothStores() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext

        let book = Book(title: "Thinking, Fast and Slow", format: .epub)
        context.insert(book)
        let chapter = Chapter(bookID: book.id, index: 0, title: "Intro", text: "Hello reader.")
        context.insert(chapter)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Chapter>()) == 1)
    }


    @Test func memoryModelsStayInTheirIntendedStores() {
        #expect(AppStores.placement(for: MemoryItem.self) == .synced)
        #expect(AppStores.placement(for: MemoryEmbedding.self) == .local)
        #expect(AppStores.placement(for: Chapter.self) == .local)
        #expect(AppStores.placement(for: Book.self) == .synced)
    }

    @Test func deletingBookCascadesToHighlightsAndSessions() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext

        let book = Book(title: "Book", format: .epub)
        context.insert(book)
        let highlight = Highlight(
            anchor: TextAnchor(chapterIndex: 0, startUTF16: 0, endUTF16: 5),
            textSnapshot: "Hello"
        )
        context.insert(highlight)
        highlight.book = book
        let session = ReadingSession(startPosition: .start)
        context.insert(session)
        session.book = book
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<Highlight>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ReadingSession>()) == 1)

        context.delete(book)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<Highlight>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ReadingSession>()) == 0)
    }

    @Test func deletingBookCascadesToStudyCards() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext

        let book = Book(title: "Book", format: .epub)
        context.insert(book)
        let card = StudyCardEntry(question: "Q?", answer: "A.")
        context.insert(card)
        card.book = book
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<StudyCardEntry>()) == 1)

        context.delete(book)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<StudyCardEntry>()) == 0)
    }

    @Test func chapterTextRoundTripsAndCachesLength() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext

        let text = "思维阅读 — reading with your mind on. 🚀"
        let chapter = Chapter(bookID: UUID(), index: 0, text: text)
        context.insert(chapter)
        try context.save()

        #expect(chapter.text == text)
        #expect(chapter.utf16Length == text.utf16.count)
    }

    @Test func spoilerSafePredicateSelectsOnlyFullyReadChunks() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let bookID = UUID()

        let chunks = [
            Chunk(
                bookID: bookID,
                ordinal: 0,
                anchor: TextAnchor(chapterIndex: 0, startUTF16: 0, endUTF16: 100),
                text: "c0"
            ),
            Chunk(
                bookID: bookID,
                ordinal: 1,
                anchor: TextAnchor(chapterIndex: 1, startUTF16: 0, endUTF16: 80),
                text: "c1"
            ),
            Chunk(
                bookID: bookID,
                ordinal: 2,
                anchor: TextAnchor(chapterIndex: 1, startUTF16: 80, endUTF16: 200),
                text: "c2"
            ),
            Chunk(
                bookID: bookID,
                ordinal: 3,
                anchor: TextAnchor(chapterIndex: 2, startUTF16: 0, endUTF16: 50),
                text: "c3"
            ),
            // A different book entirely — must never match.
            Chunk(
                bookID: UUID(),
                ordinal: 0,
                anchor: TextAnchor(chapterIndex: 0, startUTF16: 0, endUTF16: 10),
                text: "other"
            ),
        ]
        for chunk in chunks {
            context.insert(chunk)
        }
        try context.save()

        // Reader is mid-chapter 1 at offset 80: c0 and c1 read, c2/c3 not.
        let position = ReadingPosition(chapterIndex: 1, utf16Offset: 80)
        let fetched = try context.fetch(
            FetchDescriptor(
                predicate: Chunk.fullyReadPredicate(bookID: bookID, position: position),
                sortBy: [SortDescriptor(\Chunk.ordinal)]
            )
        )
        #expect(fetched.map(\.ordinal) == [0, 1])
    }

    @Test func readingPositionOrderingAndAnchorSafety() {
        let earlier = ReadingPosition(chapterIndex: 1, utf16Offset: 500)
        let later = ReadingPosition(chapterIndex: 2, utf16Offset: 0)
        #expect(earlier < later)
        #expect(
            ReadingPosition(chapterIndex: 1, utf16Offset: 10)
                < ReadingPosition(chapterIndex: 1, utf16Offset: 11)
        )

        let anchor = TextAnchor(chapterIndex: 1, startUTF16: 480, endUTF16: 500)
        #expect(anchor.isFullyRead(at: earlier))
        #expect(!anchor.isFullyRead(at: ReadingPosition(chapterIndex: 1, utf16Offset: 499)))
    }
}
