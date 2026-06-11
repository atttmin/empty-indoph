//
//  RetrievalTests.swift
//  EmptyTests
//

import Foundation
import SwiftData
import Testing
@testable import Empty

@MainActor
struct BookIndexerTests {
    @Test func buildsChunksAcrossChaptersIdempotently() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext

        let book = Book(title: "Indexed", format: .epub)
        context.insert(book)
        let chapterOne = Chapter(
            bookID: book.id,
            index: 0,
            title: "一",
            text: String(repeating: "第一章的内容句子。", count: 80)
        )
        let chapterTwo = Chapter(
            bookID: book.id,
            index: 1,
            title: "二",
            text: String(repeating: "Second chapter sentence here. ", count: 60)
        )
        context.insert(chapterOne)
        context.insert(chapterTwo)
        try context.save()

        let indexer = BookIndexer(modelContext: context)
        let created = try indexer.ensureChunks(for: book)
        #expect(created > 2)

        let chunks = try context.fetch(
            FetchDescriptor<Chunk>(sortBy: [SortDescriptor(\Chunk.ordinal)])
        )
        #expect(chunks.count == created)
        // Ordinals are the global reading order.
        #expect(chunks.map(\.ordinal) == Array(0..<created))
        // Chapter indexes carried into anchors; both chapters represented.
        #expect(Set(chunks.map(\.chapterIndex)) == [0, 1])
        // Anchors stay within their chapter's text bounds.
        for chunk in chunks {
            let chapter = chunk.chapterIndex == 0 ? chapterOne : chapterTwo
            #expect(chunk.startUTF16 >= 0)
            #expect(chunk.endUTF16 <= chapter.utf16Length)
            #expect(chunk.chapter === chapter)
        }

        // Second run is a no-op.
        let second = try indexer.ensureChunks(for: book)
        #expect(second == created)
        #expect(try context.fetchCount(FetchDescriptor<Chunk>()) == created)

        _ = container
    }

    @Test func bookWithoutChaptersYieldsZeroChunks() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let book = Book(title: "Empty", format: .pdf)
        context.insert(book)
        try context.save()

        #expect(try BookIndexer(modelContext: context).ensureChunks(for: book) == 0)
        _ = container
    }
}

@MainActor
struct ChunkRetrieverTests {
    private func seed(context: ModelContext, bookID: UUID) throws {
        let chunks = [
            Chunk(
                bookID: bookID,
                ordinal: 0,
                anchor: TextAnchor(chapterIndex: 0, startUTF16: 0, endUTF16: 100),
                text: "乔伊走进了图书馆，挑了一本侦探小说。"
            ),
            Chunk(
                bookID: bookID,
                ordinal: 1,
                anchor: TextAnchor(chapterIndex: 1, startUTF16: 0, endUTF16: 80),
                text: "管家端来了咖啡，大家围坐在壁炉旁。"
            ),
            // Past the reader's position — the spoiler.
            Chunk(
                bookID: bookID,
                ordinal: 2,
                anchor: TextAnchor(chapterIndex: 1, startUTF16: 80, endUTF16: 200),
                text: "真相大白：凶手就是管家本人！"
            ),
        ]
        for chunk in chunks {
            context.insert(chunk)
        }
        try context.save()
    }

    @Test func spoilerChunksNeverSurfaceEvenWhenTheyMatchBest() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let bookID = UUID()
        try seed(context: context, bookID: bookID)

        // Reader is mid-chapter 1, offset 80: chunk 2 is unread.
        let results = try ChunkRetriever(modelContext: context).retrieve(
            question: "凶手是谁？",
            bookID: bookID,
            position: ReadingPosition(chapterIndex: 1, utf16Offset: 80)
        )

        #expect(!results.isEmpty)
        #expect(!results.map(\.ordinal).contains(2))
        _ = container
    }

    @Test func lexicalMatchRanksFirst() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let bookID = UUID()
        try seed(context: context, bookID: bookID)

        let results = try ChunkRetriever(modelContext: context).retrieve(
            question: "图书馆里发生了什么",
            bookID: bookID,
            position: ReadingPosition(chapterIndex: 1, utf16Offset: 80)
        )
        #expect(results.first?.ordinal == 0)
        _ = container
    }

    @Test func zeroLexicalOverlapFallsBackToRecentChunks() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let bookID = UUID()
        try seed(context: context, bookID: bookID)

        let results = try ChunkRetriever(modelContext: context).retrieve(
            question: "summarize the situation",
            bookID: bookID,
            position: ReadingPosition(chapterIndex: 1, utf16Offset: 80),
            limit: 1
        )
        // Most recent read chunk, never the unread one.
        #expect(results.map(\.ordinal) == [1])
        _ = container
    }

    @Test func emptyWhenNothingReadYet() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let bookID = UUID()
        try seed(context: context, bookID: bookID)

        let results = try ChunkRetriever(modelContext: context).retrieve(
            question: "乔伊",
            bookID: bookID,
            position: .start
        )
        #expect(results.isEmpty)
        _ = container
    }
}
