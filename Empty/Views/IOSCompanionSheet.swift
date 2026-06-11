//
//  IOSCompanionSheet.swift
//  Empty
//
//  朱 · AI 伴读 as the 02 iOS prototype's half-screen sheet: the same
//  spoiler-safe conversation as the Mac side panel, summoned from the
//  vermilion 朱 button or a reader 追问.
//

#if !os(macOS)

import SwiftData
import SwiftUI

struct IOSCompanionSheet: View {
    @Bindable var model: CompanionModel
    let book: Book?
    let position: ReadingPosition

    @Environment(\.dismiss) private var dismiss
    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.line).frame(height: 1)
            if book != nil {
                transcript
                composer
            } else {
                noBookState
            }
        }
        .background(palette.side)
        .presentationDetents([.fraction(0.66), .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            // 追问 hand-off: the reader stages the question in the draft.
            if !model.draft.trimmingCharacters(in: .whitespaces).isEmpty {
                send()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZhuBadge(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("AI 伴读")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(palette.ink)
                Text(contextLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("×")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.ink3)
                    .frame(width: 28, height: 28)
                    .background(palette.accentSoft, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 14, leading: 20, bottom: 12, trailing: 16))
    }

    private var contextLine: String {
        guard let book else { return "尚未打开书" }
        return "语境:《\(book.title)》第 \(position.chapterIndex + 1) 章"
    }

    private var noBookState: some View {
        VStack(spacing: 10) {
            EnsoMark(size: 40)
                .opacity(0.5)
            Text("先打开一本书,我才能不剧透地陪你读。")
                .font(.system(size: 13))
                .foregroundStyle(palette.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.messages) { message in
                        bubble(message)
                            .id(message.id)
                    }
                    if model.thinking {
                        IOSThinkingDots()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
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
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 8, trailing: 16))
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
                .font(.system(size: 12.5))
                .lineSpacing(4)
                .foregroundStyle(palette.window)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
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
            VStack(alignment: .leading, spacing: 7) {
                if !message.steps.isEmpty {
                    Text("朱批 · \(message.steps.joined(separator: " → "))")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: 7))
                }
                Text(message.text)
                    .font(.system(size: 12.5))
                    .lineSpacing(4.5)
                    .foregroundStyle(palette.ink2)
                    .textSelection(.enabled)
                ForEach(message.actions) { action in
                    Button {
                        if let book {
                            model.perform(
                                actionID: action.id,
                                messageID: message.id,
                                book: book,
                                position: position,
                                modelContext: modelContext
                            )
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(action.isDone ? "✓" : "＋")
                                .font(.system(size: 10, weight: .bold))
                            Text(action.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(action.isDone ? palette.ink3 : palette.onAccent)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(
                            action.isDone ? palette.accentSoft : palette.accent,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(action.isDone)
                }
                if let source = message.source {
                    Text("原文 · \(source)")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(palette.accentSoft, in: Capsule())
                        .overlay(Capsule().strokeBorder(palette.accentSoft2, lineWidth: 1))
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                suggestionChip("帮我回顾一下读到哪了")
                suggestionChip("这一章的核心主张是什么?")
                if let book {
                    Button("提炼本轮主题") {
                        model.proposeTheme(for: book)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(model.canProposeTheme ? palette.accent : palette.ink3)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(palette.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
                    .disabled(!model.canProposeTheme)
                }
            }
            HStack(spacing: 8) {
                TextField("就这一页,问点什么…", text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.ink)
                    .focused($inputFocused)
                    .onSubmit(send)

                Button(action: send) {
                    Text("↑")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(palette.onAccent)
                        .frame(width: 30, height: 30)
                        .background(palette.accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(
                    model.thinking
                        || model.draft.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
            .padding(EdgeInsets(top: 5, leading: 13, bottom: 5, trailing: 5))
            .background(palette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(palette.line2, lineWidth: 1)
            )
        }
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 14, trailing: 14))
    }

    private func suggestionChip(_ title: String) -> some View {
        Button {
            model.draft = title
            send()
        } label: {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(palette.ink2)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(palette.card, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(model.thinking)
    }

    private func send() {
        guard let book else { return }
        model.send(book: book, position: position, modelContext: modelContext)
    }
}

/// Three vermilion dots blinking in sequence while the model thinks.
private struct IOSThinkingDots: View {
    @Environment(\.emptyPalette) private var palette
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(palette.accent)
                    .frame(width: 5, height: 5)
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
