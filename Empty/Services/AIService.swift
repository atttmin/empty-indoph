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

/// Plain AI text generated for an in-flow reader annotation. This is not the
/// grounded Q&A path: the reader needs the text itself, not JSON/citations.
nonisolated enum AIInlineNoteKind: Sendable {
    case bilingual
    case companion
    /// 辩难 lens: Socratic counter-questions only — never answers.
    case debate
    /// 文献 lens: public-domain commentary and parallel passages only.
    case sources
}

nonisolated enum AIInlineNotePrompt {
    static func user(kind: AIInlineNoteKind, text: String) -> String {
        let instruction = switch kind {
        case .bilingual:
            // 今译 lens: language-adaptive. Foreign text translates;
            // classical/literary Chinese modernizes; text that is ALREADY
            // plain modern Chinese has nothing to translate — say so with
            // a sentinel the client suppresses (a Chinese book must never
            // show its own text duplicated as a "translation").
            "今译: If the paragraph is not Chinese, translate it into natural, literary Simplified Chinese. If it is classical/literary Chinese (文言、半文言、旧白话), render it in plain modern Chinese. If it is ALREADY plain modern Chinese, output exactly 「原文即白话」 and nothing else."
        case .companion:
            // 导读 is a margin note, NOT a retell — the chapter overview
            // already summarizes content. Point at what the paragraph is
            // DOING and what deserves a pause.
            "你是页边的朱批（导读）。不要复述或翻译这段话——读者看得见原文。指出:这一段在做什么（立论/转折/铺垫/反驳/抒情），以及一个值得读者停下来想的点。最多两句，口吻克制，像一位老编辑的旁注。"
        case .debate:
            "You are a Socratic sparring partner (辩难). Pose one or two sharp counter-questions in Simplified Chinese that challenge this paragraph's claim or assumption. Ask only — never answer them, never explain, never take a side."
        case .sources:
            "You are a classical-commentary companion (文献). In Simplified Chinese, cite at most two RELEVANT passages from public-domain works (classics, traditional commentaries, pre-1928 texts) that echo or illuminate this paragraph. Format each as 「书名」：引文 — never invent sources; if nothing genuinely fits, output exactly 暂无可靠文献参照。"
        }
        return """
        \(instruction)
        Output only the generated Chinese text. Do not include JSON, labels, bullets, or commentary about your task.

        Text:
        \(text)
        """
    }
}

/// Client-side quality gate for inline notes: a note that just echoes
/// the paragraph (the same-language "translation" failure mode) or hits
/// the 今译 sentinel must not paint.
nonisolated enum InlineNoteQuality {
    static let nothingToTranslate = "原文即白话"

    static func isWorthShowing(note: String, original: String) -> Bool {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(nothingToTranslate) { return false }
        return !isEcho(note: trimmed, original: original)
    }

    /// True when the note is essentially the original text again.
    static func isEcho(note: String, original: String) -> Bool {
        let a = normalize(note)
        let b = normalize(original)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b || b.contains(a) || a.contains(b) { return true }
        // Character-overlap ratio for near-identical restatements.
        let setA = Set(a)
        let setB = Set(b)
        let overlap = Double(setA.intersection(setB).count)
            / Double(max(min(setA.count, setB.count), 1))
        let lengthRatio = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
        return overlap > 0.9 && lengthRatio > 0.7
    }

    private static func normalize(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
        })
    }
}

nonisolated enum AITransientRetry {
    static func run<T>(
        attempts: Int = 2,
        delayNanoseconds: UInt64 = 250_000_000,
        operation: () async throws -> T
    ) async throws -> T {
        let totalAttempts = max(1, attempts)
        var nextDelay = delayNanoseconds
        for attempt in 1...totalAttempts {
            do {
                return try await operation()
            } catch {
                guard attempt < totalAttempts, isTransient(error) else {
                    throw error
                }
                try await Task.sleep(nanoseconds: nextDelay)
                nextDelay *= 2
            }
        }
        throw AIServiceError.invalidResponse
    }

    static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .dnsLookupFailed,
                 .notConnectedToInternet:
                return true
            default:
                return false
            }
        }
        guard let serviceError = error as? AIServiceError else { return false }
        if case .providerError(let message) = serviceError {
            return isTransientProviderMessage(message)
        }
        return false
    }

    private static func isTransientProviderMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("429")
            || lowered.contains("busy")
            || lowered.contains("capacity")
            || lowered.contains("connection")
            || lowered.contains("network")
            || lowered.contains("overload")
            || lowered.contains("rate limit")
            || lowered.contains("rate_limit")
            || lowered.contains("temporar")
            || lowered.contains("timed out")
            || lowered.contains("timeout")
            || lowered.contains("too many requests")
            || lowered.contains("try again")
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

/// One decision of the reading-agent loop: call a tool with a single text
/// argument, or finish with the answer. Kept to one string argument per
/// tool — small on-device models handle that reliably; tools parse their
/// own argument when they need structure.
nonisolated enum AgentStep: Equatable, Sendable {
    case call(tool: String, argument: String)
    case finish(answer: String)
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

    /// Generates a plain paragraph translation or 导读 note. Unlike
    /// `answer(question:groundedIn:)`, this path deliberately does not ask
    /// for JSON; inline reading notes should not fail because a model chose
    /// prose over a citation envelope.
    func inlineNote(for text: String, kind: AIInlineNoteKind) async throws -> String

    /// Drafts up to `maxCount` study cards from a passage.
    func flashcards(from text: String, maxCount: Int) async throws -> [Flashcard]

    /// One reading-agent decision: given the tool catalog and the loop
    /// transcript so far, either call a tool or finish. On-device uses
    /// guided generation (a 3B model can't be trusted with free-form
    /// JSON); cloud providers use JSON mode.
    func toolStep(toolDocs: String, transcript: String) async throws -> AgentStep
}

extension AIService {
    /// Gate every request behind the provider's availability check.
    func ensureAvailable() throws {
        if case .unavailable(let reason) = availability {
            throw AIServiceError.modelUnavailable(reason)
        }
    }
}
