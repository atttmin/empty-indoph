//
//  ReadingAgent.swift
//  Empty
//
//  The thin agent loop behind 朱 · AI 伴读: ask the model for one step at
//  a time (call a tool / finish), run the tool through the spoiler-safe
//  toolbox, feed the observation back, repeat — bounded, traced, and
//  with every write gated behind reader confirmation.
//

import Foundation

/// What one agent run produced for the conversation.
nonisolated struct ReadingAgentReply: Sendable {
    var text: String
    /// 朱批 trace fragments, in order ("查已读「…」", "生成闪卡(待确认)").
    var steps: [String]
    /// Confirm-gated writes proposed along the way.
    var actions: [CompanionAction]
}

@MainActor
struct ReadingAgent {
    let toolbox: ReadingToolbox
    let service: any AIService
    /// Step budget: on-device models get a short leash, cloud a longer one.
    let maxSteps: Int

    /// Observations are clipped before they re-enter the transcript so a
    /// verbose tool can't blow the context window.
    private static let observationBudget = 900

    func run(question: String) async throws -> ReadingAgentReply {
        var transcript = "读者:\(question)\n"
        var steps: [String] = []
        var actions: [CompanionAction] = []

        for stepIndex in 0..<maxSteps {
            let isLastStep = stepIndex == maxSteps - 1
            let prompt = isLastStep
                ? transcript + "\n(工具预算已用完 — 现在必须 finish,直接回答读者。)"
                : transcript
            let step = try await service.toolStep(
                toolDocs: ReadingToolbox.toolDocs,
                transcript: prompt
            )

            switch step {
            case .finish(let answer):
                return ReadingAgentReply(text: answer, steps: steps, actions: actions)
            case .call(let tool, let argument):
                guard !isLastStep else {
                    // Model tried to keep digging past the budget — answer
                    // from what's on the table instead of looping.
                    break
                }
                let result = try await toolbox.run(tool, argument: argument)
                steps.append(result.traceLabel)
                if result.citedMemory, !steps.contains("⚲ 引用了记忆") {
                    // 防剧透三定律 ③: memory citations are explicit.
                    steps.append("⚲ 引用了记忆")
                }
                if let action = result.proposedAction {
                    actions.append(action)
                }
                transcript += """
                工具 \(tool)(\(argument.prefix(80))):
                \(String(result.observation.prefix(Self.observationBudget)))

                """
            }
        }

        // Budget exhausted without a finish — one grounded wrap-up from the
        // transcript so the reader still gets an answer.
        let answer = try await service.answer(
            question: question,
            groundedIn: [GroundedPassage(id: 0, text: String(transcript.suffix(3_000)))]
        )
        return ReadingAgentReply(text: answer.text, steps: steps, actions: actions)
    }
}
