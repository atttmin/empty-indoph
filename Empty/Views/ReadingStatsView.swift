//
//  ReadingStatsView.swift
//  Empty
//
//  P1 阅读统计: weekly/monthly active-minutes bars, streak, measured
//  reading speed, and remaining-time estimates for in-progress books.
//  强调全部本地计算 — nothing leaves the device.
//

import SwiftData
import SwiftUI

struct ReadingStatsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext

    private enum Period: String, CaseIterable {
        case week = "本周"
        case month = "本月"

        var days: Int {
            switch self {
            case .week: 7
            case .month: 30
            }
        }
    }

    @State private var period: Period = .week
    @State private var dayStats: [ReadingDayStat] = []
    @State private var streak = 0
    @State private var charsPerMinute: Double?
    @State private var inProgress: [(title: String, remainingMinutes: Double?)] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.line).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    periodPicker
                    chart
                    tiles
                    if !inProgress.isEmpty {
                        remainingSection
                    }
                    Text("所有统计在本机计算，不上传任何数据。计时只统计真实滚动 / 翻页的时间，挂机不算。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.ink3)
                }
                .padding(EdgeInsets(top: 16, leading: 20, bottom: 24, trailing: 20))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(palette.window)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
        #if os(iOS)
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
        #endif
        .task(id: period) {
            reload()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("阅读统计")
                    .font(.system(size: 17, weight: .black, design: .serif))
                    .foregroundStyle(palette.ink)
                Text("只算真正读着的时间")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
            }
            Spacer()
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

    private var periodPicker: some View {
        HStack(spacing: 8) {
            ForEach(Period.allCases, id: \.self) { choice in
                Button {
                    period = choice
                } label: {
                    Text(choice.rawValue)
                        .font(.system(size: 12, weight: period == choice ? .bold : .regular))
                        .foregroundStyle(period == choice ? palette.onAccent : palette.ink2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            period == choice ? palette.accent : palette.side,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("共 \(Int(dayStats.reduce(0) { $0 + $1.minutes })) 分钟")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.ink3)
        }
    }

    private var chart: some View {
        let peak = max(dayStats.map(\.minutes).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: period == .week ? 10 : 3) {
                ForEach(dayStats) { stat in
                    VStack(spacing: 4) {
                        Capsule()
                            .fill(stat.minutes >= 1 ? palette.accent : palette.line)
                            .frame(height: max(4, CGFloat(stat.minutes / peak) * 110))
                            .frame(maxWidth: .infinity)
                        if period == .week {
                            Text(weekdayLabel(stat.day))
                                .font(.system(size: 9.5))
                                .foregroundStyle(palette.ink3)
                        }
                    }
                }
            }
            .frame(height: 132, alignment: .bottom)
        }
        .padding(14)
        .emptyCard(palette, radius: 12)
    }

    private var tiles: some View {
        HStack(spacing: 10) {
            tile(
                value: streak > 0 ? "\(streak) 天" : "—",
                label: "连续阅读"
            )
            tile(
                value: todayMinutes >= 1 ? "\(Int(todayMinutes)) 分钟" : "—",
                label: "今天"
            )
            tile(
                value: charsPerMinute.map { "\(Int($0)) 字/分" } ?? "读几次就有了",
                label: "平均速度"
            )
        }
    }

    private func tile(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .black, design: .serif))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(palette.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .emptyCard(palette, radius: 12)
    }

    private var remainingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("在读 · 按你的速度还要")
                .font(.system(size: 11, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(palette.ink3)
            ForEach(inProgress, id: \.title) { entry in
                HStack {
                    Text(entry.title)
                        .font(.system(size: 12.5, weight: .bold, design: .serif))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    Spacer()
                    Text(remainingLabel(entry.remainingMinutes))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.accent)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .emptyCard(palette, radius: 10)
            }
        }
    }

    private var todayMinutes: Double {
        guard let today = dayStats.last else { return 0 }
        return today.minutes
    }

    private func weekdayLabel(_ day: Date) -> String {
        let weekday = Calendar.current.component(.weekday, from: day)
        return ["日", "一", "二", "三", "四", "五", "六"][weekday - 1]
    }

    private func remainingLabel(_ minutes: Double?) -> String {
        guard let minutes else { return "速度测算中" }
        if minutes < 60 { return "约 \(max(1, Int(minutes))) 分钟" }
        let hours = minutes / 60
        return String(format: "约 %.1f 小时", hours)
    }

    private func reload() {
        let store = ReadingStatsStore(modelContext: modelContext)
        dayStats = (try? store.dailyMinutes(days: period.days)) ?? []
        streak = (try? store.streakDays()) ?? 0
        charsPerMinute = try? store.averageCharsPerMinute() ?? nil

        let books = (try? modelContext.fetch(FetchDescriptor<Book>(
            sortBy: [SortDescriptor(\Book.lastOpenedAt, order: .reverse)]
        ))) ?? []
        inProgress = books
            .filter { $0.progressFraction > 0.01 && $0.progressFraction < 0.99 }
            .prefix(3)
            .map { book in
                (title: book.title, remainingMinutes: try? store.remainingMinutes(for: book) ?? nil)
            }
    }
}
