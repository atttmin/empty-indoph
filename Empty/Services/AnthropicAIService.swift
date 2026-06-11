//
//  AnthropicAIService.swift
//  Empty
//
//  `AIService` over the Anthropic Messages API — Empty's second cloud
//  standard, alongside the OpenAI-compatible `CloudAIService`.
//
//  The default target is Kimi Code's Anthropic-compatible endpoint
//  (`https://api.kimi.com/coding/` → `/v1/messages`), which a Kimi
//  membership reaches with just an API key — no approved-client
//  User-Agent gate, unlike Kimi's OpenAI endpoint. The same shape also
//  serves api.anthropic.com or any Messages-API-compatible host.
//
//  Wire format differs from chat-completions: `system` is a top-level
//  string, the reply is content blocks, headers are `x-api-key` +
//  `anthropic-version`, and there's no JSON-mode flag — so the JSON
//  features (grounded answer, flashcards, agent step) prompt for JSON and
//  reuse `CloudAIService`'s tested parsers.
//

import Foundation

final class AnthropicAIService: AIService {
    struct Configuration: Equatable, Sendable {
        var baseURLString: String
        var model: String
        var apiKey: String
        /// Character budget per prompt window — generous, matching the
        /// large context these endpoints offer.
        var windowBudget: Int = 20_000
        /// `max_tokens` is mandatory on the Messages API; ample for a
        /// summary, answer, flashcard set, or one agent step.
        var maxOutputTokens: Int = 4_096
        var anthropicVersion: String = "2023-06-01"

        static func kimi(apiKey: String) -> Configuration {
            Configuration(
                baseURLString: AIProviderSettings.kimiBaseURL,
                model: AIProviderSettings.kimiModel,
                apiKey: apiKey
            )
        }
    }

    private let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Availability

    var availability: AIAvailability {
        guard let url = URL(string: configuration.baseURLString),
              url.scheme == "https" || url.scheme == "http" else {
            return .unavailable(reason: "The cloud base URL is invalid.")
        }
        guard !configuration.apiKey.isEmpty else {
            return .unavailable(reason: "Add an API key to use the cloud provider.")
        }
        return .available
    }

    // MARK: - AIService

    func summarize(_ text: String, focus: SummaryFocus) async throws -> String {
        try ensureAvailable()
        return try await SummarizationPipeline.run(
            text: text,
            windowBudget: configuration.windowBudget,
            condense: { piece in
                try await self.message(user: AnthropicPrompts.partialSummary(of: piece))
            },
            finish: { whole in
                try await self.message(user: AnthropicPrompts.finalSummary(of: whole, focus: focus))
            }
        )
    }

    func answer(
        question: String,
        groundedIn passages: [GroundedPassage]
    ) async throws -> GroundedAnswer {
        try ensureAvailable()
        guard !passages.isEmpty else { throw AIServiceError.emptyInput }

        var contextBlock = ""
        var includedIDs: Set<Int> = []
        for passage in passages {
            let entry = "[\(passage.id)] \(passage.text)\n\n"
            guard contextBlock.count + entry.count + question.count <= configuration.windowBudget else {
                break
            }
            contextBlock += entry
            includedIDs.insert(passage.id)
        }
        guard !includedIDs.isEmpty else { throw AIServiceError.inputTooLarge }

        let content = try await message(
            user: AnthropicPrompts.groundedAnswer(question: question, passages: contextBlock)
        )
        return try CloudAIService.groundedAnswer(fromContent: content, includedIDs: includedIDs)
    }

