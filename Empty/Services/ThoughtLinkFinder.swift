//
//  ThoughtLinkFinder.swift
//  Empty
//

import Foundation
import SwiftData

/// A cross-highlight connection surfaced while reading — lexical first,
/// AI explanation optional.
nonisolated struct ThoughtLink: Equatable, Sendable {
    var currentText: String
    var currentSource: String
    var relatedText: String
    var relatedSource: String
    var relatedBookTitle: String
    var explanation: String
}

/// Finds the strongest lexical link between a passage and the reader's
/// prior highlights on other books (or earlier chapters).
@MainActor
struct ThoughtLinkFinder {
    let modelContext: ModelContext

    func findLink(
        passage: String,
        book: Book,
        chapterIndex: Int
    ) throws -> ThoughtLink? {
        let highlights = try modelContext.fetch(
            FetchDescriptor<Highlight>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        )
        let candidates = highlights.filter { highlight in
            guard let highlightBook = highlight.book else { return false }
            guard highlightBook.id != book.id
                || highlight.chapterIndex < chapterIndex else { return false }
            return LexicalScorer.score(
                query: passage,
                text: highlight.textSnapshot
            ) > 0.15
        }
        guard let best = candidates.max(by: { lhs, rhs in
            LexicalScorer.score(query: passage, text: lhs.textSnapshot)
                < LexicalScorer.score(query: passage, text: rhs.textSnapshot)
        }) else { return nil }

        let relatedBook = best.book?.title ?? "另一本书"
        let relatedSource = "\(relatedBook) · 第 \(best.chapterIndex + 1) 章"
        let currentSource = "\(book.title) · 第 \(chapterIndex + 1) 章"
        return ThoughtLink(
            currentText: String(passage.prefix(160)),
            currentSource: currentSource,
            relatedText: best.textSnapshot,
            relatedSource: relatedSource,
            relatedBookTitle: relatedBook,
            explanation: "两段文字在主题上相呼应 — 都在做生活的减法,把注意力收回到自己可以掌控的核心。"
        )
    }

    func explainLink(_ link: ThoughtLink) async throws -> String {
        let resolution = AIProviderSettings.load().resolveUsableService()
        let question = """
        Two passages from a reader's library may be thematically linked. \
        In 2-3 Chinese sentences, explain why they connect. Start with \
        "为什么相连:".
        Passage A (\(link.currentSource)): \(link.currentText)
        Passage B (\(link.relatedSource)): \(link.relatedText)
        """
        let answer = try await resolution.service.answer(
            question: question,
            groundedIn: [
                GroundedPassage(id: 0, text: link.currentText),
                GroundedPassage(id: 1, text: link.relatedText),
            ]
        )
        return answer.text
    }
}