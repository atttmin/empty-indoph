//
//  ReadingView.swift
//  Empty
//

import SwiftData
import SwiftUI

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

/// A live native-reader selection, anchored by nearby plain-text context.
nonisolated struct ReaderSelection: Equatable {
    var text: String
    var prefix: String
    var suffix: String
}

/// What reader painters need to mark one stored highlight.
nonisolated struct HighlightPaint: Codable, Equatable {
    var id: String
    var text: String
    var startUTF16: Int? = nil
    var endUTF16: Int? = nil
}

/// Reader text mode — the prototype's 原文 / 双语对照 / 导读 toggle,
/// expressed as the token pushed into the chapter page's script.
nonisolated enum InlineNoteKind: String {
    case none
    case bilingual = "bi"
    case companion = "comp"
}

/// How bilingual notes lay out: stacked under each paragraph (iOS), or
/// the prototype's side-by-side parallel text (Mac 双语对照).
nonisolated enum InlineNoteLayout: String {
    case stacked
    case parallel
}

/// One in-flow AI note (a paragraph's translation or 导读 paraphrase),
/// keyed by the paragraph's index in the chapter DOM. `failed` marks a
/// paragraph whose translation errored, so the page can retire its
/// "预译中" placeholder instead of blinking forever.
nonisolated struct InlineNotePaint: Codable, Equatable {
    var idx: Int
    var text: String
    var failed: Bool = false
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
    @State private var showChapterSelection = false
    @State private var saveErrorMessage: String?
    @State private var showControls = true
    @AppStorage("reader.fontSize") private var fontSize: Double = 18
    @AppStorage("reader.lineSpacing") private var lineSpacing: Double = 1.6
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
                NativeChapterReaderView(
                    chapter: book.chapters[currentChapterIndex],
                    basePath: book.basePath,
                    fontSize: fontSize,
                    lineSpacing: lineSpacing,
                    landing: chapterLanding,
                    resumeUTF16Offset: resumeUTF16Offset,
                    chapterPlainText: currentChapterPlainText(),
                    highlights: chapterHighlights,
                    inlineMode: isBilingual ? .bilingual : .none,
                    inlineLayout: .stacked,
                    inlineNotes: inlineNotes,
                    selectionActive: pendingSelection != nil,
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
                .id(currentChapterIndex)

                readerOverlay
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .sheet(isPresented: $showChapterList) {
            ChapterListView(
                titles: sectionTitles,
                unitLabel: "章",
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
            HighlightsListView(book: self.book) { position in
                currentChapterIndex = position.chapterIndex
                currentUTF16Offset = position.utf16Offset
                chapterLanding = .start
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 460)
            #endif
        }
        .sheet(isPresented: $showChapterSelection) {
            NativeChapterSelectionSheet(
                title: sectionTitles.indices.contains(currentChapterIndex)
                    ? sectionTitles[currentChapterIndex]
                    : "当前章节",
                chapterText: currentChapterPlainText() ?? "",
                highlights: chapterHighlights,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                focusUTF16Offset: currentUTF16Offset,
                initialSelection: pendingSelection
            ) { selection in
                handleSelectionChange(selection)
            }
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
                    unitLabel: "页",
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
                HighlightsListView(book: self.book) { position in
                    currentChapterIndex = position.chapterIndex
                    syncPageProgress(at: position.chapterIndex)
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
            .accessibilityIdentifier("reader.back")

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
                .accessibilityIdentifier("reader.toggleBilingual")
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
            .accessibilityIdentifier("reader.aloud")

            Menu {
                Button("目录", systemImage: "list.bullet") { showChapterList = true }
                    .accessibilityIdentifier("reader.menu.chapterList")
                Button("高亮", systemImage: "highlighter") { showHighlights = true }
                    .accessibilityIdentifier("reader.menu.highlights")
                Button("前情回顾", systemImage: "sparkles") { showRecap = true }
                    .accessibilityIdentifier("reader.menu.recap")
                Button("阅读设置", systemImage: "textformat.size") { showSettings = true }
                    .accessibilityIdentifier("reader.menu.settings")
            } label: {
                Text("⋯")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.ink3)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("reader.overflow")
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
            selectionButton("跨段") { showChapterSelection = true }
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
        showChapterSelection = false
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
    /// reading order. Resolution: in-memory → persistent cache (the
    /// 「不重复翻译」 rule — reopening a book never re-translates) → AI.
    private func handleVisibleParagraphs(_ paragraphs: [ReaderParagraph]) {
        guard isBilingual else { return }
        let chapter = currentChapterIndex
        let store = TranslationStore(modelContext: modelContext)
        var missing: [ReaderParagraph] = []
        for paragraph in paragraphs {
            let key = inlineNoteKey(chapter: chapter, idx: paragraph.idx)
            if let cached = inlineCache[key] {
                if !cached.isEmpty,
                   !inlineNotes.contains(where: { $0.idx == paragraph.idx }) {
                    inlineNotes.append(InlineNotePaint(idx: paragraph.idx, text: cached))
                }
            } else if let persisted = store.lookup(
                bookID: book.id,
                kind: .bilingual,
                text: paragraph.text
            ) {
                inlineCache[key] = persisted
                if !inlineNotes.contains(where: { $0.idx == paragraph.idx }) {
                    inlineNotes.append(InlineNotePaint(idx: paragraph.idx, text: persisted))
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
                let text = try await AITransientRetry.run {
                    try await resolution.service.inlineNote(
                        for: paragraph.text,
                        kind: .bilingual
                    )
                }.trimmingCharacters(in: .whitespacesAndNewlines)
                inlineCache[key] = text
                if !text.isEmpty {
                    TranslationStore(modelContext: modelContext).store(
                        text,
                        bookID: book.id,
                        chapterIndex: chapter,
                        kind: .bilingual,
                        text: paragraph.text
                    )
                }
                if isBilingual, currentChapterIndex == chapter, !text.isEmpty {
                    inlineNotes.append(InlineNotePaint(idx: paragraph.idx, text: text))
                }
            } catch {
                // Transient provider pressure (busy/rate-limited/network)
                // should retry on the next settled viewport report, not
                // retire the paragraph for this visit.
                guard !AITransientRetry.isTransient(error) else { continue }
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
                .map {
                    HighlightPaint(
                        id: $0.id.uuidString,
                        text: $0.textSnapshot,
                        startUTF16: $0.startUTF16,
                        endUTF16: $0.endUTF16
                    )
                }
        } catch {
            chapterHighlights = []
        }
    }
}

// MARK: - Chapter List

/// 目录 in the 朱批 language: serif header, numbered rows, read chapters
/// dimmed, the current one carrying the vermilion 正在读 chip. Opens
/// scrolled to where the reader is.
struct ChapterListView: View {
    let titles: [String]
    /// "章" for EPUB chapters, "页" for PDF pages.
    var unitLabel: String = "章"
    let currentIndex: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.emptyPalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.line).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                            row(index: index, title: title)
                                .id(index)
                        }
                    }
                    .padding(EdgeInsets(top: 10, leading: 12, bottom: 16, trailing: 12))
                }
                .onAppear {
                    proxy.scrollTo(currentIndex, anchor: .center)
                }
            }
        }
        .background(palette.window)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("目录")
                    .font(.system(size: 17, weight: .black, design: .serif))
                    .foregroundStyle(palette.ink)
                Text("共 \(titles.count) \(unitLabel) · 正在读第 \(currentIndex + 1) \(unitLabel)")
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

    private func row(index: Int, title: String) -> some View {
        let isCurrent = index == currentIndex
        let isRead = index < currentIndex
        let display = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? "第 \(index + 1) \(unitLabel)"
            : title
        return Button {
            onSelect(index)
        } label: {
            HStack(spacing: 12) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 11, design: .serif).monospacedDigit())
                    .foregroundStyle(isCurrent ? palette.accent : palette.ink3)
                    .frame(width: 24, alignment: .trailing)
                Text(display)
                    .font(.system(size: 13.5, weight: isCurrent ? .bold : .regular))
                    .foregroundStyle(
                        isCurrent ? palette.accent : (isRead ? palette.ink3 : palette.ink)
                    )
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isCurrent {
                    Text("正在读")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.onAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(palette.accent, in: Capsule())
                } else if isRead {
                    Text("读过")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.ink3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                isCurrent ? palette.accentSoft : .clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reading Settings

struct ReadingSettingsView: View {
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double

    @Environment(\.dismiss) private var dismiss
    @Environment(\.emptyPalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("阅读设置")
                        .font(.system(size: 17, weight: .black, design: .serif))
                        .foregroundStyle(palette.ink)
                    Text("字号 \(Int(fontSize)) · 行距 \(lineSpacing, specifier: "%.1f")")
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
                settingRow(label: "字号") {
                    HStack(spacing: 12) {
                        Text("A").font(.system(size: 11, design: .serif))
                        Slider(value: $fontSize, in: 12...28, step: 1)
                            .tint(palette.accent)
                        Text("A").font(.system(size: 20, design: .serif))
                    }
                    .foregroundStyle(palette.ink2)
                }
                settingRow(label: "行距") {
                    HStack(spacing: 12) {
                        Image(systemName: "text.alignleft").font(.system(size: 10))
                        Slider(value: $lineSpacing, in: 1.2...2.2, step: 0.1)
                            .tint(palette.accent)
                        Image(systemName: "text.alignleft").font(.system(size: 16))
                    }
                    .foregroundStyle(palette.ink2)
                }
                Text("\u{201C}I went to the woods because I wished to live deliberately…\u{201D}")
                    .font(.system(size: fontSize * 0.8, design: .serif))
                    .lineSpacing(fontSize * 0.8 * (lineSpacing - 1))
                    .foregroundStyle(palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .emptyCard(palette, radius: 12)
            }
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 20, trailing: 20))

            Spacer(minLength: 0)
        }
        .background(palette.window)
        #if os(iOS)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        #endif
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
