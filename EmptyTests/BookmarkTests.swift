//
//  BookmarkTests.swift
//  EmptyTests
//
//  P0 drawer: the ⌘D bookmark toggle and the spoiler-grouped full-text
//  search behind the 目录/书签/搜索 panel.
//

import Foundation
import SwiftData
import Testing
@testable import Empty

@MainActor
struct BookmarkStoreTests {
    private func makeFixture() throws -> (container: ModelContainer, book: Book) {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let book = Book(title: "B", format: .epub)
        context.insert(book)
        try context.save()
        return (container, book)
    }

    @Test func toggleAddsThenRemovesNearbyBookmark() throws {
        let fixture = try makeFixture()
        let store = BookmarkStore(modelContext: fixture.container.mainContext)

        let added = try store.toggle(
            book: fixture.book, chapterIndex: 1, utf16Offset: 1000, snippet: "片段"
        )
        #expect(added)
        #expect(try store.bookmarks(for: fixture.book).count == 1)

        // Within ~a page of the existing bookmark → toggle removes it.
        let addedAgain = try store.toggle(
            book: fixture.book, chapterIndex: 1, utf16Offset: 1300, snippet: "片段"
        )
        #expect(!addedAgain)
        #expect(try store.bookmarks(for: fixture.book).isEmpty)

        _ = fixture.container
    }

    @Test func bookmarksSortInReadingOrder() throws {
        let fixture = try makeFixture()
        let store = BookmarkStore(modelContext: fixture.container.mainContext)

        try store.toggle(book: fixture.book, chapterIndex: 3, utf16Offset: 10, snippet: "c")
        try store.toggle(book: fixture.book, chapterIndex: 0, utf16Offset: 99, snippet: "a")
        try store.toggle(book: fixture.book, chapterIndex: 1, utf16Offset: 5, snippet: "b")

        let ordered = try store.bookmarks(for: fixture.book)
        #expect(ordered.map(\.chapterIndex) == [0, 1, 3])

        _ = fixture.container
    }
}

@MainActor
struct BookTextSearchTests {
    @Test func groupsHitsBySpoilerBoundaryWithUTF16Offsets() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let book = Book(title: "B", format: .epub)
        context.insert(book)
        context.insert(Chapter(bookID: book.id, index: 0, text: "第一章。深读始于空白处。"))
        context.insert(Chapter(bookID: book.id, index: 1, text: "第二章。空白也是内容。"))
        context.insert(Chapter(bookID: book.id, index: 2, text: "终章。空白收束一切。"))
        try context.save()

        let result = try BookTextSearch(modelContext: context).search(
            book: book, query: "空白", maxReadChapter: 1
        )

        #expect(result.read.map(\.chapterIndex) == [0, 1])
        #expect(result.unread.map(\.chapterIndex) == [2])
        // Offsets must be exact UTF-16 positions of the match.
        let first = result.read[0]
        let chapterText = "第一章。深读始于空白处。"
        let expected = chapterText.range(of: "空白").map {
            chapterText[..<$0.lowerBound].utf16.count
        }
        #expect(first.utf16Offset == expected)

        _ = container
    }

    @Test func shortQueriesReturnNothing() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let book = Book(title: "B", format: .epub)
        context.insert(book)
        context.insert(Chapter(bookID: book.id, index: 0, text: "空"))
        try context.save()

        let result = try BookTextSearch(modelContext: context).search(
            book: book, query: "空", maxReadChapter: 0
        )
        #expect(result.read.isEmpty && result.unread.isEmpty)

        _ = container
    }
}
