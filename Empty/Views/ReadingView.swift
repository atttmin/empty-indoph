//
//  ReadingView.swift
//  Empty
//

import SwiftData
import SwiftUI
import WebKit

/// Where to land inside a chapter after navigating to it.
nonisolated enum ChapterLanding {
    case start
    case end
}

/// Direction of a page turn that ran past the chapter's edge.
nonisolated enum PageTurnDirection {
    case forward
    case backward
}

/// A live text selection reported by the chapter web view.
nonisolated struct ReaderSelection: Equatable {
    var text: String
    var prefix: String
    var suffix: String
}

/// What the in-page painter needs to mark one stored highlight.
nonisolated struct HighlightPaint: Codable, Equatable {
    var id: String
    var text: String
}

/// Reader text mode — the prototype's 原文 / 双语对照 / 导读 toggle,
/// expressed as the token pushed into the chapter page's script.
nonisolated enum InlineNoteKind: String {
    case none
    case bilingual = "bi"
    case companion = "comp"
}

/// One in-flow AI note (a paragraph's translation or 导读 paraphrase),
/// keyed by the paragraph's index in the chapter DOM.
nonisolated struct InlineNotePaint: Codable, Equatable {
    var idx: Int
    var text: String
}

/// A paragraph on the currently visible page, reported by the web view so
/// inline-note modes can translate exactly what the reader is looking at.
nonisolated struct ReaderParagraph: Equatable {
    var idx: Int
    var text: String
}

