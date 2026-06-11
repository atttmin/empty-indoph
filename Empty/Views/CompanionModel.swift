//
//  CompanionModel.swift
//  Empty
//
//  朱 · AI 伴读 conversation state, shared by the Mac side panel and the
//  iOS half-screen sheet: a chat over the book, grounded strictly in
//  already-read passages (the same spoiler-safe retrieval pipeline as
//  ask-the-book).
//

import SwiftData
import SwiftUI

/// Conversation state for one reader visit. Held above the panel/sheet so
/// closing and reopening keeps the thread.
@MainActor
@Observable
final class CompanionModel {
    struct Message: Identifiable, Equatable {
        enum Role: Equatable {
            case user
            case ai
        }

        let id = UUID()
        var role: Role
        var text: String
        /// Citation chip, e.g. a chapter title — only on grounded answers.
        var source: String?
        /// The user question this AI answer responded to; enables 存为卡片.
        var question: String?
        /// 朱批 agent trace ("查已读「…」 → 生成闪卡(待确认)").
        var steps: [String] = []
        /// Confirm-gated writes the agent proposed with this answer.
        var actions: [CompanionAction] = []
    }

    var messages: [Message] = [
        Message(
            role: .ai,
            text: "我在。划到哪儿,问到哪儿 — 我只根据你已经读过的部分回答,不会剧透。"
        )
    ]
    var thinking = false
    var draft = ""

    func send(
        book: Book,
        position: ReadingPosition,
        modelContext: ModelContext
    ) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !thinking else { return }
        draft = ""
        messages.append(Message(role: .user, text: question))
        thinking = true

        Task {
            defer { thinking = false }
            do {
                let chunkCount = try BookIndexer(modelContext: modelContext)
                    .ensureChunks(for: book)
                guard chunkCount > 0 else {
                    messages.append(Message(
                        role: .ai,
                        text: "这本书没有可检索的文本,我帮不上忙。"
                    ))
                    return
                }
                guard position.chapterIndex > 0 else {
                    messages.append(Message(
                        role: .ai,
                        text: "答案池是你已经读过的部分 — 先往后读一点,再来问我。"
                    ))
                    return
                }

                let resolution = AIProviderSettings.load().resolveUsableService()
                // Agent first: the model decides which reading tools to
                // use. Any failure falls back to plain grounded RAG so the
                // companion never dead-ends.
                do {
                    let toolbox = ReadingToolbox(
                        book: book,
                        position: position,
                        modelContext: modelContext,
                        service: resolution.service
                    )
                    let agent = ReadingAgent(
                        toolbox: toolbox,
                        service: resolution.service,
                        maxSteps: resolution.route == .onDevice ? 3 : 4
                    )
                    let reply = try await agent.run(question: question)
                    messages.append(Message(
                        role: .ai,
                        text: reply.text,
                        question: question,
                        steps: reply.steps,
                        actions: reply.actions
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try await legacyAnswer(
                        question: question,
                        book: book,
                        position: position,
                        modelContext: modelContext,
                        service: resolution.service
                    )
                }
            } catch is CancellationError {
                // Panel torn down mid-flight.
            } catch {
                messages.append(Message(
                    role: .ai,
                    text: "出错了:\(error.localizedDescription)"
                ))
            }
        }
    }

    /// The pre-agent pipeline: spoiler-safe retrieval + one grounded answer.
    private func legacyAnswer(
        question: String,
        book: Book,
        position: ReadingPosition,
        modelContext: ModelContext,
        service: any AIService
    ) async throws {
        let chunks = try ChunkRetriever(modelContext: modelContext).retrieve(
            question: question,
            bookID: book.id,
            position: position
        )
        guard !chunks.isEmpty else {
            messages.append(Message(
                role: .ai,
                text: "在你读过的部分里没找到相关内容。换个问法试试?"
            ))
            return
        }
        let passages = chunks.map { GroundedPassage(id: $0.ordinal, text: $0.text) }
        let answer = try await service.answer(
            question: question,
            groundedIn: passages
        )
        let citedChunk = answer.citedPassageIDs
            .compactMap { id in chunks.first { $0.ordinal == id } }
            .first ?? chunks.first
        messages.append(Message(
            role: .ai,
            text: answer.text,
            source: citedChunk.flatMap(Self.sourceTitle(for:)),
            question: question
        ))
    }

    /// Executes one reader-confirmed agent action and marks it done on the
    /// message, appending the outcome to the conversation.
    func perform(
        actionID: UUID,
        messageID: UUID,
        book: Book,
        position: ReadingPosition,
        modelContext: ModelContext
    ) {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              let actionIndex = messages[messageIndex].actions
                  .firstIndex(where: { $0.id == actionID }),
              !messages[messageIndex].actions[actionIndex].isDone
        else { return }
        let action = messages[messageIndex].actions[actionIndex]

        Task {
            do {
                let resolution = AIProviderSettings.load().resolveUsableService()
                let toolbox = ReadingToolbox(
                    book: book,
                    position: position,
                    modelContext: modelContext,
                    service: resolution.service
                )
                let outcome = try await toolbox.perform(action)
                if let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
                   let actionIndex = messages[messageIndex].actions
                       .firstIndex(where: { $0.id == actionID }) {
                    messages[messageIndex].actions[actionIndex].isDone = true
                }
                messages.append(Message(role: .ai, text: "✓ \(outcome)"))
            } catch {
                messages.append(Message(
                    role: .ai,
                    text: "这一步没做成:\(error.localizedDescription)"
                ))
            }
        }
    }

    private static func sourceTitle(for chunk: Chunk) -> String {
        if let title = chunk.chapter?.title, !title.isEmpty {
            return title
        }
        return "第 \(chunk.chapterIndex + 1) 章"
    }
}
