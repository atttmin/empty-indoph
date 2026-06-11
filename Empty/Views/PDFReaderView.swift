//
//  PDFReaderView.swift
//  Empty
//

import PDFKit
import SwiftUI

#if canImport(UIKit)
private typealias PlatformColor = UIColor
#else
private typealias PlatformColor = NSColor
#endif

/// Same marker yellow the EPUB reader paints (rgba 255,214,10,0.45).
private let highlightFill = PlatformColor(
    red: 1, green: 0.84, blue: 0.04, alpha: 0.45
)

/// Native PDFKit reader — one page at a time, synced to `pageIndex`.
/// Reports text selections (for highlighting and AI actions) and paints
/// stored highlights as PDF annotations on the visible page.
struct PDFReaderView: View {
    let documentURL: URL
    @Binding var pageIndex: Int
    var highlights: [HighlightPaint] = []
    /// 夜间反色 (smart-ish: hue-rotated so colors keep their identity).
    var nightInverted: Bool = false
    /// Per-book zoom memory: UserDefaults key, nil disables.
    var zoomMemoryKey: String? = nil
    /// 双页 spread (Mac).
    var twoUp: Bool = false
    var onPageChange: (Int) -> Void = { _ in }
    var onSelectionChange: (ReaderSelection?) -> Void = { _ in }

    var body: some View {
        PDFReaderRepresentable(
            documentURL: documentURL,
            pageIndex: $pageIndex,
            highlights: highlights,
            zoomMemoryKey: zoomMemoryKey,
            twoUp: twoUp,
            onPageChange: onPageChange,
            onSelectionChange: onSelectionChange
        )
        .colorInvert(enabled: nightInverted)
    }
}

private extension View {
    @ViewBuilder
    func colorInvert(enabled: Bool) -> some View {
        if enabled {
            self.colorInvert().hueRotation(.degrees(180))
        } else {
            self
        }
    }
}

// MARK: - Selection context

/// Builds the `ReaderSelection` (text + disambiguation context) for a PDF
/// selection, mirroring what the EPUB web view reports. Factored out of the
/// coordinator so the UTF-16 slicing is unit-testable without a `PDFView`.
nonisolated enum PDFSelectionContext {
    /// Characters of surrounding page text kept on each side of the
    /// selection; matches the EPUB reader's prefix/suffix window.
    static let contextLength = 40

    static func readerSelection(
        pageText: String,
        selectedText: String,
        range: NSRange
    ) -> ReaderSelection {
        let text = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = pageText as NSString
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= page.length else {
            return ReaderSelection(text: text, prefix: "", suffix: "")
        }

        // Round to composed-character boundaries so the context never slices
        // a surrogate pair into a replacement character.
        var prefixStart = max(0, range.location - contextLength)
        if prefixStart > 0, prefixStart < page.length {
            prefixStart = page.rangeOfComposedCharacterSequence(at: prefixStart).location
        }
        let prefix = page.substring(
            with: NSRange(location: prefixStart, length: range.location - prefixStart)
        )

        let suffixStart = NSMaxRange(range)
        var suffixEnd = min(page.length, suffixStart + contextLength)
        if suffixEnd > suffixStart, suffixEnd < page.length {
            let sequence = page.rangeOfComposedCharacterSequence(at: suffixEnd - 1)
            suffixEnd = NSMaxRange(sequence)
        }
        let suffix = page.substring(
            with: NSRange(location: suffixStart, length: suffixEnd - suffixStart)
        )

        return ReaderSelection(text: text, prefix: prefix, suffix: suffix)
    }
}

// MARK: - Bridge

final class PDFReaderCoordinator: NSObject {
    var pageIndex: Int = 0
    var paints: [HighlightPaint] = []
    /// 按书缩放记忆: persisted scale factor under this defaults key.
    var zoomMemoryKey: String?
    var onPageChange: (Int) -> Void = { _ in }
    var onSelectionChange: (ReaderSelection?) -> Void = { _ in }