/// WebView-based EPUB reader with CSS-column pagination: one column per
/// page, horizontal paging, spoiler-free chapter crossing at the edges.
/// Reading position and sessions persist through the SwiftData `Book`.
struct ReadingView: View {
    let book: Book
    /// Tab-hosted on iOS: back returns to 书库 instead of popping.
    var onExit: (() -> Void)?
    /// 追问 hand-off to the 朱 companion sheet (question, live position).
    var onAskCompanion: ((String, ReadingPosition) -> Void)?
    /// Mirrors the tap-to-hide chrome so the shell can hide its tab bar.
    var onControlsChange: ((Bool) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext

    @State private var epubBook: EPUBBook?
    @State private var pdfDocumentURL: URL?
    @State private var sectionCount: Int = 0
    @State private var sectionTitles: [String] = []
    @State private var currentChapterIndex: Int
    @State private var currentUTF16Offset: Int
    @State private var chapterLanding: ChapterLanding = .start
    @State private var session: ReadingSession?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showChapterList = false
    @State private var showSettings = false
    @State private var showRecap = false
    @State private var recapCache: RecapCache?
    @State private var pendingSelection: ReaderSelection?
    @State private var chapterHighlights: [HighlightPaint] = []
    @State private var showHighlights = false
    @State private var saveErrorMessage: String?
    @State private var showControls = true
    @State private var fontSize: Double = 18
    @State private var lineSpacing: Double = 1.6
    @State private var isBilingual = false
    @State private var inlineNotes: [InlineNotePaint] = []
    @State private var inlineCache: [Int: String] = [:]
    @State private var inlineInFlight: Set<Int> = []
    @State private var marginNote: String?
    @State private var marginSubject: String?
    @State private var isSelectionWorking = false
    @State private var thoughtLink: ThoughtLink?
    @State private var thoughtLinkExpanded = false
    @State private var thoughtLinkSaved = false
    @State private var chapterPageInfo: (page: Int, count: Int)?
    @StateObject private var aloud = ReadingAloud()

    init(
        book: Book,
        onExit: (() -> Void)? = nil,
        onAskCompanion: ((String, ReadingPosition) -> Void)? = nil,
        onControlsChange: ((Bool) -> Void)? = nil
    ) {
        self.book = book
        self.onExit = onExit
        self.onAskCompanion = onAskCompanion
        self.onControlsChange = onControlsChange
        _currentChapterIndex = State(initialValue: book.position.chapterIndex)
        _currentUTF16Offset = State(initialValue: book.position.utf16Offset)
    }

    private var currentReadingPosition: ReadingPosition {
        ReadingPosition(
            chapterIndex: currentChapterIndex,
            utf16Offset: currentUTF16Offset
        )
    }

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            if isLoading {
                ProgressView("正在打开…")
                    .foregroundStyle(palette.ink3)
            } else if let error = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("无法打开这本书")
                        .font(.system(size: 15, weight: .bold, design: .serif))
                        .foregroundStyle(palette.ink)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(palette.ink3)
                        .multilineTextAlignment(.center)
                    Button("返回") { exitReader() }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accent)
                }
                .padding()
            } else if let epubBook {
                readerContent(epubBook)
            } else if pdfDocumentURL != nil {
                pdfReaderContent
            }
        }
        .onAppear(perform: loadBook)
        .onDisappear {
            aloud.stop()
            saveProgress()
        }
        .onChange(of: showControls) { _, visible in
            onControlsChange?(visible)
        }
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        #if os(iOS)
        .statusBarHidden(!showControls)
        #endif
    }

    private func exitReader() {
        saveProgress()
        if let onExit {
            onExit()
        } else {
            dismiss()
        }
    }

    @ViewBuilder
    private func readerContent(_ book: EPUBBook) -> some View {
        VStack(spacing: 0) {
            if showControls {
                readerTopBar(
                    title: book.metadata.title,
                    subtitle: chapterSubtitle(sectionLabel: "章"),
                    showsBilingual: true
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            ZStack(alignment: .bottom) {
                ChapterWebView(
                    chapter: book.chapters[currentChapterIndex],
                    basePath: book.basePath,
                    fontSize: fontSize,
                    isDarkMode: palette.isDark,
                    lineSpacing: lineSpacing,
                    landing: chapterLanding,
                    resumeUTF16Offset: resumeUTF16Offset,
                    chapterPlainText: currentChapterPlainText(),
                    highlights: chapterHighlights,
                    inlineMode: isBilingual ? .bilingual : .none,
                    inlineNotes: inlineNotes,
                    onTap: { withAnimation(.easeInOut(duration: 0.25)) { showControls.toggle() } },
                    onChapterBoundary: { direction in
                        crossChapterBoundary(direction, chapterCount: book.chapters.count)
                    },
                    onSelectionChange: { handleSelectionChange($0) },
                    onPositionChange: { updateUTF16Offset(domPrefix: $0) },
                    onVisibleParagraphs: { handleVisibleParagraphs($0) },
                    onPageInfo: { page, count in
                        chapterPageInfo = (page: page, count: count)
                    }
                )

                readerOverlay
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .sheet(isPresented: $showChapterList) {
            ChapterListView(
                titles: sectionTitles,
                listTitle: "Chapters",
                currentIndex: currentChapterIndex
            ) { index in
                currentChapterIndex = index
                currentUTF16Offset = 0
                chapterLanding = .start
                showChapterList = false
            }
            #if os(macOS)
            .frame(minWidth: 380, minHeight: 460)
            #endif
        }
        .sheet(isPresented: $showSettings) {
            ReadingSettingsView(
                fontSize: $fontSize,
                lineSpacing: $lineSpacing
            )
            #if os(iOS)
            .presentationDetents([.medium])
            #else
            .frame(minWidth: 320, minHeight: 280)
            #endif
        }
        .sheet(isPresented: $showRecap) {
            RecapView(
                book: self.book,
                position: currentReadingPosition,
                cache: $recapCache
            )
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 480)
            #endif
        }
        .sheet(isPresented: $showHighlights) {
            HighlightsListView(book: self.book) { chapterIndex in
                currentChapterIndex = chapterIndex
                currentUTF16Offset = 0
                chapterLanding = .start
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 460)
            #endif
        }
        .onChange(of: currentChapterIndex) { _, _ in
            resetChapterArtifacts()
            refreshChapterHighlights()
        }
        .onChange(of: isBilingual) { _, _ in
            // The chapter page clears and re-requests notes; cached
            // translations rejoin instantly.
            inlineNotes = []
        }
        .onChange(of: showHighlights) { _, isShowing in
            if !isShowing { refreshChapterHighlights() }
        }
        .alert(
            "Couldn't Save Highlight",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private var pdfReaderContent: some View {
        if let documentURL = pdfDocumentURL {
            VStack(spacing: 0) {
                if showControls {
                    readerTopBar(
                        title: book.title,
                        subtitle: chapterSubtitle(sectionLabel: "页"),
                        showsBilingual: false
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                ZStack(alignment: .bottom) {
                    PDFReaderView(
                        documentURL: documentURL,
                        pageIndex: $currentChapterIndex,
                        highlights: chapterHighlights,
                        onPageChange: syncPageProgress,
                        onSelectionChange: { handleSelectionChange($0) }
                    )
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) { showControls.toggle() }
                    }

                    readerOverlay
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showControls)
            .sheet(isPresented: $showChapterList) {
                ChapterListView(
                    titles: sectionTitles,
                    listTitle: "Pages",
                    currentIndex: currentChapterIndex
                ) { index in
                    currentChapterIndex = index
                    syncPageProgress(at: index)
                    showChapterList = false
                }
                #if os(macOS)
                .frame(minWidth: 380, minHeight: 460)
                #endif
            }
            .sheet(isPresented: $showRecap) {
                RecapView(
                    book: self.book,
                    position: currentReadingPosition,
                    cache: $recapCache
                )
                #if os(macOS)
                .frame(minWidth: 440, minHeight: 480)
                #endif
            }
            .sheet(isPresented: $showHighlights) {
                HighlightsListView(book: self.book) { chapterIndex in
                    currentChapterIndex = chapterIndex
                    syncPageProgress(at: chapterIndex)
                }
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 460)
                #endif
            }
            .onChange(of: currentChapterIndex) { _, newIndex in
                resetChapterArtifacts()
                syncPageProgress(at: newIndex)
            }
            .onChange(of: showHighlights) { _, isShowing in
                if !isShowing { refreshChapterHighlights() }
            }
        }
    }

    private var currentSectionTitle: String {
        guard currentChapterIndex >= 0, currentChapterIndex < sectionTitles.count else {
            return "Page \(currentChapterIndex + 1)"
        }
        return sectionTitles[currentChapterIndex]
    }

    private func syncPageProgress(at index: Int) {
        currentChapterIndex = index
        if let plainText = currentChapterPlainText() {
            currentUTF16Offset = plainText.utf16.count
        } else {
            currentUTF16Offset = 0
        }
        refreshChapterHighlights()
    }

    // MARK: 朱批 chrome (02 iOS prototype)

    /// Compact top bar: ‹ back, centered title + position line, the 「译」
    /// bilingual toggle (EPUB), the aloud toggle, and an overflow menu for
    /// 目录 / 高亮 / 前情回顾 / 阅读设置.
    private func readerTopBar(
        title: String,
        subtitle: String,
        showsBilingual: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Button {
                exitReader()
            } label: {
                Text("‹")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .serif))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if showsBilingual {
                Button {
                    isBilingual.toggle()
                } label: {
                    Text("译")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isBilingual ? palette.onAccent : palette.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(isBilingual ? palette.accent : .clear, in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(
                                isBilingual ? palette.accent : palette.accentSoft2,
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(.plain)
            }

            Button {
                toggleAloud()
            } label: {
                Text(aloud.isSpeaking ? "❚❚" : "▷ 朗读")
                    .font(.system(size: 12))
                    .foregroundStyle(aloud.isSpeaking ? palette.accent : palette.ink3)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("目录", systemImage: "list.bullet") { showChapterList = true }
                Button("高亮", systemImage: "highlighter") { showHighlights = true }
                Button("前情回顾", systemImage: "sparkles") { showRecap = true }
                Button("阅读设置", systemImage: "textformat.size") { showSettings = true }
            } label: {
                Text("⋯")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.ink3)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    /// "第 N/M 章 · X%[ · 剩 Y 页]" — the prototype's position line.
    private func chapterSubtitle(sectionLabel: String) -> String {
        let chapterCount = Double(max(sectionCount, 1))
        let chapterLength = Double(currentChapterPlainText()?.utf16.count ?? 1)
        let intraChapter = chapterLength > 0
            ? Double(currentUTF16Offset) / chapterLength
            : 0
        let progress = min(1, (Double(currentChapterIndex) + intraChapter) / chapterCount)
        var parts = [
            "第 \(currentChapterIndex + 1)/\(sectionCount) \(sectionLabel)",
            "\(Int(progress * 100))%",
        ]
        if let info = chapterPageInfo, info.count > 1 {
            parts.append("剩 \(max(info.count - info.page - 1, 0)) 页")
        }
        return parts.joined(separator: " · ")
    }

    /// Floating layers over the reading surface: margin note, thought
    /// link, selection actions, and the aloud bar. Shared by EPUB and PDF.
    private var readerOverlay: some View {
        VStack(spacing: 10) {
            if let marginNote {
                ZhupiCallout(title: "朱批 · 划词解释") {
                    Text(marginNote)
                        .font(.system(size: 12.5))
                        .lineSpacing(5)
                        .foregroundStyle(palette.ink2)
                    Button("继续追问 ↩") {
                        askCompanion(about: marginSubject ?? marginNote)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(palette.accent, lineWidth: 1))
                    .padding(.top, 8)
                }
                .padding(.horizontal, 18)
            }

            if let thoughtLink {
                thoughtLinkCard(thoughtLink)
                    .padding(.horizontal, 18)
            }

            if pendingSelection != nil {
                selectionBar
            }

            if aloud.isSpeaking || !aloud.currentSnippet.isEmpty {
                aloudBar
            }
        }
        .padding(.bottom, 76)
    }

    /// 解释 / 翻译 / 追问 / 高亮 on the prototype's dark pill.
    private var selectionBar: some View {
        HStack(spacing: 2) {
            selectionButton("解释") { runSelectionAction(.explain) }
            selectionButton("翻译") { runSelectionAction(.translate) }
            Button {
                if let selection = pendingSelection {
                    askCompanion(about: selection.text)
                }
            } label: {
                Text("追问 ↩")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            selectionButton("高亮") { saveHighlight() }
            if isSelectionWorking {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 6)
            }
        }
        .padding(5)
        .background(palette.ink, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 7)
    }

    private func selectionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(palette.window)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// ⟲ 思维链接 chip and the vertical cross-book card.
    private func thoughtLinkCard(_ link: ThoughtLink) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                thoughtLinkExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Text("⟲ 思维链接 · 与你的一条高亮相连")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(thoughtLinkExpanded ? "⌃" : "⌄")
                }
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(palette.accentSoft, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.accentSoft2, lineWidth: 1))
            }
            .buttonStyle(.plain)

            if thoughtLinkExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    linkPane("现在 · \(link.currentSource)", text: link.currentText, italic: true)
                    Text("⟷")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.accent)
                        .frame(maxWidth: .infinity)
                    linkPane("你的高亮 · \(link.relatedSource)", text: link.relatedText, italic: false)
                    Text(link.explanation)
                        .font(.system(size: 12))
                        .lineSpacing(4.5)
                        .foregroundStyle(palette.ink2)
                        .padding(.top, 2)
                    HStack(spacing: 7) {
                        Button("就此追问 ↩") {
                            askCompanion(about: link.explanation)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.onAccent)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(palette.accent, in: Capsule())

                        Button(thoughtLinkSaved ? "✓ 已存为链接卡" : "存为链接卡") {
                            saveThoughtLinkCard()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(thoughtLinkSaved ? palette.accent : palette.ink2)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
                        .disabled(thoughtLinkSaved)
                    }
                }
                .padding(14)
                .emptyCard(palette, radius: 14)
            }
        }
    }

    private func linkPane(_ label: String, text: String, italic: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(palette.ink3)
            Text(text)
                .font(.system(size: 12, design: .serif))
                .italic(italic)
                .lineSpacing(4)
                .foregroundStyle(palette.ink)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(palette.line, lineWidth: 1)
        )
    }

    /// Floating 朗读条, above the tab bar like the prototype.
    private var aloudBar: some View {
        HStack(spacing: 11) {
            Button {
                aloud.togglePause()
            } label: {
                Text(aloud.isSpeaking ? "❚❚" : "▶")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.onAccent)
                    .frame(width: 26, height: 26)
                    .background(palette.accent, in: Circle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(palette.accent)
                        .frame(width: 2.5, height: CGFloat([7, 13, 9, 15, 6][index]))
                        .opacity(index.isMultiple(of: 2) ? 0.95 : 0.65)
                }
            }

            Text("正在朗读 · 1.0×")
                .font(.system(size: 11.5))
        }
        .foregroundStyle(palette.window)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(palette.ink, in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }

    private var backgroundColor: Color {
        palette.window
    }

    // MARK: Selection actions

    private enum SelectionAction {
        case explain, translate
    }

    private func handleSelectionChange(_ selection: ReaderSelection?) {
        pendingSelection = selection
        marginNote = nil
        if let selection {
            Task { await detectThoughtLink(for: selection.text) }
        }
    }

    private func runSelectionAction(_ action: SelectionAction) {
        guard let selection = pendingSelection, !isSelectionWorking else { return }
        isSelectionWorking = true
        Task {
            defer { isSelectionWorking = false }
            do {
                let resolution = AIProviderSettings.load().resolveUsableService()
                let question = action == .explain
                    ? "Explain this passage to a thoughtful reader. Reply in Chinese with etymology or nuance when helpful."
                    : "Translate this passage into natural Chinese, preserving literary tone."
                let answer = try await resolution.service.answer(
                    question: question,
                    groundedIn: [GroundedPassage(id: 0, text: selection.text)]
                )
                marginNote = answer.text
                marginSubject = selection.text
            } catch {
                marginNote = "出错了:\(error.localizedDescription)"
            }
        }
    }

    private func askCompanion(about text: String) {
        guard let onAskCompanion else { return }
        pendingSelection = nil
        onAskCompanion(
            "关于「\(text.prefix(60))」",
            currentReadingPosition
        )
    }

    private func detectThoughtLink(for passage: String) async {
        do {
            if var link = try ThoughtLinkFinder(modelContext: modelContext).findLink(
                passage: passage,
                book: book,
                chapterIndex: currentChapterIndex
            ) {
                if let explained = try? await ThoughtLinkFinder(modelContext: modelContext)
                    .explainLink(link) {
                    link.explanation = explained
                }
                thoughtLink = link
                thoughtLinkExpanded = false
                thoughtLinkSaved = false
            }
        } catch {
            thoughtLink = nil
        }
    }

    /// 思维链接 → 链接卡 in the cards screen.
    private func saveThoughtLinkCard() {
        guard let thoughtLink, !thoughtLinkSaved else { return }
        let card = StudyCardEntry(
            question: "「\(thoughtLink.currentText.prefix(60))」 ⟷ 「\(thoughtLink.relatedText.prefix(60))」",
            answer: thoughtLink.explanation,
            source: "\(thoughtLink.currentSource) ⟷ \(thoughtLink.relatedSource)",
            kind: .link
        )
        card.book = book
        modelContext.insert(card)
        try? modelContext.save()
        thoughtLinkSaved = true
    }

    private func toggleAloud() {
        if aloud.isSpeaking {
            aloud.stop()
            return
        }
        if let text = pendingSelection?.text ?? currentChapterPlainText() {
            let lang = book.languageTag?.hasPrefix("zh") == true ? "zh-CN" : "en-US"
            aloud.speak(String(text.prefix(800)), language: lang)
        }
    }

    private func resetChapterArtifacts() {
        pendingSelection = nil
        marginNote = nil
        marginSubject = nil
        thoughtLink = nil
        thoughtLinkExpanded = false
        thoughtLinkSaved = false
        chapterPageInfo = nil
        inlineNotes = []
    }

    // MARK: 双语对照 (译)

    /// Translates the visible paragraphs the chapter page reports, in
    /// reading order, replaying cached ones instantly.
    private func handleVisibleParagraphs(_ paragraphs: [ReaderParagraph]) {
        guard isBilingual else { return }
        let chapter = currentChapterIndex
        var missing: [ReaderParagraph] = []
        for paragraph in paragraphs {
            let key = inlineNoteKey(chapter: chapter, idx: paragraph.idx)
            if let cached = inlineCache[key] {
                if !cached.isEmpty,
                   !inlineNotes.contains(where: { $0.idx == paragraph.idx }) {
                    inlineNotes.append(InlineNotePaint(idx: paragraph.idx, text: cached))
                }
            } else if !inlineInFlight.contains(key) {
                inlineInFlight.insert(key)
                missing.append(paragraph)
            }
        }
        guard !missing.isEmpty else { return }
        Task { await translateParagraphs(missing, chapter: chapter) }
    }

    private func inlineNoteKey(chapter: Int, idx: Int) -> Int {
        chapter << 16 | idx
    }

    private func translateParagraphs(_ paragraphs: [ReaderParagraph], chapter: Int) async {
        let resolution = AIProviderSettings.load().resolveUsableService()
        guard resolution.service.availability.isAvailable else {
            for paragraph in paragraphs {
                inlineInFlight.remove(inlineNoteKey(chapter: chapter, idx: paragraph.idx))
            }
            return
        }
        for paragraph in paragraphs {
            let key = inlineNoteKey(chapter: chapter, idx: paragraph.idx)
            defer { inlineInFlight.remove(key) }
            // Reader moved on — skip the model call, leave it uncached.
            guard isBilingual, currentChapterIndex == chapter else { continue }
            do {
                let answer = try await resolution.service.answer(
                    question: "Translate this paragraph into natural, literary Simplified Chinese. Output only the translation, nothing else.",
                    groundedIn: [GroundedPassage(id: 0, text: paragraph.text)]
                )
                let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                inlineCache[key] = text
                if isBilingual, currentChapterIndex == chapter, !text.isEmpty {
                    inlineNotes.append(InlineNotePaint(idx: paragraph.idx, text: text))
                }
            } catch {
                // Cache the failure so a flaky provider isn't re-polled on
                // every page turn.
                inlineCache[key] = ""
            }
        }
    }

    private var resumeUTF16Offset: Int {
        chapterLanding == .start ? currentUTF16Offset : 0
    }

    private func crossChapterBoundary(_ direction: PageTurnDirection, chapterCount: Int) {
        switch direction {
        case .forward:
            guard currentChapterIndex < chapterCount - 1 else { return }
            currentChapterIndex += 1
            currentUTF16Offset = 0
            chapterLanding = .start
        case .backward:
            guard currentChapterIndex > 0 else { return }
            currentChapterIndex -= 1
            currentUTF16Offset = 0
            chapterLanding = .end
        }
    }

    private func currentChapterPlainText() -> String? {
        let bookID = book.id
        let index = currentChapterIndex
        return try? modelContext.fetch(
            FetchDescriptor<Chapter>(
                predicate: #Predicate { $0.bookID == bookID && $0.index == index }
            )
        ).first?.text
    }

    private func updateUTF16Offset(domPrefix: String) {
        guard let plainText = currentChapterPlainText() else { return }
        let offset = PlainTextSearch.utf16Offset(
            afterNormalizedPrefix: domPrefix,
            in: plainText
        )
        currentUTF16Offset = min(offset, plainText.utf16.count)
    }

    private func loadBook() {
        Task {
            do {
                guard let relativePath = book.fileRelativePath else {
                    throw EPUBParser.ParseError.fileNotFound
                }
                let fileStore = try BookFileStore.makeDefault()
                let fileURL = fileStore.url(forRelativePath: relativePath)

                switch book.format {
                case .epub:
                    let parsed = try EPUBParser().parseBook(
                        at: fileURL,
                        unzipDirectory: fileStore.unzipDirectory(forBookID: book.id)
                    )
                    guard !parsed.chapters.isEmpty else {
                        throw EPUBParser.ParseError.parsingFailed("No readable chapters found.")
                    }
                    epubBook = parsed
                    sectionCount = parsed.chapters.count
                    sectionTitles = parsed.chapters.map(\.title)
                case .pdf:
                    sectionTitles = try Library.ensurePDFChapters(
                        for: book,
                        at: fileURL,
                        in: modelContext
                    )
                    sectionCount = sectionTitles.count
                    pdfDocumentURL = fileURL
                }

                if currentChapterIndex >= sectionCount {
                    currentChapterIndex = 0
                }
                if book.format == .pdf {
                    syncPageProgress(at: currentChapterIndex)
                }
                isLoading = false
                startSession()
            } catch {
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func startSession() {
        let newSession = ReadingSession(startPosition: book.position)
        modelContext.insert(newSession)
        newSession.book = book
        session = newSession
        book.lastOpenedAt = Date()
        refreshChapterHighlights()
    }

    private func saveProgress() {
        guard epubBook != nil || pdfDocumentURL != nil else { return }
        let position = currentReadingPosition
        book.position = position
        let chapterCount = Double(max(sectionCount, 1))
        let chapterLength = Double(
            currentChapterPlainText()?.utf16.count ?? 1
        )
        let intraChapter = chapterLength > 0
            ? Double(currentUTF16Offset) / chapterLength
            : 0
        book.progressFraction = min(
            1,
            (Double(currentChapterIndex) + intraChapter) / chapterCount
        )
        if let session {
            session.endedAt = Date()
            session.endPosition = position
        }
        // Best effort on the way out; SwiftData autosave covers the rest.
        try? modelContext.save()
    }

    private func saveHighlight() {
        guard let selection = pendingSelection else { return }
        do {
            try HighlightStore(modelContext: modelContext).createHighlight(
                book: book,
                chapterIndex: currentChapterIndex,
                selection: selection.text,
                prefix: selection.prefix,
                suffix: selection.suffix
            )
            pendingSelection = nil
            refreshChapterHighlights()
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    private func refreshChapterHighlights() {
        do {
            chapterHighlights = try HighlightStore(modelContext: modelContext)
                .highlights(for: book, chapterIndex: currentChapterIndex)
                .map { HighlightPaint(id: $0.id.uuidString, text: $0.textSnapshot) }
        } catch {
            chapterHighlights = []
        }
    }
}

// MARK: - Reader bridge

/// Shared coordinator for both platform web views: navigation delegate plus
/// the JS↔Swift message bridge. String messages: "toggle" flips the control
/// bars, "boundaryForward"/"boundaryBackward" arrive when a page turn ran
/// past the chapter's edge. Dictionary messages report text selections for
/// highlighting.
final class ReaderBridge: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let messageName = "reader"

    weak var webView: WKWebView?
    var currentChapter: String = ""
    var landing: ChapterLanding = .start
    var resumeUTF16Offset: Int = 0
    var chapterPlainText: String?
    var paints: [HighlightPaint] = []
    var inlineKind: InlineNoteKind = .none
    var inlineNotes: [InlineNotePaint] = []
    var onTap: () -> Void = {}
    var onChapterBoundary: (PageTurnDirection) -> Void = { _ in }
    var onSelectionChange: (ReaderSelection?) -> Void = { _ in }
    var onPositionChange: (String) -> Void = { _ in }
    var onVisibleParagraphs: ([ReaderParagraph]) -> Void = { _ in }
    var onPageInfo: (Int, Int) -> Void = { _, _ in }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageName else { return }
        if let action = message.body as? String {
            switch action {
            case "toggle":
                onTap()
            case "boundaryForward":
                onChapterBoundary(.forward)
            case "boundaryBackward":
                onChapterBoundary(.backward)
            default:
                break
            }
            return
        }
        if let payload = message.body as? [String: Any],
           payload["type"] as? String == "selection" {
            let text = (payload["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                onSelectionChange(nil)
                return
            }
            onSelectionChange(
                ReaderSelection(
                    text: text,
                    prefix: payload["prefix"] as? String ?? "",
                    suffix: payload["suffix"] as? String ?? ""
                )
            )
            return
        }
        if let payload = message.body as? [String: Any],
           payload["type"] as? String == "position",
           let prefix = payload["prefix"] as? String {
            onPositionChange(prefix)
            if let page = payload["page"] as? Int,
               let pageCount = payload["pageCount"] as? Int {
                onPageInfo(page, pageCount)
            }
            return
        }
        if let payload = message.body as? [String: Any],
           payload["type"] as? String == "paragraphs",
           let items = payload["items"] as? [[String: Any]] {
            let paragraphs = items.compactMap { item -> ReaderParagraph? in
                guard let idx = item["idx"] as? Int,
                      let text = item["text"] as? String,
                      !text.isEmpty else { return nil }
                return ReaderParagraph(idx: idx, text: text)
            }
            if !paragraphs.isEmpty {
                onVisibleParagraphs(paragraphs)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if landing == .end {
            webView.evaluateJavaScript("readerGoToEnd()")
        } else if resumeUTF16Offset > 0,
                  let plainText = chapterPlainText {
            let prefix = PlainTextSearch.normalizedPrefix(
                of: plainText,
                throughUTF16Offset: resumeUTF16Offset
            )
            if let data = try? JSONEncoder().encode(prefix),
               var json = String(data: data, encoding: .utf8) {
                json = json
                    .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                    .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
                webView.evaluateJavaScript(
                    "if (typeof readerGoToNormalizedPrefix === 'function') { readerGoToNormalizedPrefix(\(json)); }"
                )
            }
        }
        applyPaints(on: webView)
        applyInlineMode(on: webView)
        applyInlineNotes(on: webView)
        #if os(macOS)
        // Keyboard paging only reaches the page while the web view is the
        // first responder; reclaim it after every chapter load.
        webView.window?.makeFirstResponder(webView)
        #endif
    }

    /// Pushes the current chapter's highlight snapshots into the page
    /// painter. JSON is escaped for direct embedding in a JS call.
    func applyPaints(on webView: WKWebView) {
        guard let data = try? JSONEncoder().encode(paints),
              var json = String(data: data, encoding: .utf8) else { return }
        json = json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        webView.evaluateJavaScript(
            "if (typeof paintHighlights === 'function') { paintHighlights(\(json)); }"
        )
    }

    /// Tells the page which inline-note mode is active (原文/双语/导读).
    func applyInlineMode(on webView: WKWebView) {
        webView.evaluateJavaScript(
            "if (typeof readerSetInlineMode === 'function') { readerSetInlineMode('\(inlineKind.rawValue)'); }"
        )
    }

    /// Pushes translated/导读 paragraph notes into the page. The page skips
    /// indices it has already rendered, so resending the full list is safe.
    func applyInlineNotes(on webView: WKWebView) {
        guard inlineKind != .none, !inlineNotes.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(inlineNotes),
              var json = String(data: data, encoding: .utf8) else { return }
        json = json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        webView.evaluateJavaScript(
            "if (typeof readerApplyInlineNotes === 'function') { readerApplyInlineNotes(\(json)); }"
        )
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        navigationAction.navigationType == .linkActivated ? .cancel : .allow
    }
}

// MARK: - WebView for Chapter Content

#if canImport(UIKit)
struct ChapterWebView: UIViewRepresentable {
    let chapter: EPUBChapter
    let basePath: URL
    let fontSize: Double
    let isDarkMode: Bool
    let lineSpacing: Double
    let landing: ChapterLanding
    let resumeUTF16Offset: Int
    let chapterPlainText: String?
    let highlights: [HighlightPaint]
    var inlineMode: InlineNoteKind = .none
    var inlineNotes: [InlineNotePaint] = []
    let onTap: () -> Void
    let onChapterBoundary: (PageTurnDirection) -> Void
    let onSelectionChange: (ReaderSelection?) -> Void
    let onPositionChange: (String) -> Void
    var onVisibleParagraphs: ([ReaderParagraph]) -> Void = { _ in }
    var onPageInfo: (Int, Int) -> Void = { _, _ in }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = []
        config.userContentController.add(context.coordinator, name: ReaderBridge.messageName)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        syncCoordinator(context.coordinator)
        context.coordinator.currentChapter = chapter.href
        context.coordinator.paints = highlights
        context.coordinator.inlineKind = inlineMode
        context.coordinator.inlineNotes = inlineNotes
        loadChapter(in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        syncCoordinator(context.coordinator)
        if context.coordinator.currentChapter != chapter.href {
            context.coordinator.currentChapter = chapter.href
            context.coordinator.paints = highlights
            context.coordinator.inlineKind = inlineMode
            context.coordinator.inlineNotes = inlineNotes
            loadChapter(in: webView)
        } else {
            webView.evaluateJavaScript(
                "updateStyle(\(fontSize), \(isDarkMode), \(lineSpacing));"
            )
            if context.coordinator.paints != highlights {
                context.coordinator.paints = highlights
                context.coordinator.applyPaints(on: webView)
            }
            if context.coordinator.inlineKind != inlineMode {
                context.coordinator.inlineKind = inlineMode
                context.coordinator.inlineNotes = inlineNotes
                context.coordinator.applyInlineMode(on: webView)
                context.coordinator.applyInlineNotes(on: webView)
            } else if context.coordinator.inlineNotes != inlineNotes {
                context.coordinator.inlineNotes = inlineNotes
                context.coordinator.applyInlineNotes(on: webView)
            }
        }
    }

    func makeCoordinator() -> ReaderBridge {
        ReaderBridge()
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: ReaderBridge) {
        uiView.configuration.userContentController
            .removeScriptMessageHandler(forName: ReaderBridge.messageName)
    }
}
#else
struct ChapterWebView: NSViewRepresentable {
    let chapter: EPUBChapter
    let basePath: URL
    let fontSize: Double
    let isDarkMode: Bool
    let lineSpacing: Double
    let landing: ChapterLanding
    let resumeUTF16Offset: Int
    let chapterPlainText: String?
    let highlights: [HighlightPaint]
    var inlineMode: InlineNoteKind = .none
    var inlineNotes: [InlineNotePaint] = []
    let onTap: () -> Void
    let onChapterBoundary: (PageTurnDirection) -> Void
    let onSelectionChange: (ReaderSelection?) -> Void
    let onPositionChange: (String) -> Void
    var onVisibleParagraphs: ([ReaderParagraph]) -> Void = { _ in }
    var onPageInfo: (Int, Int) -> Void = { _, _ in }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: ReaderBridge.messageName)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        syncCoordinator(context.coordinator)
        context.coordinator.currentChapter = chapter.href
        context.coordinator.paints = highlights
        context.coordinator.inlineKind = inlineMode
        context.coordinator.inlineNotes = inlineNotes
        loadChapter(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        syncCoordinator(context.coordinator)
        if context.coordinator.currentChapter != chapter.href {
            context.coordinator.currentChapter = chapter.href
            context.coordinator.paints = highlights
            context.coordinator.inlineKind = inlineMode
            context.coordinator.inlineNotes = inlineNotes
            loadChapter(in: webView)
        } else {
            webView.evaluateJavaScript(
                "updateStyle(\(fontSize), \(isDarkMode), \(lineSpacing));"
            )
            if context.coordinator.paints != highlights {
                context.coordinator.paints = highlights
                context.coordinator.applyPaints(on: webView)
            }
            if context.coordinator.inlineKind != inlineMode {
                context.coordinator.inlineKind = inlineMode
                context.coordinator.inlineNotes = inlineNotes
                context.coordinator.applyInlineMode(on: webView)
                context.coordinator.applyInlineNotes(on: webView)
            } else if context.coordinator.inlineNotes != inlineNotes {
                context.coordinator.inlineNotes = inlineNotes
                context.coordinator.applyInlineNotes(on: webView)
            }
        }
    }

    func makeCoordinator() -> ReaderBridge {
        ReaderBridge()
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: ReaderBridge) {
        nsView.configuration.userContentController
            .removeScriptMessageHandler(forName: ReaderBridge.messageName)
    }
}
#endif

// Shared page generation and loading
extension ChapterWebView {
    private func syncCoordinator(_ bridge: ReaderBridge) {
        bridge.landing = landing
        bridge.resumeUTF16Offset = resumeUTF16Offset
        bridge.chapterPlainText = chapterPlainText
        bridge.onTap = onTap
        bridge.onChapterBoundary = onChapterBoundary
        bridge.onSelectionChange = onSelectionChange
        bridge.onPositionChange = onPositionChange
        bridge.onVisibleParagraphs = onVisibleParagraphs
        bridge.onPageInfo = onPageInfo
    }

    func loadChapter(in webView: WKWebView) {
        // 朱批 palette (EmptyTheme): warm paper / night-read ink.
        let bgColor = isDarkMode ? "#1F1B16" : "#F7F2E9"
        let textColor = isDarkMode ? "#EDE5D4" : "#2A2419"

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
            * { box-sizing: border-box; }
            :root {
                --e-ink2: \(isDarkMode ? "#C4B9A4" : "#5C5443");
                --e-line2: \(isDarkMode ? "#453C2F" : "#D8CEBB");
                --e-acc: \(isDarkMode ? "#D86B47" : "#B5482A");
                --e-acc-soft: \(isDarkMode ? "rgba(216,107,71,0.12)" : "rgba(181,72,42,0.08)");
            }
            html {
                height: 100%;
                overflow: hidden;
            }
            /* One CSS column per page. The body is the (JS-driven) horizontal
               scroller; every page turn moves exactly one viewport width. */
            body {
                font-family: "Source Serif 4", "New York", "Georgia", "Songti SC", serif;
                font-size: \(fontSize)px;
                line-height: \(lineSpacing);
                color: \(textColor);
                background-color: \(bgColor);
                height: 100%;
                margin: 0;
                padding: 20px 24px;
                column-width: calc(100vw - 48px);
                column-gap: 48px;
                column-fill: auto;
                overflow-x: hidden;
                overflow-y: hidden;
                word-wrap: break-word;
                overflow-wrap: break-word;
                -webkit-text-size-adjust: none;
            }
            img {
                max-width: 100%;
                max-height: calc(100vh - 80px);
                height: auto;
                display: block;
                margin: 16px auto;
            }
            h1, h2, h3, h4, h5, h6 {
                line-height: 1.3;
                margin-top: 1.5em;
                margin-bottom: 0.5em;
            }
            p { margin: 0.8em 0; text-align: justify; }
            a { color: \(isDarkMode ? "#D86B47" : "#B5482A"); }
            ::selection { background: rgba(181,72,42,0.25); }
            pre, code {
                font-size: 0.85em;
                background: \(isDarkMode ? "#2A241C" : "#EFE8DB");
                padding: 2px 4px;
                border-radius: 4px;
                white-space: pre-wrap;
            }
            blockquote {
                border-left: 2px solid \(isDarkMode ? "#D86B47" : "#B5482A");
                margin-left: 0;
                padding-left: 16px;
                color: \(isDarkMode ? "#C4B9A4" : "#5C5443");
            }
            table { border-collapse: collapse; max-width: 100%; }
            td, th { border: 1px solid \(isDarkMode ? "#444" : "#ddd"); padding: 8px; }
            /* 双语对照: quiet gray serif under the original paragraph. */
            div[data-einject="bi"] {
                font-family: "Noto Serif SC", "Songti SC", serif;
                font-size: 0.78em;
                line-height: 2;
                color: var(--e-ink2);
                margin: 4px 0 14px;
                padding-left: 14px;
                border-left: 1px solid var(--e-line2);
                text-align: justify;
            }
            /* 导读: a 朱批 callout that retells the paragraph. */
            div[data-einject="comp"] {
                border-left: 2px solid var(--e-acc);
                padding: 10px 16px;
                background: var(--e-acc-soft);
                border-radius: 0 12px 12px 0;
                margin: 4px 0 14px;
                font-size: 0.74em;
                line-height: 1.8;
                color: var(--e-ink2);
                break-inside: avoid;
            }
            div[data-einject="comp"]::before {
                content: '导读';
                display: block;
                font-size: 0.82em;
                font-weight: 700;
                color: var(--e-acc);
                letter-spacing: 0.1em;
                margin-bottom: 4px;
            }
        </style>
        <script>
        let pageIndex = 0;
        // ---- Inline notes (双语对照 / 导读) ----
        // 'none' | 'bi' | 'comp'. Injected blocks carry data-einject and are
        // invisible to position math, highlight anchoring and selection.
        let inlineKind = 'none';
        let appliedNotes = {};
        function pageWidth() { return window.innerWidth; }
        function readerPageCount() {
            return Math.max(1, Math.round(document.body.scrollWidth / pageWidth()));
        }
        // Text walker that skips injected inline notes, so the chapter's
        // normalized buffer matches the stored plain text exactly.
        function readerTextWalker() {
            return document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
                acceptNode: function (node) {
                    return node.parentElement && node.parentElement.closest('[data-einject]')
                        ? NodeFilter.FILTER_REJECT
                        : NodeFilter.FILTER_ACCEPT;
                }
            });
        }
        function readerParagraphs() {
            return Array.prototype.slice.call(document.querySelectorAll('p'));
        }
        // Page a paragraph starts on, stable even mid smooth-scroll:
        // rect.left is viewport-relative, so adding scrollLeft recovers the
        // absolute x inside the column flow.
        function paragraphPage(p) {
            const abs = p.getBoundingClientRect().left + document.body.scrollLeft;
            return Math.floor(abs / pageWidth());
        }
        // Paragraphs the reader is looking at: those starting on the current
        // page, plus the straddler flowing in from the previous page.
        function visibleParagraphIndexes() {
            const paras = readerParagraphs();
            const out = [];
            let straddler = -1;
            for (let i = 0; i < paras.length; i++) {
                const page = paragraphPage(paras[i]);
                if (page < pageIndex) { straddler = i; }
                else if (page === pageIndex) { out.push(i); }
                else if (page > pageIndex) { break; }
            }
            if (straddler >= 0) { out.unshift(straddler); }
            return out;
        }
        function reportInlineParagraphs() {
            if (inlineKind === 'none') { return; }
            const paras = readerParagraphs();
            const items = [];
            visibleParagraphIndexes().forEach(function (idx) {
                if (items.length >= 6 || appliedNotes[idx]) { return; }
                const text = paras[idx].innerText.replace(/\\s+/g, ' ').trim();
                if (text.length < 40 || text.length > 4000) { return; }
                items.push({ idx: idx, text: text });
            });
            if (items.length) { post({ type: 'paragraphs', items: items }); }
        }
        function clearInlineNotes() {
            document.querySelectorAll('[data-einject]').forEach(function (el) {
                el.remove();
            });
            appliedNotes = {};
        }
        function readerSetInlineMode(kind) {
            if (kind === inlineKind) { reportInlineParagraphs(); return; }
            const anchors = visibleParagraphIndexes();
            inlineKind = kind;
            clearInlineNotes();
            requestAnimationFrame(function () {
                if (anchors.length) {
                    const p = readerParagraphs()[anchors[0]];
                    if (p) { pageIndex = Math.max(0, paragraphPage(p)); }
                }
                readerGoTo(pageIndex, false);
                reportInlineParagraphs();
            });
        }
        function readerApplyInlineNotes(items) {
            if (inlineKind === 'none') { return; }
            const paras = readerParagraphs();
            const anchors = visibleParagraphIndexes();
            let changed = false;
            items.forEach(function (item) {
                if (appliedNotes[item.idx]) { return; }
                const p = paras[item.idx];
                if (!p) { return; }
                const div = document.createElement('div');
                div.setAttribute('data-einject', inlineKind);
                div.textContent = item.text;
                p.insertAdjacentElement('afterend', div);
                appliedNotes[item.idx] = true;
                changed = true;
            });
            if (!changed) { return; }
            // Inserting blocks reflows the columns; stay on the page where
            // the first visible paragraph now lives.
            requestAnimationFrame(function () {
                if (anchors.length) {
                    const p = readerParagraphs()[anchors[0]];
                    if (p) { pageIndex = Math.max(0, paragraphPage(p)); }
                }
                readerGoTo(pageIndex, false);
            });
        }
        // Normalized chapter text up to the end of the last element that
        // starts on `pageIdx` or earlier. Walks only original content, so
        // injected inline notes never skew reading progress.
        function normalizedTextPrefixThroughPage(pageIdx) {
            const walker = readerTextWalker();
            let normBuffer = '';
            let lastWasSpace = true;
            while (walker.nextNode()) {
                const node = walker.currentNode;
                const el = node.parentElement;
                if (el) {
                    const rect = el.getBoundingClientRect();
                    if (rect.width || rect.height) {
                        const abs = rect.left + document.body.scrollLeft;
                        if (Math.floor(abs / pageWidth()) > pageIdx) { break; }
                    }
                }
                const value = node.nodeValue;
                for (let i = 0; i < value.length; i++) {
                    if (/\\s/.test(value[i])) {
                        if (!lastWasSpace) {
                            normBuffer += ' ';
                            lastWasSpace = true;
                        }
                    } else {
                        normBuffer += value[i];
                        lastWasSpace = false;
                    }
                }
            }
            return normBuffer;
        }
        function reportPosition() {
            post({
                type: 'position',
                prefix: normalizedTextPrefixThroughPage(pageIndex),
                page: pageIndex,
                pageCount: readerPageCount()
            });
            reportInlineParagraphs();
        }
        function applyPage(animated) {
            document.body.scrollTo({
                left: pageIndex * pageWidth(),
                top: 0,
                behavior: animated ? 'smooth' : 'auto'
            });
            reportPosition();
        }
        function readerGoTo(page, animated) {
            pageIndex = Math.max(0, Math.min(page, readerPageCount() - 1));
            applyPage(animated !== false);
        }
        function readerGoToEnd() { readerGoTo(readerPageCount() - 1, false); }
        function readerGoToNormalizedPrefix(prefix) {
            if (!prefix) { reportPosition(); return; }
            const pageCount = readerPageCount();
            let chosen = 0;
            for (let page = 0; page < pageCount; page++) {
                const slice = normalizedTextPrefixThroughPage(page);
                if (slice.length <= prefix.length && prefix.startsWith(slice)) {
                    chosen = page;
                }
                if (slice.length >= prefix.length) {
                    chosen = page;
                    break;
                }
            }
            readerGoTo(chosen, false);
        }
        function readerNext() {
            if (pageIndex >= readerPageCount() - 1) { return false; }
            readerGoTo(pageIndex + 1);
            return true;
        }
        function readerPrev() {
            if (pageIndex <= 0) { return false; }
            readerGoTo(pageIndex - 1);
            return true;
        }
        function post(message) {
            window.webkit.messageHandlers.reader.postMessage(message);
        }
        function turnForward() { if (!readerNext()) { post('boundaryForward'); } }
        function turnBackward() { if (!readerPrev()) { post('boundaryBackward'); } }
        function updateStyle(fontSize, isDark, lineSpacing) {
            const bg = isDark ? '#1F1B16' : '#F7F2E9';
            const fg = isDark ? '#EDE5D4' : '#2A2419';
            document.body.style.fontSize = fontSize + 'px';
            document.body.style.lineHeight = lineSpacing;
            document.body.style.backgroundColor = bg;
            document.body.style.color = fg;
            const root = document.documentElement.style;
            root.setProperty('--e-ink2', isDark ? '#C4B9A4' : '#5C5443');
            root.setProperty('--e-line2', isDark ? '#453C2F' : '#D8CEBB');
            root.setProperty('--e-acc', isDark ? '#D86B47' : '#B5482A');
            root.setProperty('--e-acc-soft', isDark ? 'rgba(216,107,71,0.12)' : 'rgba(181,72,42,0.08)');
            // Reflow shuffles content between columns; reapply the kept page.
            requestAnimationFrame(function () { readerGoTo(pageIndex, false); });
        }
        // Keyboard: arrows and PageUp/Down; Space pages forward,
        // Shift+Space backward.
        document.addEventListener('keydown', function (event) {
            switch (event.key) {
            case 'ArrowRight':
            case 'PageDown':
                turnForward(); event.preventDefault(); break;
            case 'ArrowLeft':
            case 'PageUp':
                turnBackward(); event.preventDefault(); break;
            case ' ':
                if (event.shiftKey) { turnBackward(); } else { turnForward(); }
                event.preventDefault(); break;
            }
        });
        // Trackpad and mouse wheel: one gesture turns exactly one page.
        // The lock releases only after the event stream (momentum tail
        // included) has been quiet for a beat.
        let wheelAccum = 0;
        let wheelLocked = false;
        let wheelQuietTimer = null;
        window.addEventListener('wheel', function (event) {
            event.preventDefault();
            const delta = Math.abs(event.deltaX) > Math.abs(event.deltaY)
                ? event.deltaX : event.deltaY;
            if (!wheelLocked) {
                wheelAccum += delta;
                if (Math.abs(wheelAccum) > 60) {
                    wheelLocked = true;
                    if (wheelAccum > 0) { turnForward(); } else { turnBackward(); }
                    wheelAccum = 0;
                }
            }
            clearTimeout(wheelQuietTimer);
            wheelQuietTimer = setTimeout(function () {
                wheelLocked = false;
                wheelAccum = 0;
            }, 250);
        }, { passive: false });
        // Touch: a horizontal swipe turns one page.
        let touchStartX = null;
        let touchStartY = null;
        let lastSwipeAt = 0;
        document.addEventListener('touchstart', function (event) {
            touchStartX = event.changedTouches[0].clientX;
            touchStartY = event.changedTouches[0].clientY;
        }, { passive: true });
        document.addEventListener('touchend', function (event) {
            if (touchStartX === null) { return; }
            const dx = event.changedTouches[0].clientX - touchStartX;
            const dy = event.changedTouches[0].clientY - touchStartY;
            touchStartX = null;
            if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy)) {
                lastSwipeAt = Date.now();
                if (dx < 0) { turnForward(); } else { turnBackward(); }
            }
        }, { passive: true });
        // Window resizes reflow the columns; stay on the kept page.
        window.addEventListener('resize', function () { readerGoTo(pageIndex, false); });
        window.addEventListener('load', function () {
            requestAnimationFrame(function () { reportPosition(); });
        });
        // Tap zones: left quarter = previous page, right quarter = next,
        // middle = toggle controls. Link clicks and swipe-tail clicks are
        // left alone.
        document.addEventListener('click', function (event) {
            if (event.target.closest('a')) { return; }
            const liveSelection = window.getSelection();
            if (liveSelection && liveSelection.toString().trim()) { return; }
            if (Date.now() - lastSwipeAt < 350) { return; }
            const x = event.clientX / window.innerWidth;
            if (x < 0.25) { turnBackward(); }
            else if (x > 0.75) { turnForward(); }
            else { post('toggle'); }
        });
        // ---- Highlights ----
        function clearHighlightMarks() {
            document.querySelectorAll('mark[data-ehl]').forEach(function (mark) {
                const parent = mark.parentNode;
                while (mark.firstChild) { parent.insertBefore(mark.firstChild, mark); }
                parent.removeChild(mark);
                parent.normalize();
            });
        }
        function paintHighlights(items) {
            clearHighlightMarks();
            items.forEach(function (item) { paintHighlight(item.id, item.text); });
        }
        function paintHighlight(id, rawText) {
            const needle = rawText.replace(/\\s+/g, ' ').trim();
            if (!needle) { return; }
            const walker = readerTextWalker();
            let normBuffer = '';
            const map = [];
            let lastWasSpace = true;
            while (walker.nextNode()) {
                const node = walker.currentNode;
                const value = node.nodeValue;
                for (let i = 0; i < value.length; i++) {
                    if (/\\s/.test(value[i])) {
                        if (!lastWasSpace) {
                            normBuffer += ' ';
                            map.push({ node: node, offset: i });
                            lastWasSpace = true;
                        }
                    } else {
                        normBuffer += value[i];
                        map.push({ node: node, offset: i });
                        lastWasSpace = false;
                    }
                }
            }
            const index = normBuffer.indexOf(needle);
            if (index < 0) { return; }
            const start = map[index];
            const end = map[index + needle.length - 1];
            const range = document.createRange();
            range.setStart(start.node, start.offset);
            range.setEnd(end.node, end.offset + 1);
            wrapRange(range, id);
        }
        function wrapRange(range, id) {
            const walker = readerTextWalker();
            const targets = [];
            while (walker.nextNode()) {
                const node = walker.currentNode;
                if (range.intersectsNode(node)) { targets.push(node); }
            }
            targets.forEach(function (node) {
                const r = document.createRange();
                r.selectNodeContents(node);
                if (node === range.startContainer) { r.setStart(node, range.startOffset); }
                if (node === range.endContainer) { r.setEnd(node, range.endOffset); }
                if (r.collapsed) { return; }
                const mark = document.createElement('mark');
                mark.dataset.ehl = id;
                mark.style.backgroundColor = 'rgba(255, 214, 10, 0.45)';
                mark.style.color = 'inherit';
                try { r.surroundContents(mark); } catch (e) {}
            });
        }
        // ---- Selection reporting ----
        let selectionTimer = null;
        document.addEventListener('selectionchange', function () {
            clearTimeout(selectionTimer);
            selectionTimer = setTimeout(function () {
                const sel = window.getSelection();
                const text = sel ? sel.toString() : '';
                if (!text.trim()) {
                    post({ type: 'selection', text: '' });
                    return;
                }
                let prefix = '';
                let suffix = '';
                try {
                    const range = sel.getRangeAt(0);
                    const before = document.createRange();
                    before.selectNodeContents(document.body);
                    before.setEnd(range.startContainer, range.startOffset);
                    prefix = before.toString().slice(-40);
                    const after = document.createRange();
                    after.selectNodeContents(document.body);
                    after.setStart(range.endContainer, range.endOffset);
                    suffix = after.toString().slice(0, 40);
                } catch (e) {}
                post({ type: 'selection', text: text, prefix: prefix, suffix: suffix });
            }, 250);
        });
        </script>
        </head>
        <body>
        \(extractBody(from: chapter.content))
        </body>
        </html>
        """

        // `loadHTMLString` grants the sandboxed web-content process no file
        // access: chapter images can't load, and a sandboxed macOS app shows
        // a blank page outright. Write the styled page next to the chapter
        // source (relative resource paths keep resolving) and load it as a
        // file URL with read access to the whole book directory.
        let chapterURL = basePath.appendingPathComponent(chapter.href)
        let pageURL = chapterURL.deletingLastPathComponent()
            .appendingPathComponent(".reader-\(chapterURL.lastPathComponent).html")
        do {
            try html.write(to: pageURL, atomically: true, encoding: .utf8)
            webView.loadFileURL(pageURL, allowingReadAccessTo: basePath)
        } catch {
            webView.loadHTMLString(html, baseURL: basePath)
        }
    }

    private func extractBody(from html: String) -> String {
        if let bodyStart = html.range(of: "<body", options: .caseInsensitive),
           let bodyTagEnd = html.range(of: ">", range: bodyStart.upperBound..<html.endIndex),
           let bodyClose = html.range(of: "</body>", options: .caseInsensitive) {
            return String(html[bodyTagEnd.upperBound..<bodyClose.lowerBound])
        }
        return html
    }
}

// MARK: - Chapter List

struct ChapterListView: View {
    let titles: [String]
    var listTitle: String = "Chapters"
    let currentIndex: Int
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    Button {
                        onSelect(index)
                    } label: {
                        HStack {
                            Text(title)
                                .font(.subheadline)
                                .foregroundStyle(index == currentIndex ? Color.accentColor : Color.primary)
                            Spacer()
                            if index == currentIndex {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle(listTitle)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Reading Settings

struct ReadingSettingsView: View {
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double

    var body: some View {
        NavigationStack {
            List {
                Section("字号") {
                    HStack {
                        Text("A")
                            .font(.caption)
                        Slider(value: $fontSize, in: 12...28, step: 1)
                        Text("A")
                            .font(.title2)
                    }
                    .padding(.vertical, 4)
                }

                Section("行距") {
                    HStack {
                        Image(systemName: "text.alignleft")
                            .font(.caption)
                        Slider(value: $lineSpacing, in: 1.2...2.2, step: 0.1)
                        Image(systemName: "text.alignleft")
                            .font(.title3)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("阅读设置")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}
