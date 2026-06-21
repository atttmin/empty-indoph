//
//  MacReaderScreen.swift
//  Empty
//

#if os(macOS)

import AVFoundation
import SwiftData
import SwiftUI

enum MacReadingMode: String, CaseIterable {
    case original
    case bilingual
    case companion
    /// 辩难 lens — counter-questions in the margins, never answers.
    case debate
    /// 文献 lens — public-domain commentary echoes.
    case sources
}

/// A chapter's pre-translation state in the TOC (✓已缓存 / ⟳预译中 /
/// 排队中 / 部分缓存 / 未译).
enum MacChapterTransStatus: Equatable {
    case queued
    case translating(done: Int, total: Int)
}

struct MacReaderScreen: View {
    let book: Book
    var onBack: () -> Void
    var onOpenVocab: () -> Void
    var onOpenNotes: () -> Void

    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext
    @Query private var vocabEntries: [VocabEntry]

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
    @State private var showHighlights = false
    @State private var recapCache: RecapCache?
    @AppStorage("reader.fontSize") private var fontSize: Double = 18
    @AppStorage("reader.lineSpacing") private var lineSpacing: Double = 1.8
    @AppStorage("reader.theme") private var readerTheme: ReaderTheme = .paper
    @AppStorage("reader.font") private var readerFont: ReaderFont = .serif
    @AppStorage("reader.contentWidth") private var readerContentWidth: ReaderContentWidth = .medium
    @AppStorage("reader.firstLineIndent") private var readerFirstLineIndent: ReaderFirstLineIndent = .classic
    @AppStorage("reader.paragraphSpacing") private var readerParagraphSpacing: ReaderParagraphSpacingStyle = .book
    @AppStorage("reader.textAlignment") private var readerTextAlignment: ReaderTextAlignmentStyle = .justified
    @AppStorage("reader.chapterOpening") private var readerChapterOpening: ReaderChapterOpeningStyle = .outdent
    @AppStorage("reader.pageturn.mac") private var pageTurn: ReaderPageTurn = .paged
    @State private var pendingSelection: ReaderSelection?
    @State private var chapterHighlights: [HighlightPaint] = []
    @State private var showChapterSelection = false
    @State private var isCompanionOpen = false
    @State private var companion: CompanionModel
    @AppStorage("reader.mode.mac") private var readingMode: MacReadingMode = .original
    @State private var summaryOpen = true
    @State private var chapterSummary = ""
    @State private var isSummaryLoading = false
    @State private var modeGuideText = ""
    @State private var isGuideLoading = false
    @State private var selectionInsight: ReaderSelectionInsight?
    @State private var selectionInsightSaved = false
    @State private var glossEntry: VocabEntry?
    @State private var isSelectionWorking = false
    @State private var thoughtLinks: [ThoughtLink] = []
    @State private var expandedThoughtLinkIDs: Set<String> = []
    @State private var savedThoughtLinkIDs: Set<String> = []
    @State private var chapterOutline: ChapterOutline?
    @State private var chapterPageInfo: (page: Int, count: Int)?
    @State private var inlineNotes: [InlineNotePaint] = []
    @State private var inlineCache: [String: String] = [:]
    @State private var inlineRetryCounts: [String: Int] = [:]
    @State private var inlineInFlight: Set<String> = []
    @State private var inlineAIUnavailable = false
    @State private var isTocOpen = false
    @State private var chromeHidden = false
    /// Reference box: re-arming the timer per mouse move must NOT
    /// invalidate the view (that re-parsed the chapter on every move).
    @State private var chromeTimer = TaskBox()
    @State private var bookmarkedHere = false
    @State private var activityMeter = ReadingActivityMeter()
    @AppStorage("reader.aloud.autonext") private var aloudAutoNext = false
    @AppStorage("reader.pdf.invert") private var pdfNightInverted = false
    @AppStorage("reader.pdf.autocrop") private var pdfAutoCrop = false
    @AppStorage("reader.pdf.twoup") private var pdfTwoUp = false
    @AppStorage("reader.traditional") private var traditionalChinese = false
    @State private var traditionalCache = DictionaryBox<Int, (chapter: EPUBChapter, plain: String?)>()
    /// Per-chapter pre-translation activity for the TOC chips.
    @State private var pretransProgress: [Int: MacChapterTransStatus] = [:]
    /// Translated chapter titles for the bilingual TOC (kind `.title`).
    @State private var tocTitleTranslations: [Int: String] = [:]
    /// Bumps whenever the translation cache changes, so TOC stats refresh.
    @State private var cacheStatsTick = 0
    @State private var pretransTask: Task<Void, Never>?
    @StateObject private var aloud = ReadingAloud()

    init(
        book: Book,
        onBack: @escaping () -> Void,
        onOpenVocab: @escaping () -> Void = {},
        onOpenNotes: @escaping () -> Void = {}
    ) {
        self.book = book
        self.onBack = onBack
        self.onOpenVocab = onOpenVocab
        self.onOpenNotes = onOpenNotes
        _currentChapterIndex = State(initialValue: book.position.chapterIndex)
        _currentUTF16Offset = State(initialValue: book.position.utf16Offset)
        _companion = State(initialValue: CompanionModel())
    }

    private var currentReadingPosition: ReadingPosition {
        ReadingPosition(
            chapterIndex: currentChapterIndex,
            utf16Offset: currentUTF16Offset
        )
    }

    private var resumeUTF16Offset: Int {
        chapterLanding == .start ? currentUTF16Offset : 0
    }

    private var dueVocabCount: Int {
        let now = Date()
        return vocabEntries.filter { $0.dueAt <= now }.count
    }

    /// Reading-mode token pushed into the chapter page for in-flow notes.
    private var inlineNoteKind: InlineNoteKind {
        switch readingMode {
        case .original: .none
        case .bilingual: .bilingual
        case .companion: .companion
        case .debate: .debate
        case .sources: .sources
        }
    }

    /// Intra-chapter progress, for the overview card's "你在这里" marker.
    private var intraChapterFraction: Double {
        let length = currentChapterRecord?.utf16Length ?? 0
        guard length > 0 else { return 0 }
        return min(1, Double(currentUTF16Offset) / Double(length))
    }