    private var observations: [NSObjectProtocol] = []
    private var isApplyingPage = false
    private var selectionDebounce: DispatchWorkItem?
    private var paintedAnnotations: [PDFAnnotation] = []

    func attach(to pdfView: PDFView) {
        detach()
        observations.append(NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self, weak pdfView] _ in
            guard let self, let pdfView else { return }
            self.applyHighlights(on: pdfView)
            guard !self.isApplyingPage else { return }
            guard let page = pdfView.currentPage,
                  let document = pdfView.document else { return }
            let index = document.index(for: page)
            guard index != NSNotFound, index != self.pageIndex else { return }
            self.pageIndex = index
            self.onPageChange(index)
        })
        observations.append(NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged,
            object: pdfView,
            queue: .main
        ) { [weak self, weak pdfView] _ in
            guard let self, let pdfView, let key = self.zoomMemoryKey else { return }
            UserDefaults.standard.set(Double(pdfView.scaleFactor), forKey: key)
        })
        observations.append(NotificationCenter.default.addObserver(
            forName: .PDFViewSelectionChanged,
            object: pdfView,
            queue: .main
        ) { [weak self, weak pdfView] _ in
            guard let self else { return }
            // Debounce: drags fire a notification per glyph.
            self.selectionDebounce?.cancel()
            let work = DispatchWorkItem { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                self.reportSelection(in: pdfView)
            }
            self.selectionDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        })
    }

    func detach() {
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
        }
        observations.removeAll()
        selectionDebounce?.cancel()
        selectionDebounce = nil
    }

    /// Restores the book's remembered zoom (must run after the document
    /// is set; `autoScales` wins until a stored value exists).
    func restoreZoom(in pdfView: PDFView) {
        guard let key = zoomMemoryKey else { return }
        let stored = UserDefaults.standard.double(forKey: key)
        guard stored > 0.05 else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = CGFloat(stored)
    }

    func applyPage(in pdfView: PDFView, index: Int) {
        guard let document = pdfView.document,
              index >= 0,
              index < document.pageCount,
              let page = document.page(at: index) else { return }
        guard pdfView.currentPage !== page else { return }
        isApplyingPage = true
        pdfView.go(to: page)
        isApplyingPage = false
        applyHighlights(on: pdfView)
    }

    // MARK: Selection

    private func reportSelection(in pdfView: PDFView) {
        guard let selection = pdfView.currentSelection,
              let rawText = selection.string,
              !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let page = selection.pages.first else {
            onSelectionChange(nil)
            return
        }
        var range = NSRange(location: NSNotFound, length: 0)
        if selection.numberOfTextRanges(on: page) > 0 {
            range = selection.range(at: 0, on: page)
        }
        onSelectionChange(PDFSelectionContext.readerSelection(
            pageText: page.string ?? "",
            selectedText: rawText,
            range: range
        ))
    }

    // MARK: Highlight painting

    /// Repaints stored highlights on the visible page. Mirrors the EPUB
    /// painter's strategy: locate each highlight by its text snapshot and
    /// mark the first occurrence on the page.
    func applyHighlights(on pdfView: PDFView) {
        for annotation in paintedAnnotations {
            annotation.page?.removeAnnotation(annotation)
        }
        paintedAnnotations.removeAll()

        guard !paints.isEmpty,
              let document = pdfView.document,
              let page = pdfView.currentPage else { return }

        for paint in paints {
            let needle = paint.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { continue }
            let matches = document.findString(needle, withOptions: [])
            guard let match = matches.first(where: { $0.pages.contains(page) }) else {
                continue
            }
            for line in match.selectionsByLine() where line.pages.contains(page) {
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty else { continue }
                let annotation = PDFAnnotation(
                    bounds: bounds,
                    forType: .highlight,
                    withProperties: nil
                )
                annotation.color = highlightFill
                page.addAnnotation(annotation)
                paintedAnnotations.append(annotation)
            }
        }
    }

    deinit {
        detach()
    }
}

