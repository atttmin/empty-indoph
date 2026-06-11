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
    @State private var recapCache: RecapCache?
    @State private var fontSize: Double = 18
    @State private var lineSpacing: Double = 1.8
    @State private var pendingSelection: ReaderSelection?
    @State private var chapterHighlights: [HighlightPaint] = []
    @State private var isCompanionOpen = false
    @State private var companion: CompanionModel
    @State private var readingMode: MacReadingMode = .original
    @State private var summaryOpen = true
    @State private var chapterSummary = ""
    @State private var isSummaryLoading = false
    @State private var modeGuideText = ""
    @State private var isGuideLoading = false
    @State private var marginNote: String?
    @State private var marginNoteSubject: String?
    @State private var marginNoteSaved = false
    @State private var glossEntry: VocabEntry?
    @State private var isSelectionWorking = false
    @State private var thoughtLink: ThoughtLink?
    @State private var thoughtLinkExpanded = false
    @State private var thoughtLinkSaved = false
    @State private var chapterOutline: ChapterOutline?
    @State private var chapterPageInfo: (page: Int, count: Int)?
    @State private var inlineNotes: [InlineNotePaint] = []
    @State private var inlineCache: [String: String] = [:]
    @State private var inlineInFlight: Set<String> = []
    @State private var inlineAIUnavailable = false
    @State private var isTocOpen = false
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

    @ViewBuilder
    private func readerContent(_ epub: EPUBBook) -> some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                topBar(epub)
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
                            }
                        )
                        .frame(width: 272)
                        .transition(.move(edge: .leading))
                        Rectangle().fill(palette.line).frame(width: 1)
                    }

                    VStack(spacing: 0) {
                        ZStack(alignment: .bottom) {
                            NativeChapterReaderView(
                                chapter: epub.chapters[currentChapterIndex],
                                basePath: epub.basePath,
                                fontSize: fontSize,
                                lineSpacing: lineSpacing,
                                landing: chapterLanding,
                                resumeUTF16Offset: resumeUTF16Offset,
                                chapterPlainText: currentChapterPlainText(),
                                highlights: chapterHighlights,
                                inlineMode: inlineNoteKind,
                                inlineLayout: readingMode == .bilingual ? .parallel : .stacked,
                                inlineNotes: inlineNotes,
                                selectionActive: pendingSelection != nil,
                                onTap: { pendingSelection = nil },
                                onChapterBoundary: { direction in
                                    crossChapterBoundary(direction, chapterCount: epub.chapters.count)
                                },
                                onSelectionChange: { selection in
                                    pendingSelection = selection
                                    marginNote = nil
                                    glossEntry = nil
                                    if let selection {
                                        Task { await detectThoughtLink(for: selection.text) }
                                    }
                                },
                                onPositionChange: { updateUTF16Offset(domPrefix: $0) },
                                onVisibleParagraphs: { handleVisibleParagraphs($0) },
                                onPageInfo: { page, count in
                                    chapterPageInfo = (page: page, count: count)
                                }
                            )
                            .id(currentChapterIndex)

                            selectionOverlay
                        }
                        Rectangle().fill(palette.line).frame(height: 1)
                        bottomBar(epub)
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
                    isPaused: !aloud.isSpeaking
                )
                .padding(.bottom, 22)
            }
        }
        .sheet(isPresented: $showSettings) {
            ReadingSettingsView(
                fontSize: $fontSize,
                lineSpacing: $lineSpacing
            )
            .frame(minWidth: 320, minHeight: 280)
        }
        .sheet(isPresented: $showRecap) {
            RecapView(
                book: book,
                position: currentReadingPosition,
                cache: $recapCache
            )
            .frame(minWidth: 440, minHeight: 480)
        }
        .onChange(of: currentChapterIndex) { _, _ in
            pendingSelection = nil
            refreshChapterHighlights()
            resetChapterArtifacts()
            Task { await loadChapterSummary() }
            // Shift the 预译 window (current + next two chapters).
            startPretranslation()
        }
        .onChange(of: readingMode) { _, newMode in
            // The chapter page clears and re-requests notes for the new
            // mode; cached translations rejoin instantly.
            inlineNotes = []
            inlineAIUnavailable = newMode != .original
                && !AIProviderSettings.load().resolveUsableService()
                    .service.availability.isAvailable
            startPretranslation()
        }
        .onDisappear {
            pretransTask?.cancel()
        }
    }

    /// Thin status line under the top bar for 导读 progress or an
    /// unavailable provider (双语对照 reports through the top-bar chip).
    private var inlineModeStatusBar: some View {
        HStack(spacing: 8) {
            if inlineAIUnavailable {
                Text("朱 · AI 暂不可用 — 在侧栏「AI 状态」配置后,\(readingMode == .bilingual ? "双语对照" : "导读")会随阅读逐段出现。")
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
                                    onPageChange: syncPageProgress,
                                    onSelectionChange: { selection in
                                        pendingSelection = selection
                                        marginNote = nil
                                        glossEntry = nil
                                        if let selection {
                                            Task { await detectThoughtLink(for: selection.text) }
                                        }
                                    }
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
                        isPaused: !aloud.isSpeaking
                    )
                    .padding(.bottom, 22)
                }
            }
            .sheet(isPresented: $showChapterList) {
                ChapterListView(
                    titles: sectionTitles,
                    unitLabel: "页",
                    currentIndex: currentChapterIndex
                ) { index in
                    currentChapterIndex = index
                    syncPageProgress(at: index)
                    showChapterList = false
                    resetChapterArtifacts()
                }
                .frame(minWidth: 380, minHeight: 460)
            }
            .sheet(isPresented: $showSettings) {
                ReadingSettingsView(
                    fontSize: $fontSize,
                    lineSpacing: $lineSpacing
                )
                .frame(minWidth: 320, minHeight: 280)
            }
            .sheet(isPresented: $showRecap) {
                RecapView(
                    book: book,
                    position: currentReadingPosition,
                    cache: $recapCache
                )
                .frame(minWidth: 440, minHeight: 480)
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
                    (.bilingual, "双语对照"),
                    (.companion, "导读"),
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

            pillButton("目录") { showChapterList = true }

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

    /// Floating cards over the reading surface: margin note, vocab gloss,
    /// thought link, and the selection action popover. Shared by the EPUB
    /// and PDF readers.
    private var selectionOverlay: some View {
        VStack(spacing: 12) {
            if let marginNote {
                ZhupiCallout(title: "朱批 · 划词解释") {
                    Text(marginNote)
                        .font(.system(size: 12.5))
                        .lineSpacing(5)
                        .foregroundStyle(palette.ink2)
                    HStack(spacing: 8) {
                        Button("继续追问 ↩") {
                            askAboutSelection(marginNoteSubject ?? marginNote)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(palette.accent, lineWidth: 1))

                        Button(marginNoteSaved ? "✓ 已存为卡片" : "存为卡片") {
                            saveMarginNoteCard()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(marginNoteSaved ? palette.accent : palette.ink3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
                        .disabled(marginNoteSaved)
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 24)
            }

            if let glossEntry {
                glossCard(glossEntry)
                    .padding(.horizontal, 24)
            }

            if let thoughtLink {
                MacThoughtLinkCard(
                    link: thoughtLink,
                    isExpanded: thoughtLinkExpanded,
                    isSaved: thoughtLinkSaved,
                    onToggle: { thoughtLinkExpanded.toggle() },
                    onOpenNotes: onOpenNotes,
                    onSaveLink: saveThoughtLinkCard,
                    onAsk: { askAboutSelection(thoughtLink.explanation) }
                )
            }

            if pendingSelection != nil {
                MacSelectionPopover(
                    onExplain: { runSelectionAction(.explain) },
                    onTranslate: { runSelectionAction(.translate) },
                    onAsk: { runSelectionAction(.ask) },
                    onHighlight: saveHighlight,
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
                ProgressView(readingMode == .bilingual ? "生成双语对照…" : "生成导读…")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            } else if !modeGuideText.isEmpty {
                ZhupiCallout(title: readingMode == .bilingual ? "双语对照" : "导读") {
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
                    (.bilingual, "双语对照"),
                    (.companion, "导读"),
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

    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
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
                let resolution = AIProviderSettings.load().resolveUsableService()
                let service = resolution.service
                let passage = GroundedPassage(id: 0, text: selection.text)
                let source = chapterSourceLabel

                switch action {
                case .explain:
                    let answer = try await service.answer(
                        question: "Explain this passage to a thoughtful reader. Reply in Chinese with etymology or nuance when helpful.",
                        groundedIn: [passage]
                    )
                    marginNote = answer.text
                    marginNoteSubject = selection.text
                    marginNoteSaved = false
                case .translate:
                    let answer = try await service.answer(
                        question: "Translate this passage into natural Chinese, preserving literary tone.",
                        groundedIn: [passage]
                    )
                    marginNote = answer.text
                    marginNoteSubject = selection.text
                    marginNoteSaved = false
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
                            source: source
                        )
                    glossEntry = entry
                }
            } catch {
                marginNote = "出错了:\(error.localizedDescription)"
            }
        }
    }

    private func askAboutSelection(_ text: String) {
        withAnimation { isCompanionOpen = true }
        companion.draft = "关于「\(text.prefix(60))」"
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
        thoughtLink = nil
        thoughtLinkExpanded = false
        thoughtLinkSaved = false
        marginNote = nil
        marginNoteSubject = nil
        marginNoteSaved = false
        glossEntry = nil
        pendingSelection = nil
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
            let resolution = AIProviderSettings.load().resolveUsableService()
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
        let resolution = AIProviderSettings.load().resolveUsableService()
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
        readingMode == .companion ? .companion : .bilingual
    }

    /// Called whenever the chapter page reports the paragraphs the reader
    /// is looking at. Resolution order: in-memory → persistent cache
    /// (instant, the 「不重复翻译」 rule) → AI, in reading order.
    private func handleVisibleParagraphs(_ paragraphs: [ReaderParagraph]) {
        guard readingMode != .original else { return }
        let mode = readingMode
        let chapter = currentChapterIndex
        let store = TranslationStore(modelContext: modelContext)
        var missing: [ReaderParagraph] = []
        for paragraph in paragraphs {
            let key = inlineKey(mode, chapter, paragraph.idx)
            if let cached = inlineCache[key] {
                if !cached.isEmpty,
                   !inlineNotes.contains(where: { $0.idx == paragraph.idx }) {
                    inlineNotes.append(InlineNotePaint(idx: paragraph.idx, text: cached))
                }
            } else if let persisted = store.lookup(
                bookID: book.id,
                kind: translationKind,
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
        Task { await translateParagraphs(missing, mode: mode, chapter: chapter) }
    }

    private func translateParagraphs(
        _ paragraphs: [ReaderParagraph],
        mode: MacReadingMode,
        chapter: Int
    ) async {
        let resolution = AIProviderSettings.load().resolveUsableService()
        guard resolution.service.availability.isAvailable else {
            for paragraph in paragraphs {
                inlineInFlight.remove(inlineKey(mode, chapter, paragraph.idx))
            }
            return
        }
        let inlineKind: AIInlineNoteKind = mode == .bilingual ? .bilingual : .companion
        let kind: TranslationKind = mode == .companion ? .companion : .bilingual
        for paragraph in paragraphs {
            let key = inlineKey(mode, chapter, paragraph.idx)
            defer { inlineInFlight.remove(key) }
            // Reader moved on — skip the model call, leave it uncached.
            guard readingMode == mode, currentChapterIndex == chapter else { continue }
            do {
                let text = try await AITransientRetry.run {
                    try await resolution.service.inlineNote(
                        for: paragraph.text,
                        kind: inlineKind
                    )
                }.trimmingCharacters(in: .whitespacesAndNewlines)
                inlineCache[key] = text
                if !text.isEmpty {
                    TranslationStore(modelContext: modelContext).store(
                        text,
                        bookID: book.id,
                        chapterIndex: chapter,
                        kind: kind,
                        text: paragraph.text
                    )
                    cacheStatsTick += 1
                }
                if readingMode == mode, currentChapterIndex == chapter, !text.isEmpty {
                    inlineNotes.append(InlineNotePaint(idx: paragraph.idx, text: text))
                }
            } catch {
                // Busy/rate-limited providers are common while 导读, summary,
                // and pre-translation compete. Let the paragraph retry on the
                // next settled viewport report instead of painting a scary
                // permanent failure marker.
                guard !AITransientRetry.isTransient(error) else { continue }
                inlineCache[key] = ""
                if readingMode == mode, currentChapterIndex == chapter {
                    inlineNotes.append(
                        InlineNotePaint(idx: paragraph.idx, text: "", failed: true)
                    )
                }
            }
        }
    }

    // MARK: 预译 (pre-translation, never blocking)

    /// Pre-translates the current and next two chapters (plus chapter
    /// titles for the bilingual TOC) into the persistent cache while the
    /// reader is in 双语对照 — the prototype's 「预译 + 永不阻塞」.
    private func startPretranslation() {
        pretransTask?.cancel()
        pretransProgress = [:]
        guard readingMode == .bilingual, epubBook != nil else { return }
        let chapter = currentChapterIndex
        pretransTask = Task { await pretranslate(from: chapter) }
    }

    private func pretranslate(from startChapter: Int) async {
        let resolution = AIProviderSettings.load().resolveUsableService()
        guard resolution.service.availability.isAvailable else { return }
        let store = TranslationStore(modelContext: modelContext)
        let bookID = book.id
        let chapters = (try? modelContext.fetch(
            FetchDescriptor<Chapter>(
                predicate: #Predicate { $0.bookID == bookID },
                sortBy: [SortDescriptor(\.index)]
            )
        )) ?? []

        // Chapter titles first — they make the TOC bilingual and cost
        // almost nothing.
        for chapter in chapters.prefix(50) {
            guard !Task.isCancelled, readingMode == .bilingual else { return }
            guard let title = chapter.title,
                  !title.isEmpty,
                  tocTitleTranslations[chapter.index] == nil else { continue }
            if let cached = store.lookup(bookID: bookID, kind: .title, text: title) {
                tocTitleTranslations[chapter.index] = cached
                continue
            }
            // Plain-text path — the grounded JSON Q&A path occasionally
            // mis-formats and would surface as a missing translation.
            guard let note = try? await resolution.service.inlineNote(
                for: title,
                kind: .bilingual
            ) else { continue }
            let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            store.store(text, bookID: bookID, chapterIndex: chapter.index, kind: .title, text: title)
            tocTitleTranslations[chapter.index] = text
        }

        // Then paragraphs of the reading window.
        let window = chapters.filter {
            $0.index >= startChapter && $0.index < startChapter + 3
        }
        for chapter in window where chapter.pretranslatedAt == nil {
            pretransProgress[chapter.index] = .queued
        }
        for chapter in window {
            guard !Task.isCancelled, readingMode == .bilingual else { return }
            guard chapter.pretranslatedAt == nil else { continue }
            let paragraphs = TranslationStore.paragraphs(in: chapter.text)
            guard !paragraphs.isEmpty else {
                chapter.pretranslatedAt = Date()
                try? modelContext.save()
                continue
            }
            var done = 0
            pretransProgress[chapter.index] = .translating(done: 0, total: paragraphs.count)
            for paragraph in paragraphs {
                guard !Task.isCancelled, readingMode == .bilingual else { return }
                if store.lookup(bookID: bookID, kind: .bilingual, text: paragraph) == nil {
                    guard let text = try? await resolution.service.inlineNote(
                        for: paragraph,
                        kind: .bilingual
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    else { continue }
                    guard !text.isEmpty else { continue }
                    store.store(
                        text,
                        bookID: bookID,
                        chapterIndex: chapter.index,
                        kind: .bilingual,
                        text: paragraph
                    )
                }
                done += 1
                pretransProgress[chapter.index] = .translating(done: done, total: paragraphs.count)
            }
            chapter.pretranslatedAt = Date()
            try? modelContext.save()
            pretransProgress[chapter.index] = nil
            cacheStatsTick += 1
        }
    }

    // MARK: Saved cards

    /// 朱批边注 → 问答卡 in the notes screen.
    private func saveMarginNoteCard() {
        guard let marginNote, !marginNoteSaved else { return }
        let subject = (marginNoteSubject ?? "这一段").prefix(80)
        let card = StudyCardEntry(
            question: "朱批:\(subject)",
            answer: marginNote,
            source: chapterSourceLabel,
            kind: .qa
        )
        card.book = book
        modelContext.insert(card)
        try? modelContext.save()
        marginNoteSaved = true
    }

    /// 思维链接 → 链接卡 in the notes screen.
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

    private func loadModeGuide() async {
        guard readingMode != .original else {
            modeGuideText = ""
            return
        }
        isGuideLoading = true
        defer { isGuideLoading = false }
        guard let text = currentChapterRecord?.text, !text.isEmpty else { return }
        do {
            let resolution = AIProviderSettings.load().resolveUsableService()
            let clipped = String(text.prefix(4_000))
            if readingMode == .bilingual {
                modeGuideText = try await AITransientRetry.run {
                    try await resolution.service.inlineNote(
                        for: clipped,
                        kind: .bilingual
                    )
                }
            } else {
                modeGuideText = try await resolution.service.summarize(clipped, focus: .recap)
            }
        } catch {
            modeGuideText = "导读暂不可用 — \(error.localizedDescription)"
        }
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
                thoughtLinkSaved = false
            }
        } catch {
            thoughtLink = nil
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

    private func toggleReadingAloud() {
        if aloud.isSpeaking {
            aloud.stop()
            return
        }
        if let text = pendingSelection?.text ?? currentChapterRecord?.text {
            let lang = book.languageTag?.hasPrefix("zh") == true ? "zh-CN" : "en-US"
            aloud.speak(String(text.prefix(800)), language: lang)
        }
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
            loadError = error.localizedDescription
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

// MARK: - 章节目录 (TOC panel)

/// The prototype's in-reader TOC: roman numerals, bilingual chapter
/// titles, per-chapter reading progress / 朱批 count / estimated length,
/// the chapter's 预译 state, and the whole-book translation-cache footer.
private struct MacTOCPanel: View {
    let bookTitle: String
    let titles: [String]
    let cnTitles: [Int: String]
    let currentIndex: Int
    let intraChapterFraction: Double
    let progressByChapter: [Int: MacChapterTransStatus]
    /// Changing this re-fetches cache statistics.
    let statsTick: Int
    let book: Book
    var onSelect: (Int) -> Void
    var onClose: () -> Void

    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext

    private struct ChapterFacts {
        var utf16Length = 0
        var pretranslated = false
        var cachedCount = 0
        var highlightCount = 0
    }

    @State private var facts: [Int: ChapterFacts] = [:]
    @State private var footprint: (count: Int, bytes: Int) = (0, 0)

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("目录")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.ink)
                Text("\(bookTitle) · \(titles.count) 章")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Text("×")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.ink3)
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 16, leading: 18, bottom: 10, trailing: 14))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                            row(index: index, title: title)
                                .id(index)
                        }
                    }
                    .padding(EdgeInsets(top: 2, leading: 10, bottom: 10, trailing: 10))
                }
                .onAppear {
                    proxy.scrollTo(currentIndex, anchor: .center)
                }
            }

            footer
        }
        .background(palette.side)
        .task(id: statsTick) {
            refreshFacts()
        }
    }

    private func row(index: Int, title: String) -> some View {
        let isCurrent = index == currentIndex
        let chapterFacts = facts[index] ?? ChapterFacts()
        let display = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? "第 \(index + 1) 章"
            : title
        return Button {
            onSelect(index)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(RomanNumeral.format(index + 1))
                        .font(.system(size: 11, design: .serif))
                        .italic()
                        .foregroundStyle(isCurrent ? palette.accent : palette.ink3)
                        .frame(width: 22, alignment: .leading)
                    Text(display)
                        .font(.system(size: 13, weight: .bold, design: .serif))
                        .foregroundStyle(isCurrent ? palette.accent : palette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 9) {
                    Spacer().frame(width: 22)
                    if let cn = cnTitles[index] {
                        Text(cn)
                            .font(.system(size: 11, design: .serif))
                            .foregroundStyle(palette.ink3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    transChip(index: index, facts: chapterFacts)
                }
                HStack(spacing: 9) {
                    Spacer().frame(width: 22)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.line)
                            Capsule()
                                .fill(palette.accent)
                                .frame(width: geo.size.width * progressFraction(index: index))
                        }
                    }
                    .frame(height: 3)
                    Text(metaLine(index: index, facts: chapterFacts))
                        .font(.system(size: 10))
                        .foregroundStyle(palette.ink3)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .background(
                isCurrent ? palette.accentSoft : .clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func transChip(index: Int, facts chapterFacts: ChapterFacts) -> some View {
        if chapterFacts.pretranslated {
            Text("✓ 已缓存")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(palette.accentSoft, in: Capsule())
        } else if case .translating(let done, let total) = progressByChapter[index], total > 0 {
            Text("⟳ 预译 \(Int(Double(done) / Double(total) * 100))%")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.accent)
        } else if progressByChapter[index] == .queued {
            Text("排队中")
                .font(.system(size: 10))
                .foregroundStyle(palette.ink3)
        } else if chapterFacts.cachedCount > 0 {
            Text("部分缓存")
                .font(.system(size: 10))
                .foregroundStyle(palette.ink3)
        } else {
            Text("未译")
                .font(.system(size: 10))
                .foregroundStyle(palette.ink3)
        }
    }

    private func progressFraction(index: Int) -> CGFloat {
        if index < currentIndex { return 1 }
        if index == currentIndex { return CGFloat(min(max(intraChapterFraction, 0), 1)) }
        return 0
    }

    private func metaLine(index: Int, facts chapterFacts: ChapterFacts) -> String {
        if index < currentIndex {
            return chapterFacts.highlightCount > 0
                ? "已读完 · 朱批 \(chapterFacts.highlightCount)"
                : "已读完"
        }
        if index == currentIndex {
            let percent = "\(Int((intraChapterFraction * 100).rounded()))%"
            return chapterFacts.highlightCount > 0
                ? "\(percent) · 朱批 \(chapterFacts.highlightCount)"
                : percent
        }
        let minutes = ReadingTimeEstimate.minutes(
            utf16Length: chapterFacts.utf16Length,
            languageTag: book.languageTag
        )
        return minutes > 0 ? "约 \(minutes) 分钟" : "—"
    }

    private var footer: some View {
        let pretranslated = facts.values.count { $0.pretranslated }
        let fraction = titles.isEmpty ? 0 : Double(pretranslated) / Double(titles.count)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("全书预译")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(palette.ink)
                Spacer()
                Text("\(Int((fraction * 100).rounded()))% · \(Self.byteLabel(footprint.bytes))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.line)
                    Capsule()
                        .fill(palette.accent)
                        .frame(width: geo.size.width * CGFloat(fraction))
                }
            }
            .frame(height: 4)
            .padding(.top, 7)
            Text("译文缓存在本机,离线可读、不重复翻译。阅读时自动预译后两章。")
                .font(.system(size: 10.5))
                .lineSpacing(4)
                .foregroundStyle(palette.ink3)
                .padding(.top, 8)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
        .overlay(alignment: .top) {
            Rectangle().fill(palette.line).frame(height: 1)
        }
    }

    private static func byteLabel(_ bytes: Int) -> String {
        if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        }
        if bytes >= 1_024 {
            return "\(bytes / 1_024) KB"
        }
        return "\(bytes) B"
    }

    private func refreshFacts() {
        let bookID = book.id
        let store = TranslationStore(modelContext: modelContext)
        let chapters = (try? modelContext.fetch(
            FetchDescriptor<Chapter>(
                predicate: #Predicate { $0.bookID == bookID },
                sortBy: [SortDescriptor(\.index)]
            )
        )) ?? []
        let highlights = (try? modelContext.fetch(
            FetchDescriptor<Highlight>(
                predicate: #Predicate { $0.book?.id == bookID }
            )
        )) ?? []
        let highlightCounts = Dictionary(grouping: highlights, by: \.chapterIndex)
            .mapValues(\.count)

        var collected: [Int: ChapterFacts] = [:]
        for chapter in chapters {
            collected[chapter.index] = ChapterFacts(
                utf16Length: chapter.utf16Length,
                pretranslated: chapter.pretranslatedAt != nil,
                cachedCount: store.cachedCount(
                    bookID: bookID,
                    chapterIndex: chapter.index,
                    kind: .bilingual
                ),
                highlightCount: highlightCounts[chapter.index] ?? 0
            )
        }
        facts = collected
        footprint = store.bookFootprint(bookID: bookID)
    }
}

#endif