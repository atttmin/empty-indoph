//
//  MacNotesScreen.swift
//  Empty
//

#if os(macOS)

import SwiftData
import SwiftUI

/// One card in the notes grid — a highlight-derived card or a saved
/// study card (复习卡 / 问答卡 / 链接卡).
private enum NoteCardItem: Identifiable {
    case highlight(Highlight)
    case study(StudyCardEntry)

    var id: UUID {
        switch self {
        case .highlight(let highlight): highlight.id
        case .study(let card): card.id
        }
    }

    var createdAt: Date {
        switch self {
        case .highlight(let highlight): highlight.createdAt
        case .study(let card): card.createdAt
        }
    }
}

struct MacNotesScreen: View {
    @Environment(\.emptyPalette) private var palette
    @Query(sort: \Highlight.createdAt, order: .reverse) private var highlights: [Highlight]
    @Query(sort: \VocabEntry.dueAt) private var vocabEntries: [VocabEntry]
    @Query(sort: \StudyCardEntry.createdAt, order: .reverse)
    private var studyCards: [StudyCardEntry]

    /// `nil` = 全部; `.review` = 待复习生词.
    @State private var filterBookID: UUID?
    @State private var showDueOnly = false
    @State private var graphSuggestion = ""
    @State private var isLoadingSuggestion = false
    @State private var showFullGraph = false

    private var filterableBooks: [Book] {
        var seen = Set<UUID>()
        let owners = highlights.compactMap(\.book) + studyCards.compactMap(\.book)
        return owners.filter { seen.insert($0.id).inserted }
    }

    private var dueVocabCount: Int {
        let now = Date()
        return vocabEntries.filter { $0.dueAt <= now }.count
    }

    private var dueStudyCards: [StudyCardEntry] {
        let now = Date()
        return studyCards.filter { $0.dueAt <= now }
    }

    private var visibleHighlights: [Highlight] {
        if showDueOnly { return [] }
        guard let filterBookID else { return highlights }
        return highlights.filter { $0.book?.id == filterBookID }
    }

