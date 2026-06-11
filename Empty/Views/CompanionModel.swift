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
                let resolution = AIProviderSettings.load().resolveUsableService()
                let answer = try await resolution.service.answer(
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

    private static func sourceTitle(for chunk: Chunk) -> String {
        if let title = chunk.chapter?.title, !title.isEmpty {
            return title
        }
        return "第 \(chunk.chapterIndex + 1) 章"
    }
}
