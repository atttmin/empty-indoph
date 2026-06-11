//
//  BookmarkStore.swift
//  Empty
//

import Foundation
import SwiftData

/// Creates, lists, toggles, and deletes reader bookmarks (P0 drawer).
@MainActor
struct BookmarkStore {
    let modelContext: ModelContext

    /// Bookmarks of `book` in reading order.
    func bookmarks(for book: Book) throws -> [Bookmark] {
        let bookID = book.id
        return try modelContext.fetch(
            FetchDescriptor<Bookmark>(
                predicate: #Predicate { $0.book?.id == bookID },
                sortBy: [
                    SortDescriptor(\.chapterIndex),
                    SortDescriptor(\.utf16Offset),
                ]
            )
        )
    }

    /// Adds a bookmark at the position, or removes the existing one nearby
    /// (within ~a page) — the ⌘D toggle the prototype shows.
    /// Returns true when a bookmark was added.
    @discardableResult
    func toggle(
        book: Book,
        chapterIndex: Int,
        utf16Offset: Int,
        snippet: String
    ) throws -> Bool {
        let existing = try bookmarks(for: book).first {
            $0.chapterIndex == chapterIndex
                && abs($0.utf16Offset - utf16Offset) < 600
        }
        if let existing {
            modelContext.delete(existing)
            try modelContext.save()
            return false
        }
        let bookmark = Bookmark(
            chapterIndex: chapterIndex,
            utf16Offset: utf16Offset,
            snippet: String(snippet.prefix(80))
        )
        modelContext.insert(bookmark)
        bookmark.book = book
        try modelContext.save()
        return true
    }

    func delete(_ bookmark: Bookmark) throws {
        modelContext.delete(bookmark)
        try modelContext.save()
    }
}

/// One full-text search hit inside a book.
nonisolated struct BookSearchHit: Identifiable, Equatable {
    var chapterIndex: Int
    var utf16Offset: Int
    var snippet: String

    var id: String { "\(chapterIndex)-\(utf16Offset)" }
}

/// Local full-text search over a book's chapters, grouped for the
/// spoiler-safe drawer: hits in unread chapters fold behind a count.
@MainActor
struct BookTextSearch {
    let modelContext: ModelContext

    func search(
        book: Book,
        query: String,
        maxReadChapter: Int,
        limitPerChapter: Int = 8
    ) throws -> (read: [BookSearchHit], unread: [BookSearchHit]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return ([], []) }
        let bookID = book.id
        let chapters = try modelContext.fetch(
            FetchDescriptor<Chapter>(
                predicate: #Predicate { $0.bookID == bookID },
                sortBy: [SortDescriptor(\.index)]
            )
        )

        var read: [BookSearchHit] = []
        var unread: [BookSearchHit] = []
        for chapter in chapters {
            var found = 0
            var searchStart = chapter.text.startIndex
            while found < limitPerChapter,
                  let range = chapter.text.range(
                    of: trimmed,
                    options: [.caseInsensitive],
                    range: searchStart..<chapter.text.endIndex
                  ) {
                let utf16Offset = chapter.text[..<range.lowerBound].utf16.count
                let snippetStart = chapter.text.index(
                    range.lowerBound,
                    offsetBy: -24,
                    limitedBy: chapter.text.startIndex
                ) ?? chapter.text.startIndex
                let snippetEnd = chapter.text.index(
                    range.upperBound,
                    offsetBy: 44,
                    limitedBy: chapter.text.endIndex
                ) ?? chapter.text.endIndex
                let snippet = String(chapter.text[snippetStart..<snippetEnd])
                    .replacingOccurrences(of: "\n", with: " ")
                let hit = BookSearchHit(
                    chapterIndex: chapter.index,
                    utf16Offset: utf16Offset,
                    snippet: snippet
                )
                if chapter.index <= maxReadChapter {
                    read.append(hit)
                } else {
                    unread.append(hit)
                }
                found += 1
                searchStart = range.upperBound
            }
        }
        return (read, unread)
    }
}