    func inlineNote(for text: String, kind: AIInlineNoteKind) async throws -> String {
        try ensureAvailable()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIServiceError.emptyInput }
        guard trimmed.count <= configuration.windowBudget else {
            throw AIServiceError.inputTooLarge
        }
        let content = try await message(
            user: AIInlineNotePrompt.user(kind: kind, text: trimmed)
        )
        let note = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { throw AIServiceError.invalidResponse }
        return note
    }

    func flashcards(from text: String, maxCount: Int) async throws -> [Flashcard] {
        try ensureAvailable()
        guard maxCount > 0 else { return [] }
        let windows = TextWindowing.windows(for: text, maxCharacters: configuration.windowBudget)
        guard !windows.isEmpty else { throw AIServiceError.emptyInput }

        var cards: [Flashcard] = []
        for window in windows {
            guard cards.count < maxCount else { break }
            let content = try await message(
                user: AnthropicPrompts.flashcards(from: window, count: maxCount - cards.count)
            )
            cards.append(contentsOf: try CloudAIService.flashcards(
                fromContent: content,
                maxCount: maxCount - cards.count
            ))
        }
        return cards
    }

    func toolStep(toolDocs: String, transcript: String) async throws -> AgentStep {
        try ensureAvailable()
        let content = try await message(
            user: AnthropicPrompts.toolStep(toolDocs: toolDocs, transcript: transcript)
        )
        return try CloudAIService.agentStep(fromContent: content)
    }

    // MARK: - Networking

    private func message(user: String) async throws -> String {
        guard let base = URL(string: configuration.baseURLString) else {
            throw AIServiceError.modelUnavailable("The cloud base URL is invalid.")
        }
        var request = URLRequest(url: base.appending(path: "v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(configuration.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AnthropicMessageRequest(
                model: configuration.model,
                maxTokens: configuration.maxOutputTokens,
                system: AnthropicPrompts.instructions,
                messages: [AnthropicMessage(role: "user", content: user)],
                temperature: 0.3
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data))?
                .error.message
            throw AIServiceError.providerError(message ?? "HTTP \(http.statusCode)")
        }
        guard let text = Self.text(fromResponseData: data), !text.isEmpty else {
            throw AIServiceError.invalidResponse
        }
        return text
    }

    /// Joins the text blocks of a Messages response (internal for tests).
    static func text(fromResponseData data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(AnthropicMessageResponse.self, from: data)
        else { return nil }
        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// MARK: - Wire types (Anthropic Messages API)

nonisolated struct AnthropicMessage: Codable, Equatable {
    var role: String
    var content: String
}

nonisolated struct AnthropicMessageRequest: Encodable, Equatable {
    var model: String
    var maxTokens: Int
    var system: String
    var messages: [AnthropicMessage]
    var temperature: Double

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case temperature
    }
}

nonisolated struct AnthropicMessageResponse: Decodable {
    nonisolated struct Block: Decodable {
        var type: String
        var text: String?
    }

    var content: [Block]
}

nonisolated struct AnthropicErrorEnvelope: Decodable {
    nonisolated struct Payload: Decodable {
        var message: String
    }

    var error: Payload
}

// MARK: - Prompts

private enum AnthropicPrompts {
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
        Respond with JSON only, exactly like \
        {"answer": "...", "cited_passage_ids": [1, 2]} where the IDs are \
        the bracketed numbers of the passages you relied on. No other text.

        Passages:
        \(passages)
        Question: \(question)
        """
    }

    static func flashcards(from text: String, count: Int) -> String {
        """
        Create up to \(count) question-and-answer study cards covering the \
        key ideas of the following passage. Questions must be answerable \
        from the passage alone. Respond with JSON only, exactly like \
        {"cards": [{"question": "...", "answer": "..."}]}. No other text.

        \(text)
        """
    }

    static func toolStep(toolDocs: String, transcript: String) -> String {
        """
        You are the reading agent inside a book app. You may use the tools \
        below to look things up in what the reader has ALREADY read, or to \
        propose saving study material. Decide ONE next step.

        Tools:
        \(toolDocs)

        Conversation and tool results so far:
        \(transcript)

        Respond with JSON only, exactly like one of:
        {"action": "call", "tool": "<tool name>", "argument": "<single text argument>"}
        {"action": "finish", "answer": "<your reply to the reader, in their language>"}

        Call a tool only when its result is needed. When you have enough, finish. No other text.
        """
    }
}
