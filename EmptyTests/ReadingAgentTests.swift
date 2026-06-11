//
//  ReadingAgentTests.swift
//  EmptyTests
//
//  The reading agent: step parsing, the bounded tool loop, and the
//  rule that writes never happen without reader confirmation.
//

import Foundation
import SwiftData
import Testing
@testable import Empty

// MARK: - Cloud step parsing

struct AgentStepParsingTests {
    @Test func parsesToolCall() throws {
        let step = try CloudAIService.agentStep(
            fromContent: #"{"action": "call", "tool": "search_passages", "argument": "simplicity"}"#
        )
        #expect(step == .call(tool: "search_passages", argument: "simplicity"))
    }

    @Test func parsesFinishAndFencedContent() throws {
        let plain = try CloudAIService.agentStep(
            fromContent: #"{"action": "finish", "answer": "读到这里,梭罗在做减法。"}"#
        )
        #expect(plain == .finish(answer: "读到这里,梭罗在做减法。"))

        let fenced = try CloudAIService.agentStep(
            fromContent: """
            ```json
            {"action": "finish", "answer": "ok"}
            ```
            """
        )
        #expect(fenced == .finish(answer: "ok"))
    }

    @Test func missingArgumentDefaultsToEmpty() throws {
        let step = try CloudAIService.agentStep(
            fromContent: #"{"action": "call", "tool": "recap_progress"}"#
        )
        #expect(step == .call(tool: "recap_progress", argument: ""))
    }

    @Test func rejectsGarbageAndEmptyAnswers() {
        #expect(throws: AIServiceError.self) {
            try CloudAIService.agentStep(fromContent: "I think we should search.")
        }
        #expect(throws: AIServiceError.self) {
            try CloudAIService.agentStep(fromContent: #"{"action": "finish", "answer": ""}"#)
        }
        #expect(throws: AIServiceError.self) {
            try CloudAIService.agentStep(fromContent: #"{"action": "call", "tool": ""}"#)
        }
    }
}

// MARK: - Scripted provider

/// Plays back a fixed sequence of agent steps; counts mutate via
/// `nonisolated(unsafe)` because each test drives one instance serially.
private final class ScriptedAIService: AIService, @unchecked Sendable {
    nonisolated(unsafe) var stepQueue: [AgentStep]
    nonisolated(unsafe) var fallbackAnswer = "fallback"
    nonisolated(unsafe) var flashcardsToReturn: [Flashcard] = []

    init(steps: [AgentStep]) {
        self.stepQueue = steps
    }

    var availability: AIAvailability { .available }

    func summarize(_ text: String, focus: SummaryFocus) async throws -> String {
        "summary"
    }

    func answer(
        question: String,
        groundedIn passages: [GroundedPassage]
    ) async throws -> GroundedAnswer {
        GroundedAnswer(text: fallbackAnswer, citedPassageIDs: [])
    }

    func flashcards(from text: String, maxCount: Int) async throws -> [Flashcard] {
        Array(flashcardsToReturn.prefix(maxCount))
    }

    func toolStep(toolDocs: String, transcript: String) async throws -> AgentStep {
        guard !stepQueue.isEmpty else { return .finish(answer: "done") }
        return stepQueue.removeFirst()
    }
}

// MARK: - Loop + write gating

@MainActor
struct ReadingAgentTests {
    private struct Fixture {
        let container: ModelContainer
        let book: Book
        let toolbox: ReadingToolbox
        let service: ScriptedAIService
    }

    private func makeFixture(steps: [AgentStep]) throws -> Fixture {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let book = Book(title: "Walden", format: .epub)
        context.insert(book)
        try context.save()
        let service = ScriptedAIService(steps: steps)
        let toolbox = ReadingToolbox(
            book: book,
            position: ReadingPosition(chapterIndex: 2, utf16Offset: 0),
            modelContext: context,
            service: service
        )
        return Fixture(container: container, book: book, toolbox: toolbox, service: service)
    }

    @Test func loopRunsToolsThenFinishesWithTraceAndActions() async throws {
        let fixture = try makeFixture(steps: [
            .call(tool: "add_vocab", argument: "resignation"),
            .finish(answer: "这个词值得记。"),
        ])
        let agent = ReadingAgent(
            toolbox: fixture.toolbox,
            service: fixture.service,
            maxSteps: 3
        )

        let reply = try await agent.run(question: "resignation 值得记吗?")

        #expect(reply.text == "这个词值得记。")
        #expect(reply.steps == ["建议生词(待确认)"])
        #expect(reply.actions.count == 1)
        #expect(reply.actions.first?.title == "加入生词本「resignation」")
    }

    @Test func proposalsDoNotWriteUntilPerformed() async throws {
        let fixture = try makeFixture(steps: [])
        let context = fixture.container.mainContext

        // The tool only proposes — nothing lands in the store.
        let result = try await fixture.toolbox.run("add_vocab", argument: "marrow")
        #expect(result.proposedAction != nil)
        #expect(try context.fetchCount(FetchDescriptor<VocabEntry>()) == 0)

        // Flashcard saves are pure SwiftData writes once confirmed.
        let cards = [Flashcard(question: "Q1", answer: "A1"), Flashcard(question: "Q2", answer: "A2")]
        let action = CompanionAction(title: "保存 2 张闪卡", kind: .saveFlashcards(cards))
        let outcome = try await fixture.toolbox.perform(action)
        #expect(outcome.contains("2"))
        #expect(try context.fetchCount(FetchDescriptor<StudyCardEntry>()) == 2)
    }

    @Test func budgetExhaustionFallsBackToGroundedAnswer() async throws {
        let fixture = try makeFixture(steps: [
            .call(tool: "add_vocab", argument: "one"),
            .call(tool: "add_vocab", argument: "two"),
            .call(tool: "add_vocab", argument: "three"),
        ])
        fixture.service.fallbackAnswer = "预算用完后的兜底回答"
        let agent = ReadingAgent(
            toolbox: fixture.toolbox,
            service: fixture.service,
            maxSteps: 3
        )

        let reply = try await agent.run(question: "帮我整理生词")

        // Two tool steps ran; the third (last-step) call was refused and
        // the loop wrapped up through the grounded answer path.
        #expect(reply.steps.count == 2)
        #expect(reply.actions.count == 2)
        #expect(reply.text == "预算用完后的兜底回答")
    }

    @Test func unknownToolIsReportedNotFatal() async throws {
        let fixture = try makeFixture(steps: [])
        let result = try await fixture.toolbox.run("teleport", argument: "moon")
        #expect(result.observation.contains("未知工具"))
        #expect(result.proposedAction == nil)
    }
}