    /// Cards shown in the two grid columns, newest first. The 待复习
    /// filter narrows to due study cards; a book filter narrows both kinds.
    private var visibleItems: [NoteCardItem] {
        if showDueOnly {
            return dueStudyCards.map(NoteCardItem.study)
        }
        let cards = filterBookID.map { id in
            studyCards.filter { $0.book?.id == id }
        } ?? studyCards
        return (visibleHighlights.map(NoteCardItem.highlight) + cards.map(NoteCardItem.study))
            .sorted { $0.createdAt > $1.createdAt }
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

                if highlights.isEmpty && vocabEntries.isEmpty && studyCards.isEmpty {
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
        .task(id: suggestionTaskKey) {
            await loadGraphSuggestion()
        }
        .sheet(isPresented: $showFullGraph) {
            MacFullGraphSheet(
                highlights: Array(visibleHighlights.prefix(8)),
                suggestion: graphSuggestion
            )
            .frame(minWidth: 640, minHeight: 560)
        }
    }

    private var suggestionTaskKey: String {
        let ids = visibleHighlights.prefix(5).map(\.id.uuidString).joined(separator: "-")
        return "\(filterBookID?.uuidString ?? "all")-\(ids)"
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 8) {
                Text("笔记 · 卡片")
                    .font(.system(size: 32, weight: .black, design: .serif))
                    .foregroundStyle(palette.ink)
                Text("高亮与问答沉淀的知识卡片,按概念聚类 · 共 \(highlights.count + studyCards.count) 张")
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.ink3)
            }
            Spacer()
            HStack(spacing: 8) {
                filterChip(title: "全部", bookID: nil, dueOnly: false)
                ForEach(filterableBooks.prefix(4)) { book in
                    filterChip(title: book.title, bookID: book.id, dueOnly: false)
                }
                if dueVocabCount + dueStudyCards.count > 0 {
                    filterChip(
                        title: "待复习 \(dueVocabCount + dueStudyCards.count)",
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
        let items = visibleItems
        let left = items.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        let right = items.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)

        return HStack(alignment: .top, spacing: 18) {
            column(left)
            column(right)
            VStack(spacing: 18) {
                if showDueOnly {
                    dueVocabPanel
                } else if items.isEmpty {
                    Text("没有匹配的卡片")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
                MacKnowledgeGraph(
                    nodes: graphNodes,
                    aiSuggestion: isLoadingSuggestion
                        ? "AI 正在分析你的高亮主题…"
                        : graphSuggestion,
                    onShowFull: { showFullGraph = true }
                )
            }
            .frame(width: 340)
        }
    }

    private func loadGraphSuggestion() async {
        guard !visibleHighlights.isEmpty else {
            graphSuggestion = ""
            return
        }
        isLoadingSuggestion = true
        defer { isLoadingSuggestion = false }

        let fallback =
            "AI 建议:你的 \(min(visibleHighlights.count, 3)) 条高亮已收录。继续阅读时留意跨书呼应,图谱会随笔记生长。"
        let samples = visibleHighlights.prefix(5).map(\.textSnapshot).joined(separator: "\n")
        let resolution = AIProviderSettings.load().resolveUsableService()
        guard resolution.service.availability.isAvailable else {
            graphSuggestion = fallback
            return
        }
        do {
            let summary = try await resolution.service.summarize(
                samples,
                focus: .digest
            )
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            graphSuggestion = trimmed.isEmpty
                ? fallback
                : "AI 建议:\(trimmed)"
        } catch {
            graphSuggestion = fallback
        }
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

    private func column(_ items: [NoteCardItem]) -> some View {
        VStack(spacing: 18) {
            ForEach(items) { item in
                switch item {
                case .highlight(let highlight):
                    HighlightCard(highlight: highlight)
                case .study(let card):
                    StudyNoteCard(card: card)
                }
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

/// A saved study card in the notes grid: 复习卡 (interactive spaced-rep
/// reveal), 问答卡 (kept companion exchange), or 链接卡 (saved thought link).
private struct StudyNoteCard: View {
    let card: StudyCardEntry

    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(chipTitle)
                    .emptyChip(foreground: palette.accent, background: palette.accentSoft)
                Text(metaLine)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(card.kind == .qa ? "Q:\(card.question)" : card.question)
                .font(.system(size: 14, weight: .bold))
                .lineSpacing(4)
                .foregroundStyle(palette.ink)
                .padding(.top, 12)

            switch card.kind {
            case .review:
                if revealed {
                    Text(card.answer)
                        .font(.system(size: 13))
                        .lineSpacing(6)
                        .foregroundStyle(palette.ink2)
                        .padding(.top, 8)
                }
                HStack(spacing: 8) {
                    if !revealed {
                        Button("显示答案") {
                            withAnimation { revealed = true }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.ink2)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
                    }
                    Button("记得 ✓") {
                        card.applyReview(.good)
                        try? modelContext.save()
                        revealed = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(palette.accentSoft, in: Capsule())
                }
                .padding(.top, 14)
            case .qa, .link:
                Text(card.answer)
                    .font(.system(size: 13))
                    .lineSpacing(6)
                    .foregroundStyle(palette.ink2)
                    .padding(.top, 8)
                if let source = card.source {
                    Text(source)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.ink2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
                        .padding(.top, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
        .emptyCard(palette)
        .contextMenu {
            Button("删除", systemImage: "trash", role: .destructive) {
                modelContext.delete(card)
                try? modelContext.save()
            }
        }
    }

    private var chipTitle: String {
        switch card.kind {
        case .review: "复习卡"
        case .qa: "问答卡"
        case .link: "⟲ 链接卡"
        }
    }

    private var metaLine: String {
        switch card.kind {
        case .review:
            "间隔复习 · 第 \(card.stage) 轮 · \(card.intervalDays) 天"
        case .qa:
            "来自你的追问 · \(card.createdAt.formatted(.relative(presentation: .named)))"
        case .link:
            "AI 发现关联 · \(card.createdAt.formatted(.relative(presentation: .named)))"
        }
    }
}

/// 查看完整图谱: a larger canvas over the reader's recent highlight
/// concepts, edges drawn where passages lexically resonate.
private struct MacFullGraphSheet: View {
    let highlights: [Highlight]
    let suggestion: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.emptyPalette) private var palette

    private struct Node {
        var label: String
        var bookTitle: String
        var text: String
    }

    private var nodes: [Node] {
        highlights.map { highlight in
            Node(
                label: String(highlight.textSnapshot.prefix(16)),
                bookTitle: highlight.book?.title ?? "—",
                text: highlight.textSnapshot
            )
        }
    }

    /// Index pairs whose passages overlap enough to draw an edge.
    private var edges: [(Int, Int, Double)] {
        var result: [(Int, Int, Double)] = []
        for i in nodes.indices {
            for j in nodes.indices where j > i {
                let score = LexicalScorer.score(query: nodes[i].text, text: nodes[j].text)
                if score > 0.12 {
                    result.append((i, j, score))
                }
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("知识图谱")
                    .font(.system(size: 18, weight: .black, design: .serif))
                    .foregroundStyle(palette.ink)
                Text("跨书概念关联 · \(nodes.count) 个概念")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.ink3)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.ink3)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 20, leading: 24, bottom: 12, trailing: 18))

            if nodes.isEmpty {
                Text("还没有可以联结的高亮 — 阅读时多留几条朱批,图谱会自己生长。")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.ink3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Canvas { context, size in
                    let positions = nodePositions(in: size)
                    for (i, j, score) in edges {
                        var path = Path()
                        path.move(to: positions[i])
                        path.addLine(to: positions[j])
                        let style = score > 0.2
                            ? StrokeStyle(lineWidth: 1.5)
                            : StrokeStyle(lineWidth: 1, dash: [3, 4])
                        context.stroke(
                            path,
                            with: .color(palette.accent.opacity(0.55)),
                            style: style
                        )
                    }
                    for index in nodes.indices {
                        drawNode(context, nodes[index], at: positions[index], isCenter: index == 0)
                    }
                }
                .padding(.horizontal, 16)
            }

            if !suggestion.isEmpty {
                Text(suggestion)
                    .font(.system(size: 12.5))
                    .lineSpacing(5)
                    .foregroundStyle(palette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 12, leading: 24, bottom: 20, trailing: 24))
                    .overlay(alignment: .top) {
                        Rectangle().fill(palette.line).frame(height: 1)
                    }
            }
        }
        .background(palette.window)
    }

    /// First node center stage, the rest on a ring around it.
    private func nodePositions(in size: CGSize) -> [CGPoint] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        guard nodes.count > 1 else { return [center] }
        let radius = min(size.width, size.height) * 0.36
        var positions = [center]
        let others = nodes.count - 1
        for index in 0..<others {
            let angle = (Double(index) / Double(others)) * 2 * .pi - .pi / 2
            positions.append(CGPoint(
                x: center.x + radius * CGFloat(Foundation.cos(angle)),
                y: center.y + radius * CGFloat(Foundation.sin(angle))
            ))
        }
        return positions
    }

    private func drawNode(
        _ context: GraphicsContext,
        _ node: Node,
        at point: CGPoint,
        isCenter: Bool
    ) {
        let radius: CGFloat = isCenter ? 52 : 40
        let circle = Path(ellipseIn: CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        if isCenter {
            context.fill(circle, with: .color(palette.accent))
        } else {
            context.fill(circle, with: .color(palette.card))
            context.stroke(circle, with: .color(palette.accent), lineWidth: 1.5)
        }
        context.draw(
            Text(node.label)
                .font(.system(size: isCenter ? 11 : 10, weight: .semibold))
                .foregroundStyle(isCenter ? palette.onAccent : palette.accent),
            in: CGRect(
                x: point.x - radius + 6,
                y: point.y - radius / 2,
                width: radius * 2 - 12,
                height: radius
            )
        )
        context.draw(
            Text(node.bookTitle)
                .font(.system(size: 8.5))
                .foregroundStyle(isCenter ? palette.onAccent.opacity(0.8) : palette.ink3),
            at: CGPoint(x: point.x, y: point.y + radius + 10)
        )
    }
}

#endif