#if canImport(UIKit)
struct PDFReaderRepresentable: UIViewRepresentable {
    let documentURL: URL
    @Binding var pageIndex: Int
    let highlights: [HighlightPaint]
    var zoomMemoryKey: String? = nil
    var twoUp: Bool = false
    let onPageChange: (Int) -> Void
    let onSelectionChange: (ReaderSelection?) -> Void

    func makeCoordinator() -> PDFReaderCoordinator {
        PDFReaderCoordinator()
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = twoUp ? .twoUp : .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.usePageViewController(true, withViewOptions: nil)
        pdfView.backgroundColor = .clear
        pdfView.document = PDFDocument(url: documentURL)
        context.coordinator.pageIndex = pageIndex
        context.coordinator.paints = highlights
        context.coordinator.zoomMemoryKey = zoomMemoryKey
        syncCallbacks(context.coordinator)
        context.coordinator.attach(to: pdfView)
        context.coordinator.applyPage(in: pdfView, index: pageIndex)
        context.coordinator.applyHighlights(on: pdfView)
        context.coordinator.restoreZoom(in: pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != documentURL {
            pdfView.document = PDFDocument(url: documentURL)
        }
        let mode: PDFDisplayMode = twoUp ? .twoUp : .singlePage
        if pdfView.displayMode != mode {
            pdfView.displayMode = mode
        }
        syncCallbacks(context.coordinator)
        if context.coordinator.pageIndex != pageIndex {
            context.coordinator.pageIndex = pageIndex
            context.coordinator.applyPage(in: pdfView, index: pageIndex)
        }
        if context.coordinator.paints != highlights {
            context.coordinator.paints = highlights
            context.coordinator.applyHighlights(on: pdfView)
        }
    }

    private func syncCallbacks(_ coordinator: PDFReaderCoordinator) {
        coordinator.onPageChange = { index in
            pageIndex = index
            onPageChange(index)
        }
        coordinator.onSelectionChange = onSelectionChange
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: PDFReaderCoordinator) {
        coordinator.detach()
    }
}
#else
struct PDFReaderRepresentable: NSViewRepresentable {
    let documentURL: URL
    @Binding var pageIndex: Int
    let highlights: [HighlightPaint]
    var zoomMemoryKey: String? = nil
    var twoUp: Bool = false
    let onPageChange: (Int) -> Void
    let onSelectionChange: (ReaderSelection?) -> Void

    func makeCoordinator() -> PDFReaderCoordinator {
        PDFReaderCoordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = twoUp ? .twoUp : .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.backgroundColor = .clear
        pdfView.document = PDFDocument(url: documentURL)
        context.coordinator.pageIndex = pageIndex
        context.coordinator.paints = highlights
        context.coordinator.zoomMemoryKey = zoomMemoryKey
        syncCallbacks(context.coordinator)
        context.coordinator.attach(to: pdfView)
        context.coordinator.applyPage(in: pdfView, index: pageIndex)
        context.coordinator.applyHighlights(on: pdfView)
        context.coordinator.restoreZoom(in: pdfView)
        DispatchQueue.main.async {
            pdfView.window?.makeFirstResponder(pdfView)
        }
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != documentURL {
            pdfView.document = PDFDocument(url: documentURL)
        }
        let mode: PDFDisplayMode = twoUp ? .twoUp : .singlePage
        if pdfView.displayMode != mode {
            pdfView.displayMode = mode
        }
        syncCallbacks(context.coordinator)
        if context.coordinator.pageIndex != pageIndex {
            context.coordinator.pageIndex = pageIndex
            context.coordinator.applyPage(in: pdfView, index: pageIndex)
        }
        if context.coordinator.paints != highlights {
            context.coordinator.paints = highlights
            context.coordinator.applyHighlights(on: pdfView)
        }
    }

    private func syncCallbacks(_ coordinator: PDFReaderCoordinator) {
        coordinator.onPageChange = { index in
            pageIndex = index
            onPageChange(index)
        }
        coordinator.onSelectionChange = onSelectionChange
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: PDFReaderCoordinator) {
        coordinator.detach()
    }
}
#endif
