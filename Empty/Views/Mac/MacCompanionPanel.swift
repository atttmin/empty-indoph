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
    /// Answers already saved as 问答卡 this visit.
    @State private var savedMessageIDs: Set<UUID> = []

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
                if !message.steps.isEmpty {
                    Text("朱批 · \(message.steps.joined(separator: " → "))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                }
                Text(message.text)
                    .font(.system(size: 13))
                    .lineSpacing(4.5)
                    .foregroundStyle(palette.ink2)
                    .textSelection(.enabled)
                if !message.actions.isEmpty {
                    actionRow(for: message)
                }
                if message.source != nil || message.question != nil {
                    saveRow(for: message)
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

    /// Confirm-gated writes the agent proposed (加入生词本 / 保存闪卡…).
    private func actionRow(for message: CompanionModel.Message) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(message.actions) { action in
                Button {
                    model.perform(
                        actionID: action.id,
                        messageID: message.id,
                        book: book,
                        position: position,
                        modelContext: modelContext
                    )
                } label: {
                    HStack(spacing: 6) {
                        Text(action.isDone ? "✓" : "＋")
                            .font(.system(size: 11, weight: .bold))
                        Text(action.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(action.isDone ? palette.ink3 : palette.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        action.isDone ? palette.accentSoft : palette.accent,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .disabled(action.isDone)
            }
        }
    }

    /// Citation chip plus the 存为卡片 action under an AI answer.
    private func saveRow(for message: CompanionModel.Message) -> some View {
        HStack(spacing: 6) {
            if let source = message.source {
                Text("原文 · \(source)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(palette.accentSoft, in: Capsule())
                    .overlay(Capsule().strokeBorder(palette.accentSoft2, lineWidth: 1))
            }
            if message.question != nil {
                let isSaved = savedMessageIDs.contains(message.id)
                Button(isSaved ? "✓ 已存为卡片" : "存为卡片") {
                    saveCard(for: message)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(isSaved ? palette.accent : palette.ink3)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
                .disabled(isSaved)
            }
        }
    }

    /// 伴读问答 → 问答卡 in the notes screen.
    private func saveCard(for message: CompanionModel.Message) {
        guard let question = message.question,
              !savedMessageIDs.contains(message.id) else { return }
        let card = StudyCardEntry(
            question: question,
            answer: message.text,
            source: "\(bookTitle) · \(chapterTitle)",
            kind: .qa
        )
        card.book = book
        modelContext.insert(card)
        try? modelContext.save()
        savedMessageIDs.insert(message.id)
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
