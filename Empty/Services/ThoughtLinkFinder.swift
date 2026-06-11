//
//  ThoughtLinkFinder.swift
//  Empty
//

import Foundation
import SwiftData

/// A cross-highlight connection surfaced while reading — semantic recall
/// first, lexical fallback, AI theme/why on demand.
nonisolated struct ThoughtLink: Equatable, Sendable {
    var currentText: String
    var currentSource: String
    var relatedText: String
    var relatedSource: String
    var relatedBookTitle: String
    /// Stable identity of the related highlight (negative feedback).
    var relatedHighlightID: UUID?
    /// Short theme label ("不争之争") once the LLM has reviewed the pair.
    var theme: String?
    var explanation: String
}

/// 活思维链接 negative feedback: pairs the reader marked 不相关 never
/// resurface, and a highlight dismissed twice stops being recalled.
nonisolated enum ThoughtLinkFeedback {
    private static let key = "thoughtlink.dismissed.v1"

    static func pairKey(passage: String, highlightID: UUID) -> String {
        "\(passage.prefix(60))|\(highlightID.uuidString)"
    }

    static func dismissed(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    static func dismiss(
        passage: String,
        highlightID: UUID,
        defaults: UserDefaults = .standard
    ) {
        var all = dismissed(defaults: defaults)
        all.append(pairKey(passage: passage, highlightID: highlightID))
        defaults.set(Array(all.suffix(400)), forKey: key)
    }

    static func isBlocked(
        passage: String,
        highlightID: UUID,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let all = dismissed(defaults: defaults)
        if all.contains(pairKey(passage: passage, highlightID: highlightID)) {
            return true
        }
        // Dismissed twice anywhere → the highlight itself goes quiet.
        let suffix = "|\(highlightID.uuidString)"
        return all.filter { $0.hasSuffix(suffix) }.count >= 2
    }
}

/// Finds the strongest link between a passage and the reader's prior
/// highlights on other books (or earlier chapters): sentence-embedding
/// similarity when the language has a model, lexical overlap otherwise.
/// Both sides are read text by construction (the passage is under the
/// reader's eyes; highlights only exist on read text).
@MainActor
struct ThoughtLinkFinder {
    let modelContext: ModelContext

    private static let semanticThreshold = 0.45
    private static let lexicalThreshold = 0.15

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
        let query = SemanticScorer.queryVector(for: passage)

        var bestScore = 0.0
        var best: Highlight?
        for highlight in highlights {
            guard let highlightBook = highlight.book else { continue }
            guard highlightBook.id != book.id
                || highlight.chapterIndex < chapterIndex else { continue }
            guard !ThoughtLinkFeedback.isBlocked(
                passage: passage, highlightID: highlight.id
            ) else { continue }

            var score = 0.0
            if let query,
               let candidate = SemanticScorer.queryVector(for: highlight.textSnapshot),
               candidate.languageTag == query.languageTag {
                let similarity = SemanticScorer.cosineSimilarity(
                    query.vector, candidate.vector
                )
                if similarity >= Self.semanticThreshold {
                    score = similarity
                }
            }
            if score == 0 {
                let lexical = LexicalScorer.score(
                    query: passage, text: highlight.textSnapshot
                )
                if lexical > Self.lexicalThreshold {
                    score = lexical
                }
            }
            if score > bestScore {
                bestScore = score
                best = highlight
            }
        }
        guard let best else { return nil }

        let relatedBook = best.book?.title ?? "另一本书"
        let relatedSource = "\(relatedBook) · 第 \(best.chapterIndex + 1) 章"
        let currentSource = "\(book.title) · 第 \(chapterIndex + 1) 章"
        return ThoughtLink(
            currentText: String(passage.prefix(160)),
            currentSource: currentSource,
            relatedText: best.textSnapshot,
            relatedSource: relatedSource,
            relatedBookTitle: relatedBook,
            relatedHighlightID: best.id,
            theme: nil,
            explanation: "两段文字在主题上相呼应。点开看朱批的解读。"
        )
    }

    /// LLM review pass: a short theme label plus the why. Parses the
    /// 主题/为什么 line format; an unstructured reply becomes the why.
    func linkInsight(_ link: ThoughtLink) async throws -> (theme: String?, why: String) {
        let resolution = AIProviderRegistry.load().resolveUsableService(feature: .chat)
        let question = """
        Two passages from a reader's library may be thematically linked. \
        Reply in Simplified Chinese, exactly two lines:
        主题：<a 2-6 character theme label>
        为什么：<2-3 sentences on why they connect>
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
        return Self.parseInsight(answer.text)
    }

    nonisolated static func parseInsight(_ text: String) -> (theme: String?, why: String) {
        var theme: String?
        var why: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("主题：") || trimmed.hasPrefix("主题:") {
                theme = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("为什么：") || trimmed.hasPrefix("为什么:") {
                why.append(String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces))
            } else if !trimmed.isEmpty {
                why.append(trimmed)
            }
        }
        let whyText = why.joined(separator: " ")
        return (
            theme?.isEmpty == false ? theme : nil,
            whyText.isEmpty ? text : whyText
        )
    }

    func explainLink(_ link: ThoughtLink) async throws -> String {
        try await linkInsight(link).why
    }
}