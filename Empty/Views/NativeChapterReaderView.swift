//
//  NativeChapterReaderView.swift
//  Empty
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Pure SwiftUI EPUB chapter renderer used by the native reader path.
/// It reports visible paragraphs through preferences instead of DOM queries,
/// so inserting translations or guide notes never asks WebKit to reflow/scroll.
struct NativeChapterReaderView: View {
    let chapter: EPUBChapter
    let basePath: URL
    let fontSize: Double
    let lineSpacing: Double
    let landing: ChapterLanding
    let resumeUTF16Offset: Int
    let chapterPlainText: String?
    let highlights: [HighlightPaint]
    let inlineMode: InlineNoteKind
    let inlineLayout: InlineNoteLayout
    let inlineNotes: [InlineNotePaint]
    var selectionActive: Bool = false
    var onTap: () -> Void = {}
    var onChapterBoundary: (PageTurnDirection) -> Void = { _ in }
    var onSelectionChange: (ReaderSelection?) -> Void = { _ in }
    var onPositionChange: (String) -> Void = { _ in }
    var onVisibleParagraphs: ([ReaderParagraph]) -> Void = { _ in }
    var onPageInfo: (Int, Int) -> Void = { _, _ in }

    private let document: NativeChapterDocument
    private let blockSpans: [String: NativeTextBlockSpan]
    private let paragraphByID: [String: ReaderParagraph]
    private let orderedTextSpans: [NativeTextBlockSpan]
    private let coordinateSpace = "NativeChapterReaderView.scroll"

    @Environment(\.emptyPalette) private var palette
    @State private var viewportHeight: CGFloat = 0
    @State private var lastVisibleParagraphs: [ReaderParagraph] = []
    @State private var lastPositionPrefix = ""
    @State private var activeSelectionBlockID: String?

    init(
        chapter: EPUBChapter,
        basePath: URL,
        fontSize: Double,
        lineSpacing: Double,
        landing: ChapterLanding,
        resumeUTF16Offset: Int,
        chapterPlainText: String?,
        highlights: [HighlightPaint],
        inlineMode: InlineNoteKind,
        inlineLayout: InlineNoteLayout = .stacked,
        inlineNotes: [InlineNotePaint],
        selectionActive: Bool = false,
        onTap: @escaping () -> Void = {},
        onChapterBoundary: @escaping (PageTurnDirection) -> Void = { _ in },
        onSelectionChange: @escaping (ReaderSelection?) -> Void = { _ in },
        onPositionChange: @escaping (String) -> Void = { _ in },
        onVisibleParagraphs: @escaping ([ReaderParagraph]) -> Void = { _ in },
        onPageInfo: @escaping (Int, Int) -> Void = { _, _ in }
    ) {
        self.chapter = chapter
        self.basePath = basePath
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.landing = landing
        self.resumeUTF16Offset = resumeUTF16Offset
        self.chapterPlainText = chapterPlainText
        self.highlights = highlights
        self.inlineMode = inlineMode
        self.inlineLayout = inlineLayout
        self.inlineNotes = inlineNotes
        self.selectionActive = selectionActive
        self.onTap = onTap
        self.onChapterBoundary = onChapterBoundary
        self.onSelectionChange = onSelectionChange
        self.onPositionChange = onPositionChange
        self.onVisibleParagraphs = onVisibleParagraphs
        self.onPageInfo = onPageInfo

        let parsed = NativeChapterParser.parse(chapter)
        let spans = parsed.resolvedTextSpans(in: chapterPlainText)
        self.document = parsed
        self.blockSpans = spans
        self.paragraphByID = Dictionary(
            uniqueKeysWithValues: parsed.blocks.compactMap { block in
                guard let paragraph = block.readerParagraph else { return nil }
                return (block.id, paragraph)
            }
        )
        self.orderedTextSpans = spans.values.sorted {
            $0.chapterRange.lowerBound < $1.chapterRange.lowerBound
        }
    }

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        chapterBoundaryButton(.backward)
                            .padding(.bottom, 18)

