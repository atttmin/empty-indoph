//
//  CompanionModelTests.swift
//  EmptyTests
//

import Testing
@testable import Empty

@MainActor
struct CompanionModelTests {
    @Test func themePassagesUseOnlyAnsweredQuestions() {
        let messages: [CompanionModel.Message] = [
            .init(role: .ai, text: "欢迎回来"),
            .init(role: .user, text: "这一段在说什么？"),
            .init(role: .ai, text: "它在收束论点。", question: "这一段在说什么？"),
            .init(role: .ai, text: "减法是一种纪律。", question: "为什么一直谈减法？"),
        ]

        let passages = CompanionModel.themePassages(from: messages)

        #expect(passages.count == 2)
        #expect(passages[0].text.contains("Q: 这一段在说什么？"))
        #expect(passages[1].text.contains("Q: 为什么一直谈减法？"))
    }

    @Test func parseThemeDraftSplitsTitleBodyAndTags() {
        let parsed = CompanionModel.parseThemeDraft(
            """
            Title: 减法与专注
            Summary: 这轮追问反复围绕如何削掉噪音、留下重点。
            Tags: 减法, 专注, 本质
            """
        )

        #expect(parsed.title == "减法与专注")
        #expect(parsed.body.contains("削掉噪音"))
        #expect(parsed.tags == ["减法", "专注", "本质"])
    }

    @Test func makeThemeDraftRequiresAtLeastTwoAnsweredQuestions() async throws {
        let messages: [CompanionModel.Message] = [
            .init(role: .ai, text: "它在收束论点。", question: "这一段在说什么？")
        ]

        let draft = try await CompanionModel.makeThemeDraft(
            from: messages,
            targetLanguage: "Simplified Chinese",
            service: ScriptedThemeService(response: "unused")
        )

        #expect(draft == nil)
    }

    @Test func makeThemeDraftUsesServiceResponse() async throws {
        let messages: [CompanionModel.Message] = [
            .init(role: .ai, text: "减法是一种纪律。", question: "为什么一直谈减法？"),
            .init(role: .ai, text: "因为作者要把注意力留给本质。", question: "减法最后想得到什么？")
        ]

        let draft = try await CompanionModel.makeThemeDraft(
            from: messages,
            targetLanguage: "Simplified Chinese",
            service: ScriptedThemeService(
                response: """
                Title: 减法与本质
                Summary: 这些追问都在逼近一个长期兴趣：如何删去噪音，只保留真正重要的东西。
                Tags: 减法, 本质
                """
            )
        )

        let resolved = try #require(draft)
        #expect(resolved.title == "减法与本质")
        #expect(resolved.body.contains("长期兴趣"))
        #expect(resolved.tags == ["减法", "本质"])
    }

    @Test func autoThemeDraftReturnsSignatureAndDraft() async throws {
        let messages: [CompanionModel.Message] = [
            .init(role: .ai, text: "减法是一种纪律。", question: "为什么一直谈减法？"),
            .init(role: .ai, text: "因为作者要把注意力留给本质。", question: "减法最后想得到什么？")
        ]

        let proposal = try await CompanionModel.autoThemeDraft(
            from: messages,
            lastSignature: nil,
            targetLanguage: "Simplified Chinese",
            service: ScriptedThemeService(
                response: """
                Title: 减法与本质
                Summary: 这些追问都在逼近一个长期兴趣：如何删去噪音，只保留真正重要的东西。
                Tags: 减法, 本质
                """
            )
        )

        let resolved = try #require(proposal)
        #expect(!resolved.signature.isEmpty)
        #expect(resolved.draft.title == "减法与本质")
    }

    @Test func autoThemeDraftSkipsRepeatedSignature() async throws {
        let messages: [CompanionModel.Message] = [
            .init(role: .ai, text: "减法是一种纪律。", question: "为什么一直谈减法？"),
            .init(role: .ai, text: "因为作者要把注意力留给本质。", question: "减法最后想得到什么？")
        ]
        let signature = try #require(CompanionModel.themeProposalSignature(from: messages))

        let proposal = try await CompanionModel.autoThemeDraft(
            from: messages,
            lastSignature: signature,
            targetLanguage: "Simplified Chinese",
            service: ScriptedThemeService(response: "unused")
        )

        #expect(proposal == nil)
    }
}

private struct ScriptedThemeService: AIService {
    let response: String

    var availability: AIAvailability { .available }

    func summarize(_ text: String, focus: SummaryFocus) async throws -> String {
        response
    }

    func answer(question: String, groundedIn passages: [GroundedPassage]) async throws -> GroundedAnswer {
        GroundedAnswer(text: response, citedPassageIDs: passages.map(\.id))
    }

    func inlineNote(
        for text: String,
        kind: AIInlineNoteKind,
        targetLanguage: String
    ) async throws -> String {
        response
    }

    func flashcards(from text: String, maxCount: Int) async throws -> [Flashcard] {
        []
    }

    func toolStep(toolDocs: String, transcript: String) async throws -> AgentStep {
        .finish(answer: response)
    }
}
