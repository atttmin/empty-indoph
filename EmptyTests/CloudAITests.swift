//
//  CloudAITests.swift
//  EmptyTests
//

import Foundation
import Testing
@testable import Empty

@MainActor
struct CloudAITests {
    @Test func chatRequestEncodesOpenAICompatibleJSON() throws {
        let request = ChatRequest(
            model: "deepseek-v4-flash",
            messages: [
                ChatMessage(role: "system", content: "sys"),
                ChatMessage(role: "user", content: "hi"),
            ],
            temperature: 0.3,
            responseFormat: .jsonObject
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["model"] as? String == "deepseek-v4-flash")
        #expect((object["messages"] as? [[String: Any]])?.count == 2)
        #expect(object["temperature"] as? Double == 0.3)
        let responseFormat = try #require(object["response_format"] as? [String: Any])
        #expect(responseFormat["type"] as? String == "json_object")
    }

    @Test func chatRequestOmitsResponseFormatWhenNil() throws {
        let request = ChatRequest(
            model: "m",
            messages: [],
            temperature: 0.3,
            responseFormat: nil
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["response_format"] == nil)
    }

    @Test func chatResponseDecodesContent() throws {
        let json = """
        {"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":"你好"},"finish_reason":"stop"}],"usage":{"total_tokens":5}}
        """
        let response = try JSONDecoder().decode(ChatResponse.self, from: Data(json.utf8))
        #expect(response.choices.first?.message.content == "你好")
    }

    @Test func errorEnvelopeDecodes() throws {
        let json = """
        {"error":{"message":"Insufficient Balance","type":"invalid_request_error"}}
        """
        let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: Data(json.utf8))
        #expect(envelope.error.message == "Insufficient Balance")
    }

    @Test func groundedAnswerFiltersUnknownCitations() throws {
        let content = """
        {"answer": "主角在第三章离开了。", "cited_passage_ids": [2, 7, 99]}
        """
        let answer = try CloudAIService.groundedAnswer(
            fromContent: content,
            includedIDs: [2, 7, 11]
        )
        #expect(answer.text == "主角在第三章离开了。")
        #expect(answer.citedPassageIDs == [2, 7])
    }

    @Test func groundedAnswerSurvivesMarkdownFences() throws {
        let content = """
        ```json
        {"answer": "ok", "cited_passage_ids": [1]}
        ```
        """
        let answer = try CloudAIService.groundedAnswer(fromContent: content, includedIDs: [1])
        #expect(answer.text == "ok")
        #expect(answer.citedPassageIDs == [1])
    }

    @Test func malformedGroundedAnswerThrowsInvalidResponse() {
        #expect(throws: AIServiceError.self) {
            try CloudAIService.groundedAnswer(fromContent: "not json", includedIDs: [1])
        }
    }

    @Test func inlineNotePromptIsPlainTextNotJSON() {
        let prompt = AIInlineNotePrompt.user(
            kind: .bilingual,
            text: "Our life is frittered away by detail."
        )
        #expect(prompt.contains("Output only the generated Chinese text"))
        #expect(prompt.contains("Do not include JSON"))
        #expect(prompt.contains("Text:\nOur life is frittered away by detail."))
    }

    @Test func transientRetryClassifiesProviderPressureOnly() {
        #expect(AITransientRetry.isTransient(
            AIServiceError.providerError("The on-device model is busy. Try again in a moment.")
        ))
        #expect(AITransientRetry.isTransient(
            AIServiceError.providerError("HTTP 429 Too Many Requests")
        ))
        #expect(!AITransientRetry.isTransient(AIServiceError.invalidResponse))
        #expect(!AITransientRetry.isTransient(
            AIServiceError.providerError("Insufficient Balance")
        ))
    }

    @Test func flashcardsDecodeAndRespectMaxCount() throws {
        let content = """
        {"cards": [
            {"question": "Q1", "answer": "A1"},
            {"question": "Q2", "answer": "A2"},
            {"question": "Q3", "answer": "A3"}
        ]}
        """
        let cards = try CloudAIService.flashcards(fromContent: content, maxCount: 2)
        #expect(cards == [
            Flashcard(question: "Q1", answer: "A1"),
            Flashcard(question: "Q2", answer: "A2"),
        ])
    }

    @Test func cloudAvailabilityRequiresKeyAndValidURL() {
        let noKey = CloudAIService(
            configuration: CloudAIService.Configuration(
                baseURLString: "https://api.deepseek.com",
                model: "deepseek-chat",
                apiKey: ""
            )
        )
        #expect(!noKey.availability.isAvailable)

        let badURL = CloudAIService(
            configuration: CloudAIService.Configuration(
                baseURLString: "not a url",
                model: "m",
                apiKey: "sk-x"
            )
        )
        #expect(!badURL.availability.isAvailable)

        let ready = CloudAIService(configuration: .deepSeek(apiKey: "sk-x"))
        #expect(ready.availability.isAvailable)
    }

    @Test func settingsRoundTripThroughDefaults() throws {
        let suiteName = "CloudAITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = AIProviderSettings()
        settings.mode = .cloud
        settings.cloudBaseURL = "https://openrouter.ai/api/v1"
        settings.cloudModel = "deepseek/deepseek-chat-v3"
        settings.save(to: defaults)

        let loaded = AIProviderSettings.load(from: defaults)
        #expect(loaded == settings)
    }

    @Test func defaultSettingsTargetDeepSeekOnDevice() {
        let settings = AIProviderSettings()
        #expect(settings.mode == .onDevice)
        #expect(settings.cloudBaseURL == "https://api.deepseek.com")
        #expect(settings.cloudModel == "deepseek-v4-flash")
    }

    @Test func legacyDeepSeekAliasesMigrateToV4() throws {
        let suiteName = "CloudAITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = AIProviderSettings()
        settings.mode = .cloud
        settings.cloudModel = "deepseek-chat"
        settings.save(to: defaults)
        #expect(AIProviderSettings.load(from: defaults).cloudModel == "deepseek-v4-flash")

        settings.cloudModel = "deepseek-reasoner"
        settings.save(to: defaults)
        #expect(AIProviderSettings.load(from: defaults).cloudModel == "deepseek-v4-pro")

        // Non-DeepSeek endpoints keep their model names untouched.
        settings.cloudBaseURL = "http://localhost:11434/v1"
        settings.cloudModel = "deepseek-chat"
        settings.save(to: defaults)
        #expect(AIProviderSettings.load(from: defaults).cloudModel == "deepseek-chat")
    }
}

