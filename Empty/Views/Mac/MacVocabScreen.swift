//
//  MacVocabScreen.swift
//  Empty
//

#if os(macOS)

import SwiftData
import SwiftUI

struct MacVocabScreen: View {
    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VocabEntry.dueAt) private var entries: [VocabEntry]

    @State private var now = Date()
    @State private var reviewIndex = 0
    @State private var revealed = false
    @State private var sessionLog: [VocabReviewGrade] = []

    private var dueEntries: [VocabEntry] {
        entries.filter { $0.dueAt <= now }
    }

    private var currentReview: VocabEntry? {
        guard !dueEntries.isEmpty, reviewIndex < dueEntries.count else { return nil }
        return dueEntries[reviewIndex]
    }

    private var ladderDistribution: [(days: Int, count: Int)] {
        VocabEntry.ladderDays.map { days in
            let stage = VocabEntry.ladderDays.firstIndex(of: days)! + 1
            let count = entries.filter { $0.stage == stage }.count
            return (days: days, count: count)
        }
    }

    private var sourceBookCount: Int {
        Set(entries.compactMap(\.source).map { $0.components(separatedBy: " · ").first }).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                if entries.isEmpty {
                    emptyState
                        .padding(.top, 28)
                } else {
                    reviewGrid
                        .padding(.top, 28)
                    allWordsSection
                        .padding(.top, 28)
                }
            }
            .frame(maxWidth: 1010, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.top, 36)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .onAppear { now = Date() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 8) {
                Text("生词本")
                    .font(.system(size: 32, weight: .black, design: .serif))
                    .foregroundStyle(palette.ink)
                Text("\(entries.count) 个生词 · 来自 \(max(sourceBookCount, 1)) 本书 · 按艾宾浩斯遗忘曲线安排复习")
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.ink3)
            }
            Spacer()
            if !dueEntries.isEmpty {
                Text("今日待复习 \(dueEntries.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(palette.accentSoft, in: Capsule())
            }
        }
    }

    private var reviewGrid: some View {
        HStack(alignment: .top, spacing: 18) {
            reviewCard
                .frame(maxWidth: .infinity)
            VStack(spacing: 18) {
                MacForgettingCurveChart()
                MacVocabLadderChart(distribution: ladderDistribution)
            }
            .frame(width: 360)
        }
    }

    @ViewBuilder
    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let entry = currentReview {
                activeReview(entry)
            } else if !dueEntries.isEmpty && reviewIndex >= dueEntries.count {
                completedReview
            } else {
                noDueReview
            }
        }
        .padding(26)
        .frame(minHeight: 380, alignment: .topLeading)
        .emptyCard(palette, radius: 18)
    }

    private func activeReview(_ entry: VocabEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("今日复习")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.2)
                    .foregroundStyle(palette.accent)
                Text("\(reviewIndex + 1) / \(dueEntries.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.ink3)
                Spacer()
                Text("第 \(entry.stage) 轮 · 当前间隔 \(entry.intervalDays) 天")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
            }

            Spacer(minLength: 28)

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(entry.word)
                    .font(.system(size: 40, weight: .bold, design: .serif))
                    .foregroundStyle(palette.ink)
                if let phonetic = entry.phonetic {
                    Text(phonetic)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.ink3)
                }
                if let pos = entry.partOfSpeech {
                    Text(pos)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.ink3)
                }
            }

            if let sentence = entry.sentence, !sentence.isEmpty {
                Text("\"\(sentence)\"")
                    .font(.system(size: 15.5, design: .serif))
                    .italic()
                    .lineSpacing(6)
                    .foregroundStyle(palette.ink2)
                    .padding(.top, 18)
            }

            if let source = entry.source, !source.isEmpty {
                Text(source)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
                    .padding(.top, 8)
            }

            if revealed {
                ZhupiCallout(title: "释义") {
                    Text(entry.meaning)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(palette.ink)
                    if let note = entry.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.ink2)
                            .padding(.top, 4)
                    }
                }
                .padding(.top, 20)

                HStack(spacing: 10) {
                    gradeButton(
                        title: "忘了",
                        subtitle: "降级 → 明天再见",
                        grade: .forgot,
                        emphasized: false
                    )
                    gradeButton(
                        title: "模糊",
                        subtitle: "保持 → \(entry.intervalDays) 天后",
                        grade: .fuzzy,
                        emphasized: false
                    )
                    gradeButton(
                        title: "记得 ✓",
                        subtitle: "升级 → \(entry.nextIntervalDays) 天后",
                        grade: .good,
                        emphasized: true
                    )
                }
                .padding(.top, 16)
            } else {
                Button {
                    withAnimation { revealed = true }
                } label: {
                    Text("显示释义")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.window)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(palette.ink, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.top, 28)
            }

            Spacer(minLength: 0)
        }
    }

    private var completedReview: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("✓")
                .font(.system(size: 22))
                .foregroundStyle(palette.accent)
                .frame(width: 52, height: 52)
                .background(palette.accentSoft, in: Circle())
            Text("今日复习完成")
                .font(.system(size: 20, weight: .black, design: .serif))
                .foregroundStyle(palette.ink)
                .padding(.top, 6)
            Text("本轮 \(sessionLog.count) 词 · 记得 \(sessionLog.filter { $0 == .good }.count) · 模糊 \(sessionLog.filter { $0 == .fuzzy }.count)")
                .font(.system(size: 13))
                .foregroundStyle(palette.ink2)
            Button("↻ 再练一轮") {
                reviewIndex = 0
                revealed = false
                sessionLog = []
                now = Date()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(palette.ink2)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
            .padding(.top, 10)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var noDueReview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日没有到期的生词")
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(palette.ink2)
            Text("继续阅读,选中词语加入生词本,这里会按记忆曲线安排复习。")
                .font(.system(size: 13))
                .foregroundStyle(palette.ink3)
            Spacer()
        }
    }

    private var allWordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("全部生词")
                    .font(.system(size: 18, weight: .black, design: .serif))
                    .foregroundStyle(palette.ink)
                Text("点击任意词可查看原文语境")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.ink3)
            }

            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    HStack(spacing: 16) {
                        Text(entry.word)
                            .font(.system(size: 15.5, weight: .bold, design: .serif))
                            .foregroundStyle(palette.ink)
                            .frame(width: 150, alignment: .leading)
                        Text(entry.meaning)
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.ink2)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(entry.source ?? "—")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.ink3)
                            .frame(width: 130, alignment: .leading)
                            .lineLimit(1)
                        StagePill(entry: entry)
                            .frame(width: 88)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 13)
                    .overlay(alignment: .bottom) {
                        if entry.id != entries.last?.id {
                            Rectangle().fill(palette.line).frame(height: 1)
                        }
                    }
                    .contextMenu {
                        Button("删除", systemImage: "trash", role: .destructive) {
                            delete(entry)
                        }
                    }
                }
            }
            .emptyCard(palette)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有生词")
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(palette.ink2)
            Text("阅读时选中词语,点「生词」加入生词本,这里会按记忆曲线安排复习。")
                .font(.system(size: 13))
                .foregroundStyle(palette.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .emptyCard(palette, radius: 12)
    }

    private func gradeButton(
        title: String,
        subtitle: String,
        grade: VocabReviewGrade,
        emphasized: Bool
    ) -> some View {
        Button {
            review(grade: grade)
        } label: {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: emphasized ? .bold : .semibold))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(emphasized ? palette.onAccent.opacity(0.85) : palette.ink3)
            }
            .foregroundStyle(emphasized ? palette.onAccent : palette.ink2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(emphasized ? palette.accent : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if !emphasized {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(palette.line2, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func review(grade: VocabReviewGrade) {
        guard let entry = currentReview else { return }
        entry.applyReview(grade)
        sessionLog.append(grade)
        try? modelContext.save()
        revealed = false
        reviewIndex += 1
        now = Date()
    }

    private func delete(_ entry: VocabEntry) {
        modelContext.delete(entry)
        try? modelContext.save()
        now = Date()
    }
}

private struct StagePill: View {
    let entry: VocabEntry

    @Environment(\.emptyPalette) private var palette

    var body: some View {
        Text(entry.isStable ? "已掌握" : "D\(entry.intervalDays)")
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(entry.isStable ? palette.accent : palette.ink3)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                entry.isStable ? palette.accentSoft : palette.line.opacity(0.5),
                in: Capsule()
            )
    }
}

#endif