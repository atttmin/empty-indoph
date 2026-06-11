//
//  MacCompanionPanel.swift
//  Empty
//
//  朱 · AI 伴读 side panel from the 01 Mac prototype: a chat over the
//  book, grounded strictly in already-read passages (the same
//  spoiler-safe retrieval pipeline as AskBookView).
//

#if os(macOS)

import SwiftData
import SwiftUI

/// Conversation state for one reader visit. Held by the reader screen so
/// closing and reopening the panel keeps the thread.
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
                    source: citedChunk.flatMap(Self.sourceTitle(for:))
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

struct MacCompanionPanel: View {
    @Bindable var model: CompanionModel
    let book: Book
    let bookTitle: String
    let chapterTitle: String
    var highlightCount: Int = 0
    let position: ReadingPosition
    var onClose: () -> Void

    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.line).frame(height: 1)
            transcript
            composer
        }
        .background(palette.side)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZhuBadge(size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("AI 伴读")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(palette.ink)
                Text("语境:《\(bookTitle)》· \(chapterTitle) · 你的 \(highlightCount) 条高亮")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.ink3)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 12, trailing: 12))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages) { message in
                        bubble(message)
                            .id(message.id)
                    }
                    if model.thinking {
                        ThinkingDots()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                palette.card,
                                in: UnevenRoundedRectangle(
                                    topLeadingRadius: 14, bottomLeadingRadius: 4,
                                    bottomTrailingRadius: 14, topTrailingRadius: 14
                                )
                            )
                            .id("thinking")
                    }
                }
                .padding(EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.messages) {
                if let last = model.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: model.thinking) {
                if model.thinking {
                    withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: CompanionModel.Message) -> some View {
        switch message.role {
        case .user:
            Text(message.text)
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundStyle(palette.window)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    palette.ink,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 14, bottomLeadingRadius: 14,
                        bottomTrailingRadius: 4, topTrailingRadius: 14
                    )
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)
        case .ai:
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text)
                    .font(.system(size: 13))
                    .lineSpacing(4.5)
                    .foregroundStyle(palette.ink2)
                    .textSelection(.enabled)
                if let source = message.source {
                    Text("原文 · \(source)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(palette.accentSoft, in: Capsule())
                        .overlay(Capsule().strokeBorder(palette.accentSoft2, lineWidth: 1))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                palette.card,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 14, bottomLeadingRadius: 4,
                    bottomTrailingRadius: 14, topTrailingRadius: 14
                )
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 14, bottomLeadingRadius: 4,
                    bottomTrailingRadius: 14, topTrailingRadius: 14
                )
                .strokeBorder(palette.line, lineWidth: 1)
            )
            .padding(.trailing, 28)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                suggestionChip("和《沉思录》有何呼应?") {
                    model.draft = "和《沉思录》有何呼应?"
                    send()
                }
                suggestionChip("这段的核心主张是什么?") {
                    model.draft = "这段的核心主张是什么?"
                    send()
                }
            }
            HStack(spacing: 8) {
                TextField("就这一页,问点什么…", text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.ink)
                    .focused($inputFocused)
                    .onSubmit(send)

                Button(action: send) {
                    Text("↑")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(palette.onAccent)
                        .frame(width: 32, height: 32)
                        .background(palette.accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(model.thinking || model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 6))
            .background(palette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(palette.line2, lineWidth: 1)
            )
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 16, trailing: 16))
        }
    }

    private func suggestionChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.ink2)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(palette.card, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(model.thinking)
    }

    private func send() {
        model.send(book: book, position: position, modelContext: modelContext)
    }
}

/// Three vermilion dots blinking in sequence while the model thinks.
private struct ThinkingDots: View {
    @Environment(\.emptyPalette) private var palette
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(palette.accent)
                    .frame(width: 6, height: 6)
                    .opacity(animating ? 1 : 0.2)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

#endif