@MainActor
struct SummarizationPipelineTests {
    @Test func singleWindowGoesStraightToFinish() async throws {
        var condenseCalls = 0
        var finishCalls = 0
        let result = try await SummarizationPipeline.run(
            text: "Short text.",
            windowBudget: 100,
            condense: { piece in
                condenseCalls += 1
                return piece
            },
            finish: { whole in
                finishCalls += 1
                return "SUMMARY(\(whole))"
            }
        )
        #expect(condenseCalls == 0)
        #expect(finishCalls == 1)
        #expect(result == "SUMMARY(Short text.)")
    }

    @Test func multiWindowCondensesEveryWindowThenFinishes() async throws {
        let paragraphs = (0..<12).map { "Paragraph \($0) carries some content." }
        let text = paragraphs.joined(separator: "\n\n")
        var condensed: [String] = []
        let result = try await SummarizationPipeline.run(
            text: text,
            windowBudget: 80,
            condense: { piece in
                condensed.append(piece)
                return "·"
            },
            finish: { _ in "DONE" }
        )
        #expect(result == "DONE")
        #expect(condensed.count > 1)
        // Nothing dropped on the way into the condense passes.
        let seen = condensed.joined().filter { !$0.isWhitespace && $0 != "·" }
        let original = text.filter { !$0.isWhitespace }
        #expect(seen == original)
    }

    @Test func nonShrinkingReducePassThrows() async {
        let paragraphs = (0..<6).map { "Paragraph \($0) carries some content." }
        let text = paragraphs.joined(separator: "\n\n")
        await #expect(throws: AIServiceError.self) {
            _ = try await SummarizationPipeline.run(
                text: text,
                windowBudget: 60,
                condense: { _ in String(repeating: "x", count: 90) },
                finish: { _ in "unreachable" }
            )
        }
    }

    @Test func emptyTextThrowsEmptyInput() async {
        await #expect(throws: AIServiceError.self) {
            _ = try await SummarizationPipeline.run(
                text: "   \n  ",
                windowBudget: 50,
                condense: { $0 },
                finish: { $0 }
            )
        }
    }
}
