//
//  RecapTests.swift
//  EmptyTests
//

import Foundation
import SwiftData
import Testing
@testable import Empty

@MainActor
struct FullyReadTextTests {
    @Test func gathersOnlyChaptersBehindPositionInOrder() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let bookID = UUID()
        let otherBookID = UUID()

        context.insert(Chapter(bookID: bookID, index: 0, title: "Intro", text: "开篇内容。"))
        context.insert(Chapter(bookID: bookID, index: 1, title: "第一章", text: "第一章内容。"))
        context.insert(Chapter(bookID: bookID, index: 2, title: "第二章", text: "第二章剧透内容。"))
        context.insert(Chapter(bookID: otherBookID, index: 0, title: "Other", text: "别的书的内容。"))
        try context.save()

        let text = try Chapter.fullyReadText(
            forBookID: bookID,
            before: ReadingPosition(chapterIndex: 2, utf16Offset: 0),
            in: context
        )

        #expect(text.contains("开篇内容。"))
        #expect(text.contains("第一章内容。"))
        #expect(text.contains("Intro"))
        #expect(text.contains("第一章"))
        // Spoiler safety: nothing at or past the position, nothing cross-book.
        #expect(!text.contains("第二章剧透内容。"))
        #expect(!text.contains("别的书的内容。"))

        // Reading order preserved.
        let first = try #require(text.range(of: "开篇内容。"))
        let second = try #require(text.range(of: "第一章内容。"))
        #expect(first.lowerBound < second.lowerBound)

        _ = container
    }

    @Test func emptyWhenNothingReadYet() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let bookID = UUID()
        context.insert(Chapter(bookID: bookID, index: 0, title: "Intro", text: "内容"))
        try context.save()

        let text = try Chapter.fullyReadText(
            forBookID: bookID,
            before: .start,
            in: context
        )
        #expect(text.isEmpty)
        _ = container
    }

    @Test func skipsWhitespaceOnlyChaptersAndFallsBackToNumberedHeading() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let bookID = UUID()

        context.insert(Chapter(bookID: bookID, index: 0, title: nil, text: "正文。"))
        context.insert(Chapter(bookID: bookID, index: 1, title: "空白章", text: "   \n  "))
        try context.save()

        let text = try Chapter.fullyReadText(
            forBookID: bookID,
            before: ReadingPosition(chapterIndex: 2, utf16Offset: 0),
            in: context
        )

        #expect(text.contains("Chapter 1"))
        #expect(text.contains("正文。"))
        #expect(!text.contains("空白章"))
        _ = container
    }
}

struct CharacterBudgetTests {
    @Test func latinTextGetsGenerousCharacterBudget() {
        let english = String(repeating: "Reading is thinking with someone else's head. ", count: 50)
        let budget = CharacterBudget.characters(forTokens: 2_600, in: english)
        // ~0.4 tokens/char → ~6500 chars.
        #expect(budget > 5_000)
        #expect(budget < 8_000)
    }

    @Test func cjkTextGetsTightCharacterBudget() {
        let chinese = String(repeating: "思维阅读是一种主动的阅读方式，强调理解与联结。", count: 100)
        let budget = CharacterBudget.characters(forTokens: 2_600, in: chinese)
        // ~1.6 tokens/char → ~1600 chars; must stay well under the old
        // fixed 2800 that overflowed the context window.
        #expect(budget > 1_000)
        #expect(budget < 2_200)
    }

    @Test func mixedTextLandsBetween() {
        let mixed = String(repeating: "思维阅读 means reading with your mind switched on. ", count: 60)
        let budget = CharacterBudget.characters(forTokens: 2_600, in: mixed)
        let latin = CharacterBudget.characters(forTokens: 2_600, in: String(repeating: "a word ", count: 800))
        let cjk = CharacterBudget.characters(forTokens: 2_600, in: String(repeating: "思维阅读方式", count: 500))
        #expect(budget > cjk)
        #expect(budget < latin)
    }

    @Test func floorAndEmptyTextDefaults() {
        #expect(CharacterBudget.characters(forTokens: 10, in: "思维") == 500)
        let emptyBudget = CharacterBudget.characters(forTokens: 2_600, in: "")
        #expect(emptyBudget == 6_500)
    }
}

@MainActor
struct RecapBuilderTests {
    private func seed(
        context: ModelContext,
        longChapterText: String
    ) throws -> Book {
        let book = Book(title: "B", format: .epub)
        context.insert(book)
        context.insert(Chapter(bookID: book.id, index: 0, title: "Cover", text: "封面"))
        context.insert(Chapter(bookID: book.id, index: 1, title: "第一章", text: longChapterText))
        context.insert(Chapter(bookID: book.id, index: 2, title: "第二章", text: "未读章节" + longChapterText))
        try context.save()
        return book
    }

    @Test func cachesChapterSummariesAndReusesThem() async throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let longText = String(repeating: "第一章正文内容，足够长以触发摘要。", count: 30)
        let book = try seed(context: context, longChapterText: longText)

        var digestCalls = 0
        var recapCalls = 0
        let builder = RecapBuilder(modelContext: context) { text, focus in
            switch focus {
            case .digest:
                digestCalls += 1
                return "【摘要】"
            case .recap:
                recapCalls += 1
                #expect(text.contains("【摘要】")) // reduce runs over summaries
                #expect(text.contains("封面")) // short chapter passed verbatim
                #expect(!text.contains("未读章节")) // spoiler safety
                return "前情提要"
            case .argument:
                return ""
            }
        }

        let position = ReadingPosition(chapterIndex: 2, utf16Offset: 0)
        let first = try await builder.recap(for: book, before: position)
        #expect(first == "前情提要")
        #expect(digestCalls == 1) // only the long chapter needed a model call
        #expect(recapCalls == 1)

        // Cache persisted on the chapter…
        let bookID = book.id
        let chapters = try context.fetch(
            FetchDescriptor<Chapter>(
                predicate: #Predicate { $0.bookID == bookID && $0.index == 1 }
            )
        )
        #expect(chapters.first?.cachedSummary == "【摘要】")

        // …so the second recap pays zero digest calls.
        _ = try await builder.recap(for: book, before: position)
        #expect(digestCalls == 1)
        #expect(recapCalls == 2)

        _ = container
    }

    @Test func throwsEmptyInputWhenNothingRead() async throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let book = try seed(
            context: context,
            longChapterText: String(repeating: "正文。", count: 100)
        )

        let builder = RecapBuilder(modelContext: context) { _, _ in "x" }
        await #expect(throws: AIServiceError.self) {
            _ = try await builder.recap(for: book, before: .start)
        }
        _ = container
    }
}
