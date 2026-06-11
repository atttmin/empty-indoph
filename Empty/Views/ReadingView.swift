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

    @Environment(\.dismiss) private var dismiss
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
    @State private var showAsk = false
    @State private var recapCache: RecapCache?
    @State private var pendingSelection: ReaderSelection?
    @State private var chapterHighlights: [HighlightPaint] = []
    @State private var showHighlights = false
    @State private var saveErrorMessage: String?
    @State private var showControls = true
    @State private var fontSize: Double = 18
    @State private var isDarkMode = false
    @State private var lineSpacing: Double = 1.6

    init(book: Book) {
        self.book = book
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
                ProgressView("Loading book...")
                    .foregroundStyle(.secondary)
            } else if let error = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Could not load book")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Dismiss") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if let epubBook {
                readerContent(epubBook)
            } else if pdfDocumentURL != nil {
                pdfReaderContent
            }
        }
        .preferredColorScheme(isDarkMode ? .dark : nil)
        .onAppear(perform: loadBook)
        .onDisappear(perform: saveProgress)
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        #if os(iOS)
        .statusBarHidden(!showControls)
        #endif
    }

    @ViewBuilder
    private func readerContent(_ book: EPUBBook) -> some View {
        VStack(spacing: 0) {
            if showControls {
                topBar(book)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ZStack(alignment: .bottom) {
                ChapterWebView(
                    chapter: book.chapters[currentChapterIndex],
                    basePath: book.basePath,
                    fontSize: fontSize,
                    isDarkMode: isDarkMode,
                    lineSpacing: lineSpacing,
                    landing: chapterLanding,
                    resumeUTF16Offset: resumeUTF16Offset,
                    chapterPlainText: currentChapterPlainText(),
                    highlights: chapterHighlights,
                    onTap: { withAnimation(.easeInOut(duration: 0.25)) { showControls.toggle() } },
                    onChapterBoundary: { direction in
                        crossChapterBoundary(direction, chapterCount: book.chapters.count)
                    },
                    onSelectionChange: { pendingSelection = $0 },
                    onPositionChange: { updateUTF16Offset(domPrefix: $0) }
                )

                if pendingSelection != nil {
                    Button {
                        saveHighlight()
                    } label: {
                        Label("Highlight", systemImage: "highlighter")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 28)
                }
            }

            if showControls {
                bottomBar(book)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
                lineSpacing: $lineSpacing,
                isDarkMode: $isDarkMode
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
        .sheet(isPresented: $showAsk) {
            AskBookView(
                book: self.book,
                position: currentReadingPosition
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
            pendingSelection = nil
            refreshChapterHighlights()
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
                    pdfTopBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                ZStack(alignment: .bottom) {
                    PDFReaderView(
                        documentURL: documentURL,
                        pageIndex: $currentChapterIndex,
                        highlights: chapterHighlights,
                        onPageChange: syncPageProgress,
                        onSelectionChange: { pendingSelection = $0 }
                    )
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) { showControls.toggle() }
                    }

                    if pendingSelection != nil {
                        Button {
                            saveHighlight()
                        } label: {
                            Label("Highlight", systemImage: "highlighter")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.bottom, 28)
                    }
                }

                if showControls {
                    pdfBottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
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
            .sheet(isPresented: $showAsk) {
                AskBookView(
                    book: self.book,
                    position: currentReadingPosition
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
                pendingSelection = nil
                syncPageProgress(at: newIndex)
            }
            .onChange(of: showHighlights) { _, isShowing in
                if !isShowing { refreshChapterHighlights() }
            }
        }
    }

    private var pdfTopBar: some View {
        HStack {
            Button {
                saveProgress()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Spacer()

            VStack(spacing: 1) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(currentSectionTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button { showHighlights = true } label: {
                Image(systemName: "bookmark")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Button { showAsk = true } label: {
                Image(systemName: "questionmark.bubble")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Button { showRecap = true } label: {
                Image(systemName: "sparkles")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var pdfBottomBar: some View {
        HStack(spacing: 24) {
            Button { showChapterList = true } label: {
                Image(systemName: "list.bullet")
                    .font(.body.weight(.medium))
            }

            Spacer()

            Button {
                if currentChapterIndex > 0 {
                    currentChapterIndex -= 1
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .disabled(currentChapterIndex <= 0)

            Text("\(currentChapterIndex + 1) / \(sectionCount)")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                if currentChapterIndex < sectionCount - 1 {
                    currentChapterIndex += 1
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
            }
            .disabled(currentChapterIndex >= sectionCount - 1)

            Spacer()

            let progress = Double(currentChapterIndex + 1) / Double(max(sectionCount, 1))
            Text("\(Int(progress * 100))%")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
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

    private func topBar(_ book: EPUBBook) -> some View {
        HStack {
            Button {
                saveProgress()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Spacer()

            VStack(spacing: 1) {
                Text(book.metadata.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(book.chapters[currentChapterIndex].title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                showHighlights = true
            } label: {
                Image(systemName: "bookmark")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Button {
                showAsk = true
            } label: {
                Image(systemName: "questionmark.bubble")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Button {
                showRecap = true
            } label: {
                Image(systemName: "sparkles")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Button {
                showSettings = true
            } label: {
                Image(systemName: "textformat.size")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func bottomBar(_ book: EPUBBook) -> some View {
        HStack(spacing: 24) {
            Button {
                showChapterList = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.body.weight(.medium))
            }

            Spacer()

            Button {
                if currentChapterIndex > 0 {
                    currentChapterIndex -= 1
                    currentUTF16Offset = 0
                    chapterLanding = .start
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .disabled(currentChapterIndex <= 0)

            Text("\(currentChapterIndex + 1) / \(book.chapters.count)")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                if currentChapterIndex < book.chapters.count - 1 {
                    currentChapterIndex += 1
                    currentUTF16Offset = 0
                    chapterLanding = .start
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
            }
            .disabled(currentChapterIndex >= book.chapters.count - 1)

            Spacer()

            let progress = Double(currentChapterIndex + 1) / Double(max(book.chapters.count, 1))
            Text("\(Int(progress * 100))%")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var backgroundColor: Color {
        isDarkMode ? Color(hex: 0x1F1B16) : Color(hex: 0xF7F2E9)
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
    @Binding var isDarkMode: Bool

    var body: some View {
        NavigationStack {
            List {
                Section("Font Size") {
                    HStack {
                        Text("A")
                            .font(.caption)
                        Slider(value: $fontSize, in: 12...28, step: 1)
                        Text("A")
                            .font(.title2)
                    }
                    .padding(.vertical, 4)
                }

                Section("Line Spacing") {
                    HStack {
                        Image(systemName: "text.alignleft")
                            .font(.caption)
                        Slider(value: $lineSpacing, in: 1.2...2.2, step: 0.1)
                        Image(systemName: "text.alignleft")
                            .font(.title3)
                    }
                    .padding(.vertical, 4)
                }

                Section("Appearance") {
                    Toggle("Dark Mode", isOn: $isDarkMode)
                }
            }
            .navigationTitle("Settings")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}
