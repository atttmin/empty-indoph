//
//  MacUIComponents.swift
//  Empty
//
//  Shared Mac workbench controls from 01 Mac 原型.dc.html.
//

#if os(macOS)

import SwiftUI

// MARK: - Search

struct MacSearchField: View {
    @Binding var text: String
    var placeholder: String

    @Environment(\.emptyPalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Text("⌕")
                .font(.system(size: 13))
                .foregroundStyle(palette.ink3)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(palette.ink)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(width: 250)
        .background(palette.card, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
    }
}

// MARK: - Segmented pills

struct MacSegmentedPills<Option: Hashable>: View {
    let options: [(Option, String)]
    @Binding var selection: Option

    @Environment(\.emptyPalette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { option, title in
                let isActive = selection == option
                Button {
                    selection = option
                } label: {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isActive ? palette.accent : palette.ink2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(isActive ? palette.card : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(palette.accentSoft, in: Capsule())
    }
}

// MARK: - Selection popover

struct MacSelectionPopover: View {
    var onExplain: () -> Void
    var onTranslate: () -> Void
    var onAsk: () -> Void
    var onHighlight: () -> Void
    var onVocab: () -> Void
    var isLoading: Bool

    @Environment(\.emptyPalette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            popButton("解释", action: onExplain)
            popButton("翻译", action: onTranslate)
            Button(action: onAsk) {
                Text("追问 ↩")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            popButton("高亮", action: onHighlight)
            popButton("生词", action: onVocab)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 8)
            }
        }
        .padding(6)
        .background(palette.ink, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
    }

    private func popButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(palette.window)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chapter summary

struct MacChapterSummaryCard: View {
    let title: String
    let summary: String
    var onCollapse: () -> Void

    @Environment(\.emptyPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ZhuBadge(size: 18)
                Text("AI 章节概览")
                    .font(.system(size: 12, weight: .bold))
                    .kerning(1)
                    .foregroundStyle(palette.accent)
                Text("读前 30 秒")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.ink3)
                Spacer()
                Button("收起 ⌃", action: onCollapse)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.ink3)
            }
            Text(summary)
                .font(.system(size: 12.5))
                .lineSpacing(6)
                .foregroundStyle(palette.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .emptyCard(palette, radius: 14)
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }
}

// MARK: - TTS bar

struct MacReadingAloudBar: View {
    let snippet: String
    var onToggle: () -> Void
    var isPaused: Bool

    @Environment(\.emptyPalette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onToggle) {
                Text(isPaused ? "▶" : "❚❚")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.onAccent)
                    .frame(width: 30, height: 30)
                    .background(palette.accent, in: Circle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 3) {
                ForEach(0..<6, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(palette.accent)
                        .frame(width: 3, height: CGFloat([8, 16, 11, 18, 7, 14][index]))
                        .opacity(index.isMultiple(of: 2) ? 0.85 : 0.6)
                }
            }

            Text("正在朗读 · \"\(snippet)…\"")
                .font(.system(size: 12.5))
                .lineLimit(1)
            Text("1.0×")
                .font(.system(size: 11.5))
                .opacity(0.6)
        }
        .foregroundStyle(palette.window)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(palette.ink, in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
    }
}

// MARK: - Thought link

struct MacThoughtLinkCard: View {
    let link: ThoughtLink
    var isExpanded: Bool
    var onToggle: () -> Void
    var onOpenNotes: () -> Void
    var onAsk: () -> Void

