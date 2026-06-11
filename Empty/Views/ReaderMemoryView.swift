//
//  ReaderMemoryView.swift
//  Empty
//
//  ReaderMemory management (handoff P2 spec): the master switch — off
//  means the AI is instantly amnesiac, entries untouched — and the
//  per-item list with delete. Memory only ever derives from what the
//  reader read and asked.
//

import SwiftData
import SwiftUI

struct ReaderMemoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext

    @AppStorage(ReaderMemory.enabledKey) private var memoryEnabled = true
    @Query(sort: \MemoryItem.updatedAt, order: .reverse) private var items: [MemoryItem]

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.line).frame(height: 1)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(memoryEnabled ? "记忆开启" : "记忆已关闭")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(memoryEnabled ? palette.ink : palette.ink3)
                        Text("关掉后朱立即「失忆」— 条目保留，只是 AI 看不见。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.ink3)
                    }
                    Spacer()
                    Toggle("", isOn: $memoryEnabled)
                        .labelsHidden()
                        .tint(palette.accent)
                }
                .padding(13)
                .emptyCard(palette, radius: 12)

                if items.isEmpty {
                    Text("还没有记忆条目 — 给高亮写批注、保存问答卡或链接卡，或在伴读里确认「记住」，都会成为记忆。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.ink3)
                        .padding(.top, 16)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(items) { item in
                                memoryRow(item)
                            }
                        }
                    }
                }

                Text("记忆只来自你读过和问过的内容，全部存在本机/你的 iCloud，逐条可删。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.ink3)
            }
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 16, trailing: 18))
        }
        .background(palette.window)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
        #if os(iOS)
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
        #endif
        .task {
            try? ReaderMemory(modelContext: modelContext).syncFromReaderData()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("⚲ 读者记忆")
                    .font(.system(size: 17, weight: .black, design: .serif))
                    .foregroundStyle(palette.ink)
                Text("\(items.count) 条 · 越读越懂你")
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
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 12, trailing: 14))
    }

    private func memoryRow(_ item: MemoryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(item.kind.title)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(palette.accentSoft, in: Capsule())
                if let source = item.sourceLabel {
                    Text(source)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.ink3)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    modelContext.delete(item)
                    try? modelContext.save()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.ink3)
                }
                .buttonStyle(.plain)
            }
            Text(item.title)
                .font(.system(size: 12.5, weight: .bold, design: .serif))
                .foregroundStyle(memoryEnabled ? palette.ink : palette.ink3)
                .lineLimit(1)
            Text(item.body)
                .font(.system(size: 11))
                .foregroundStyle(palette.ink3)
                .lineLimit(2)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card.opacity(memoryEnabled ? 0.7 : 0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
