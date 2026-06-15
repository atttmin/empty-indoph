//
//  ReadingSettingsView.swift
//  Empty
//

import Foundation
import SwiftData
import SwiftUI

struct ReadingSettingsView: View {
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double
    @Binding var theme: ReaderTheme
    @Binding var font: ReaderFont
    @Binding var contentWidth: ReaderContentWidth
    @Binding var firstLineIndent: ReaderFirstLineIndent
    @Binding var paragraphSpacing: ReaderParagraphSpacingStyle
    @Binding var textAlignment: ReaderTextAlignmentStyle
    @Binding var chapterOpening: ReaderChapterOpeningStyle
    var pageTurn: Binding<ReaderPageTurn>? = nil
    /// When set, the panel offers 本书覆盖 — a per-book目标语言 kept on
    /// the book dimension (the global default lives in AI 状态 → 语言).
    var bookID: UUID? = nil

    @State private var bookTargetOverride: String?
    @State private var instructionSources: [ReaderInstructionSource] = []
    @State private var showingInstructionPopover = false

    @AppStorage("reader.traditional") private var traditionalChinese = false
    @AppStorage("reader.pdf.invert") private var pdfInvert = false
    @AppStorage("reader.pdf.twoup") private var pdfTwoUp = false
    @AppStorage("reader.pdf.autocrop") private var pdfAutoCrop = false
    @AppStorage("reader.vertical.mac") private var verticalText = false
    @Environment(\.modelContext) private var modelContext

    @Environment(\.dismiss) private var dismiss
    @Environment(\.emptyPalette) private var palette