    @Environment(\.emptyPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Text("⟲ 思维链接 · 这段与你的一条高亮相连")
                        .font(.system(size: 12, weight: .semibold))
                    Text(isExpanded ? "⌃" : "⌄")
                }
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(palette.accentSoft, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.accentSoft2, lineWidth: 1))
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        linkPane(link.currentSource, text: link.currentText, italic: true)
                        Text("⟷")
                            .font(.system(size: 15))
                            .foregroundStyle(palette.accent)
                            .padding(.top, 24)
                        linkPane(link.relatedSource, text: link.relatedText, italic: false)
                    }
                    Text(link.explanation)
                        .font(.system(size: 12.5))
                        .lineSpacing(5)
                        .foregroundStyle(palette.ink2)
                    HStack(spacing: 8) {
                        Button("在图谱中查看 →", action: onOpenNotes)
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(palette.onAccent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(palette.accent, in: Capsule())
                        Button("就此追问 ↩", action: onAsk)
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.ink2)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
                    }
                }
                .padding(16)
                .emptyCard(palette, radius: 14)
            }
        }
        .padding(.horizontal, 24)
    }

    private func linkPane(_ label: String, text: String, italic: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(palette.ink3)
            Text(text)
                .font(.system(size: 12.5, design: .serif))
                .italic(italic)
                .lineSpacing(4)
                .foregroundStyle(palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(palette.line, lineWidth: 1)
        )
    }
}

// MARK: - Knowledge graph

struct MacKnowledgeGraph: View {
    let nodes: [String]
    var aiSuggestion: String

    @Environment(\.emptyPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("知识图谱")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.ink)
                Text("跨书概念关联")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
            }

            Canvas { context, size in
                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.33)
                let left = CGPoint(x: size.width * 0.24, y: size.height * 0.64)
                let right = CGPoint(x: size.width * 0.76, y: size.height * 0.61)
                let bottom = CGPoint(x: size.width * 0.5, y: size.height * 0.84)

                var path = Path()
                path.move(to: center)
                path.addLine(to: left)
                path.move(to: center)
                path.addLine(to: right)
                path.move(to: center)
                path.addLine(to: bottom)
                path.move(to: left)
                path.addLine(to: bottom)
                context.stroke(
                    path,
                    with: .color(palette.accent.opacity(0.55)),
                    lineWidth: 1.5
                )

                drawNode(context, at: center, radius: 40, filled: true, label: nodes.first ?? "概念")
                drawNode(context, at: left, radius: 30, filled: false, label: nodes.dropFirst().first ?? "关联")
                drawNode(context, at: right, radius: 30, filled: false, label: nodes.dropFirst(2).first ?? "主题")
                drawNode(context, at: bottom, radius: 24, filled: false, label: "?", dashed: true)
            }
            .frame(height: 220)

            if !aiSuggestion.isEmpty {
                Text(aiSuggestion)
                    .font(.system(size: 12))
                    .lineSpacing(4)
                    .foregroundStyle(palette.ink2)
                    .padding(.top, 6)
                    .overlay(alignment: .top) {
                        Rectangle().fill(palette.line).frame(height: 1).offset(y: -6)
                    }
            }

            Button("查看完整图谱 →") {}
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(palette.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(palette.accent, lineWidth: 1))
        }
        .padding(20)
        .emptyCard(palette)
    }

    private func drawNode(
        _ context: GraphicsContext,
        at point: CGPoint,
        radius: CGFloat,
        filled: Bool,
        label: String,
        dashed: Bool = false
    ) {
        let circle = Path(ellipseIn: CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        if filled {
            context.fill(circle, with: .color(palette.accent))
            context.draw(
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.onAccent),
                at: point
            )
        } else {
            if dashed {
                context.stroke(
                    circle,
                    with: .color(palette.ink3),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
            } else {
                context.stroke(circle, with: .color(palette.accent), lineWidth: 1.5)
            }
            context.draw(
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(dashed ? palette.ink3 : palette.accent),
                at: point
            )
        }
    }
}

// MARK: - Forgetting curve

