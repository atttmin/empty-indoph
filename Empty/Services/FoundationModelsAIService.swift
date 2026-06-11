//
//  FoundationModelsAIService.swift
//  Empty
//

import Foundation
import FoundationModels

/// On-device `AIService` backed by Apple's Foundation Models framework.
///
/// The constraints that shape this implementation:
/// - **~4k-token context window** → inputs are windowed (`TextWindowing`)
///   and summarization is map-reduce.
/// - **~3B-parameter model** → prompts are narrow, one job each; structured
///   output uses `@Generable` guided generation, never "return JSON".
/// - **Fresh `LanguageModelSession` per request** → no cross-request context
///   bleed, no creeping window exhaustion.
///
/// Free, offline, private: the right default route. Deep-reasoning features
/// route to a cloud provider later through the same `AIService` protocol.
final class FoundationModelsAIService: AIService {
    /// Token budget for prompt input. The model's context window is ~4096
    /// tokens shared by instructions, input, and output; this leaves
    /// comfortable headroom. Converted per-text into a character budget by
    /// `CharacterBudget` (CJK is ~4× denser than Latin).
    private let inputTokenTarget: Int

    init(inputTokenTarget: Int = 2_600) {
        self.inputTokenTarget = inputTokenTarget
    }

    // MARK: - Availability

    var availability: AIAvailability {
        let model = SystemLanguageModel.default
        if model.isAvailable { return .available }
        if case .unavailable(let reason) = model.availability {
            return .unavailable(reason: Self.describe(reason))
        }
        return .unavailable(reason: "The on-device model is unavailable.")
    }

    private static func describe(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            "This device doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is turned off. Enable it in Settings."
        case .modelNotReady:
            "The on-device model is still getting ready. Try again shortly."
        @unknown default:
            "The on-device model is unavailable."
        }
    }

    // MARK: - AIService

    func summarize(_ text: String, focus: SummaryFocus) async throws -> String {
        try ensureAvailable()
        var windowBudget = budget(for: text)
        while true {
            do {
                return try await SummarizationPipeline.run(
                    text: text,
                    windowBudget: windowBudget,
                    condense: { piece in
                        try await self.respond(to: Prompts.partialSummary(of: piece))
                    },
                    finish: { whole in
                        try await self.respond(to: Prompts.finalSummary(of: whole, focus: focus))
                    }
                )
            } catch let error as AIServiceError {
                // Density estimate missed (unusual script mix) and a window
                // overflowed the context — tighten and retry.
                if case .inputTooLarge = error, windowBudget > 700 {
                    windowBudget /= 2
                    continue
                }
                throw error
            }
        }
    }

    func answer(
        question: String,
        groundedIn passages: [GroundedPassage]
    ) async throws -> GroundedAnswer {
        try ensureAvailable()
        guard !passages.isEmpty else { throw AIServiceError.emptyInput }

        // Keep passages (most relevant first) until the budget is spent.
        let contextBudget = CharacterBudget.characters(
            forTokens: inputTokenTarget,
            in: passages.map(\.text).joined()
        )
        var contextBlock = ""
        var includedIDs: Set<Int> = []
        for passage in passages {
            let entry = "[\(passage.id)] \(passage.text)\n\n"
            guard contextBlock.count + entry.count + question.count <= contextBudget else {
                break
            }
            contextBlock += entry
            includedIDs.insert(passage.id)
        }
        guard !includedIDs.isEmpty else { throw AIServiceError.inputTooLarge }

        let response = try await makeSession().respond(
            to: Prompts.groundedAnswer(question: question, passages: contextBlock),
            generating: CitedAnswerDraft.self
        )
        return GroundedAnswer(
            text: response.content.answer,
            citedPassageIDs: response.content.citedPassageIDs.filter(includedIDs.contains)
        )
    }

    func flashcards(from text: String, maxCount: Int) async throws -> [Flashcard] {
        try ensureAvailable()
        guard maxCount > 0 else { return [] }
        let windows = TextWindowing.windows(for: text, maxCharacters: budget(for: text))
        guard !windows.isEmpty else { throw AIServiceError.emptyInput }

        var cards: [Flashcard] = []
        for window in windows {
            guard cards.count < maxCount else { break }
            let response = try await makeSession().respond(
                to: Prompts.flashcards(from: window, count: maxCount - cards.count),
                generating: FlashcardSetDraft.self
            )
            for draft in response.content.cards where cards.count < maxCount {
                cards.append(Flashcard(question: draft.question, answer: draft.answer))
            }
        }
        return cards
    }

    // MARK: - Plumbing

    private func budget(for text: String) -> Int {
        CharacterBudget.characters(forTokens: inputTokenTarget, in: text)
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(instructions: Prompts.instructions)
    }

    private func respond(to prompt: String) async throws -> String {
        do {
            let response = try await makeSession().respond(to: prompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.mapped(error)
        }
    }

    /// Folds the framework's generation errors into readable, actionable
    /// `AIServiceError`s — the raw descriptions are often blank.
    private static func mapped(_ error: LanguageModelSession.GenerationError) -> AIServiceError {
        switch error {
        case .exceededContextWindowSize:
            .inputTooLarge
        case .guardrailViolation:
            .providerError(
                "Apple's on-device safety filter declined this content. Try the cloud provider."
            )
        case .unsupportedLanguageOrLocale:
            .providerError("The on-device model doesn't support this language yet.")
        case .assetsUnavailable:
            .providerError("The on-device model is still downloading. Try again later.")
        case .rateLimited:
            .providerError("The on-device model is busy. Try again in a moment.")
        default:
            .providerError(error.localizedDescription)
        }
    }
}

// MARK: - Guided generation drafts

@Generable
private struct CitedAnswerDraft {
    @Guide(description: "The answer, drawn only from the numbered passages.")
    var answer: String
    @Guide(description: "The bracketed numbers of the passages the answer relies on.")
    var citedPassageIDs: [Int]
}

@Generable
private struct FlashcardDraft {
    @Guide(description: "A question testing understanding of the passage.")
    var question: String
    @Guide(description: "The answer, grounded in the passage.")
    var answer: String
}

@Generable
private struct FlashcardSetDraft {
    @Guide(description: "Study cards covering the passage's key ideas.")
    var cards: [FlashcardDraft]
}

// MARK: - Prompts

private enum Prompts {
    static let instructions = """
        You are the reading assistant inside a book-reading app. \
        Always respond in the same language as the text you are given. \
        Be precise and concise; never invent content that is not in the text.
        """

    static func partialSummary(of text: String) -> String {
        """
        Condense the following passage, keeping every plot-critical or \
        argument-critical detail. Output only the condensed text.

        \(text)
        """
    }

    static func finalSummary(of text: String, focus: SummaryFocus) -> String {
        """
        \(focus.taskDescription)

        \(text)
        """
    }

    static func groundedAnswer(question: String, passages: String) -> String {
        """
        Answer the question using ONLY the numbered passages below. \
        If they do not contain the answer, say so plainly. \
        Cite the numbers of the passages you used.

        Passages:
        \(passages)
        Question: \(question)
        """
    }

    static func flashcards(from text: String, count: Int) -> String {
        """
        Create up to \(count) question-and-answer study cards covering the \
        key ideas of the following passage. Questions must be answerable \
        from the passage alone.

        \(text)
        """
    }
}
