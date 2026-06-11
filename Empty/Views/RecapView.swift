//
//  RecapView.swift
//  Empty
//

import SwiftData
import SwiftUI

/// Result cache for one recap, keyed by the position it covered; the reader
/// keeps it across sheet openings and it invalidates by position mismatch.
nonisolated struct RecapCache: Equatable {
    var position: ReadingPosition
    var text: String
}

/// 前情回顾 — "previously on…" over only the chapters BEHIND the reader's
/// current position (spoiler-safe by construction), through whichever AI
/// provider is configured. Styled as a 朱批 sheet.
struct RecapView: View {
    let book: Book
    let position: ReadingPosition
    @Binding var cache: RecapCache?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext

    private enum Phase {
        case loading
        case nothingRead
        case failed(String)
        case ready(String)
    }

    @State private var phase: Phase = .loading
    @State private var routeNote: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.line).frame(height: 1)
            content
        }
        .background(palette.window)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .task { await generateIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZhuBadge(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("前情回顾")
                    .font(.system(size: 17, weight: .black, design: .serif))
                    .foregroundStyle(palette.ink)
                Text("《\(book.title)》· 只回顾你已读过的部分,不剧透")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
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

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 14) {
                ProgressView()
                Text("朱批落笔中 — 正在回顾你读过的章节…")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.ink3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .nothingRead:
            VStack(spacing: 10) {
                EnsoMark(size: 44)
                    .opacity(0.5)
                Text("还没有可回顾的内容")
                    .font(.system(size: 16, weight: .black, design: .serif))
                    .foregroundStyle(palette.ink)
                    .padding(.top, 6)
                Text("回顾只覆盖当前位置之前的章节 — 先往后读一点,再回来。")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.ink3)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.ink2)
                    .multilineTextAlignment(.center)
                Button("重试") {
                    Task { await generate() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.onAccent)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(palette.accent, in: Capsule())
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let recap):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ZhupiCallout(title: "朱批 · PREVIOUSLY ON") {
                        Text(recap)
                            .font(.system(size: 13.5))
                            .lineSpacing(6)
                            .foregroundStyle(palette.ink2)
                            .textSelection(.enabled)
                    }
                    if let routeNote {
                        Text(routeNote)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.ink3)
                    }
                }
                .padding(EdgeInsets(top: 16, leading: 20, bottom: 24, trailing: 20))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func generateIfNeeded() async {
        if let cache, cache.position == position {
            phase = .ready(cache.text)
            return
        }
        await generate()
    }

    private func generate() async {
        phase = .loading
        do {
            let resolution = AIProviderSettings.load().resolveUsableService()
            let service = resolution.service
            let builder = RecapBuilder(
                modelContext: modelContext,
                summarize: { text, focus in
                    try await service.summarize(text, focus: focus)
                }
            )
            let recap = try await builder.recap(for: book, before: position)
            routeNote = resolution.fellBack
                ? Self.fallbackNote(for: resolution.route)
                : nil
            cache = RecapCache(position: position, text: recap)
            phase = .ready(recap)
        } catch is CancellationError {
            // Sheet dismissed mid-flight; nothing to show.
        } catch AIServiceError.emptyInput {
            phase = .nothingRead
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private static func fallbackNote(for route: AIProviderMode) -> String {
        switch route {
        case .cloud:
            "本机模型不可用 — 这份回顾由云端模型生成。"
        case .onDevice:
            "云端服务不可用 — 这份回顾由本机模型生成。"
        }
    }
}
