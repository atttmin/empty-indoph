//
//  HighlightTests.swift
//  EmptyTests
//

import Foundation
import SwiftData
import Testing
@testable import Empty

struct PlainTextSearchTests {
    @Test func findsExactCJKRangeWithCorrectUTF16Offsets() throws {
        let haystack = "阅读是思维的训练。🚀 专注是稀缺资源。"
        let range = try #require(PlainTextSearch.utf16Range(of: "专注是稀缺", in: haystack))

        let utf16 = Array(haystack.utf16)
        let sliced = String(decoding: utf16[range], as: UTF16.self)
        #expect(sliced == "专注是稀缺")
    }

    @Test func toleratesWhitespaceDivergence() throws {
        let haystack = "First line of text\ncontinues  here   with spaces."
        // The DOM rendered this with collapsed whitespace.
        let needle = "text continues here with"
        let range = try #require(PlainTextSearch.utf16Range(of: needle, in: haystack))

        let utf16 = Array(haystack.utf16)
        let sliced = String(decoding: utf16[range], as: UTF16.self)
        #expect(sliced.hasPrefix("text"))
        #expect(sliced.hasSuffix("with"))
        #expect(sliced.contains("\n"))
    }

    @Test func contextDisambiguatesRepeatedSelections() throws {
        let haystack = "他说今天不行。后来他又说今天可以。"
        // "说今天" appears twice; context points at the second occurrence.
        let range = try #require(
            PlainTextSearch.utf16Range(
                of: "说今天",
                prefix: "他又",
                suffix: "可以",
                in: haystack
            )
        )
        let first = try #require(PlainTextSearch.utf16Range(of: "说今天", in: haystack))
        #expect(range.lowerBound > first.lowerBound)
    }

    @Test func missingNeedleReturnsNil() {
        #expect(PlainTextSearch.utf16Range(of: "不存在的句子", in: "完全无关的内容。") == nil)
        #expect(PlainTextSearch.utf16Range(of: "", in: "内容") == nil)
    }
}

@MainActor
struct HighlightStoreTests {
    @Test func createAnchorsSelectionAgainstChapterText() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext

        let book = Book(title: "B", format: .epub)
        context.insert(book)
        let chapterText = "阅读训练思维。\n专注是这个时代最稀缺的资源。"
        let chapter = Chapter(bookID: book.id, index: 3, text: chapterText)
        context.insert(chapter)
        try context.save()

        let store = HighlightStore(modelContext: context)
        let highlight = try store.createHighlight(
            book: book,
            chapterIndex: 3,
            selection: "专注是这个时代",
            prefix: "思维。",
            suffix: "最稀缺"
        )

        #expect(highlight.chapterIndex == 3)
        #expect(highlight.textSnapshot == "专注是这个时代")
        #expect(highlight.book === book)

        // Anchor slices back to the selected text.
        let utf16 = Array(chapterText.utf16)
        let sliced = String(
            decoding: utf16[highlight.startUTF16..<highlight.endUTF16],
            as: UTF16.self
        )
        #expect(sliced == "专注是这个时代")

        _ = container
    }

    @Test func unlocatableSelectionSavesSnapshotOnly() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext

        let book = Book(title: "B", format: .epub)
        context.insert(book)
        context.insert(Chapter(bookID: book.id, index: 0, text: "章节正文。"))
        try context.save()

        let highlight = try HighlightStore(modelContext: context).createHighlight(
            book: book,
            chapterIndex: 0,
            selection: "渲染器吐出来的幽灵文本"
        )
        #expect(highlight.startUTF16 == 0)
        #expect(highlight.endUTF16 == 0)
        #expect(highlight.textSnapshot == "渲染器吐出来的幽灵文本")

        _ = container
    }

    @Test func listsPerChapterAndDeletes() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext

        let book = Book(title: "B", format: .epub)
        context.insert(book)
        context.insert(Chapter(bookID: book.id, index: 0, text: "第一章的内容在这里。"))
        context.insert(Chapter(bookID: book.id, index: 1, text: "第二章的内容在那里。"))
        try context.save()

        let store = HighlightStore(modelContext: context)
        try store.createHighlight(book: book, chapterIndex: 0, selection: "第一章的内容")
        try store.createHighlight(book: book, chapterIndex: 1, selection: "第二章的内容")

        #expect(try store.highlights(for: book).count == 2)
        let chapterOne = try store.highlights(for: book, chapterIndex: 1)
        #expect(chapterOne.count == 1)
        #expect(chapterOne[0].textSnapshot == "第二章的内容")

        try store.delete(chapterOne[0])
        #expect(try store.highlights(for: book).count == 1)

        _ = container
    }
}
