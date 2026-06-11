//
//  CloudAIService.swift
//  Empty
//

import Foundation

/// `AIService` backed by any OpenAI-compatible chat-completions endpoint.
///
/// The default preset is DeepSeek (cheap, JSON mode, 64k context), but the
/// same shape covers Kimi/Moonshot, Qwen, OpenRouter, or a local Ollama
/// server — anything speaking `POST /chat/completions`. Strictly BYOK: the
/// key comes from the Keychain and never ships with the app.
///
/// Compared to the on-device route this provider gets a far bigger window
/// budget, so most books summarize in a single reduce pass.
final class CloudAIService: AIService {
    struct Configuration: Equatable, Sendable {
        var baseURLString: String
        var model: String
        var apiKey: String
        /// Character budget per prompt window. Conservative for 64k-token
        /// models, leaving ample room for instructions and output.
        var windowBudget: Int = 20_000

        static func deepSeek(apiKey: String) -> Configuration {
            Configuration(
                baseURLString: AIProviderSettings.deepSeekBaseURL,
                model: AIProviderSettings.deepSeekModel,
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
                try await self.chat(user: CloudPrompts.partialSummary(of: piece))
            },
            finish: { whole in
                try await self.chat(user: CloudPrompts.finalSummary(of: whole, focus: focus))
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

        let content = try await chat(
            user: CloudPrompts.groundedAnswer(question: question, passages: contextBlock),
            jsonResponse: true
        )
        return try Self.groundedAnswer(fromContent: content, includedIDs: includedIDs)
    }

    func flashcards(from text: String, maxCount: Int) async throws -> [Flashcard] {
        try ensureAvailable()
        guard maxCount > 0 else { return [] }
        let windows = TextWindowing.windows(for: text, maxCharacters: configuration.windowBudget)
        guard !windows.isEmpty else { throw AIServiceError.emptyInput }

        var cards: [Flashcard] = []
        for window in windows {
            guard cards.count < maxCount else { break }
            let content = try await chat(
                user: CloudPrompts.flashcards(from: window, count: maxCount - cards.count),
                jsonResponse: true
            )
            cards.append(contentsOf: try Self.flashcards(fromContent: content, maxCount: maxCount - cards.count))
        }
        return cards
    }

    func toolStep(toolDocs: String, transcript: String) async throws -> AgentStep {
        try ensureAvailable()
        let content = try await chat(
            user: CloudPrompts.toolStep(toolDocs: toolDocs, transcript: transcript),
            jsonResponse: true
        )
        return try Self.agentStep(fromContent: content)
    }

    // MARK: - Response mapping (internal for tests)

    static func agentStep(fromContent content: String) throws -> AgentStep {
        let data = jsonData(fromModelContent: content)
        guard let payload = try? JSONDecoder().decode(AgentStepPayload.self, from: data) else {
            throw AIServiceError.invalidResponse
        }
        if payload.action == "call", let tool = payload.tool, !tool.isEmpty {
            return .call(tool: tool, argument: payload.argument ?? "")
        }
        if let answer = payload.answer, !answer.isEmpty {
            return .finish(answer: answer)
        }
        throw AIServiceError.invalidResponse
    }

    static func groundedAnswer(
        fromContent content: String,
        includedIDs: Set<Int>
    ) throws -> GroundedAnswer {
        let data = jsonData(fromModelContent: content)
        guard let payload = try? JSONDecoder().decode(CitedAnswerPayload.self, from: data) else {
            throw AIServiceError.invalidResponse
        }
        let cited = (payload.citedPassageIDs ?? []).filter(includedIDs.contains)
        return GroundedAnswer(text: payload.answer, citedPassageIDs: cited)
    }

    static func flashcards(
        fromContent content: String,
        maxCount: Int
    ) throws -> [Flashcard] {
        let data = jsonData(fromModelContent: content)
        guard let payload = try? JSONDecoder().decode(FlashcardsPayload.self, from: data) else {
            throw AIServiceError.invalidResponse
        }
        return payload.cards
            .prefix(maxCount)
            .map { Flashcard(question: $0.question, answer: $0.answer) }
    }

    /// Models occasionally wrap JSON in Markdown fences even in JSON mode;
    /// strip them before decoding.
    static func jsonData(fromModelContent content: String) -> Data {
        var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            var lines = trimmed.components(separatedBy: .newlines)
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            trimmed = lines.joined(separator: "\n")
        }
        return Data(trimmed.utf8)
    }

    // MARK: - Networking

    private func chat(user: String, jsonResponse: Bool = false) async throws -> String {
        guard let base = URL(string: configuration.baseURLString) else {
            throw AIServiceError.modelUnavailable("The cloud base URL is invalid.")
        }
        var request = URLRequest(url: base.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: configuration.model,
                messages: [
                    ChatMessage(role: "system", content: CloudPrompts.instructions),
                    ChatMessage(role: "user", content: user),
                ],
                temperature: 0.3,
                responseFormat: jsonResponse ? .jsonObject : nil
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?
                .error.message
            throw AIServiceError.providerError(message ?? "HTTP \(http.statusCode)")
        }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = decoded.choices.first?.message.content,
              !content.isEmpty else {
            throw AIServiceError.invalidResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Wire types (OpenAI-compatible)

nonisolated struct ChatMessage: Codable, Equatable {
    var role: String
    var content: String
}

nonisolated struct ChatRequest: Encodable, Equatable {
    nonisolated struct ResponseFormat: Encodable, Equatable {
        var type: String
        static let jsonObject = ResponseFormat(type: "json_object")
    }

    var model: String
    var messages: [ChatMessage]
    var temperature: Double
    var responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case responseFormat = "response_format"
    }
}

nonisolated struct ChatResponse: Decodable {
    nonisolated struct Choice: Decodable {
        var message: ChatMessage
    }

    var choices: [Choice]
}

nonisolated struct APIErrorEnvelope: Decodable {
    nonisolated struct Payload: Decodable {
        var message: String
    }

    var error: Payload
}

nonisolated struct CitedAnswerPayload: Decodable {
    var answer: String
    var citedPassageIDs: [Int]?

    enum CodingKeys: String, CodingKey {
        case answer
        case citedPassageIDs = "cited_passage_ids"
    }
}

nonisolated struct FlashcardsPayload: Decodable {
    nonisolated struct Card: Decodable {
        var question: String
        var answer: String
    }

    var cards: [Card]
}

nonisolated struct AgentStepPayload: Decodable {
    var action: String
    var tool: String?
    var argument: String?
    var answer: String?
}

// MARK: - Prompts

private enum CloudPrompts {
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
        Respond with JSON exactly like \
        {"answer": "...", "cited_passage_ids": [1, 2]} where the IDs are \
        the bracketed numbers of the passages you relied on.

        Passages:
        \(passages)
        Question: \(question)
        """
    }

    static func flashcards(from text: String, count: Int) -> String {
        """
        Create up to \(count) question-and-answer study cards covering the \
        key ideas of the following passage. Questions must be answerable \
        from the passage alone. Respond with JSON exactly like \
        {"cards": [{"question": "...", "answer": "..."}]}.

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

        Respond with JSON exactly like one of:
        {"action": "call", "tool": "<tool name>", "argument": "<single text argument>"}
        {"action": "finish", "answer": "<your reply to the reader, in their language>"}

        Call a tool only when its result is needed. When you have enough, finish.
        """
    }
}