struct MacForgettingCurveChart: View {
    @Environment(\.emptyPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("遗忘曲线")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.ink)
                Text("Ebbinghaus, 1885")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
            }

            Canvas { context, size in
                let origin = CGPoint(x: 24, y: size.height - 24)
                let endX = size.width - 10

                var axis = Path()
                axis.move(to: CGPoint(x: origin.x, y: 20))
                axis.addLine(to: CGPoint(x: origin.x, y: origin.y))
                axis.addLine(to: CGPoint(x: endX, y: origin.y))
                context.stroke(axis, with: .color(palette.line2), lineWidth: 1)

                var decay = Path()
                decay.move(to: CGPoint(x: origin.x, y: 24))
                decay.addCurve(
                    to: CGPoint(x: endX, y: origin.y - 2),
                    control1: CGPoint(x: origin.x + 80, y: 90),
                    control2: CGPoint(x: origin.x + 200, y: origin.y - 4)
                )
                context.stroke(
                    decay,
                    with: .color(palette.ink3.opacity(0.65)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                )

                var retention = Path()
                retention.move(to: CGPoint(x: origin.x, y: 24))
                retention.addCurve(
                    to: CGPoint(x: origin.x + 56, y: 98),
                    control1: CGPoint(x: origin.x + 20, y: 70),
                    control2: CGPoint(x: origin.x + 38, y: 90)
                )
                retention.addLine(to: CGPoint(x: origin.x + 56, y: 24))
                retention.addCurve(
                    to: CGPoint(x: origin.x + 126, y: 78),
                    control1: CGPoint(x: origin.x + 80, y: 56),
                    control2: CGPoint(x: origin.x + 104, y: 70)
                )
                retention.addLine(to: CGPoint(x: origin.x + 126, y: 24))
                retention.addCurve(
                    to: CGPoint(x: origin.x + 201, y: 57),
                    control1: CGPoint(x: origin.x + 150, y: 44),
                    control2: CGPoint(x: origin.x + 178, y: 52)
                )
                retention.addLine(to: CGPoint(x: origin.x + 201, y: 24))
                retention.addCurve(
                    to: CGPoint(x: endX, y: 40),
                    control1: CGPoint(x: origin.x + 240, y: 34),
                    control2: CGPoint(x: origin.x + 270, y: 38)
                )
                context.stroke(retention, with: .color(palette.accent), lineWidth: 2)

                for (x, label) in [
                    (CGFloat(80), "复习① 1天"),
                    (CGFloat(150), "复习② 2天"),
                    (CGFloat(225), "复习③ 4天"),
                ] {
                    var tick = Path()
                    tick.move(to: CGPoint(x: origin.x + x, y: 20))
                    tick.addLine(to: CGPoint(x: origin.x + x, y: origin.y))
                    context.stroke(
                        tick,
                        with: .color(palette.accent.opacity(0.5)),
                        style: StrokeStyle(lineWidth: 0.75, dash: [2, 3])
                    )
                    context.draw(
                        Text(label)
                            .font(.system(size: 9.5))
                            .foregroundStyle(palette.ink2),
                        at: CGPoint(x: origin.x + x, y: origin.y + 14)
                    )
                }
            }
            .frame(height: 170)

            Text("不复习,一天后只剩约 33%(灰线)。每在临界点复习一次,曲线就被抬回 100%,且衰减更慢 — 间隔可以越拉越长。")
                .font(.system(size: 12))
                .lineSpacing(4)
                .foregroundStyle(palette.ink2)
                .padding(.top, 4)
                .overlay(alignment: .top) {
                    Rectangle().fill(palette.line).frame(height: 1)
                }
        }
        .padding(18)
        .emptyCard(palette)
    }
}

// MARK: - Ladder distribution

struct MacVocabLadderChart: View {
    let distribution: [(days: Int, count: Int)]

    @Environment(\.emptyPalette) private var palette

    private var maxCount: Int {
        max(distribution.map(\.count).max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("间隔阶梯 · \(distribution.reduce(0) { $0 + $1.count }) 词分布")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.ink)

            ForEach(distribution, id: \.days) { row in
                HStack(spacing: 10) {
                    Text("\(row.days) 天")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.ink3)
                        .frame(width: 38, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.accentSoft)
                            Capsule()
                                .fill(palette.accent)
                                .frame(width: geo.size.width * CGFloat(row.count) / CGFloat(maxCount))
                        }
                    }
                    .frame(height: 8)
                    Text(row.count > 0 ? "\(row.count) 词" : "—")
                        .font(.system(size: 11.5))
                        .foregroundStyle(row.count > 0 ? palette.ink2 : palette.ink3)
                        .frame(width: 36, alignment: .trailing)
                }
            }

            Text("记得 ✓ → 升一级(间隔×2) · 忘了 → 回到 1 天")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.ink3)
        }
        .padding(18)
        .emptyCard(palette)
    }
}

#endif