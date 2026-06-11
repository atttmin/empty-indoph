//
//  AIService.swift
//  Empty
//

import Foundation

/// Whether an AI provider can serve requests right now.
nonisolated enum AIAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    var isAvailable: Bool {
        if case .available = self { true } else { false }
    }
}

/// What a summary optimizes for.
nonisolated enum SummaryFocus: Sendable {
    /// Neutral compression of the content.
    case digest
    /// "Previously on…" — reorient a reader returning after time away.
    case recap
    /// Claims → evidence → assumptions skeleton (nonfiction).
    case argument
}

/// A retrieval result handed to grounded answering. `id` is the chunk's
/// `ordinal`, echoed back in citations.
nonisolated struct GroundedPassage: Identifiable, Sendable {
    let id: Int
    let text: String

    init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

/// An answer constrained to the provided passages, with citations.
nonisolated struct GroundedAnswer: Equatable, Sendable {
    var text: String
    /// IDs of passages the answer used; always a subset of the input.
    var citedPassageIDs: [Int]
}

/// A question/answer study card (highlight → spaced-repetition pipeline).
nonisolated struct Flashcard: Hashable, Sendable {
    var question: String
    var answer: String
}

nonisolated enum AIServiceError: LocalizedError {
    case modelUnavailable(String)
    case emptyInput
    case inputTooLarge
    case providerError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason):
            reason
        case .emptyInput:
            "There's no text to work with."
        case .inputTooLarge:
            "This text is too long for the model."
        case .providerError(let message):
            message
        case .invalidResponse:
            "The model returned something unusable. Try again."
        }
    }
}

extension SummaryFocus {
    /// Task line shared by every provider's final-summary prompt.
    var taskDescription: String {
        switch self {
        case .digest:
            "Summarize the following text faithfully and concisely."
        case .recap:
            """
            Write a short “previously on” recap of the following text for a \
            reader returning to the book after time away. Reorient them: who \
            and what matters now, and where things stand. Do not reveal \
            anything beyond this text.
            """
        case .argument:
            """
            Lay out the argument skeleton of the following text: each main \
            claim, the evidence offered for it, and any unstated assumptions.
            """
        }
    }
}

/// Provider-agnostic surface for the app's AI features.
///
/// Deliberately plain Swift — no FoundationModels types — so inference can
/// route to the on-device model today and a cloud provider (or BYOK) later
/// without touching call sites. Implementations own their context budgets:
/// callers pass whole texts, providers window them.
protocol AIService: Sendable {
    /// Check before showing AI affordances. On-device availability depends
    /// on hardware and the user's Apple Intelligence setting, and can change
    /// while the app runs.
    var availability: AIAvailability { get }

    /// Summarizes text of any length (providers map-reduce past their
    /// context budget), responding in the language of the source text.
    func summarize(_ text: String, focus: SummaryFocus) async throws -> String

    /// Answers strictly from `passages` (ordered most-relevant-first;
    /// trailing passages may be dropped to fit budget). Outside knowledge is
    /// off limits — this is what keeps answers spoiler-safe and
    /// book-grounded.
    func answer(question: String, groundedIn passages: [GroundedPassage]) async throws -> GroundedAnswer

    /// Drafts up to `maxCount` study cards from a passage.
    func flashcards(from text: String, maxCount: Int) async throws -> [Flashcard]
}

extension AIService {
    /// Gate every request behind the provider's availability check.
    func ensureAvailable() throws {
        if case .unavailable(let reason) = availability {
            throw AIServiceError.modelUnavailable(reason)
        }
    }
}
