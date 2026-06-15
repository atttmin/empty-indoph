//
//  ReaderInstructionPopover.swift
//  Empty
//
//  Shows the reader-supplied instruction files that customize the AI companion
//  for the current book.
//

import SwiftUI

struct ReaderInstructionPopover: View {
    let sources: [ReaderInstructionSource]

    @Environment(\.emptyPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("AI 伴读指令")
                    .font(.system(size: 15, weight: .black, design: .serif))
                    .foregroundStyle(palette.ink)
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
            Rectangle().fill(palette.line).frame(height: 1)

            if sources.isEmpty {
                emptyView
            } else {
                listView
            }
        }
        .background(palette.window)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("还没有发现指令文件")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.ink2)
            Text("可尝试创建以下任意文件:\n~/Empty/instructions.md\n书的文件夹/instructions.md\n书的文件夹/CLAUDE.md\n书的文件夹/AGENTS.md")
                .font(.system(size: 11))
                .foregroundStyle(palette.ink3)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(20)
    }

    private var listView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(sources.enumerated()), id: \.element.path) { _, source in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: source.path.lastPathComponent)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.accent)
                        Text(source.content)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.ink2)
                            .lineSpacing(2)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(palette.card)
                            .overlay(
                                Rectangle()
                                    .fill(palette.accentSoft2)
                                    .frame(width: 2),
                                alignment: .leading
                            )
                    }
                }
            }
            .padding(20)
        }
    }
}

private extension String {
    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }
}