                        ForEach(document.blocks) { block in
                            blockView(block)
                                .id(block.id)
                        }

                        chapterBoundaryButton(.forward)
                            .padding(.top, 22)
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, horizontalPadding(for: outer.size.width))
                    .padding(.top, 34)
                    .padding(.bottom, 96)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .coordinateSpace(name: coordinateSpace)
                .background(palette.window)
                .contentShape(Rectangle())
                .onTapGesture {
                    activeSelectionBlockID = nil
                    onTap()
                    onSelectionChange(nil)
                }
                .onAppear {
                    viewportHeight = outer.size.height
                    onPageInfo(0, 1)
                    DispatchQueue.main.async {
                        scrollToLanding(with: proxy)
                    }
                }
                .onChange(of: outer.size.height) { _, height in
                    viewportHeight = height
                }
                .onChange(of: selectionActive) { _, isActive in
                    if !isActive {
                        activeSelectionBlockID = nil
                    }
                }
                .onPreferenceChange(NativeParagraphFrameKey.self) { frames in
                    updateVisibleParagraphs(frames)
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: NativeChapterBlock) -> some View {
        switch block {
        case .heading(_, let level, _):
            selectableText(
                for: block,
                fontSize: headingSize(level),
                weight: .bold,
                tone: .primary,
                bullet: nil
            )
            .padding(.top, level <= 2 ? 22 : 16)
            .padding(.bottom, level <= 2 ? 12 : 8)

        case .paragraph:
            paragraphBlock(block, quoteStyle: false, bullet: nil)

        case .quote:
            paragraphBlock(block, quoteStyle: true, bullet: nil)

        case .listItem:
            paragraphBlock(block, quoteStyle: false, bullet: "•")

        case .image(_, let source, let alt):
            NativeReaderImageView(url: resourceURL(for: source), alt: alt)
                .padding(.vertical, 16)
        }
    }

    private func paragraphBlock(
        _ block: NativeChapterBlock,
        quoteStyle: Bool,
        bullet: String?
    ) -> some View {
        Group {
            if inlineMode != .none, inlineLayout == .parallel, let paragraph = block.readerParagraph {
                HStack(alignment: .top, spacing: 22) {
                    selectableText(
                        for: block,
                        fontSize: fontSize,
                        weight: .regular,
                        tone: quoteStyle ? .secondary : .primary,
                        bullet: bullet
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    inlineNoteView(for: paragraph.idx)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    selectableText(
                        for: block,
                        fontSize: fontSize,
                        weight: .regular,
                        tone: quoteStyle ? .secondary : .primary,
                        bullet: bullet
                    )
                    if inlineMode != .none, let paragraph = block.readerParagraph {
                        inlineNoteView(for: paragraph.idx)
                    }
                }
            }
        }
        .padding(.horizontal, quoteStyle ? 16 : 0)
        .padding(.vertical, 8)
        .overlay(alignment: .leading) {
            if quoteStyle {
                Rectangle()
                    .fill(palette.accentSoft2)
                    .frame(width: 3)
            }
        }
        .background(visibilityProbe(for: block))
    }

    private func selectableText(
        for block: NativeChapterBlock,
        fontSize: Double,
        weight: NativeTextWeight,
        tone: NativeTextTone,
        bullet: String?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let bullet {
                Text(bullet)
                    .font(.system(size: fontSize, weight: .bold, design: .serif))
                    .foregroundStyle(palette.accent)
            }
            NativeSelectableTextBlockView(
                text: block.text,
                fontSize: fontSize,
                lineSpacing: textLineSpacing(for: fontSize),
                weight: weight,
                tone: tone,
                highlightRanges: localHighlightRanges(for: block),
                isDark: palette.isDark,
                clearSelection: !selectionActive || activeSelectionBlockID != block.id,
                onSelectionChange: { updateSelection(for: block, localRange: $0) }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func updateSelection(
        for block: NativeChapterBlock,
        localRange: Range<Int>?
    ) {
        guard let localRange,
              let selection = document.selection(
                for: block.id,
                localUTF16Range: localRange,
                chapterPlainText: chapterPlainText,
                spans: blockSpans
              ) else {
            if activeSelectionBlockID == block.id {
                activeSelectionBlockID = nil
            }
            onSelectionChange(nil)
            return
        }
        activeSelectionBlockID = block.id
        onSelectionChange(selection)
    }

    private func localHighlightRanges(for block: NativeChapterBlock) -> [Range<Int>] {
        var localRanges: [Range<Int>] = []
        if let span = blockSpans[block.id] {
            for highlight in highlights {
                if let start = highlight.startUTF16,
                   let end = highlight.endUTF16,
                   end > start,
                   let local = span.localRange(intersecting: start..<end) {
                    localRanges.append(local)
                    continue
                }
                let needle = highlight.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !needle.isEmpty,
                      let fallback = PlainTextSearch.utf16Range(of: needle, in: block.text) else {
                    continue
                }
                localRanges.append(fallback)
            }
        }
        return mergeRanges(localRanges)
    }

    @ViewBuilder
    private func inlineNoteView(for index: Int) -> some View {
        let note = inlineNotes.first { $0.idx == index }
        let title = inlineMode == .bilingual ? "译" : "导读"
        let body = note?.failed == true
            ? "暂不可用，稍后会自动重试。"
            : (note?.text.isEmpty == false ? note?.text ?? "" : "生成中…")
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .kerning(1.1)
                .foregroundStyle(palette.accent)
            Text(body)
                .font(.system(size: max(13, fontSize - 2), weight: .regular, design: .serif))
                .lineSpacing(max(3, textLineSpacing(for: max(13, fontSize - 2)) * 0.8))
                .foregroundStyle(note == nil ? palette.ink3 : palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(palette.accentSoft2, lineWidth: 1)
        )
    }

    private func chapterBoundaryButton(_ direction: PageTurnDirection) -> some View {
        Button {
            onChapterBoundary(direction)
        } label: {
            HStack(spacing: 8) {
                Text(direction == .backward ? "上一章" : "下一章")
                Text(direction == .backward ? "↑" : "↓")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.ink3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(palette.line, style: StrokeStyle(dash: [4, 4]))
            )
        }
        .buttonStyle(.plain)
    }

    private func visibilityProbe(for block: NativeChapterBlock) -> some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .named(coordinateSpace))
            Color.clear.preference(
                key: NativeParagraphFrameKey.self,
                value: block.readerParagraph == nil ? [] : [
                    NativeParagraphFrame(
                        blockID: block.id,
                        minY: frame.minY,
                        maxY: frame.maxY
                    )
                ]
            )
        }
    }

    private func updateVisibleParagraphs(_ frames: [NativeParagraphFrame]) {
        guard viewportHeight > 0 else { return }
        let visible = frames
            .filter { $0.maxY >= 0 && $0.minY <= viewportHeight }
            .sorted { lhs, rhs in lhs.minY < rhs.minY }
        let paragraphs = visible.compactMap { paragraphByID[$0.blockID] }
        guard !paragraphs.isEmpty else { return }

        if paragraphs != lastVisibleParagraphs {
            lastVisibleParagraphs = paragraphs
            onVisibleParagraphs(paragraphs)
        }

        guard let first = visible.first else { return }
        let prefix = document.prefix(before: first.blockID)
        if prefix != lastPositionPrefix {
            lastPositionPrefix = prefix
            onPositionChange(prefix)
        }
    }

    private func scrollToLanding(with proxy: ScrollViewProxy) {
        if let target = preciseLandingTarget() {
            proxy.scrollTo(
                target.blockID,
                anchor: UnitPoint(x: 0.5, y: target.localProgress)
            )
            return
        }
        guard let blockID = document.blockIDForLanding(
            landing,
            resumeUTF16Offset: resumeUTF16Offset,
            chapterPlainText: chapterPlainText
        ) else { return }
        proxy.scrollTo(blockID, anchor: landing == .end ? .bottom : .top)
    }

    private func preciseLandingTarget() -> (blockID: String, localProgress: CGFloat)? {
        guard landing == .start, resumeUTF16Offset > 0 else { return nil }
        guard let span = orderedTextSpans.first(where: { span in
            resumeUTF16Offset >= span.chapterRange.lowerBound
                && resumeUTF16Offset < span.chapterRange.upperBound
        }) else { return nil }
        let progress = min(max(span.localProgress(for: resumeUTF16Offset), 0.05), 0.95)
        return (span.blockID, progress)
    }

    private func resourceURL(for source: String) -> URL {
        let cleaned = source.components(separatedBy: "#").first ?? source
        if let absolute = URL(string: cleaned), absolute.scheme != nil {
            return absolute
        }
        let chapterDirectory = basePath
            .appendingPathComponent(chapter.href)
            .deletingLastPathComponent()
        if cleaned.hasPrefix("/") {
            return basePath.appendingPathComponent(String(cleaned.dropFirst()))
        }
        return chapterDirectory.appendingPathComponent(cleaned)
    }

    private func mergeRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.sorted {
            if $0.lowerBound != $1.lowerBound {
                return $0.lowerBound < $1.lowerBound
            }
            return $0.upperBound < $1.upperBound
        }
        var merged: [Range<Int>] = []
        for range in sorted {
            guard !range.isEmpty else { continue }
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func headingSize(_ level: Int) -> Double {
        switch level {
        case 1: fontSize + 10
        case 2: fontSize + 6
        case 3: fontSize + 3
        default: fontSize + 1
        }
    }

    private func textLineSpacing(for size: Double) -> CGFloat {
        max(3, CGFloat((lineSpacing - 1) * size))
    }

    private func horizontalPadding(for width: CGFloat) -> CGFloat {
        #if os(macOS)
        max(46, min(96, width * 0.12))
        #else
        max(22, min(34, width * 0.08))
        #endif
    }
}

