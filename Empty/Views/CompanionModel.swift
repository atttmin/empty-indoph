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
    private var lastThemeProposalSignature: String?


    var canProposeTheme: Bool {
        guard !thinking,
              let signature = Self.themeProposalSignature(from: messages) else { return false }
        return signature != lastThemeProposalSignature
    }

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
                guard try Self.hasReadableContext(
                    bookID: book.id,
                    position: position,
                    modelContext: modelContext
                ) else {
                    messages.append(Message(
                        role: .ai,
                        text: "答案池是你已经读过的部分 — 先往后读一点,再来问我。"
                    ))
                    return
                }

                let resolution = AIProviderRegistry.load().resolveUsableService(feature: .chat)
                // 朱的回答 follows the目标语言 unless 作用范围 fixes it —
                // declared on the question itself so both the agent path
                // and the RAG fallback inherit it.
                let answerLanguage = LanguageSettings.promptName(
                    for: LanguageSettings.effective(for: book.id).resolvedChatTarget()
                )
                let directedQuestion = "\(question)\n\n(Respond in \(answerLanguage).)"
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
                        maxSteps: resolution.provider.isLocal ? 3 : 4
                    )
                    let reply = try await agent.run(question: directedQuestion)
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
                        answerLanguage: answerLanguage,
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

    func proposeTheme(for book: Book) {
        guard canProposeTheme else { return }
        thinking = true
        let signature = Self.themeProposalSignature(from: messages)

        Task {
            defer { thinking = false }
            do {
                let resolution = AIProviderRegistry.load().resolveUsableService(feature: .chat)
                let targetLanguage = LanguageSettings.promptName(
                    for: LanguageSettings.effective(for: book.id).resolvedChatTarget()
                )
                guard let draft = try await Self.makeThemeDraft(
                    from: messages,
                    targetLanguage: targetLanguage,
                    service: resolution.service
                ) else {
                    messages.append(Message(
                        role: .ai,
                        text: "至少要有两轮有效追问,我才能替你提炼一个长期主题。"
                    ))
                    return
                }
                lastThemeProposalSignature = signature
                messages.append(Message(
                    role: .ai,
                    text: draft.body,
                    steps: ["聚合本轮问答", "提炼主题(待确认)"],
                    actions: [
                        CompanionAction(
                            title: "记住主题「\(draft.title)」",
                            kind: .saveMemory(
                                title: draft.title,
                                body: draft.body,
                                tags: draft.tags
                            )
                        )
                    ]
                ))
            } catch {
                messages.append(Message(
                    role: .ai,
                    text: "这轮主题还没提炼出来:\(error.localizedDescription)"
                ))
            }
        }
    }

    static func hasReadableContext(
        bookID: UUID,
        position: ReadingPosition,
        modelContext: ModelContext
    ) throws -> Bool {
        let readText = try Chapter.fullyReadText(
            forBookID: bookID,
            before: position,
            in: modelContext
        )
        return !readText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func themeProposalSignature(
        from messages: [Message],
        limit: Int = 4
    ) -> String? {
        let ids = themePassages(from: messages, limit: limit).map(\.id.description)
        guard ids.count >= 2 else { return nil }
        return ids.joined(separator: "|")
    }

    static func themePassages(
        from messages: [Message],
        limit: Int = 4
    ) -> [GroundedPassage] {
        messages
            .filter { $0.role == .ai && $0.question != nil }
            .suffix(limit)
            .enumerated()
            .map { index, message in
                GroundedPassage(
                    id: index,
                    text: "Q: \(message.question ?? "")\nA: \(message.text)"
                )
            }
    }

    static func makeThemeDraft(
        from messages: [Message],
        targetLanguage: String,
        service: any AIService
    ) async throws -> (title: String, body: String, tags: [String])? {
        let passages = themePassages(from: messages)
        guard passages.count >= 2 else { return nil }
        let answer = try await service.answer(
            question: """
            Synthesize one durable reader-memory theme from these companion Q&A turns.
            Respond in \(targetLanguage) using exactly three lines:
            Title: <2-8 words or 2-10 characters>
            Summary: <1-2 sentences on the recurring concern or obsession>
            Tags: <up to 3 short tags, comma-separated; write none if empty>
            """,
            groundedIn: passages
        )
        return parseThemeDraft(answer.text)
    }

    static func parseThemeDraft(_ text: String) -> (title: String, body: String, tags: [String]) {
        var title: String?
        var body: String?
        var tags: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Title:") {
                title = String(line.dropFirst("Title:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Summary:") {
                body = String(line.dropFirst("Summary:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Tags:") {
                let rawTags = String(line.dropFirst("Tags:".count)).trimmingCharacters(in: .whitespaces)
                if rawTags.lowercased() != "none" {
                    tags = rawTags
                        .split(whereSeparator: { [",", "，", "、"].contains($0) })
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
            }
        }

        let resolvedTitle = title?.isEmpty == false ? title! : "本轮反复追问的主题"
        let resolvedBody = body?.isEmpty == false ? body! : text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (resolvedTitle, resolvedBody, Array(tags.prefix(3)))
    }


    /// The pre-agent pipeline: spoiler-safe retrieval + one grounded answer.
    /// `answerLanguage` rides only on the model question — the retrieval
    /// query and the saved-card question stay clean.
    private func legacyAnswer(
        question: String,
        answerLanguage: String? = nil,
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
            question: answerLanguage.map { "\(question)\n\n(Respond in \($0).)" } ?? question,
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
                let resolution = AIProviderRegistry.load().resolveUsableService(feature: .chat)
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
