//
//  MacNotesScreen.swift
//  Empty
//

#if os(macOS)

import SwiftData
import SwiftUI

struct MacNotesScreen: View {
    @Environment(\.emptyPalette) private var palette
    @Query(sort: \Highlight.createdAt, order: .reverse) private var highlights: [Highlight]
    @Query(sort: \VocabEntry.dueAt) private var vocabEntries: [VocabEntry]

    /// `nil` = 全部; `.review` = 待复习生词.
    @State private var filterBookID: UUID?
    @State private var showDueOnly = false

    private var filterableBooks: [Book] {
        var seen = Set<UUID>()
        return highlights.compactMap { highlight in
            guard let book = highlight.book, seen.insert(book.id).inserted else {
                return nil
            }
            return book
        }
    }

    private var dueVocabCount: Int {
        let now = Date()
        return vocabEntries.filter { $0.dueAt <= now }.count
    }

    private var visibleHighlights: [Highlight] {
        if showDueOnly { return [] }
        guard let filterBookID else { return highlights }
        return highlights.filter { $0.book?.id == filterBookID }
    }

    private var graphNodes: [String] {
        let seeds = visibleHighlights.prefix(3).map { highlight in
            String(highlight.textSnapshot.prefix(24))
        }
        return seeds.isEmpty ? ["阅读", "思考", "关联"] : Array(seeds)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                if highlights.isEmpty && vocabEntries.isEmpty {
                    emptyState
                        .padding(.top, 28)
                } else {
                    cardGrid
                        .padding(.top, 28)
                }
            }
            .frame(maxWidth: 1010, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.top, 36)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 8) {
                Text("笔记 · 卡片")
                    .font(.system(size: 32, weight: .black, design: .serif))
                    .foregroundStyle(palette.ink)
                Text("高亮自动生成的知识卡片,按概念聚类 · 共 \(highlights.count) 张")
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.ink3)
            }
            Spacer()
            HStack(spacing: 8) {
                filterChip(title: "全部", bookID: nil, dueOnly: false)
                ForEach(filterableBooks.prefix(4)) { book in
                    filterChip(title: book.title, bookID: book.id, dueOnly: false)
                }
                if dueVocabCount > 0 {
                    filterChip(
                        title: "待复习 \(dueVocabCount)",
                        bookID: nil,
                        dueOnly: true
                    )
                }
            }
        }
    }

    private func filterChip(title: String, bookID: UUID?, dueOnly: Bool) -> some View {
        let isActive = showDueOnly == dueOnly && filterBookID == bookID
        return Button {
            showDueOnly = dueOnly
            filterBookID = bookID
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? palette.onAccent : palette.ink2)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isActive ? palette.accent : .clear, in: Capsule())
                .overlay {
                    if !isActive {
                        Capsule().strokeBorder(palette.line2, lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var cardGrid: some View {
        let cards = visibleHighlights
        let left = cards.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
        let middle = cards.enumerated().filter { $0.offset % 3 == 1 }.map(\.element)

        return HStack(alignment: .top, spacing: 18) {
            column(left)
            column(middle)
            VStack(spacing: 18) {
                if showDueOnly {
                    dueVocabPanel
                } else if cards.isEmpty {
                    Text("没有匹配的卡片")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
                MacKnowledgeGraph(
                    nodes: graphNodes,
                    aiSuggestion: graphSuggestion
                )
            }
            .frame(width: 340)
        }
    }

    private var graphSuggestion: String {
        guard !highlights.isEmpty else { return "" }
        return "AI 建议:你的 \(min(highlights.count, 3)) 个高频高亮都指向「自主注意力」。继续阅读时留意跨书呼应,图谱会自动生长。"
    }

    private var dueVocabPanel: some View {
        let now = Date()
        let due = vocabEntries.filter { $0.dueAt <= now }
        return VStack(alignment: .leading, spacing: 12) {
            Text("今日待复习 · \(due.count)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.ink)
            ForEach(due.prefix(3)) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.word)
                        .font(.system(size: 15, weight: .bold, design: .serif))
                    Text(entry.meaning)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.ink2)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10).strokeBorder(palette.line, lineWidth: 1)
                )
            }
        }
        .padding(16)
        .emptyCard(palette)
    }

    private func column(_ items: [Highlight]) -> some View {
        VStack(spacing: 18) {
            ForEach(items) { highlight in
                HighlightCard(highlight: highlight)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            EnsoMark(size: 44)
                .opacity(0.5)
            Text("虚室生白")
                .font(.system(size: 20, weight: .black, design: .serif))
                .foregroundStyle(palette.ink)
                .padding(.top, 8)
            Text("这里还空着。阅读时留下的高亮与批注,会以卡片的形式聚集在这里。")
                .font(.system(size: 13))
                .foregroundStyle(palette.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

private struct HighlightCard: View {
    let highlight: Highlight

    @Environment(\.emptyPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(cardKind)
                    .emptyChip(foreground: chipForeground, background: chipBackground)
                Text(sourceLine)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if cardKind == "概念卡" {
                Text(highlight.textSnapshot)
                    .font(.system(size: 19, weight: .bold, design: .serif))
                    .foregroundStyle(palette.ink)
                    .lineLimit(2)
                    .padding(.top, 10)
            }

            Text(displayQuote)
                .font(.system(size: cardKind == "概念卡" ? 12.5 : 15, design: .serif))
                .italic(cardKind != "概念卡")
                .lineSpacing(6)
                .foregroundStyle(cardKind == "概念卡" ? palette.ink3 : palette.ink)
                .padding(.top, cardKind == "概念卡" ? 8 : 12)

            if let note = highlight.note, !note.isEmpty {
                Text("你的批注:\(note)")
                    .font(.system(size: 12.5))
                    .lineSpacing(4)
                    .foregroundStyle(palette.ink3)
                    .padding(.top, 8)
            }

            if highlight.textSnapshot.count > 40 {
                HStack(spacing: 6) {
                    Text("⟲ AI 发现关联")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
        .emptyCard(palette)
    }

    private var cardKind: String {
        if highlight.note?.isEmpty == false { return "批注卡" }
        if highlight.textSnapshot.count < 28 { return "概念卡" }
        return "我的高亮"
    }

    private var chipForeground: Color {
        switch cardKind {
        case "概念卡", "批注卡": palette.accent
        default:
            palette.isDark ? Color(hex: 0xDEB248) : Color(hex: 0x7A6320)
        }
    }

    private var chipBackground: Color {
        switch cardKind {
        case "概念卡", "批注卡": palette.accentSoft
        default: palette.highlight
        }
    }

    private var displayQuote: String {
        if cardKind == "概念卡" {
            return "\"\(highlight.textSnapshot)\" — \(sourceLine)"
        }
        return "\u{201C}\(highlight.textSnapshot)\u{201D}"
    }

    private var sourceLine: String {
        var parts: [String] = []
        if let title = highlight.book?.title {
            parts.append(title)
        }
        parts.append("第 \(highlight.chapterIndex + 1) 章")
        parts.append(highlight.createdAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }
}

#endif