private struct NativeParagraphFrame: Equatable {
    var blockID: String
    var minY: CGFloat
    var maxY: CGFloat
}

private struct NativeParagraphFrameKey: PreferenceKey {
    static var defaultValue: [NativeParagraphFrame] = []

    static func reduce(
        value: inout [NativeParagraphFrame],
        nextValue: () -> [NativeParagraphFrame]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct NativeReaderImageView: View {
    let url: URL
    let alt: String?

    @Environment(\.emptyPalette) private var palette
    @State private var loadTask: Task<Void, Never>?
    #if canImport(UIKit)
    @State private var image: UIImage?
    #elseif canImport(AppKit)
    @State private var image: NSImage?
    #endif

    var body: some View {
        Group {
            #if canImport(UIKit)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
            #elseif canImport(AppKit)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
            #else
            placeholder
            #endif
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear(perform: loadImage)
        .onDisappear { loadTask?.cancel() }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.system(size: 22))
            if let alt, !alt.isEmpty {
                Text(alt)
                    .font(.system(size: 11))
            }
        }
        .foregroundStyle(palette.ink3)
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(palette.side, in: RoundedRectangle(cornerRadius: 14))
    }

    private func loadImage() {
        guard loadTask == nil else { return }
        #if canImport(UIKit)
        guard image == nil else { return }
        #elseif canImport(AppKit)
        guard image == nil else { return }
        #endif

        loadTask = Task(priority: .utility) {
            guard let data = try? Data(contentsOf: url), !Task.isCancelled else {
                await MainActor.run { loadTask = nil }
                return
            }
            #if canImport(UIKit)
            let loadedImage = UIImage(data: data)
            await MainActor.run {
                if !Task.isCancelled {
                    image = loadedImage
                }
                loadTask = nil
            }
            #elseif canImport(AppKit)
            let loadedImage = NSImage(data: data)
            await MainActor.run {
                if !Task.isCancelled {
                    image = loadedImage
                }
                loadTask = nil
            }
            #endif
        }
    }
}
