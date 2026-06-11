//
//  TextChunkerTests.swift
//  EmptyTests
//

import Foundation
import Testing
@testable import Empty

struct TextChunkerTests {
    @Test func offsetsSliceBackToVerbatimText() {
        let text = """
        第一段，含有表情🚀和一些 English words 混排的内容。

        Second paragraph is plain ASCII text with several words in it.

        第三段比较短。
        """
        let chunks = TextChunker.chunks(of: text, maxCharacters: 60)
        #expect(!chunks.isEmpty)

        let utf16 = Array(text.utf16)
        for chunk in chunks {
            let slice = utf16[chunk.startUTF16..<chunk.endUTF16]
            #expect(Array(chunk.text.utf16) == Array(slice))
        }
    }

    @Test func chunksRespectBudgetAndMonotonicOrder() {
        let paragraphs = (0..<30).map { "Paragraph \($0) with a handful of words inside." }
        let text = paragraphs.joined(separator: "\n\n")
        let chunks = TextChunker.chunks(of: text, maxCharacters: 120)

        #expect(chunks.count > 1)
        var previousEnd = -1
        for chunk in chunks {
            #expect(chunk.text.count <= 120)
            #expect(chunk.startUTF16 > previousEnd || previousEnd == -1)
            #expect(chunk.startUTF16 < chunk.endUTF16)
            previousEnd = chunk.endUTF16
        }
    }

    @Test func contentSurvivesChunking() {
        let text = """
        阅读是一种思维训练。它要求专注。

        而专注，恰恰是这个时代最稀缺的资源。我们需要刻意练习。
        """
        let chunks = TextChunker.chunks(of: text, maxCharacters: 20)
        let joined = chunks.map(\.text).joined()
        #expect(nonWhitespace(joined) == nonWhitespace(text))
    }

    @Test func oversizedSingleSentenceHardCutsOnGraphemes() {
        let text = String(repeating: "🚀思维", count: 100) // no sentence breaks
        let chunks = TextChunker.chunks(of: text, maxCharacters: 50)
        for chunk in chunks {
            #expect(chunk.text.count <= 50)
        }
        let utf16 = Array(text.utf16)
        for chunk in chunks {
            #expect(Array(chunk.text.utf16) == Array(utf16[chunk.startUTF16..<chunk.endUTF16]))
        }
        #expect(nonWhitespace(chunks.map(\.text).joined()) == nonWhitespace(text))
    }

    private func nonWhitespace(_ string: String) -> String {
        String(string.filter { !$0.isWhitespace })
    }
}

struct LexicalScorerTests {
    @Test func cjkBigramsRankRelatedTextHigher() {
        let query = "凶手是谁"
        let related = LexicalScorer.score(query: query, text: "大家都怀疑凶手就在屋子里。")
        let unrelated = LexicalScorer.score(query: query, text: "今天天气晴朗，适合散步。")
        #expect(related > unrelated)
        #expect(related > 0)
    }

    @Test func latinMatchingIsCaseInsensitive() {
        let score = LexicalScorer.score(query: "Where is JOEY", text: "joey went back home.")
        #expect(score > 0)
    }

    @Test func emptyQueryScoresZero() {
        #expect(LexicalScorer.score(query: "  ", text: "anything") == 0)
    }

    @Test func tokensMixScriptsCorrectly() {
        let tokens = LexicalScorer.tokens(of: "读书Notes：思考")
        #expect(tokens.contains("notes"))
        #expect(tokens.contains("读书"))
        #expect(tokens.contains("思"))
        #expect(tokens.contains("思考"))
        // No bigram across the latin break.
        #expect(!tokens.contains("书n"))
    }
}
