//
//  IOSCardsScreen.swift
//  Empty
//
//  iOS 卡片 from the 02 iOS prototype: one stream that mixes highlight
//  cards, saved study cards (复习卡 / 问答卡 / 链接卡), a compact
//  Ebbinghaus 生词复习 card, and the 朱批 · 发现关联 footer.
//

#if !os(macOS)

import SwiftData
import SwiftUI

struct IOSCardsScreen: View {
    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Highlight.createdAt, order: .reverse) private var highlights: [Highlight]
    @Query(sort: \StudyCardEntry.createdAt, order: .reverse)
    private var studyCards: [StudyCardEntry]
    @Query(sort: \VocabEntry.dueAt) private var vocabEntries: [VocabEntry]

    @State private var filterBookID: UUID?
    @State private var showDueOnly = false
    @State private var connection: ThoughtLink?

    private var filterableBooks: [Book] {
        var seen = Set<UUID>()
        let owners = highlights.compactMap(\.book) + studyCards.compactMap(\.book)
        return owners.filter { seen.insert($0.id).inserted }
    }

    private var dueCount: Int {
        let now = Date()
        return studyCards.count { $0.dueAt <= now }
            + vocabEntries.count { $0.dueAt <= now }
    }

    private var visibleHighlights: [Highlight] {
        if showDueOnly { return [] }
        guard let filterBookID else { return highlights }
        return highlights.filter { $0.book?.id == filterBookID }
    }

    private var visibleStudyCards: [StudyCardEntry] {
        if showDueOnly {
            let now = Date()
            return studyCards.filter { $0.dueAt <= now }
        }
        guard let filterBookID else { return studyCards }
        return studyCards.filter { $0.book?.id == filterBookID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("卡片")
                    .font(.system(size: 30, weight: .black, design: .serif))
                    .foregroundStyle(palette.ink)
                Text("\(highlights.count + studyCards.count) 张 · 今日待复习 \(dueCount) 张")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.ink3)
                    .padding(.top, 2)

                filterRow
                    .padding(.top, 16)

                if highlights.isEmpty && studyCards.isEmpty && vocabEntries.isEmpty {
                    emptyState
                        .padding(.top, 48)
                } else {
                    cardStream
                        .padding(.top, 16)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 130)
        }
        .task(id: highlights.first?.id) {
            await loadConnection()
        }
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip("全部", bookID: nil, dueOnly: false)
                ForEach(filterableBooks.prefix(4)) { book in
                    filterChip(book.title, bookID: book.id, dueOnly: false)
                }
                if dueCount > 0 {
                    filterChip("待复习 \(dueCount)", bookID: nil, dueOnly: true)
                }
            }
        }
    }

    private func filterChip(_ title: String, bookID: UUID?, dueOnly: Bool) -> some View {
        let isActive = showDueOnly == dueOnly && filterBookID == bookID
        return Button {
            showDueOnly = dueOnly
            filterBookID = bookID
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? palette.onAccent : palette.ink2)
                .lineLimit(1)
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
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

    private var cardStream: some View {
        LazyVStack(spacing: 14) {
            // 生词复习 sits on top while anything is due — the prototype's
            // "碎片时间过两个词" compact review.
            if !vocabEntries.isEmpty {
                IOSVocabReviewCard()
            }

            ForEach(visibleStudyCards) { card in
                IOSStudyCard(card: card)
            }

            ForEach(visibleHighlights) { highlight in
                highlightCard(highlight)
            }

            if let connection {
                connectionCallout(connection)
            }
        }
    }

    private func highlightCard(_ highlight: Highlight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(highlight.textSnapshot.count < 28 ? "概念卡" : "我的高亮")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(1)
                    .foregroundStyle(chipColor(for: highlight))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(chipBackground(for: highlight), in: Capsule())
                Text(sourceLine(for: highlight))
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text("\u{201C}\(highlight.textSnapshot)\u{201D}")
                .font(.system(size: 13.5, design: .serif))
                .lineSpacing(5)
                .foregroundStyle(palette.ink)
            if let note = highlight.note, !note.isEmpty {
                Text("你的批注:\(note)")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .emptyCard(palette)
    }

    private func chipColor(for highlight: Highlight) -> Color {
        highlight.textSnapshot.count < 28
            ? palette.accent
            : (palette.isDark ? Color(hex: 0xDEB248) : Color(hex: 0x7A6320))
    }

    private func chipBackground(for highlight: Highlight) -> Color {
        highlight.textSnapshot.count < 28 ? palette.accentSoft : palette.highlight
    }

    private func sourceLine(for highlight: Highlight) -> String {
        var parts: [String] = []
        if let title = highlight.book?.title { parts.append(title) }
        parts.append("第 \(highlight.chapterIndex + 1) 章")
        return parts.joined(separator: " · ")
    }

    // MARK: 朱批 · 发现关联

    private func connectionCallout(_ link: ThoughtLink) -> some View {
        ZhupiCallout(title: "朱批 · 发现关联") {
            Text("「\(link.currentText.prefix(16))…」与《\(link.relatedBookTitle)》的一条高亮指向同一件事。完整图谱在 Mac 端查看更佳。")
                .font(.system(size: 12.5))
                .lineSpacing(5)
                .foregroundStyle(palette.ink2)
        }
    }

    /// Lexical-only link between the two most recent highlights — no model
    /// call, instant.
    private func loadConnection() async {
        guard let latest = highlights.first, let book = latest.book else {
            connection = nil
            return
        }
        connection = try? ThoughtLinkFinder(modelContext: modelContext).findLink(
            passage: latest.textSnapshot,
            book: book,
            chapterIndex: latest.chapterIndex
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            EnsoMark(size: 44)
                .opacity(0.5)
            Text("还没有卡片")
                .font(.system(size: 18, weight: .black, design: .serif))
                .foregroundStyle(palette.ink)
                .padding(.top, 6)
            Text("阅读时的高亮、向 AI 的追问、查过的生词,都会沉淀到这里复习。")
                .font(.system(size: 13))
                .foregroundStyle(palette.ink3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Study card (复习卡 / 问答卡 / 链接卡)

private struct IOSStudyCard: View {
    let card: StudyCardEntry

    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(chipTitle)
                    .font(.system(size: 10, weight: .bold))
                    .kerning(1)
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(palette.accentSoft, in: Capsule())
                Text(metaLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(card.kind == .qa ? "Q:\(card.question)" : card.question)
                .font(.system(size: 13.5, weight: .bold))
                .lineSpacing(4)
                .foregroundStyle(palette.ink)
                .padding(.top, 10)

            if card.kind == .review {
                if revealed {
                    Text(card.answer)
                        .font(.system(size: 12.5))
                        .lineSpacing(5)
                        .foregroundStyle(palette.ink2)
                        .padding(.top, 8)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(palette.accent).frame(width: 2)
                        }
                }
                HStack(spacing: 8) {
                    Button(revealed ? "收起答案" : "显示答案") {
                        withAnimation { revealed.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.ink2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))

                    Button("记得 ✓") {
                        card.applyReview(.good)
                        try? modelContext.save()
                        revealed = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(palette.accentSoft, in: Capsule())
                }
                .padding(.top, 12)
            } else {
                Text(card.answer)
                    .font(.system(size: 12.5))
                    .lineSpacing(5)
                    .foregroundStyle(palette.ink2)
                    .padding(.top, 8)
                if let source = card.source {
                    Text(source)
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.ink3)
                        .lineLimit(1)
                        .padding(.top, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
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
        case .review: "间隔复习 · 第 \(card.stage) 轮"
        case .qa: "来自你的追问"
        case .link: "AI 发现关联"
        }
    }
}

// MARK: - Compact vocab review (艾宾浩斯)

private struct IOSVocabReviewCard: View {
    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VocabEntry.dueAt) private var entries: [VocabEntry]

    @State private var now = Date()
    @State private var reviewIndex = 0
    @State private var revealed = false

    private var dueEntries: [VocabEntry] {
        entries.filter { $0.dueAt <= now }
    }

    private var current: VocabEntry? {
        guard reviewIndex < dueEntries.count else { return nil }
        return dueEntries[reviewIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("生词复习")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(1)
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(palette.accentSoft, in: Capsule())
                Text("艾宾浩斯间隔 · \(progressLabel)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.ink3)
                Spacer(minLength: 0)
            }

            if let entry = current {
                activeReview(entry)
            } else {
                doneState
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .emptyCard(palette)
        .onAppear { now = Date() }
    }

    private var progressLabel: String {
        dueEntries.isEmpty || current == nil
            ? "完成"
            : "\(min(reviewIndex + 1, dueEntries.count)) / \(dueEntries.count)"
    }

    @ViewBuilder
    private func activeReview(_ entry: VocabEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.word)
                .font(.system(size: 21, weight: .bold, design: .serif))
                .foregroundStyle(palette.ink)
            if let phonetic = entry.phonetic {
                Text("\(phonetic) · 第 \(entry.stage) 轮")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
            } else {
                Text("第 \(entry.stage) 轮")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
            }
        }
        .padding(.top, 10)

        if let sentence = entry.sentence, !sentence.isEmpty {
            Text("\u{201C}\(revealed ? sentence : VocabCloze.blank(sentence, word: entry.word))\u{201D}")
                .font(.system(size: 12.5, design: .serif))
                .italic()
                .lineSpacing(5)
                .foregroundStyle(palette.ink2)
                .padding(.top, 6)
        }

        if revealed {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.meaning)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(palette.ink)
                if let note = entry.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.ink2)
                }
            }
            .padding(.top, 8)
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Rectangle().fill(palette.accent).frame(width: 2)
            }

            HStack(spacing: 8) {
                gradeButton("忘了 · 明天再见", grade: .forgot, entry: entry, emphasized: false)
                gradeButton(
                    "记得 ✓ · \(entry.nextIntervalDays) 天后",
                    grade: .good,
                    entry: entry,
                    emphasized: true
                )
            }
            .padding(.top, 10)
        } else {
            Button("显示释义") {
                withAnimation { revealed = true }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(palette.window)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(palette.ink, in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 10)
        }
    }

    private var doneState: some View {
        VStack(spacing: 4) {
            Text("✓")
                .font(.system(size: 18))
                .foregroundStyle(palette.accent)
            Text("今日生词复习完成")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(palette.ink)
            let forecast = VocabQueueForecast.describe(dueDates: entries.map(\.dueAt), now: now)
            if !forecast.isEmpty {
                Text("下次队列:\(forecast)")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
            }
            Button("↻ 再练一轮") {
                reviewIndex = 0
                revealed = false
                now = Date()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(palette.ink2)
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func gradeButton(
        _ title: String,
        grade: VocabReviewGrade,
        entry: VocabEntry,
        emphasized: Bool
    ) -> some View {
        Button {
            entry.applyReview(grade)
            try? modelContext.save()
            revealed = false
            // `now` stays frozen for the session, so the queue keeps its
            // members and the index walks it — same semantics as the Mac
            // review (and what makes ↻ 再练一轮 meaningful).
            reviewIndex += 1
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: emphasized ? .bold : .semibold))
                .foregroundStyle(emphasized ? palette.onAccent : palette.ink2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    emphasized ? palette.accent : .clear,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay {
                    if !emphasized {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(palette.line2, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

#endif