    private var previewAppearance: ReaderAppearance {
        ReaderAppearance(
            theme: theme,
            font: font,
            contentWidth: contentWidth,
            firstLineIndent: firstLineIndent,
            paragraphSpacing: paragraphSpacing,
            textAlignment: textAlignment,
            chapterOpening: chapterOpening
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("阅读设置")
                        .font(.system(size: 17, weight: .black, design: .serif))
                        .foregroundStyle(palette.ink)
                    Text(
                        "字号 \(Int(fontSize)) · 行距 \(lineSpacing, specifier: "%.1f") · \(contentWidth.title)版心"
                    )
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
            Rectangle().fill(palette.line).frame(height: 1)

            VStack(alignment: .leading, spacing: 16) {
                settingRow(label: "纸页预设") {
                    HStack(spacing: 8) {
                        selectionChip("纸页模式", isActive: previewAppearance == .paperPreset) {
                            applyPaperPreset()
                        }
                        secondaryChip("恢复默认") {
                            restoreDefaults()
                        }
                    }
                }
                settingRow(label: "字号") {
                    HStack(spacing: 12) {
                        Text("A").font(.system(size: 11, design: .serif))
                        Slider(value: $fontSize, in: 12 ... 28, step: 1)
                            .tint(palette.accent)
                        Text("A").font(.system(size: 20, design: .serif))
                    }
                    .foregroundStyle(palette.ink2)
                }
                settingRow(label: "行距") {
                    HStack(spacing: 12) {
                        Image(systemName: "text.alignleft").font(.system(size: 10))
                        Slider(value: $lineSpacing, in: 1.2 ... 2.2, step: 0.1)
                            .tint(palette.accent)
                        Image(systemName: "text.alignleft").font(.system(size: 16))
                    }
                    .foregroundStyle(palette.ink2)
                }
                settingRow(label: "字体") {
                    optionScroll {
                        ForEach(ReaderFont.allCases, id: \.self) { choice in
                            selectionChip(choice.title, isActive: font == choice) {
                                font = choice
                            }
                        }
                    }
                }
                settingRow(label: "主题") {
                    HStack(spacing: 10) {
                        ForEach(ReaderTheme.allCases, id: \.self) { choice in
                            themeSwatch(choice)
                        }
                    }
                }
                settingRow(label: "版心") {
                    optionScroll {
                        ForEach(ReaderContentWidth.allCases, id: \.self) { choice in
                            selectionChip(choice.title, isActive: contentWidth == choice) {
                                contentWidth = choice
                            }
                        }
                    }
                }
                settingRow(label: "首行") {
                    optionScroll {
                        ForEach(ReaderFirstLineIndent.allCases, id: \.self) { choice in
                            selectionChip(choice.title, isActive: firstLineIndent == choice) {
                                firstLineIndent = choice
                            }
                        }
                    }
                }
                settingRow(label: "段落") {
                    optionScroll {
                        ForEach(ReaderParagraphSpacingStyle.allCases, id: \.self) { choice in
                            selectionChip(choice.title, isActive: paragraphSpacing == choice) {
                                paragraphSpacing = choice
                            }
                        }
                    }
                }
                settingRow(label: "对齐") {
                    optionScroll {
                        ForEach(ReaderTextAlignmentStyle.allCases, id: \.self) { choice in
                            selectionChip(choice.title, isActive: textAlignment == choice) {
                                textAlignment = choice
                            }
                        }
                    }
                }
                settingRow(label: "章首") {
                    optionScroll {
                        ForEach(ReaderChapterOpeningStyle.allCases, id: \.self) { choice in
                            selectionChip(choice.title, isActive: chapterOpening == choice) {
                                chapterOpening = choice
                            }
                        }
                    }
                }
                if let pageTurn {
                    settingRow(label: "翻页方式") {
                        Picker("", selection: pageTurn) {
                            ForEach(ReaderPageTurn.allCases, id: \.self) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                settingRow(label: "繁简 · PDF") {
                    optionScroll {
                        optionChip("繁体显示", isOn: $traditionalChinese)
                        optionChip("PDF 夜间反色", isOn: $pdfInvert)
                        #if os(macOS)
                            optionChip("PDF 双页", isOn: $pdfTwoUp)
                            optionChip("PDF 裁边", isOn: $pdfAutoCrop)
                            optionChip("竖排（翻页·实验）", isOn: $verticalText)
                        #else
                            optionChip("PDF 裁边", isOn: $pdfAutoCrop)
                        #endif
                    }
                }
                if bookID != nil {
                    settingRow(label: "本书语言") {
                        VStack(alignment: .leading, spacing: 6) {
                            optionScroll {
                                bookLanguageChip("跟随全局", target: nil)
                                ForEach(LanguageSettings.targetOptions, id: \.id) { option in
                                    bookLanguageChip(option.native, target: option.id)
                                }
                            }
                            Text("只改这一本的目标语言；全局默认在 AI 状态 → 语言。")
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.ink3)
                        }
                    }
                }
                if bookID != nil {
                    settingRow(label: "AI 指令") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                if instructionSources.isEmpty {
                                    Text("未找到 instructions.md / CLAUDE.md / AGENTS.md")
                                        .font(.system(size: 11))
                                        .foregroundStyle(palette.ink3)
                                } else {
                                    Text("已发现 \(instructionSources.count) 条指令")
                                        .font(.system(size: 11))
                                        .foregroundStyle(palette.ink)
                                }
                                Spacer()
                                Button {
                                    showingInstructionPopover = true
                                } label: {
                                    Text("查看")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(palette.accent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(palette.accentSoft, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .popover(isPresented: $showingInstructionPopover) {
                                    ReaderInstructionPopover(sources: instructionSources)
                                        .frame(minWidth: 320, minHeight: 240)
                                }
                            }
                            Text("在书的文件夹或 ~/Empty/instructions.md 放置 Markdown 文件，即可定制伴读语气与规则。")
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.ink3)
                        }
                    }
                }
                previewCard
            }
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 20, trailing: 20))

            Spacer(minLength: 0)
        }
        .background(palette.window)
        #if os(iOS)
            .presentationDetents([.large, .medium])
            .presentationDragIndicator(.visible)
        #endif
            .onAppear {
                if let bookID {
                    bookTargetOverride = LanguageSettings.bookOverride(for: bookID)?.target
                    loadInstructionSources()
                }
            }
    }

    private func loadInstructionSources() {
        guard let bookID else {
            instructionSources = []
            return
        }
        guard let book = try? modelContext.fetch(
            FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })
        ).first else {
            instructionSources = []
            return
        }
        let fileURL = book.fileRelativePath.map { BookFileStore.default.url(forRelativePath: $0) }
        instructionSources = ReaderInstructionService().loadInstructions(bookFileURL: fileURL)
    }

    private var previewCard: some View {
        let sampleSize = fontSize * 0.82
        let sampleSpacing = previewAppearance.blockPadding(fontSize: sampleSize)
        let pageFill = previewAppearance.theme.pageFill(baseIsDark: palette.isDark)
        let pageRule = previewAppearance.theme.pageRule(baseIsDark: palette.isDark)
        return settingRow(label: "预览") {
            VStack(alignment: .leading, spacing: sampleSpacing) {
                Text("第一章 · 森林")
                    .font(previewFont(size: sampleSize + 4, bold: true))
                    .foregroundStyle(palette.ink)
                Text(previewParagraph(
                    "我走进树林，是因为我想有意识地生活，只面对生活的基本事实。",
                    opening: true
                ))
                .font(previewFont(size: sampleSize))
                .lineSpacing(sampleSize * max(0.2, lineSpacing - 1))
                .foregroundStyle(palette.ink)
                Text(previewParagraph(
                    "纸页模式收紧了版心、补上了首行缩进，也让章节开头更像一本书，而不是一块会滚动的屏幕。",
                    opening: false
                ))
                .font(previewFont(size: sampleSize))
                .lineSpacing(sampleSize * max(0.2, lineSpacing - 1))
                .foregroundStyle(palette.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(pageFill, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(pageRule, lineWidth: 1)
            )
        }
    }

    private func previewParagraph(_ text: String, opening: Bool) -> String {
        if opening, chapterOpening != .plain {
            return text
        }
        let prefix: String
        switch firstLineIndent {
        case .none:
            prefix = ""
        case .modest:
            prefix = "　"
        case .classic:
            prefix = "　　"
        }
        return prefix + text
    }

    private func previewFont(size: Double, bold: Bool = false) -> Font {
        let resolved = previewAppearance.openingFontSize(base: size, isOpeningParagraph: bold)
        if let family = font.familyName {
            return .custom(family, size: resolved).weight(bold ? .bold : .regular)
        }
        let weight: Font.Weight = bold ? .bold : .regular
        if font.usesSerifDesign {
            return .system(size: resolved, weight: weight, design: .serif)
        }
        return .system(size: resolved, weight: weight, design: .default)
    }

    private func applyPaperPreset() {
        let preset = ReaderAppearance.paperPreset
        theme = preset.theme
        font = preset.font
        contentWidth = preset.contentWidth
        firstLineIndent = preset.firstLineIndent
        paragraphSpacing = preset.paragraphSpacing
        textAlignment = preset.textAlignment
        chapterOpening = preset.chapterOpening
        fontSize = 19
        lineSpacing = 1.75
        pageTurn?.wrappedValue = .paged
    }

    private func restoreDefaults() {
        theme = .paper
        font = .serif
        contentWidth = .medium
        firstLineIndent = .none
        paragraphSpacing = .book
        textAlignment = .leading
        chapterOpening = .plain
        fontSize = 18
        lineSpacing = 1.6
    }

    private func bookLanguageChip(_ title: String, target: String?) -> some View {
        let isActive = bookTargetOverride == target
        return Button {
            guard let bookID else { return }
            bookTargetOverride = target
            var override = LanguageSettings.bookOverride(for: bookID)
                ?? LanguageSettings.BookOverride()
            override.target = target
            LanguageSettings.setBookOverride(override, for: bookID)
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: isActive ? .bold : .regular))
                .foregroundStyle(isActive ? palette.onAccent : palette.ink2)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(isActive ? palette.accent : palette.side, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func optionChip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: isOn.wrappedValue ? .bold : .regular))
                .foregroundStyle(isOn.wrappedValue ? palette.onAccent : palette.ink2)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    isOn.wrappedValue ? palette.accent : palette.side,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func selectionChip(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: isActive ? .bold : .regular))
                .foregroundStyle(isActive ? palette.onAccent : palette.ink2)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? palette.accent : palette.side, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        isActive ? palette.accent : palette.line2,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private func secondaryChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.ink2)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(palette.side, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func optionScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                content()
            }
        }
    }

    private func themeSwatch(_ choice: ReaderTheme) -> some View {
        Button {
            theme = choice
        } label: {
            VStack(spacing: 5) {
                Circle()
                    .fill(choice.swatch)
                    .frame(width: 34, height: 34)
                    .overlay(
                        Circle().strokeBorder(
                            theme == choice ? palette.accent : palette.line2,
                            lineWidth: theme == choice ? 2 : 1
                        )
                    )
                    .overlay {
                        if theme == choice {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(
                                    choice.isDarkCanvas(baseIsDark: false)
                                        ? Color(hex: 0xEDE5D4) : Color(hex: 0x2A2419)
                                )
                        }
                    }
                Text(choice.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme == choice ? palette.accent : palette.ink3)
            }
        }
        .buttonStyle(.plain)
    }

    private func settingRow(
        label: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .kerning(1.6)
                .foregroundStyle(palette.ink3)
            content()
        }
    }
}