    /// Estimated minutes for the current chapter ("本章约 X 分钟").
    private var chapterMinutes: Int {
        ReadingTimeEstimate.minutes(
            utf16Length: currentChapterRecord?.utf16Length ?? 0,
            languageTag: book.languageTag
        )
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在打开…")
                    .foregroundStyle(palette.ink3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                errorView(loadError)
            } else if let epubBook {
                readerContent(epubBook)
            } else if pdfDocumentURL != nil {
                pdfReaderContent
            }
        }
        .background(palette.window)
        .onAppear(perform: loadBook)
        .onDisappear {
            aloud.stop()
            saveProgress()
        }
    }

    /// 沉浸态: the mouse resting ~2.5s fades the reader chrome out;
    /// any movement brings it back, and open overlays pin it visible.
    private var immersionBlocked: Bool {
        showSettings || showChapterList || showRecap || showHighlights
            || showChapterSelection || isCompanionOpen || isTocOpen
            || pendingSelection != nil || selectionInsight != nil || glossEntry != nil
    }

    private func wakeChrome() {
        if chromeHidden {
            withAnimation(.easeInOut(duration: 0.25)) { chromeHidden = false }
        }
        chromeTimer.replace(Task {
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled, !immersionBlocked else { return }
            withAnimation(.easeInOut(duration: 0.4)) { chromeHidden = true }
        })
    }

    @ViewBuilder
    private func readerContent(_ epub: EPUBBook) -> some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                topBar(epub)
                    .opacity(chromeHidden ? 0 : 1)
                    .allowsHitTesting(!chromeHidden)
                Rectangle().fill(palette.line).frame(height: 1)

                if summaryOpen {
                    if isSummaryLoading {
                        ProgressView("生成章节概览…")
                            .padding()
                    } else if !chapterSummary.isEmpty || chapterOutline != nil {
                        MacChapterSummaryCard(
                            title: epub.chapters[currentChapterIndex].title,
                            summary: chapterSummary,
                            outline: chapterOutline,
                            currentPartIndex: ChapterOutline.partIndex(
                                forProgress: intraChapterFraction
                            ),
                            minutes: chapterMinutes,
                            highlightCount: chapterHighlights.count,
                            onCollapse: { summaryOpen = false }
                        )
                    }
                } else {
                    Button("朱 · 展开章节概览") {
                        summaryOpen = true
                        Task { await loadChapterSummary() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.ink3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .overlay(
                        Capsule().strokeBorder(palette.line2, style: StrokeStyle(dash: [4, 3]))
                    )
                    .padding(.top, 12)
                }

                if readingMode == .companion || inlineAIUnavailable {
                    inlineModeStatusBar
                }

                HStack(spacing: 0) {
                    if isTocOpen {
                        MacTOCPanel(
                            bookTitle: epub.metadata.title,
                            titles: sectionTitles,
                            cnTitles: tocTitleTranslations,
                            currentIndex: currentChapterIndex,
                            intraChapterFraction: intraChapterFraction,
                            progressByChapter: pretransProgress,
                            statsTick: cacheStatsTick,
                            book: book,
                            onSelect: { index in
                                guard index != currentChapterIndex else { return }
                                currentChapterIndex = index
                                currentUTF16Offset = 0
                                chapterLanding = .start
                                resetChapterArtifacts()
                            },
                            onClose: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isTocOpen = false
                                }
                            },
                            onJump: { position in
                                jumpToHighlight(position)
                            }
                        )
                        .frame(width: 272)
                        .transition(.move(edge: .leading))
                        Rectangle().fill(palette.line).frame(width: 1)
                    }

                    VStack(spacing: 0) {
                        ZStack(alignment: .bottom) {
                            Group {
                                if pageTurn == .paged {
                                    MacPagedChapterReaderView(
                                        chapter: displayChapter(epub.chapters[currentChapterIndex]),
                                        basePath: epub.basePath,
                                        fontSize: fontSize,
                                        lineSpacing: lineSpacing,
                                        landing: chapterLanding,
                                        resumeUTF16Offset: resumeUTF16Offset,
                                        chapterPlainText: displayChapterPlainText(),
                                        highlights: chapterHighlights,
                                        inlineMode: inlineNoteKind,
                                        inlineNotes: inlineNotes,
                                        appearance: readerAppearance,
                                        selectionActive: pendingSelection != nil,
                                        onTap: { pendingSelection = nil },
                                        onChapterBoundary: { direction in
                                            crossChapterBoundary(direction, chapterCount: epub.chapters.count)
                                        },
                                        onSelectionChange: { applySelection($0) },
                                        onPositionChange: { updateUTF16Offset(domPrefix: $0) },
                                        onVisibleParagraphs: { handleVisibleParagraphs($0) },
                                        onPageInfo: { page, count in
                                            chapterPageInfo = (page: page, count: count)
                                        }
                                    )
                                } else {
                                    NativeChapterReaderView(
                                        chapter: displayChapter(epub.chapters[currentChapterIndex]),
                                        basePath: epub.basePath,
                                        fontSize: fontSize,
                                        lineSpacing: lineSpacing,
                                        landing: chapterLanding,
                                        resumeUTF16Offset: resumeUTF16Offset,
                                        chapterPlainText: displayChapterPlainText(),
                                        highlights: chapterHighlights,
                                        inlineMode: inlineNoteKind,
                                        inlineLayout: readingMode == .bilingual ? .parallel : .stacked,
                                        inlineNotes: inlineNotes,
                                        appearance: readerAppearance,
                                        speechRange: aloud.currentSentenceRange,
                                        selectionActive: pendingSelection != nil,
                                        onTap: { pendingSelection = nil },
                                        onChapterBoundary: { direction in
                                            crossChapterBoundary(direction, chapterCount: epub.chapters.count)
                                        },
                                        onSelectionChange: { applySelection($0) },
                                        onPositionChange: { updateUTF16Offset(domPrefix: $0) },
                                        onVisibleParagraphs: { handleVisibleParagraphs($0) },
                                        onPageInfo: { page, count in
                                            chapterPageInfo = (page: page, count: count)
                                        }
                                    )
                                }
                            }
                            .id(currentChapterIndex)

                            selectionOverlay
                        }
                        .environment(\.emptyPalette, readerTheme.palette(base: palette))
                        Rectangle().fill(palette.line).frame(height: 1)
                        bottomBar(epub)
                            .opacity(chromeHidden ? 0 : 1)
                            .allowsHitTesting(!chromeHidden)
                    }

                    if isCompanionOpen {
                        Rectangle().fill(palette.line).frame(width: 1)
                        MacCompanionPanel(
                            model: companion,
                            book: book,
                            bookTitle: epub.metadata.title,
                            chapterTitle: epub.chapters[currentChapterIndex].title,
                            highlightCount: book.highlights?.count ?? 0,
                            position: currentReadingPosition,
                            onClose: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isCompanionOpen = false
                                }
                            }
                        )
                        .frame(width: 360)
                        .transition(.move(edge: .trailing))
                    }
                }
            }

            if aloud.isSpeaking || !aloud.currentSnippet.isEmpty {
                MacReadingAloudBar(
                    snippet: aloud.currentSnippet,
                    onToggle: { aloud.togglePause() },
                    isPaused: !aloud.isSpeaking,
                    rate: aloud.rate,
                    onCycleRate: { cycleAloudRate() },
                    autoNext: aloudAutoNext,
                    onToggleAutoNext: { aloudAutoNext.toggle() }
                )
                .padding(.bottom, 22)
            }
        }
        .sheet(isPresented: $showSettings) {
            ReadingSettingsView(
                fontSize: $fontSize,
                lineSpacing: $lineSpacing,
                theme: $readerTheme,
                font: $readerFont,
                contentWidth: $readerContentWidth,
                firstLineIndent: $readerFirstLineIndent,
                paragraphSpacing: $readerParagraphSpacing,
                textAlignment: $readerTextAlignment,
                chapterOpening: $readerChapterOpening,
                pageTurn: $pageTurn,
                bookID: book.id
            )
            .frame(minWidth: 340, minHeight: 460)
        }
        .sheet(isPresented: $showRecap) {
            RecapView(
                book: book,
                position: currentReadingPosition,
                cache: $recapCache
            )
            .frame(minWidth: 440, minHeight: 480)
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
                applySelection(selection)
            }
        }
        .sheet(isPresented: $showHighlights) {
            HighlightsListView(book: book) { position in
                jumpToHighlight(position)
            }
            .frame(minWidth: 420, minHeight: 460)
        }
        .sheet(item: $selectionInsight) { insight in
            SelectionInsightSheet(insight: insight) {
                Button("继续追问 ↩") {
                    selectionInsight = nil
                    askAboutSelection(insight.subject)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(palette.accent, lineWidth: 1))

                Button(selectionInsightSaved ? "✓ 已存为卡片" : "存为卡片") {
                    saveSelectionInsightCard()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(selectionInsightSaved ? palette.accent : palette.ink3)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
                .disabled(selectionInsightSaved)
            }
        }
        .onChange(of: currentChapterIndex) { _, newIndex in
            // Load the target chapter's XHTML on demand. Only the current
            // chapter is kept in memory, so large EPUBs don't bloat the heap.
            if var book = epubBook, book.chapters.indices.contains(newIndex) {
                book.loadContent(forChapterAt: newIndex)
                epubBook = book
            }
            pendingSelection = nil
            refreshChapterHighlights()
            resetChapterArtifacts()
            refreshBookmarkState()
            Task { await loadChapterSummary() }
            // Shift the 预译 window (current + next two chapters).
            startPretranslation()
        }
        .onChange(of: traditionalChinese) { _, _ in
            traditionalCache.values = [:]
            inlineNotes = []
        }
        .onChange(of: readingMode) { _, newMode in
            // The chapter page clears and re-requests notes for the new
            // mode; cached translations rejoin instantly.
            inlineNotes = []
            inlineAIUnavailable = newMode != .original
                && !AIProviderRegistry.load().resolveUsableService(feature: .translate)
                    .service.availability.isAvailable
            startPretranslation()
        }
        .onChange(of: showHighlights) { _, isShowing in
            if !isShowing { refreshChapterHighlights() }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active = phase {
                wakeChrome()
            }
        }
        .onChange(of: immersionBlocked) { _, blocked in
            if blocked {
                chromeTimer.cancel()
                if chromeHidden {
                    withAnimation(.easeInOut(duration: 0.25)) { chromeHidden = false }
                }
            } else {
                wakeChrome()
            }
        }
        .onDisappear {
            pretransTask?.cancel()
            chromeTimer.cancel()
        }
    }

    /// Thin status line under the top bar for 导读 progress or an
    /// unavailable provider (双语对照 reports through the top-bar chip).
    private var inlineModeStatusBar: some View {
        HStack(spacing: 8) {
            if inlineAIUnavailable {
                Text("朱 · AI 暂不可用 — 在侧栏「AI 状态」配置后,\(Self.translationKind(for: readingMode) == .bilingual ? "今译" : inlineNoteKind.label)会随阅读逐段出现。")
                    .foregroundStyle(palette.accent)
            } else if !inlineInFlight.isEmpty {
                ProgressView()
                    .controlSize(.small)
                Text("正在逐段生成导读…")
                    .foregroundStyle(palette.ink3)
            } else {
                Text("导读 · 朱批随阅读逐段展开")
                    .foregroundStyle(palette.ink3)
            }
            Spacer()
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var pdfReaderContent: some View {
        if let documentURL = pdfDocumentURL {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    pdfTopBar
                    Rectangle().fill(palette.line).frame(height: 1)

                    if summaryOpen {
                        if isSummaryLoading {
                            ProgressView("生成页面概览…")
                                .padding()
                        } else if !chapterSummary.isEmpty {
                            MacChapterSummaryCard(
                                title: currentSectionTitle,
                                summary: chapterSummary,
                                onCollapse: { summaryOpen = false }
                            )
                        }
                    } else {
                        Button("朱 · 展开页面概览") {
                            summaryOpen = true
                            Task { await loadChapterSummary() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.ink3)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .overlay(
                            Capsule().strokeBorder(palette.line2, style: StrokeStyle(dash: [4, 3]))
                        )
                        .padding(.top, 12)
                    }

                    if readingMode != .original {
                        modeGuideBanner
                    }

                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            ZStack(alignment: .bottom) {
                                PDFReaderView(
                                    documentURL: documentURL,
                                    pageIndex: $currentChapterIndex,
                                    highlights: chapterHighlights,
                                    nightInverted: pdfNightInverted,
                                    zoomMemoryKey: "pdf.zoom.\(book.id.uuidString)",
                                    twoUp: pdfTwoUp,
                                    autoCrop: pdfAutoCrop,
                                    onPageChange: syncPageProgress,
                                    onSelectionChange: { applySelection($0) }
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                                selectionOverlay
                            }

                            Rectangle().fill(palette.line).frame(height: 1)
                            pdfBottomBar
                        }

                        if isCompanionOpen {
                            Rectangle().fill(palette.line).frame(width: 1)
                            MacCompanionPanel(
                                model: companion,
                                book: book,
                                bookTitle: book.title,
                                chapterTitle: currentSectionTitle,
                                highlightCount: book.highlights?.count ?? 0,
                                position: currentReadingPosition,
                                onClose: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isCompanionOpen = false
                                    }
                                }
                            )
                            .frame(width: 360)
                            .transition(.move(edge: .trailing))
                        }
                    }
                }

                if aloud.isSpeaking || !aloud.currentSnippet.isEmpty {
                    MacReadingAloudBar(
                        snippet: aloud.currentSnippet,
                        onToggle: { aloud.togglePause() },
                        isPaused: !aloud.isSpeaking,
                        rate: aloud.rate,
                        onCycleRate: { cycleAloudRate() },
                        autoNext: aloudAutoNext,
                        onToggleAutoNext: { aloudAutoNext.toggle() }
                    )
                    .padding(.bottom, 22)
                }
            }
            .sheet(isPresented: $showChapterList) {
                ChapterListView(
                    titles: sectionTitles,
                    unitLabel: "页",
                    currentIndex: currentChapterIndex,
                    onSelect: { index in
                        currentChapterIndex = index
                        syncPageProgress(at: index)
                        showChapterList = false
                        resetChapterArtifacts()
                    }
                )
                .frame(minWidth: 380, minHeight: 460)
            }
            .sheet(isPresented: $showSettings) {
                ReadingSettingsView(
                    fontSize: $fontSize,
                    lineSpacing: $lineSpacing,
                    theme: $readerTheme,
                    font: $readerFont,
                    contentWidth: $readerContentWidth,
                    firstLineIndent: $readerFirstLineIndent,
                    paragraphSpacing: $readerParagraphSpacing,
                    textAlignment: $readerTextAlignment,
                    chapterOpening: $readerChapterOpening,
                    pageTurn: $pageTurn,
                    bookID: book.id
                )
                .frame(minWidth: 340, minHeight: 460)
            }
            .sheet(isPresented: $showRecap) {
                RecapView(
                    book: book,
                    position: currentReadingPosition,
                    cache: $recapCache
                )
                .frame(minWidth: 440, minHeight: 480)
            }
            .sheet(isPresented: $showHighlights) {
                HighlightsListView(book: book) { position in
                    jumpToHighlight(position)
                }
                .frame(minWidth: 420, minHeight: 460)
            }
            .onChange(of: currentChapterIndex) { _, newIndex in
                syncPageProgress(at: newIndex)
                resetChapterArtifacts()
                Task {
                    await loadChapterSummary()
                    await loadModeGuide()
                }
            }
            .onChange(of: readingMode) { _, _ in
                Task { await loadModeGuide() }
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

    private var readerAppearance: ReaderAppearance {
        ReaderAppearance(
            theme: readerTheme,
            font: readerFont,
            contentWidth: readerContentWidth,
            firstLineIndent: readerFirstLineIndent,
            paragraphSpacing: readerParagraphSpacing,
            textAlignment: readerTextAlignment,
            chapterOpening: readerChapterOpening
        )
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

    private func jumpToHighlight(_ position: ReadingPosition) {
        if pdfDocumentURL != nil {
            currentChapterIndex = position.chapterIndex
            syncPageProgress(at: position.chapterIndex)
        } else {
            currentChapterIndex = position.chapterIndex
            currentUTF16Offset = position.utf16Offset
            chapterLanding = .start
            refreshChapterHighlights()
        }
    }

    private var pdfTopBar: some View {
        HStack(spacing: 14) {
            Button {
                saveProgress()
                onBack()
            } label: {
                Text("‹ 书库")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.ink3)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(book.title)
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text(currentSectionTitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
            }

            Spacer()

            MacSegmentedPills(
                options: [
                    (.original, "原文"),
                    (.bilingual, "今译"),
                    (.companion, "导读"),
                    (.debate, "辩难"),
                    (.sources, "文献"),
                ],
                selection: $readingMode
            )

            Button(action: onOpenVocab) {
                Text("生词本 \(vocabEntries.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button { toggleReadingAloud() } label: {
                Text(aloud.isSpeaking ? "❚❚ 朗读" : "▶ 朗读")
                    .font(.system(size: 12.5))
                    .foregroundStyle(aloud.isSpeaking ? palette.accent : palette.ink2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)

            pillButton("目录", identifier: "reader.chapterList") { showChapterList = true }
            pillButton("高亮", identifier: "reader.highlights") { showHighlights = true }
            pillButton("设置", identifier: "reader.settings") { showSettings = true }

            Button {
                toggleBookmark()
            } label: {
                Image(systemName: bookmarkedHere ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 12))
                    .foregroundStyle(bookmarkedHere ? palette.accent : palette.ink2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("d", modifiers: .command)
            .help("书签（⌘D）")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCompanionOpen.toggle()
                }
            } label: {
                Text("朱 · AI 伴读")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(isCompanionOpen ? palette.onAccent : palette.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        isCompanionOpen ? palette.accent : palette.accentSoft,
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .frame(height: 58)
    }

    private var pdfBottomBar: some View {
        HStack(spacing: 18) {
            Button {
                guard currentChapterIndex > 0 else { return }
                currentChapterIndex -= 1
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(currentChapterIndex > 0 ? palette.ink2 : palette.ink3.opacity(0.4))
            .disabled(currentChapterIndex <= 0)

            Text("第 \(currentChapterIndex + 1) / \(sectionCount) 页")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(palette.ink3)

            Button {
                guard currentChapterIndex < sectionCount - 1 else { return }
                currentChapterIndex += 1
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                currentChapterIndex < sectionCount - 1
                    ? palette.ink2 : palette.ink3.opacity(0.4)
            )
            .disabled(currentChapterIndex >= sectionCount - 1)

            Spacer()

            let chapterCount = Double(max(sectionCount, 1))
            let chapterLength = Double(
                currentChapterPlainText()?.utf16.count ?? 1
            )
            let intraChapter = chapterLength > 0
                ? Double(currentUTF16Offset) / chapterLength
                : 0
            let progress = min(
                1,
                (Double(currentChapterIndex) + intraChapter) / chapterCount
            )
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(palette.accent)
                .frame(maxWidth: 220)
            Text("\(Int(progress * 100))%")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(palette.ink3)
        }
        .padding(.horizontal, 24)
        .frame(height: 44)
    }

    /// Floating cards over the reading surface: vocab gloss, thought link,
    /// and the selection action popover. Explain / translate results now open
    /// in a sheet so long answers never cover正文.
    private var selectionOverlay: some View {
        VStack(spacing: 12) {

            if let glossEntry {
                glossCard(glossEntry)
                    .padding(.horizontal, 24)
            }

            if !thoughtLinks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(thoughtLinks) { link in
                        MacThoughtLinkCard(
                            link: link,
                            isExpanded: expandedThoughtLinkIDs.contains(link.id),
                            isSaved: savedThoughtLinkIDs.contains(link.id),
                            onToggle: { toggleThoughtLink(link) },
                            onOpenNotes: onOpenNotes,
                            onSaveLink: { saveThoughtLinkCard(link) },
                            onAsk: { askAboutSelection(link.explanation) },
                            onDismiss: { dismissThoughtLink(link) }
                        )
                    }
                }
            }

            if pendingSelection != nil {
                MacSelectionPopover(
                    onExplain: { runSelectionAction(.explain) },
                    onTranslate: { runSelectionAction(.translate) },
                    onAsk: { runSelectionAction(.ask) },
                    onExpandSelection: { showChapterSelection = true },
                    onHighlight: { saveHighlight(color: $0) },
                    onCopy: copySelection,
                    onDictionary: lookUpSelectionInDictionary,
                    onVocab: { runSelectionAction(.vocab) },
                    isLoading: isSelectionWorking
                )
                .padding(.bottom, 8)
            }
        }
        .padding(.bottom, 20)
    }

    private var modeGuideBanner: some View {
        Group {
            if isGuideLoading {
                ProgressView(readingMode.lensMode?.guideLoadingText ?? "生成导读…")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            } else if !modeGuideText.isEmpty {
                ZhupiCallout(title: readingMode.lensMode?.guideTitle ?? inlineNoteKind.label) {
                    Text(modeGuideText)
                        .font(.system(size: 13.5))
                        .lineSpacing(6)
                        .foregroundStyle(palette.ink2)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
        }
    }

    private func glossCard(_ entry: VocabEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.word)
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundStyle(palette.ink)
                if let phonetic = entry.phonetic {
                    Text(phonetic)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.ink3)
                }
                if let pos = entry.partOfSpeech {
                    Text(pos)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.ink3)
                }
                Spacer()
                Text("✓ 已入生词本")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(palette.accentSoft, in: Capsule())
            }
            Text(entry.meaning)
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundStyle(palette.ink2)
            if let note = entry.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.ink3)
            }
        }
        .padding(12)
        .emptyCard(palette, radius: 12)
    }

    // MARK: Bars

    private func topBar(_ epub: EPUBBook) -> some View {
        HStack(spacing: 14) {
            Button {
                saveProgress()
                onBack()
            } label: {
                Text("‹ 书库")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.ink3)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isTocOpen.toggle()
                }
            } label: {
                Text("☰ 目录")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isTocOpen ? palette.accent : palette.ink3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        isTocOpen ? palette.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(epub.metadata.title)
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text(epub.chapters[currentChapterIndex].title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
            }

            Spacer()

            MacSegmentedPills(
                options: [
                    (.original, "原文"),
                    (.bilingual, "今译"),
                    (.companion, "导读"),
                    (.debate, "辩难"),
                    (.sources, "文献"),
                ],
                selection: $readingMode
            )

            if readingMode == .bilingual, let chip = translationCacheChip {
                Text(chip)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(palette.accentSoft, in: Capsule())
            }

            Button(action: onOpenVocab) {
                Text("生词本 \(vocabEntries.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button {
                toggleReadingAloud()
            } label: {
                HStack(spacing: 6) {
                    Text(aloud.isSpeaking ? "❚❚ 朗读" : "▶ 朗读")
                }
                .font(.system(size: 12.5))
                .foregroundStyle(aloud.isSpeaking ? palette.accent : palette.ink2)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)

            pillButton("高亮", identifier: "reader.highlights") { showHighlights = true }
            pillButton("设置", identifier: "reader.settings") { showSettings = true }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCompanionOpen.toggle()
                }
            } label: {
                Text("朱 · AI 伴读")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(isCompanionOpen ? palette.onAccent : palette.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        isCompanionOpen ? palette.accent : palette.accentSoft,
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .frame(height: 58)
    }

    /// "✓ 本章译文已缓存 · 翻页零等待" once the chapter is fully cached;
    /// progress while the pretranslator is working on it.
    private var translationCacheChip: String? {
        if currentChapterRecord?.pretranslatedAt != nil {
            return "✓ 本章译文已缓存 · 翻页零等待"
        }
        if case .translating(let done, let total) = pretransProgress[currentChapterIndex],
           total > 0 {
            return "⟳ 预译中 \(Int(Double(done) / Double(total) * 100))% · 翻页不等待"
        }
        return nil
    }

    private func pillButton(
        _ title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(palette.ink2)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func bottomBar(_ epub: EPUBBook) -> some View {
        HStack(spacing: 18) {
            Button {
                guard currentChapterIndex > 0 else { return }
                currentChapterIndex -= 1
                currentUTF16Offset = 0
                chapterLanding = .start
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(currentChapterIndex > 0 ? palette.ink2 : palette.ink3.opacity(0.4))
            .disabled(currentChapterIndex <= 0)

            Text("第 \(currentChapterIndex + 1) / \(epub.chapters.count) 章")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(palette.ink3)

            Button {
                guard currentChapterIndex < epub.chapters.count - 1 else { return }
                currentChapterIndex += 1
                currentUTF16Offset = 0
                chapterLanding = .start
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                currentChapterIndex < epub.chapters.count - 1
                    ? palette.ink2 : palette.ink3.opacity(0.4)
            )
            .disabled(currentChapterIndex >= epub.chapters.count - 1)

            if let info = chapterPageInfo, info.count > 1 {
                Text("本章还剩 \(max(info.count - info.page - 1, 0)) 页")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(palette.ink3)
            }

            Spacer()

            let chapterCount = Double(max(epub.chapters.count, 1))
            let chapterLength = Double(
                currentChapterPlainText()?.utf16.count ?? 1
            )
            let intraChapter = chapterLength > 0
                ? Double(currentUTF16Offset) / chapterLength
                : 0
            let progress = min(
                1,
                (Double(currentChapterIndex) + intraChapter) / chapterCount
            )
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(palette.accent)
                .frame(maxWidth: 220)
            Text("\(Int(progress * 100))%")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(palette.ink3)
        }
        .padding(.horizontal, 24)
        .frame(height: 44)
    }

    // MARK: Selection actions

    private enum SelectionAction {
        case explain, translate, ask, vocab
    }

    private func runSelectionAction(_ action: SelectionAction) {
        guard let selection = pendingSelection else { return }
        isSelectionWorking = true
        Task {
            defer { isSelectionWorking = false }
            do {
                let resolution = AIProviderRegistry.load().resolveUsableService(feature: .chat)
                let service = resolution.service
                let source = chapterSourceLabel

                switch action {
                case .explain, .translate:
                    let kind: SelectionInsightKind = action == .explain ? .explain : .translate
                    let answer = try await service.answer(
                        question: kind.question(for: selection),
                        groundedIn: [GroundedPassage(id: 0, text: kind.groundedText(for: selection))]
                    )
                    selectionInsight = .make(
                        kind: kind,
                        subject: selection.text,
                        body: answer.text
                    )
                    selectionInsightSaved = false
                    pendingSelection = nil
                case .ask:
                    askAboutSelection(selection.text)
                case .vocab:
                    let word = selection.text
                        .components(separatedBy: .whitespacesAndNewlines)
                        .first { !$0.isEmpty } ?? selection.text
                    let entry = try await VocabStore(modelContext: modelContext)
                        .lookupWithAI(
                            word: word,
                            sentence: selection.text,
                            source: source,
                            book: book,
                            sourcePosition: currentReadingPosition
                        )
                    glossEntry = entry
                }
            } catch {
                if action == .explain || action == .translate {
                    let kind: SelectionInsightKind = action == .translate ? .translate : .explain
                    selectionInsight = .make(
                        kind: kind,
                        subject: selection.text,
                        body: "出错了：\(error.localizedDescription)"
                    )
                    selectionInsightSaved = false
                }
                pendingSelection = nil
            }
        }
    }

    private func askAboutSelection(_ text: String) {
        withAnimation { isCompanionOpen = true }
        companion.draft = CompanionModel.followUpQuestion(about: text)
        companion.draftFocusText = text
        companion.send(
            book: book,
            position: currentReadingPosition,
            modelContext: modelContext
        )
    }

    private var chapterSourceLabel: String {
        let title = epubBook?.metadata.title ?? book.title
        let unit = pdfDocumentURL != nil ? "页" : "章"
        return "\(title) · 第 \(currentChapterIndex + 1) \(unit)"
    }

    // MARK: AI chapter artifacts

    private func resetChapterArtifacts() {
        chapterSummary = ""
        chapterOutline = nil
        chapterPageInfo = nil
        modeGuideText = ""
        thoughtLinks = []
        expandedThoughtLinkIDs.removeAll()
        savedThoughtLinkIDs.removeAll()
        selectionInsight = nil
        selectionInsightSaved = false
        glossEntry = nil
        pendingSelection = nil
        showChapterSelection = false
        inlineNotes = []
    }

    private func loadChapterSummary() async {
        guard summaryOpen else { return }
        isSummaryLoading = true
        defer { isSummaryLoading = false }

        // EPUB chapters get the structured three-part outline; PDF pages
        // are too short for one and keep the flat digest.
        if epubBook != nil {
            await loadChapterOutline()
        }

        if let cached = currentChapterRecord?.cachedSummary, !cached.isEmpty {
            chapterSummary = cached
            return
        }
        guard let text = currentChapterRecord?.text, !text.isEmpty else { return }
        do {
            let resolution = AIProviderRegistry.load().resolveUsableService(feature: .recap)
            let summary = try await resolution.service.summarize(
                String(text.prefix(6_000)),
                focus: .digest
            )
            chapterSummary = summary
            if let chapter = currentChapterRecord {
                chapter.cachedSummary = summary
                try? modelContext.save()
            }
        } catch {
            chapterSummary = "章节概览暂不可用 — \(error.localizedDescription)"
        }
    }

    /// Loads (or generates and caches) the three-part chapter outline that
    /// upgrades the overview card from a flat digest to the prototype's
    /// ① ② ③ grid.
    private func loadChapterOutline() async {
        if let cached = currentChapterRecord?.cachedOutline,
           let outline = ChapterOutline.parse(cached) {
            chapterOutline = outline
            return
        }
        guard let text = currentChapterRecord?.text, !text.isEmpty else { return }
        let resolution = AIProviderRegistry.load().resolveUsableService(feature: .recap)
        guard resolution.service.availability.isAvailable else { return }
        do {
            let answer = try await resolution.service.answer(
                question: ChapterOutline.prompt,
                groundedIn: [GroundedPassage(id: 0, text: String(text.prefix(6_000)))]
            )
            guard let outline = ChapterOutline.parse(answer.text) else { return }
            chapterOutline = outline
            if let chapter = currentChapterRecord {
                chapter.cachedOutline = outline.serialized
                try? modelContext.save()
            }
        } catch {
            // The flat summary remains the fallback.
        }
    }

    // MARK: Inline notes (双语对照 / 导读)

    private func inlineKey(_ mode: MacReadingMode, _ chapter: Int, _ idx: Int) -> String {
        "\(mode.rawValue)|\(chapter)|\(idx)"
    }

    private var translationKind: TranslationKind {
        readingMode.lensMode?.translationKind ?? .bilingual
    }

    private static func translationKind(for mode: MacReadingMode) -> TranslationKind {
        mode.lensMode?.translationKind ?? .bilingual
    }

    private static func aiNoteKind(for mode: MacReadingMode) -> AIInlineNoteKind {
        mode.lensMode?.aiNoteKind ?? .bilingual
    }

    /// Called whenever the chapter page reports the paragraphs the reader
    /// is looking at. Resolution order: in-memory → persistent cache
    /// (instant, the 「不重复翻译」 rule) → AI, in reading order.
    private func handleVisibleParagraphs(_ paragraphs: [ReaderParagraph]) {
        guard readingMode != .original else { return }
        let mode = readingMode
        let chapter = currentChapterIndex
        let store = TranslationStore(modelContext: modelContext)
        let language = LanguageSettings.effective(for: book.id)
        var missing: [ReaderParagraph] = []
        for paragraph in paragraphs {
            // 同语言跳过 (always on): a paragraph already in the target
            // language gets no 译块. Detection is per-paragraph, so a
            // mixed-language book's quotes each decide for themselves.
            if mode == .bilingual,
               LanguageDetect.matchesTarget(
                textLanguage: LanguageDetect.sourceLanguage(of: paragraph.text, settings: language),
                target: language.target
               ) {
                continue
            }
            let key = inlineKey(mode, chapter, paragraph.idx)
            if let cached = inlineCache[key] {
                if !cached.isEmpty {
                    if !inlineNotes.contains(where: { $0.idx == paragraph.idx }) {
                        inlineNotes.append(InlineNotePaint(idx: paragraph.idx, text: cached))
                    }
                } else if inlineRetryCounts[key, default: 0] < 3,
                          !inlineInFlight.contains(key) {
                    // An empty/errored result is not a verdict — retry the
                    // paragraph while it's on screen (capped per visit).
                    inlineInFlight.insert(key)
                    missing.append(paragraph)
                }
            } else if let persisted = store.lookup(
                bookID: book.id,
                kind: translationKind,
                text: paragraph.text,
                target: language.target
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
        Task { await translateParagraphs(missing, mode: mode, chapter: chapter) }
    }

    private func translateParagraphs(
        _ paragraphs: [ReaderParagraph],
        mode: MacReadingMode,
        chapter: Int
    ) async {
        let resolution = AIProviderRegistry.load().resolveUsableService(feature: .translate)
        guard resolution.service.availability.isAvailable else {
            for paragraph in paragraphs {
                inlineInFlight.remove(inlineKey(mode, chapter, paragraph.idx))
            }
            return
        }
        let inlineKind = Self.aiNoteKind(for: mode)
        let kind = Self.translationKind(for: mode)
        let language = LanguageSettings.effective(for: book.id)
        for paragraph in paragraphs {
            let key = inlineKey(mode, chapter, paragraph.idx)
            defer { inlineInFlight.remove(key) }
            // Reader moved on — skip the model call, leave it uncached.
            guard readingMode == mode, currentChapterIndex == chapter else { continue }
            do {
                let text = try await AITransientRetry.run {
                    try await resolution.service.inlineNote(
                        for: paragraph.text,
                        kind: inlineKind,
                        targetLanguage: language.target
                    )
                }.trimmingCharacters(in: .whitespacesAndNewlines)
                // Echoes (same-language "translations") and the 今译
                // sentinel never paint — and never improve on retry.
                guard InlineNoteQuality.isWorthShowing(note: text, original: paragraph.text) else {
                    inlineCache[key] = ""
                    inlineRetryCounts[key] = 3
                    continue
                }
                inlineCache[key] = text
                TranslationStore(modelContext: modelContext).store(
                    text,
                    bookID: book.id,
                    chapterIndex: chapter,
                    kind: kind,
                    text: paragraph.text,
                    target: language.target
                )
                cacheStatsTick += 1
                if readingMode == mode, currentChapterIndex == chapter {
                    inlineNotes.removeAll { $0.idx == paragraph.idx }
                    inlineNotes.append(InlineNotePaint(idx: paragraph.idx, text: text))
                }
            } catch {
                // Busy/rate-limited providers are common while 导读, summary,
                // and pre-translation compete. Let the paragraph retry on the
                // next settled viewport report instead of painting a scary
                // permanent failure marker.
                guard !AITransientRetry.isTransient(error) else { continue }
                inlineCache[key] = ""
                inlineRetryCounts[key, default: 0] += 1
                if readingMode == mode, currentChapterIndex == chapter {
                    inlineNotes.removeAll { $0.idx == paragraph.idx }
                    inlineNotes.append(
                        InlineNotePaint(idx: paragraph.idx, text: "", failed: true)
                    )
                }
            }
        }
    }

    // MARK: 预译 (pre-translation, never blocking)

    /// Pre-caches the current and next two chapters for the active inline
    /// lens. 双语 still gets the durable TOC/title path; 导读 / 辩难 / 文献
    /// only warm paragraph caches.
    private func startPretranslation() {
        pretransTask?.cancel()
        pretransProgress = [:]
        guard readingMode != .original, epubBook != nil else { return }
        let chapter = currentChapterIndex
        pretransTask = Task { await pretranslate(from: chapter) }
    }

    private func pretranslate(from startChapter: Int) async {
        guard let lens = readingMode.lensMode else { return }
        let resolution = AIProviderRegistry.load().resolveUsableService(feature: .translate)
        guard resolution.service.availability.isAvailable else { return }
        // Whole-chapter pretranslation saturates the machine when the
        // model runs locally — reading janks. On-device stays
        // per-viewport; only cloud providers cache ahead.
        guard !resolution.provider.isLocal else { return }
        let mode = readingMode
        let store = TranslationStore(modelContext: modelContext)
        let bookID = book.id
        let language = LanguageSettings.effective(for: bookID)
        let chapters = (try? modelContext.fetch(
            FetchDescriptor<Chapter>(
                predicate: #Predicate { $0.bookID == bookID },
                sortBy: [SortDescriptor(\.index)]
            )
        )) ?? []

        if lens.pretranslatesTitles {
            // Chapter titles first — they make the TOC bilingual and cost
            // almost nothing.
            for chapter in chapters.prefix(50) {
                guard !Task.isCancelled, readingMode == mode else { return }
                guard let title = chapter.title,
                      !title.isEmpty,
                      tocTitleTranslations[chapter.index] == nil else { continue }
                if let cached = store.lookup(
                    bookID: bookID, kind: .title, text: title, target: language.target
                ) {
                    tocTitleTranslations[chapter.index] = cached
                    continue
                }
                guard let note = try? await resolution.service.inlineNote(
                    for: title,
                    kind: .bilingual,
                    targetLanguage: language.target
                ) else { continue }
                let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                store.store(
                    text,
                    bookID: bookID,
                    chapterIndex: chapter.index,
                    kind: .title,
                    text: title,
                    target: language.target
                )
                tocTitleTranslations[chapter.index] = text
            }
        }

        // Then paragraphs of the reading window.
        let window = chapters.filter {
            $0.index >= startChapter && $0.index < startChapter + 3
        }
        if lens.pretranslatesTitles {
            for chapter in window where chapter.pretranslatedAt == nil {
                pretransProgress[chapter.index] = .queued
            }
        }
        for chapter in window {
            guard !Task.isCancelled, readingMode == mode else { return }
            // Even chapters stamped pretranslated can carry holes (a
            // provider hiccup skipped paragraphs in an earlier pass) —
            // the cheap local lookups below re-check and backfill them.
            let paragraphs = TranslationStore.paragraphs(in: chapter.text)
            let missing = paragraphs.filter { paragraph in
                if lens.skipsTargetLanguageParagraphs,
                   LanguageDetect.matchesTarget(
                    textLanguage: LanguageDetect.sourceLanguage(of: paragraph, settings: language),
                    target: language.target
                   ) { return false }
                return store.lookup(
                    bookID: bookID,
                    kind: lens.translationKind,
                    text: paragraph,
                    target: language.target
                ) == nil
            }
            guard !missing.isEmpty else {
                if lens.pretranslatesTitles, chapter.pretranslatedAt == nil {
                    chapter.pretranslatedAt = Date()
                    try? modelContext.save()
                }
                pretransProgress[chapter.index] = nil
                continue
            }
            var done = paragraphs.count - missing.count
            if lens.pretranslatesTitles {
                pretransProgress[chapter.index] = .translating(done: done, total: paragraphs.count)
            }
            for paragraph in missing {
                guard !Task.isCancelled, readingMode == mode else { return }
                if let note = try? await resolution.service.inlineNote(
                    for: paragraph,
                    kind: lens.aiNoteKind,
                    targetLanguage: language.target
                ) {
                    let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    if lens.shouldStore(note: text, original: paragraph) {
                        store.store(
                            text,
                            bookID: bookID,
                            chapterIndex: chapter.index,
                            kind: lens.translationKind,
                            text: paragraph,
                            target: language.target
                        )
                    }
                }
                done += 1
                if lens.pretranslatesTitles {
                    pretransProgress[chapter.index] = .translating(done: done, total: paragraphs.count)
                }
            }
            if lens.pretranslatesTitles {
                chapter.pretranslatedAt = Date()
                try? modelContext.save()
                pretransProgress[chapter.index] = nil
            }
            cacheStatsTick += 1
        }
    }

    // MARK: Saved cards

    /// 朱批边注 → 问答卡 in the notes screen.
    private func saveSelectionInsightCard() {
        guard let selectionInsight, !selectionInsightSaved else { return }
        let subject = selectionInsight.subject.prefix(80)
        let card = StudyCardEntry(
            question: "\(selectionInsight.title):\(subject)",
            answer: selectionInsight.body,
            source: chapterSourceLabel,
            kind: .qa
        )
        card.setSourcePosition(currentReadingPosition)
        card.book = book
        modelContext.insert(card)
        try? modelContext.save()
        selectionInsightSaved = true
    }

    /// 思维链接 → 链接卡 in the notes screen.
    private func saveThoughtLinkCard(_ link: ThoughtLink) {
        guard !savedThoughtLinkIDs.contains(link.id) else { return }
        let card = StudyCardEntry(
            question: "「\(link.currentText.prefix(60))」 ⟷ 「\(link.relatedText.prefix(60))」",
            answer: link.explanation,
            source: "\(link.currentSource) ⟷ \(link.relatedSource)",
            kind: .link
        )
        card.setSourcePosition(currentReadingPosition)
        card.book = book
        modelContext.insert(card)
        try? modelContext.save()
        savedThoughtLinkIDs.insert(link.id)
    }

    private func loadModeGuide() async {
        guard let lens = readingMode.lensMode else {
            modeGuideText = ""
            return
        }
        isGuideLoading = true
        defer { isGuideLoading = false }
        guard let text = currentChapterRecord?.text, !text.isEmpty else { return }
        do {
            let resolution = AIProviderRegistry.load().resolveUsableService(feature: .recap)
            let clipped = String(text.prefix(4_000))
            modeGuideText = try await AITransientRetry.run {
                try await resolution.service.inlineNote(
                    for: clipped,
                    kind: lens.aiNoteKind,
                    targetLanguage: LanguageSettings.effective(for: book.id).target
                )
            }
        } catch {
            modeGuideText = "\(lens.guideTitle)暂不可用 — \(error.localizedDescription)"
        }
    }

    private func applySelection(_ selection: ReaderSelection?) {
        pendingSelection = selection
        selectionInsight = nil
        glossEntry = nil
        if let selection {
            Task { await detectThoughtLink(for: selection.text) }
        }
    }

    private func toggleThoughtLink(_ link: ThoughtLink) {
        if expandedThoughtLinkIDs.contains(link.id) {
            expandedThoughtLinkIDs.remove(link.id)
        } else {
            expandedThoughtLinkIDs.insert(link.id)
        }
    }

    private func dismissThoughtLink(_ link: ThoughtLink) {
        if let highlightID = link.relatedHighlightID {
            ThoughtLinkFeedback.dismiss(
                passage: link.currentText, highlightID: highlightID
            )
        }
        thoughtLinks.removeAll { $0.id == link.id }
        expandedThoughtLinkIDs.remove(link.id)
        savedThoughtLinkIDs.remove(link.id)
    }

    private func detectThoughtLink(for passage: String) async {
        do {
            let finder = ThoughtLinkFinder(modelContext: modelContext)
            let links = try finder.findLinks(
                passage: passage,
                book: book,
                chapterIndex: currentChapterIndex,
                limit: 3
            )
            thoughtLinks = await finder.enrichLinks(links)
            expandedThoughtLinkIDs.removeAll()
            savedThoughtLinkIDs.removeAll()
        } catch {
            thoughtLinks = []
        }
    }

    private var currentChapterRecord: Chapter? {
        let bookID = book.id
        let index = currentChapterIndex
        return try? modelContext.fetch(
            FetchDescriptor<Chapter>(
                predicate: #Predicate { $0.bookID == bookID && $0.index == index }
            )
        ).first
    }

    private func cycleAloudRate() {
        let steps: [Double] = [0.75, 1.0, 1.25, 1.5]
        let index = steps.firstIndex(where: { abs($0 - aloud.rate) < 0.01 }) ?? 1
        aloud.rate = steps[(index + 1) % steps.count]
    }

    private func toggleReadingAloud() {
        if aloud.isSpeaking {
            aloud.stop()
            return
        }
        let lang = book.languageTag?.hasPrefix("zh") == true ? "zh-CN" : "en-US"
        if let selection = pendingSelection {
            aloud.speak(selection.text, language: lang)
            return
        }
        guard let text = currentChapterRecord?.text else { return }
        // 从当前位置接着读; finishing the chapter rolls into the next
        // when 自动下一章 is on.
        aloud.onQueueFinished = { [self] in
            guard aloudAutoNext,
                  let chapterCount = epubBook?.chapters.count,
                  currentChapterIndex < chapterCount - 1 else { return }
            crossChapterBoundary(.forward, chapterCount: chapterCount)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let next = currentChapterRecord?.text {
                    aloud.speak(next, language: lang)
                }
            }
        }
        aloud.speak(text, fromUTF16Offset: currentUTF16Offset, language: lang)
    }

    // MARK: Loading & progress

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

    // MARK: 繁体显示 (render-layer, EPUB only)

    private func displayChapter(_ chapter: EPUBChapter) -> EPUBChapter {
        guard traditionalChinese else { return chapter }
        if let cached = traditionalCache.values[currentChapterIndex] {
            return cached.chapter
        }
        let converted = EPUBChapter(
            title: ChineseVariant.traditional(chapter.title),
            href: chapter.href,
            content: ChineseVariant.traditional(chapter.content)
        )
        let plain = currentChapterPlainText().map(ChineseVariant.traditional)
        traditionalCache.values[currentChapterIndex] = (converted, plain)
        return converted
    }

    private func displayChapterPlainText() -> String? {
        guard traditionalChinese else { return currentChapterPlainText() }
        if let cached = traditionalCache.values[currentChapterIndex] {
            return cached.plain
        }
        return currentChapterPlainText().map(ChineseVariant.traditional)
    }

    private func updateUTF16Offset(domPrefix: String) {
        guard let plainText = displayChapterPlainText() else { return }
        let offset = PlainTextSearch.utf16Offset(
            afterNormalizedPrefix: domPrefix,
            in: plainText
        )
        currentUTF16Offset = min(offset, plainText.utf16.count)
        // Position reports only arrive on real scroll/page activity —
        // exactly what the 统计 spec counts as reading time.
        activityMeter.ping()
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
                    // Open the book without pulling every spine item into
                    // memory: parse metadata and the chapter list, then load
                    // only the current chapter's XHTML before leaving the
                    // loading screen.
                    var parsed = try EPUBParser().parseBook(
                        at: fileURL,
                        unzipDirectory: fileStore.unzipDirectory(forBookID: book.id),
                        loadContent: false
                    )
                    guard !parsed.chapters.isEmpty else {
                        throw EPUBParser.ParseError.parsingFailed("No readable chapters found.")
                    }
                    if currentChapterIndex >= parsed.chapters.count {
                        currentChapterIndex = 0
                    }
                    parsed.loadContent(forChapterAt: currentChapterIndex)
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

                if book.format == .pdf {
                    syncPageProgress(at: currentChapterIndex)
                }
                isLoading = false
                if ProcessInfo.processInfo.arguments.contains("-OpenHighlights") {
                    showHighlights = true
                }
                inlineAIUnavailable = readingMode != .original
                    && !AIProviderRegistry.load().resolveUsableService(feature: .translate)
                        .service.availability.isAvailable
                startSession()
                startPretranslation()
                await loadChapterSummary()
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

    private func saveHighlight(color: HighlightColor = .yellow) {
        guard let selection = pendingSelection else { return }
        do {
            try HighlightStore(modelContext: modelContext).createHighlight(
                book: book,
                chapterIndex: currentChapterIndex,
                selection: selection.text,
                prefix: selection.prefix,
                suffix: selection.suffix,
                color: color
            )
            pendingSelection = nil
            refreshChapterHighlights()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func copySelection() {
        guard let selection = pendingSelection else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selection.text, forType: .string)
        pendingSelection = nil
    }

    // MARK: 书签 (⌘D)

    private func refreshBookmarkState() {
        bookmarkedHere = ((try? BookmarkStore(modelContext: modelContext)
            .bookmarks(for: book)) ?? [])
            .contains {
                $0.chapterIndex == currentChapterIndex
                    && abs($0.utf16Offset - currentUTF16Offset) < 600
            }
    }

    private func toggleBookmark() {
        let chapterText = currentChapterPlainText() ?? ""
        let utf16 = Array(chapterText.utf16)
        let start = max(0, min(currentUTF16Offset, max(0, utf16.count - 1)))
        let end = min(utf16.count, start + 80)
        let snippet = String(decoding: utf16[start..<end], as: UTF16.self)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        try? BookmarkStore(modelContext: modelContext).toggle(
            book: book,
            chapterIndex: currentChapterIndex,
            utf16Offset: currentUTF16Offset,
            snippet: snippet.isEmpty ? "第 \(currentChapterIndex + 1) 章" : snippet
        )
        cacheStatsTick += 1
        refreshBookmarkState()
    }

    private func lookUpSelectionInDictionary() {
        guard let selection = pendingSelection else { return }
        let term = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty,
              let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "dict://\(encoded)") else { return }
        NSWorkspace.shared.open(url)
        pendingSelection = nil
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
                        endUTF16: $0.endUTF16,
                        colorHex: $0.color.hex
                    )
                }
        } catch {
            chapterHighlights = []
        }
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
            session.activeSeconds += activityMeter.drain()
        }
        try? modelContext.save()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("无法打开这本书")
                .font(.system(size: 15, weight: .bold, design: .serif))
                .foregroundStyle(palette.ink)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(palette.ink3)
                .multilineTextAlignment(.center)
            Button("返回书库") { onBack() }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


#endif