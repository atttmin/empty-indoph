//
//  HighlightsListView.swift
//  Empty
//

import SwiftData
import SwiftUI

/// All highlights of one book, in reading order, as 朱批 quote rows.
/// Tapping jumps the reader to the highlight's chapter; context menu
/// deletes or generates AI flashcards.
struct HighlightsListView: View {
    let book: Book
    let onJump: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext
    @Query private var highlights: [Highlight]

    @State private var generatingHighlightID: UUID?
    @State private var statusMessage: String?
    @State private var showFlashcards = false

    init(book: Book, onJump: @escaping (Int) -> Void) {
        self.book = book
        self.onJump = onJump
        let bookID = book.id
        _highlights = Query(
            filter: #Predicate<Highlight> { $0.book?.id == bookID },
            sort: [
                SortDescriptor(\Highlight.chapterIndex),
                SortDescriptor(\Highlight.startUTF16),
            ]
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.line).frame(height: 1)

            if highlights.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(highlights) { highlight in
                            row(highlight)
                        }
                    }
                    .padding(EdgeInsets(top: 14, leading: 16, bottom: 20, trailing: 16))
                }
            }
        }
        .background(palette.window)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .sheet(isPresented: $showFlashcards) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("闪卡")
                        .font(.system(size: 17, weight: .black, design: .serif))
                        .foregroundStyle(palette.ink)
                    Spacer()
                    Button {
                        showFlashcards = false
                    } label: {
                        Text("×")
                            .font(.system(size: 14))
                            .foregroundStyle(palette.ink3)
                            .frame(width: 28, height: 28)
                            .background(palette.accentSoft, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(EdgeInsets(top: 16, leading: 20, bottom: 12, trailing: 16))
                Rectangle().fill(palette.line).frame(height: 1)
                ScrollView {
                    FlashcardsReviewView(bookFilter: book)
                        .padding(16)
                }
            }
            .background(palette.window)
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 420)
            #endif
        }
        .alert(
            "闪卡",
            isPresented: Binding(
                get: { statusMessage != nil },
                set: { if !$0 { statusMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(statusMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("高亮 · 朱批")
                    .font(.system(size: 17, weight: .black, design: .serif))
                    .foregroundStyle(palette.ink)
                Text("共 \(highlights.count) 条 · 点击跳转到所在章")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
            }
            Spacer()
            Button {
                showFlashcards = true
            } label: {
                Text("闪卡复习")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.ink2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button {
                dismiss()
            } label: {
                Text("×")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.ink3)
                    .frame(width: 28, height: 28)
                    .background(palette.accentSoft, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 12, trailing: 16))
    }

    private func row(_ highlight: Highlight) -> some View {
        Button {
            onJump(highlight.chapterIndex)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.highlight)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\u{201C}\(highlight.textSnapshot)\u{201D}")
                        .font(.system(size: 13, design: .serif))
                        .lineSpacing(5)
                        .lineLimit(3)
                        .foregroundStyle(palette.ink)
                    HStack(spacing: 8) {
                        Text("第 \(highlight.chapterIndex + 1) 章")
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.ink3)
                        if generatingHighlightID == highlight.id {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("正在生成闪卡…")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(palette.accent)
                            }
                        }
                    }
                    if let note = highlight.note, !note.isEmpty {
                        Text("你的批注:\(note)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.ink3)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .emptyCard(palette, radius: 12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await generateFlashcards(from: highlight) }
            } label: {
                Label("生成闪卡", systemImage: "rectangle.on.rectangle.angled")
            }
            Button("删除", systemImage: "trash", role: .destructive) {
                delete([highlight])
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            EnsoMark(size: 44)
                .opacity(0.5)
            Text("这本书还没有朱批")
                .font(.system(size: 16, weight: .black, design: .serif))
                .foregroundStyle(palette.ink)
                .padding(.top, 6)
            Text("阅读时选中文字,点「高亮」留下第一笔。")
                .font(.system(size: 13))
                .foregroundStyle(palette.ink3)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func generateFlashcards(from highlight: Highlight) async {
        generatingHighlightID = highlight.id
        defer { generatingHighlightID = nil }
        do {
            let created = try await StudyCardStore(modelContext: modelContext)
                .generate(from: highlight, book: book)
            statusMessage = created.isEmpty
                ? "没有生成卡片 — 到「AI 状态」检查一下提供商。"
                : "已加入 \(created.count) 张闪卡,在卡片/生词屏复习。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func delete(_ toDelete: [Highlight]) {
        for highlight in toDelete {
            modelContext.delete(highlight)
        }
        try? modelContext.save()
    }
}
