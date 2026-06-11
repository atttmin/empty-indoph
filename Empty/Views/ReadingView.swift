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

/// WebView-based EPUB reader with CSS-column pagination: one column per
/// page, horizontal paging, spoiler-free chapter crossing at the edges.
/// Reading position and sessions persist through the SwiftData `Book`.
struct ReadingView: View {
    let book: Book

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var epubBook: EPUBBook?
    @State private var currentChapterIndex: Int
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
                    highlights: chapterHighlights,
                    onTap: { withAnimation(.easeInOut(duration: 0.25)) { showControls.toggle() } },
                    onChapterBoundary: { direction in
                        crossChapterBoundary(direction, chapterCount: book.chapters.count)
                    },
                    onSelectionChange: { pendingSelection = $0 }
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
                chapters: book.chapters,
                currentIndex: currentChapterIndex
            ) { index in
                currentChapterIndex = index
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
                position: ReadingPosition(chapterIndex: currentChapterIndex, utf16Offset: 0),
                cache: $recapCache
            )
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 480)
            #endif
        }
        .sheet(isPresented: $showAsk) {
            AskBookView(
                book: self.book,
                position: ReadingPosition(chapterIndex: currentChapterIndex, utf16Offset: 0)
            )
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 480)
            #endif
        }
        .sheet(isPresented: $showHighlights) {
            HighlightsListView(book: self.book) { chapterIndex in
                currentChapterIndex = chapterIndex
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

    private func crossChapterBoundary(_ direction: PageTurnDirection, chapterCount: Int) {
        switch direction {
        case .forward:
            guard currentChapterIndex < chapterCount - 1 else { return }
            currentChapterIndex += 1
            chapterLanding = .start
        case .backward:
            guard currentChapterIndex > 0 else { return }
            currentChapterIndex -= 1
            chapterLanding = .end
        }
    }

    private func loadBook() {
        Task {
            do {
                guard book.format == .epub else {
                    throw EPUBParser.ParseError.parsingFailed(
                        "PDF reading isn't wired up yet — EPUB only for now."
                    )
                }
                guard let relativePath = book.fileRelativePath else {
                    throw EPUBParser.ParseError.fileNotFound
                }
                let fileStore = try BookFileStore.makeDefault()
                let parsed = try EPUBParser().parseBook(
                    at: fileStore.url(forRelativePath: relativePath),
                    unzipDirectory: fileStore.unzipDirectory(forBookID: book.id)
                )
                guard !parsed.chapters.isEmpty else {
                    throw EPUBParser.ParseError.parsingFailed("No readable chapters found.")
                }
                epubBook = parsed
                if currentChapterIndex >= parsed.chapters.count {
                    currentChapterIndex = 0
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
        guard let epubBook else { return }
        let position = ReadingPosition(chapterIndex: currentChapterIndex, utf16Offset: 0)
        book.position = position
        book.progressFraction =
            Double(currentChapterIndex + 1) / Double(max(epubBook.chapters.count, 1))
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
    var paints: [HighlightPaint] = []
    var onTap: () -> Void = {}
    var onChapterBoundary: (PageTurnDirection) -> Void = { _ in }
    var onSelectionChange: (ReaderSelection?) -> Void = { _ in }

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
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if landing == .end {
            webView.evaluateJavaScript("readerGoToEnd()")
        }
        applyPaints(on: webView)
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
    let highlights: [HighlightPaint]
    let onTap: () -> Void
    let onChapterBoundary: (PageTurnDirection) -> Void
    let onSelectionChange: (ReaderSelection?) -> Void

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
        loadChapter(in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        syncCoordinator(context.coordinator)
        if context.coordinator.currentChapter != chapter.href {
            context.coordinator.currentChapter = chapter.href
            context.coordinator.paints = highlights
            loadChapter(in: webView)
        } else {
            webView.evaluateJavaScript(
                "updateStyle(\(fontSize), \(isDarkMode), \(lineSpacing));"
            )
            if context.coordinator.paints != highlights {
                context.coordinator.paints = highlights
                context.coordinator.applyPaints(on: webView)
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
    let highlights: [HighlightPaint]
    let onTap: () -> Void
    let onChapterBoundary: (PageTurnDirection) -> Void
    let onSelectionChange: (ReaderSelection?) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: ReaderBridge.messageName)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        syncCoordinator(context.coordinator)
        context.coordinator.currentChapter = chapter.href
        context.coordinator.paints = highlights
        loadChapter(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        syncCoordinator(context.coordinator)
        if context.coordinator.currentChapter != chapter.href {
            context.coordinator.currentChapter = chapter.href
            context.coordinator.paints = highlights
            loadChapter(in: webView)
        } else {
            webView.evaluateJavaScript(
                "updateStyle(\(fontSize), \(isDarkMode), \(lineSpacing));"
            )
            if context.coordinator.paints != highlights {
                context.coordinator.paints = highlights
                context.coordinator.applyPaints(on: webView)
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
        bridge.onTap = onTap
        bridge.onChapterBoundary = onChapterBoundary
        bridge.onSelectionChange = onSelectionChange
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
        </style>
        <script>
        let pageIndex = 0;
        function pageWidth() { return window.innerWidth; }
        function readerPageCount() {
            return Math.max(1, Math.round(document.body.scrollWidth / pageWidth()));
        }
        function applyPage(animated) {
            document.body.scrollTo({
                left: pageIndex * pageWidth(),
                top: 0,
                behavior: animated ? 'smooth' : 'auto'
            });
        }
        function readerGoTo(page, animated) {
            pageIndex = Math.max(0, Math.min(page, readerPageCount() - 1));
            applyPage(animated !== false);
        }
        function readerGoToEnd() { readerGoTo(readerPageCount() - 1, false); }
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
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
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
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
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
    let chapters: [EPUBChapter]
    let currentIndex: Int
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        onSelect(index)
                    } label: {
                        HStack {
                            Text(chapter.title)
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
            .navigationTitle("Chapters")
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
