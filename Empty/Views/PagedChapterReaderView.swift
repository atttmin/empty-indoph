//
//  PagedChapterReaderView.swift
//  Empty
//
//  微信读书-style horizontal paging for the EPUB reader: the chapter lays
//  out once into fixed-size TextKit pages (measured offscreen, one text
//  container per page), and the reader swipes, edge-taps or arrow-keys
//  between pages. Selection, highlights, 双语/导读 notes and position
//  reporting ride the same chapter-offset pipeline as the scrolling
//  reader. iOS pages with a TabView; macOS pages a single text view with
//  click zones and keyboard navigation.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
private typealias PagedFont = UIFont
private typealias PagedColor = UIColor
private typealias PagedImage = UIImage
#elseif canImport(AppKit)
import AppKit
private typealias PagedFont = NSFont
private typealias PagedColor = NSColor
private typealias PagedImage = NSImage
#endif

// MARK: - Composition

/// One block's footprint inside the composed attributed string.
private struct PagedRun {
    var blockID: String
    var paragraph: ReaderParagraph?
    /// Full range in the attributed string (marker included).
    var attrRange: NSRange
    /// Where the block's own text starts (after any list marker).
    var textLocation: Int
    /// The block's exact UTF-16 range in the chapter plain text.
    var chapterRange: Range<Int>?
}

/// Page boundaries are measured ONCE with an offscreen layout manager;
/// each visible page then gets its own independent UITextView over the
/// page's substring. Sharing live text containers with SwiftUI-managed
/// text views breaks as TabView creates and destroys pages.
private final class PaginatedChapter {
    let storage: NSTextStorage
    let pageRanges: [NSRange]
    let runs: [PagedRun]
    let pageSize: CGSize
    let version: Int

    init(
        storage: NSTextStorage,
        pageRanges: [NSRange],
        runs: [PagedRun],
        pageSize: CGSize,
        version: Int
    ) {
        self.storage = storage
        self.pageRanges = pageRanges
        self.runs = runs
        self.pageSize = pageSize
        self.version = version
    }

    var pageCount: Int { pageRanges.count }

    func characterRange(forPage index: Int) -> NSRange {
        guard pageRanges.indices.contains(index) else { return NSRange(location: 0, length: 0) }
        return pageRanges[index]
    }

    func pageText(_ index: Int) -> NSAttributedString {
        let range = characterRange(forPage: index)
        guard range.length > 0,
              range.location + range.length <= storage.length else {
            return NSAttributedString(string: " ")
        }
        return storage.attributedSubstring(from: range)
    }

    /// Chapter UTF-16 offset of the first mapped character on a page.
    func chapterOffset(forPage index: Int) -> Int? {
        let pageRange = characterRange(forPage: index)
        for run in runs {
            guard let chapterRange = run.chapterRange else { continue }
            let textEnd = run.attrRange.location + run.attrRange.length
            guard textEnd > pageRange.location else { continue }
            let attrStart = max(run.textLocation, pageRange.location)
            let delta = max(0, attrStart - run.textLocation)
            return min(chapterRange.lowerBound + delta, chapterRange.upperBound)
        }
        return nil
    }

    /// First page whose content reaches the chapter offset.
    func page(forChapterOffset offset: Int) -> Int? {
        guard let run = runs.last(where: { run in
            guard let range = run.chapterRange else { return false }
            return range.lowerBound <= offset
        }), let chapterRange = run.chapterRange else { return nil }
        let delta = max(0, min(offset, chapterRange.upperBound) - chapterRange.lowerBound)
        let attrLocation = run.textLocation + delta
        for (index, pageRange) in pageRanges.enumerated() {
            if attrLocation < pageRange.location + pageRange.length {
                return index
            }
        }
        return pageRanges.indices.last
    }

    /// Paragraphs whose runs intersect the page.
    func paragraphs(onPage index: Int) -> [ReaderParagraph] {
        let pageRange = characterRange(forPage: index)
        return runs.compactMap { run in
            guard let paragraph = run.paragraph,
                  NSIntersectionRange(run.attrRange, pageRange).length > 0 else {
                return nil
            }
            return paragraph
        }
    }

    /// Maps a storage-coordinate selection to the chapter's UTF-16 range.
    func chapterRange(forAttrRange selection: NSRange) -> Range<Int>? {
        let selectionEnd = selection.location + selection.length
        let mapped = runs.compactMap { run -> Range<Int>? in
            guard let chapterRange = run.chapterRange else { return nil }
            let runTextEnd = run.attrRange.location + run.attrRange.length
            let lower = max(selection.location, run.textLocation)
            let upper = min(selectionEnd, runTextEnd)
            guard upper > lower else { return nil }
            let start = chapterRange.lowerBound + (lower - run.textLocation)
            let end = min(chapterRange.lowerBound + (upper - run.textLocation), chapterRange.upperBound)
            guard end > start else { return nil }
            return start..<end
        }
        guard let first = mapped.first, let last = mapped.last else { return nil }
        return first.lowerBound..<last.upperBound
    }
}

private struct PageComposer {
    let document: NativeChapterDocument
    let blockSpans: [String: NativeTextBlockSpan]
    let chapterPlainText: String?
    let basePath: URL
    let chapterHref: String
    let fontSize: Double
    let lineSpacing: Double
    let appearance: ReaderAppearance
    let isDarkCanvas: Bool
    let inlineMode: InlineNoteKind
    let inlineNotes: [InlineNotePaint]
    let highlights: [HighlightPaint]
    let pageSize: CGSize

    func compose(version: Int) -> PaginatedChapter {
        let (attributed, runs) = buildAttributed()
        paintHighlights(on: attributed, runs: runs)

        // Offscreen measurement pass: page boundaries only.
        let measureStorage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        measureStorage.addLayoutManager(layoutManager)

        var pageRanges: [NSRange] = []
        repeat {
            let container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            let glyphRange = layoutManager.glyphRange(for: container)
            let charRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            pageRanges.append(charRange)
            if glyphRange.location + glyphRange.length >= layoutManager.numberOfGlyphs {
                break
            }
        } while pageRanges.count < 1200

        if pageRanges.isEmpty {
            pageRanges = [NSRange(location: 0, length: attributed.length)]
        }

        return PaginatedChapter(
            storage: NSTextStorage(attributedString: attributed),
            pageRanges: pageRanges,
            runs: runs,
            pageSize: pageSize,
            version: version
        )
    }

    // MARK: Attributed text

    private var inkPrimary: PagedColor {
        let hexes = appearance.theme.inkHexes(baseIsDark: isDarkCanvas)
        return PagedColor(hex: hexes.primary)
    }

    private var inkSecondary: PagedColor {
        let hexes = appearance.theme.inkHexes(baseIsDark: isDarkCanvas)
        return PagedColor(hex: hexes.secondary)
    }

    private var accent: PagedColor {
        PagedColor(hex: appearance.theme.isDarkCanvas(baseIsDark: isDarkCanvas) ? 0xD86B47 : 0xB5482A)
    }

    private var openingParagraphID: String? {
        document.blocks.first { block in
            if case .paragraph = block { return true }
            return false
        }?.id
    }

    private func bodyFont(size: Double, bold: Bool = false) -> PagedFont {
        #if canImport(UIKit)
        if let family = appearance.font.familyName {
            var descriptor = UIFontDescriptor(fontAttributes: [.family: family])
            if bold, let boldDescriptor = descriptor.withSymbolicTraits(.traitBold) {
                descriptor = boldDescriptor
            }
            let font = UIFont(descriptor: descriptor, size: size)
            if font.familyName == family { return font }
        }
        let base = UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        guard appearance.font.usesSerifDesign,
              let descriptor = base.fontDescriptor.withDesign(.serif) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: size)
        #else
        if let family = appearance.font.familyName {
            var descriptor = NSFontDescriptor(fontAttributes: [.family: family])
            if bold {
                descriptor = descriptor.withSymbolicTraits(.bold)
            }
            if let font = NSFont(descriptor: descriptor, size: size),
               font.familyName == family {
                return font
            }
        }
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        guard appearance.font.usesSerifDesign,
              let descriptor = base.fontDescriptor.withDesign(.serif),
              let font = NSFont(descriptor: descriptor, size: size) else {
            return base
        }
        return font
        #endif
    }

    private func paragraphStyle(
        spacingBefore: CGFloat = 0,
        spacing: CGFloat,
        headIndent: CGFloat = 0,
        firstLineHeadIndent: CGFloat? = nil,
        justified: Bool = false
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = max(3, CGFloat((lineSpacing - 1) * fontSize))
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = spacingBefore
        style.headIndent = headIndent
        style.firstLineHeadIndent = firstLineHeadIndent ?? headIndent
        style.alignment = justified ? .justified : .natural
        return style
    }

    private func buildAttributed() -> (NSMutableAttributedString, [PagedRun]) {
        let result = NSMutableAttributedString()
        var runs: [PagedRun] = []

        func appendBlockText(
            _ block: NativeChapterBlock,
            text: String,
            marker: String = "",
            attributes: [NSAttributedString.Key: Any]
        ) {
            let start = result.length
            let full = marker + text
            result.append(NSAttributedString(string: full, attributes: attributes))
            runs.append(PagedRun(
                blockID: block.id,
                paragraph: block.readerParagraph,
                attrRange: NSRange(location: start, length: full.utf16.count),
                textLocation: start + marker.utf16.count,
                chapterRange: blockSpans[block.id]?.chapterRange
            ))
            result.append(NSAttributedString(string: "\n", attributes: attributes))
        }

        func appendNote(for paragraph: ReaderParagraph) {
            guard inlineMode != .none else { return }
            let note = inlineNotes.first(where: { $0.idx == paragraph.idx })
            let label = inlineMode.label

            // Untranslated paragraphs show a quiet pending/failed line
            // instead of silently nothing — the retry pipeline fills it
            // in and the page re-anchors in place.
            let body: String
            let bodyColor: PagedColor
            if let note, !note.failed, !note.text.isEmpty {
                body = note.text
                bodyColor = inkSecondary
            } else if let note, note.failed {
                body = "暂不可用，将自动重试。"
                bodyColor = inkSecondary.withAlphaComponent(0.7)
            } else {
                body = "⟳ 生成中…"
                bodyColor = inkSecondary.withAlphaComponent(0.55)
            }

            let noteSpacing = appearance.paragraphSpacing(fontSize: max(13, fontSize - 2.5)) * 0.9
            let attributes: [NSAttributedString.Key: Any] = [
                .font: bodyFont(size: max(13, fontSize - 2.5)),
                .foregroundColor: bodyColor,
                .paragraphStyle: paragraphStyle(
                    spacing: noteSpacing,
                    headIndent: 14
                ),
            ]
            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: PagedFont.systemFont(ofSize: max(10, fontSize - 7), weight: .bold),
                .foregroundColor: accent,
                .paragraphStyle: paragraphStyle(
                    spacing: noteSpacing,
                    headIndent: 14
                ),
            ]
            result.append(NSAttributedString(string: "\(label) · ", attributes: labelAttributes))
            result.append(NSAttributedString(string: body + "\n", attributes: attributes))
        }

        for block in document.blocks {
            switch block {
            case .heading(_, let level, let text):
                let size = fontSize + [10.0, 6, 3, 1, 1, 1][min(max(level - 1, 0), 5)]
                appendBlockText(block, text: text, attributes: [
                    .font: bodyFont(size: size, bold: true),
                    .foregroundColor: inkPrimary,
                    .paragraphStyle: paragraphStyle(
                        spacingBefore: fontSize * (level <= 2 ? 1.1 : 0.7),
                        spacing: appearance.paragraphSpacing(fontSize: size) * 1.08
                    ),
                ])

            case .paragraph(_, _, let text):
                let opening = block.id == openingParagraphID
                let size = appearance.openingFontSize(base: fontSize, isOpeningParagraph: opening)
                let start = result.length
                appendBlockText(block, text: text, attributes: [
                    .font: bodyFont(size: size),
                    .foregroundColor: inkPrimary,
                    .paragraphStyle: paragraphStyle(
                        spacing: appearance.paragraphSpacing(fontSize: size),
                        firstLineHeadIndent: appearance.firstLineIndentPoints(
                            fontSize: size,
                            isOpeningParagraph: opening
                        ),
                        justified: appearance.textAlignment.usesJustifiedText
                    ),
                ])
                if opening, appearance.chapterOpening.usesDropCap {
                    let dropSize = appearance.dropCapFontSize(base: size)
                    let capLength = min(1, text.utf16.count)
                    let capRange = NSRange(location: start, length: capLength)
                    result.addAttribute(.font, value: bodyFont(size: dropSize), range: capRange)
                }
                if let paragraph = block.readerParagraph { appendNote(for: paragraph) }

            case .quote(_, _, let text):
                appendBlockText(block, text: text, attributes: [
                    .font: bodyFont(size: fontSize),
                    .foregroundColor: inkSecondary,
                    .paragraphStyle: paragraphStyle(
                        spacing: appearance.paragraphSpacing(fontSize: fontSize),
                        headIndent: 16
                    ),
                ])
                if let paragraph = block.readerParagraph { appendNote(for: paragraph) }

            case .listItem(_, _, let text, let level, let marker):
                appendBlockText(block, text: text, marker: marker + " ", attributes: [
                    .font: bodyFont(size: fontSize),
                    .foregroundColor: inkPrimary,
                    .paragraphStyle: paragraphStyle(
                        spacing: appearance.paragraphSpacing(fontSize: fontSize) * 0.78,
                        headIndent: CGFloat(max(0, level - 1)) * 18 + 4,
                        firstLineHeadIndent: 0
                    ),
                ])
                if let paragraph = block.readerParagraph { appendNote(for: paragraph) }

            case .footnote(_, _, let text):
                appendBlockText(block, text: text, marker: "注 · ", attributes: [
                    .font: bodyFont(size: max(12, fontSize - 2.5)),
                    .foregroundColor: inkSecondary,
                    .paragraphStyle: paragraphStyle(
                        spacing: appearance.paragraphSpacing(fontSize: max(12, fontSize - 2.5)) * 0.72,
                        headIndent: 10,
                        firstLineHeadIndent: 0
                    ),
                ])
                if let paragraph = block.readerParagraph { appendNote(for: paragraph) }

            case .code(_, let text):
                appendBlockText(block, text: text, attributes: [
                    .font: PagedFont.monospacedSystemFont(ofSize: max(12, fontSize - 3), weight: .regular),
                    .foregroundColor: inkPrimary,
                    .paragraphStyle: paragraphStyle(
                        spacing: appearance.paragraphSpacing(fontSize: max(12, fontSize - 3)) * 0.82,
                        headIndent: 8
                    ),
                ])

            case .table(_, let rows):
                let text = rows
                    .map { $0.joined(separator: "  ·  ") }
                    .joined(separator: "\n")
                guard !text.isEmpty else { continue }
                result.append(NSAttributedString(
                    string: text + "\n",
                    attributes: [
                        .font: PagedFont.monospacedSystemFont(ofSize: max(11, fontSize - 4), weight: .regular),
                        .foregroundColor: inkSecondary,
                        .paragraphStyle: paragraphStyle(spacing: fontSize * 0.62, headIndent: 8),
                    ]
                ))

            case .image(_, let source, let alt):
                appendImage(source: source, alt: alt, into: result)
            }
        }

        if result.length == 0 {
            result.append(NSAttributedString(
                string: " ",
                attributes: [.font: bodyFont(size: fontSize)]
            ))
        }
        return (result, runs)
    }

    private func appendImage(source: String, alt: String?, into result: NSMutableAttributedString) {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.paragraphSpacing = fontSize * 0.8
        centered.paragraphSpacingBefore = fontSize * 0.5

        if let image = loadImage(source: source) {
            let maxWidth = max(40, pageSize.width - 2)
            let maxHeight = max(80, pageSize.height * 0.62)
            let scale = min(1, min(maxWidth / image.size.width, maxHeight / image.size.height))
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(
                x: 0,
                y: 0,
                width: image.size.width * scale,
                height: image.size.height * scale
            )
            let attachmentString = NSMutableAttributedString(attachment: attachment)
            attachmentString.addAttribute(
                .paragraphStyle,
                value: centered,
                range: NSRange(location: 0, length: attachmentString.length)
            )
            result.append(attachmentString)
            result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: centered]))
        }

        if let alt, !alt.isEmpty {
            result.append(NSAttributedString(
                string: alt + "\n",
                attributes: [
                    .font: bodyFont(size: max(11, fontSize - 5)),
                    .foregroundColor: inkSecondary,
                    .paragraphStyle: centered,
                ]
            ))
        }
    }

    private func loadImage(source: String) -> PagedImage? {
        let cleaned = source.components(separatedBy: "#").first ?? source
        let chapterDirectory = basePath
            .appendingPathComponent(chapterHref)
            .deletingLastPathComponent()
        let url: URL
        if cleaned.hasPrefix("/") {
            url = basePath.appendingPathComponent(String(cleaned.dropFirst()))
        } else {
            url = chapterDirectory.appendingPathComponent(cleaned)
        }
        return PagedImage(contentsOfFile: url.path)
    }

    private func paintHighlights(on attributed: NSMutableAttributedString, runs: [PagedRun]) {
        let darkCanvas = appearance.theme.isDarkCanvas(baseIsDark: isDarkCanvas)
        for highlight in highlights {
            guard let start = highlight.startUTF16,
                  let end = highlight.endUTF16,
                  end > start else { continue }
            let tint = PagedColor(hex: highlight.colorHex ?? HighlightColor.yellow.hex)
                .withAlphaComponent(darkCanvas ? 0.66 : 0.82)
            for run in runs {
                guard let chapterRange = run.chapterRange,
                      let local = NativeTextBlockSpan(
                        blockID: run.blockID,
                        chapterRange: chapterRange,
                        paragraphInfo: nil
                      ).localRange(intersecting: start..<end) else { continue }
                let runTextLength = run.attrRange.length - (run.textLocation - run.attrRange.location)
                let lower = min(local.lowerBound, runTextLength)
                let upper = min(local.upperBound, runTextLength)
                guard upper > lower else { continue }
                let range = NSRange(location: run.textLocation + lower, length: upper - lower)
                // 底线染色 per the visual-polish spec, never a block.
                attributed.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.thick.rawValue,
                    range: range
                )
                attributed.addAttribute(.underlineColor, value: tint, range: range)
            }
        }
    }
}

// MARK: - SwiftUI view (iOS pager)

#if os(iOS)
struct PagedChapterReaderView: View {
    let chapter: EPUBChapter
    let basePath: URL
    let fontSize: Double
    let lineSpacing: Double
    let landing: ChapterLanding
    let resumeUTF16Offset: Int
    let chapterPlainText: String?
    let highlights: [HighlightPaint]
    let inlineMode: InlineNoteKind
    let inlineNotes: [InlineNotePaint]
    var appearance: ReaderAppearance = ReaderAppearance()
    var selectionActive: Bool = false
    var onTap: () -> Void = {}
    var onChapterBoundary: (PageTurnDirection) -> Void = { _ in }
    var onSelectionChange: (ReaderSelection?) -> Void = { _ in }
    var onPositionChange: (String) -> Void = { _ in }
    var onVisibleParagraphs: ([ReaderParagraph]) -> Void = { _ in }
    var onPageInfo: (Int, Int) -> Void = { _, _ in }

    private let document: NativeChapterDocument
    private let blockSpans: [String: NativeTextBlockSpan]

    @Environment(\.emptyPalette) private var palette
    @State private var paginated: PaginatedChapter?
    @State private var pageIndex = 0
    @State private var composeVersion = 0
    @State private var lastComposeKey: ComposeKey?

    private struct ComposeKey: Equatable {
        var width: CGFloat
        var height: CGFloat
        var fontSize: Double
        var lineSpacing: Double
        var appearance: ReaderAppearance
        var isDark: Bool
        var inlineMode: InlineNoteKind
        var noteFingerprint: Int
        var highlightFingerprint: Int
    }

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
        inlineNotes: [InlineNotePaint],
        appearance: ReaderAppearance = ReaderAppearance(),
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
        self.inlineNotes = inlineNotes
        self.appearance = appearance
        self.selectionActive = selectionActive
        self.onTap = onTap
        self.onChapterBoundary = onChapterBoundary
        self.onSelectionChange = onSelectionChange
        self.onPositionChange = onPositionChange
        self.onVisibleParagraphs = onVisibleParagraphs
        self.onPageInfo = onPageInfo

        let parsed = NativeChapterParser.parse(chapter)
        self.document = parsed
        self.blockSpans = NativeChapterParser.resolvedSpans(
            for: chapter, document: parsed, chapterPlainText: chapterPlainText
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let pageInset = horizontalInset(for: geometry.size.width)
            let textSize = CGSize(
                width: max(40, geometry.size.width - pageInset * 2),
                height: max(80, geometry.size.height - verticalInset * 2 - pageFooterHeight)
            )
            ZStack {
                palette.window.ignoresSafeArea()

                if let paginated {
                    TabView(selection: $pageIndex) {
                        ForEach(0..<paginated.pageCount, id: \.self) { index in
                            ZStack(alignment: .bottom) {
                                pageBackdrop(
                                    horizontalInset: pageInset,
                                    verticalInset: verticalInset
                                )

                                VStack(spacing: 0) {
                                    if index == 0, appearance.chapterOpening.showsChapterHeader {
                                        pageChapterHeader(fontSize: fontSize)
                                            .padding(.horizontal, pageInset)
                                            .padding(.top, verticalInset + 4)
                                    }

                                    PageTextView(
                                        text: paginated.pageText(index),
                                        globalLocation: paginated.characterRange(forPage: index).location,
                                        clearSelection: !selectionActive,
                                        onSelectionChange: { handleSelection($0) },
                                        onTapAt: { handleTap(fraction: $0) }
                                    )
                                    .frame(
                                        width: textSize.width,
                                        height: max(40, textSize.height - (index == 0 && appearance.chapterOpening.showsChapterHeader ? appearance.chapterHeaderSpacing(fontSize: fontSize) : 0))
                                    )
                                    .padding(.horizontal, pageInset)
                                    .padding(.top, index == 0 && appearance.chapterOpening.showsChapterHeader ? 0 : verticalInset)
                                    .padding(.bottom, verticalInset + pageFooterHeight)
                                }

                                pageFooter(index: index, count: paginated.pageCount)
                                    .padding(.horizontal, pageInset + 4)
                                    .padding(.bottom, verticalInset * 0.78)
                            }
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .id(paginated.version)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleTap(fraction: geometry.size.width > 0 ? location.x / geometry.size.width : 0.5)
            }
            .onAppear {
                recomposeIfNeeded(textSize: textSize)
            }
            .onChange(of: composeKey(textSize: textSize)) { _, _ in
                recomposeIfNeeded(textSize: textSize)
            }
            .onChange(of: pageIndex) { _, newIndex in
                reportPage(newIndex)
            }
        }
    }

    private var pageFooterHeight: CGFloat { 30 }
    private var verticalInset: CGFloat { 14 }

    private func horizontalInset(for width: CGFloat) -> CGFloat {
        appearance.pagedHorizontalInset(viewWidth: width, isMac: false)
    }

    private func pageBackdrop(horizontalInset: CGFloat, verticalInset: CGFloat) -> some View {
        PaperPageBackground(
            fill: appearance.theme.pageFill(baseIsDark: palette.isDark),
            isDark: palette.isDark
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(
                    appearance.theme.pageRule(baseIsDark: palette.isDark),
                    lineWidth: 1
                )
        )
        .shadow(
            color: palette.isDark ? .black.opacity(0.28) : Color.black.opacity(0.10),
            radius: 26,
            y: 14
        )
        .shadow(
            color: palette.isDark ? .black.opacity(0.16) : Color.black.opacity(0.05),
            radius: 7,
            y: 3
        )
        .padding(.horizontal, horizontalInset * 0.46)
        .padding(.vertical, verticalInset * 0.4)
    }

    private func pageFooter(index: Int, count: Int) -> some View {
        let chapterLabel = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "本章"
            : chapter.title
        return HStack(spacing: 10) {
            Text(chapterLabel)
                .lineLimit(1)
            Spacer(minLength: 10)
            Text("第 \(index + 1) / \(count) 页")
                .monospacedDigit()
        }
        .font(.system(size: 11.5, weight: .medium, design: .serif))
        .foregroundStyle(palette.ink3)
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(appearance.theme.pageRule(baseIsDark: palette.isDark))
                .frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(chapterLabel) · 第 \(index + 1) / \(count) 页")
        .accessibilityIdentifier("reader.page.footer")
    }
    /// Book-style chapter header for the first page of a paged chapter.
    private func pageChapterHeader(fontSize: Double) -> some View {
        let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .center, spacing: 8) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: max(12, fontSize - 2), weight: .bold, design: .serif))
                    .foregroundStyle(palette.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            HStack(spacing: 8) {
                Rectangle()
                    .fill(appearance.theme.pageRule(baseIsDark: palette.isDark))
                    .frame(height: 1)
                Text("❦")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.ink3)
                Rectangle()
                    .fill(appearance.theme.pageRule(baseIsDark: palette.isDark))
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 4)
    }

    /// 微信读书-style tap navigation: left quarter back, right quarter
    /// forward, middle toggles the chrome. A pending selection makes the
    /// first tap dismiss it instead of turning a page.
    private func handleTap(fraction: CGFloat) {
        if selectionActive {
            onSelectionChange(nil)
            return
        }
        if fraction < 0.26 {
            turnPage(-1)
        } else if fraction > 0.74 {
            turnPage(1)
        } else {
            onSelectionChange(nil)
            onTap()
        }
    }

    private func turnPage(_ delta: Int) {
        guard let paginated else { return }
        let target = pageIndex + delta
        if target < 0 {
            onChapterBoundary(.backward)
            return
        }
        if target >= paginated.pageCount {
            onChapterBoundary(.forward)
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            pageIndex = target
        }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func composeKey(textSize: CGSize) -> ComposeKey {
        ComposeKey(
            width: textSize.width,
            height: textSize.height,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            appearance: appearance,
            isDark: palette.isDark,
            inlineMode: inlineMode,
            noteFingerprint: inlineNotes.reduce(0) { partial, note in
                partial &+ note.idx &* 31 &+ note.text.utf16.count &+ (note.failed ? 7 : 0)
            },
            highlightFingerprint: highlights.reduce(0) { partial, paint in
                partial &+ (paint.startUTF16 ?? 0) &* 31 &+ (paint.endUTF16 ?? 0)
            }
        )
    }

    private func recomposeIfNeeded(textSize: CGSize) {
        let key = composeKey(textSize: textSize)
        guard key != lastComposeKey else { return }
        lastComposeKey = key

        // Keep the reader's place across re-layout (notes arriving,
        // font/theme changes, rotation).
        let anchorOffset = paginated.flatMap { $0.chapterOffset(forPage: pageIndex) }

        let composer = PageComposer(
            document: document,
            blockSpans: blockSpans,
            chapterPlainText: chapterPlainText,
            basePath: basePath,
            chapterHref: chapter.href,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            appearance: appearance,
            isDarkCanvas: palette.isDark,
            inlineMode: inlineMode,
            inlineNotes: inlineNotes,
            highlights: highlights,
            pageSize: textSize
        )
        composeVersion += 1
        let next = composer.compose(version: composeVersion)
        paginated = next

        let landingPage: Int
        if let anchorOffset, let page = next.page(forChapterOffset: anchorOffset) {
            landingPage = page
        } else {
            switch landing {
            case .end:
                landingPage = max(0, next.pageCount - 1)
            case .start:
                if resumeUTF16Offset > 0,
                   let page = next.page(forChapterOffset: resumeUTF16Offset) {
                    landingPage = page
                } else {
                    landingPage = 0
                }
            }
        }
        pageIndex = min(landingPage, max(0, next.pageCount - 1))
        reportPage(pageIndex)
    }

    private func reportPage(_ index: Int) {
        guard let paginated else { return }
        onPageInfo(index, paginated.pageCount)

        let paragraphs = paginated.paragraphs(onPage: index)
        if !paragraphs.isEmpty {
            onVisibleParagraphs(paragraphs)
        }

        if let offset = paginated.chapterOffset(forPage: index) {
            let source = chapterPlainText ?? document.plainText
            let utf16 = Array(source.utf16)
            let clamped = max(0, min(offset, utf16.count))
            onPositionChange(String(decoding: utf16[0..<clamped], as: UTF16.self))
        }
    }

    private func handleSelection(_ attrRange: NSRange?) {
        guard let attrRange, attrRange.length > 0, let paginated else {
            onSelectionChange(nil)
            return
        }
        guard let chapterRange = paginated.chapterRange(forAttrRange: attrRange) else {
            onSelectionChange(nil)
            return
        }
        let source = chapterPlainText ?? document.plainText
        onSelectionChange(
            ReaderSelectionContext.selection(in: source, utf16Range: chapterRange)
        )
    }
}

// MARK: - Page text view

private struct PageTextView: UIViewRepresentable {
    /// The page's own slice of the chapter — every page view is fully
    /// independent, so TabView can create/destroy pages freely.
    let text: NSAttributedString
    /// Where this page starts in the composed chapter string; selection
    /// ranges are reported back in chapter-storage coordinates.
    let globalLocation: Int
    let clearSelection: Bool
    let onSelectionChange: (NSRange?) -> Void
    /// Tap location as an x-fraction of the page width (page turning).
    let onTapAt: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            globalLocation: globalLocation,
            onSelectionChange: onSelectionChange,
            onTapAt: onTapAt
        )
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(frame: .zero)
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        // Without low compression resistance SwiftUI sizes the view to
        // its longest unwrapped line, centers the overflow and clips
        // both edges — the页面 looked like sliced text.
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        textView.dataDetectorTypes = []
        textView.clipsToBounds = true
        textView.delegate = context.coordinator
        textView.attributedText = text

        // UITextView's own recognizers swallow single taps, so page
        // turning listens directly on the view; touches still reach the
        // text interactions (long-press selection keeps working).
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        textView.addGestureRecognizer(tap)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.globalLocation = globalLocation
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onTapAt = onTapAt
        if !textView.attributedText.isEqual(to: text) {
            context.coordinator.programmatic = true
            textView.attributedText = text
            context.coordinator.programmatic = false
        }
        if clearSelection, textView.selectedRange.length > 0 {
            context.coordinator.programmatic = true
            textView.selectedRange = NSRange(location: NSNotFound, length: 0)
            context.coordinator.programmatic = false
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var globalLocation: Int
        var onSelectionChange: (NSRange?) -> Void
        var onTapAt: (CGFloat) -> Void
        var programmatic = false

        init(
            globalLocation: Int,
            onSelectionChange: @escaping (NSRange?) -> Void,
            onTapAt: @escaping (CGFloat) -> Void
        ) {
            self.globalLocation = globalLocation
            self.onSelectionChange = onSelectionChange
            self.onTapAt = onTapAt
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !programmatic else { return }
            let range = textView.selectedRange
            guard range.location != NSNotFound, range.length > 0 else {
                onSelectionChange(nil)
                return
            }
            onSelectionChange(NSRange(location: globalLocation + range.location, length: range.length))
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view, view.bounds.width > 0 else { return }
            let fraction = recognizer.location(in: view).x / view.bounds.width
            onTapAt(fraction)
        }
    }
}
#endif

// MARK: - macOS pager

#if os(macOS)
struct MacPagedChapterReaderView: View {
    let chapter: EPUBChapter
    let basePath: URL
    let fontSize: Double
    let lineSpacing: Double
    let landing: ChapterLanding
    let resumeUTF16Offset: Int
    let chapterPlainText: String?
    let highlights: [HighlightPaint]
    let inlineMode: InlineNoteKind
    let inlineNotes: [InlineNotePaint]
    var appearance: ReaderAppearance = ReaderAppearance()
    var selectionActive: Bool = false
    var onTap: () -> Void = {}
    var onChapterBoundary: (PageTurnDirection) -> Void = { _ in }
    var onSelectionChange: (ReaderSelection?) -> Void = { _ in }
    var onPositionChange: (String) -> Void = { _ in }
    var onVisibleParagraphs: ([ReaderParagraph]) -> Void = { _ in }
    var onPageInfo: (Int, Int) -> Void = { _, _ in }

    private let document: NativeChapterDocument
    private let blockSpans: [String: NativeTextBlockSpan]

    @Environment(\.emptyPalette) private var palette
    /// 竖排 (Mac · 翻页 · EPUB): vertical-rl via NSTextView's native
    /// layout orientation. Pagination measures with swapped page
    /// dimensions and a safety factor, so it's labeled experimental.
    @AppStorage("reader.vertical.mac") private var verticalText = false
    @State private var paginated: PaginatedChapter?
    @State private var pageIndex = 0
    @State private var pageTransitionEdge: Edge = .trailing
    @State private var composeVersion = 0
    @State private var lastComposeKey: ComposeKey?
    @FocusState private var pageFocused: Bool

    private struct ComposeKey: Equatable {
        var width: CGFloat
        var height: CGFloat
        var fontSize: Double
        var lineSpacing: Double
        var appearance: ReaderAppearance
        var isDark: Bool
        var inlineMode: InlineNoteKind
        var noteFingerprint: Int
        var highlightFingerprint: Int
        var vertical: Bool
    }

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
        inlineNotes: [InlineNotePaint],
        appearance: ReaderAppearance = ReaderAppearance(),
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
        self.inlineNotes = inlineNotes
        self.appearance = appearance
        self.selectionActive = selectionActive
        self.onTap = onTap
        self.onChapterBoundary = onChapterBoundary
        self.onSelectionChange = onSelectionChange
        self.onPositionChange = onPositionChange
        self.onVisibleParagraphs = onVisibleParagraphs
        self.onPageInfo = onPageInfo

        let parsed = NativeChapterParser.parse(chapter)
        self.document = parsed
        self.blockSpans = NativeChapterParser.resolvedSpans(
            for: chapter, document: parsed, chapterPlainText: chapterPlainText
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let pageInset = horizontalInset(for: geometry.size.width)
            let textSize = CGSize(
                width: min(
                    appearance.maxTextWidth(isMac: true),
                    max(200, geometry.size.width - pageInset * 2)
                ),
                height: max(120, geometry.size.height - verticalInset * 2 - pageFooterHeight)
            )
            ZStack {
                palette.window

                if let paginated {
                    ZStack(alignment: .bottom) {
                        pageBackdrop(
                            horizontalInset: pageInset,
                            verticalInset: verticalInset
                        )

                        MacPageTextView(
                            text: paginated.pageText(pageIndex),
                            globalLocation: paginated.characterRange(forPage: pageIndex).location,
                            pageSize: textSize,
                            vertical: verticalText,
                            clearSelection: !selectionActive,
                            onSelectionChange: { handleSelection($0) },
                            onClickAt: { handleTap(fraction: $0) }
                        )
                        .frame(width: textSize.width, height: textSize.height)
                        .padding(.horizontal, pageInset)
                        .padding(.top, verticalInset)
                        .padding(.bottom, verticalInset + pageFooterHeight)
                        .id("\(paginated.version)-\(pageIndex)")
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: pageTransitionEdge).combined(with: .opacity),
                                removal: .move(edge: pageTransitionEdge == .trailing ? .leading : .trailing).combined(with: .opacity)
                            )
                        )

                        pageFooter(count: paginated.pageCount)
                            .padding(.horizontal, pageInset + 4)
                            .padding(.bottom, verticalInset * 0.72)

                        pageArrows
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleTap(fraction: geometry.size.width > 0 ? location.x / geometry.size.width : 0.5)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($pageFocused)
            .onKeyPress(.leftArrow) { turnPage(-1); return .handled }
            .onKeyPress(.rightArrow) { turnPage(1); return .handled }
            .onKeyPress(.space) { turnPage(1); return .handled }
            .onAppear {
                recomposeIfNeeded(textSize: textSize)
                pageFocused = true
            }
            .onChange(of: composeKey(textSize: textSize)) { _, _ in
                recomposeIfNeeded(textSize: textSize)
            }
            .onChange(of: pageIndex) { _, newIndex in
                reportPage(newIndex)
            }
            .animation(.easeInOut(duration: 0.15), value: pageIndex)
        }
    }

    private var pageFooterHeight: CGFloat { 34 }
    private var verticalInset: CGFloat { 36 }

    private func horizontalInset(for width: CGFloat) -> CGFloat {
        appearance.pagedHorizontalInset(viewWidth: width, isMac: true)
    }

    private func pageBackdrop(horizontalInset: CGFloat, verticalInset: CGFloat) -> some View {
        PaperPageBackground(
            fill: appearance.theme.pageFill(baseIsDark: palette.isDark),
            isDark: palette.isDark
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(
                    appearance.theme.pageRule(baseIsDark: palette.isDark),
                    lineWidth: 1
                )
        )
        .shadow(
            color: palette.isDark ? .black.opacity(0.34) : Color.black.opacity(0.12),
            radius: 28,
            y: 16
        )
        .shadow(
            color: palette.isDark ? .black.opacity(0.18) : Color.black.opacity(0.06),
            radius: 8,
            y: 3
        )
        .padding(.horizontal, horizontalInset * 0.42)
        .padding(.vertical, verticalInset * 0.28)
    }

    private func pageFooter(count: Int) -> some View {
        let chapterLabel = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "本章"
            : chapter.title
        return HStack(spacing: 10) {
            Text(chapterLabel)
                .lineLimit(1)
            Spacer(minLength: 10)
            Text("第 \(pageIndex + 1) / \(count) 页")
                .monospacedDigit()
        }
        .font(.system(size: 11.5, weight: .medium, design: .serif))
        .foregroundStyle(palette.ink3)
        .padding(.top, 11)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(appearance.theme.pageRule(baseIsDark: palette.isDark))
                .frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(chapterLabel) · 第 \(pageIndex + 1) / \(count) 页")
        .accessibilityIdentifier("reader.page.footer")
    }

    private var pageArrows: some View {
        HStack {
            arrowButton("chevron.left") { turnPage(-1) }
            Spacer()
            arrowButton("chevron.right") { turnPage(1) }
        }
        .padding(.horizontal, 16)
    }

    private func arrowButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.ink3)
                .frame(width: 32, height: 56)
                .background(palette.side.opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    private func handleTap(fraction: CGFloat) {
        if selectionActive {
            onSelectionChange(nil)
            return
        }
        if fraction < 0.18 {
            turnPage(-1)
        } else if fraction > 0.82 {
            turnPage(1)
        } else {
            onTap()
        }
    }

    private func turnPage(_ delta: Int) {
        guard let paginated else { return }
        let target = pageIndex + delta
        if target < 0 {
            onChapterBoundary(.backward)
            return
        }
        if target >= paginated.pageCount {
            onChapterBoundary(.forward)
            return
        }
        pageTransitionEdge = delta > 0 ? .trailing : .leading
        pageIndex = target
    }

    private func composeKey(textSize: CGSize) -> ComposeKey {
        ComposeKey(
            width: textSize.width,
            height: textSize.height,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            appearance: appearance,
            isDark: palette.isDark,
            inlineMode: inlineMode,
            noteFingerprint: inlineNotes.reduce(0) { partial, note in
                partial &+ note.idx &* 31 &+ note.text.utf16.count &+ (note.failed ? 7 : 0)
            },
            highlightFingerprint: highlights.reduce(0) { partial, paint in
                partial &+ (paint.startUTF16 ?? 0) &* 31 &+ (paint.endUTF16 ?? 0)
            },
            vertical: verticalText
        )
    }

    private func recomposeIfNeeded(textSize: CGSize) {
        let key = composeKey(textSize: textSize)
        guard key != lastComposeKey else { return }
        lastComposeKey = key

        let anchorOffset = paginated.flatMap { $0.chapterOffset(forPage: pageIndex) }

        // Vertical pages flow in columns: measure with swapped
        // dimensions and a safety factor against metric drift between
        // horizontal measurement and vertical display.
        let measureSize = verticalText
            ? CGSize(width: textSize.height * 0.9, height: textSize.width)
            : textSize
        let composer = PageComposer(
            document: document,
            blockSpans: blockSpans,
            chapterPlainText: chapterPlainText,
            basePath: basePath,
            chapterHref: chapter.href,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            appearance: appearance,
            isDarkCanvas: palette.isDark,
            inlineMode: inlineMode,
            inlineNotes: inlineNotes,
            highlights: highlights,
            pageSize: measureSize
        )
        composeVersion += 1
        let next = composer.compose(version: composeVersion)
        paginated = next

        let landingPage: Int
        if let anchorOffset, let page = next.page(forChapterOffset: anchorOffset) {
            landingPage = page
        } else {
            switch landing {
            case .end:
                landingPage = max(0, next.pageCount - 1)
            case .start:
                if resumeUTF16Offset > 0,
                   let page = next.page(forChapterOffset: resumeUTF16Offset) {
                    landingPage = page
                } else {
                    landingPage = 0
                }
            }
        }
        pageIndex = min(landingPage, max(0, next.pageCount - 1))
        reportPage(pageIndex)
    }

    private func reportPage(_ index: Int) {
        guard let paginated else { return }
        onPageInfo(index, paginated.pageCount)

        let paragraphs = paginated.paragraphs(onPage: index)
        if !paragraphs.isEmpty {
            onVisibleParagraphs(paragraphs)
        }

        if let offset = paginated.chapterOffset(forPage: index) {
            let source = chapterPlainText ?? document.plainText
            let utf16 = Array(source.utf16)
            let clamped = max(0, min(offset, utf16.count))
            onPositionChange(String(decoding: utf16[0..<clamped], as: UTF16.self))
        }
    }

    private func handleSelection(_ attrRange: NSRange?) {
        guard let attrRange, attrRange.length > 0, let paginated else {
            onSelectionChange(nil)
            return
        }
        guard let chapterRange = paginated.chapterRange(forAttrRange: attrRange) else {
            onSelectionChange(nil)
            return
        }
        let source = chapterPlainText ?? document.plainText
        onSelectionChange(
            ReaderSelectionContext.selection(in: source, utf16Range: chapterRange)
        )
    }
}

private struct MacPageTextView: NSViewRepresentable {
    let text: NSAttributedString
    let globalLocation: Int
    let pageSize: CGSize
    var vertical: Bool = false
    let clearSelection: Bool
    let onSelectionChange: (NSRange?) -> Void
    let onClickAt: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            globalLocation: globalLocation,
            onSelectionChange: onSelectionChange,
            onClickAt: onClickAt
        )
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(frame: NSRect(origin: .zero, size: pageSize))
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.importsGraphics = false
        textView.usesFindBar = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.delegate = context.coordinator
        if vertical {
            textView.setLayoutOrientation(.vertical)
        }
        textView.textStorage?.setAttributedString(text)

        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:))
        )
        click.delaysPrimaryMouseButtonEvents = false
        textView.addGestureRecognizer(click)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.globalLocation = globalLocation
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onClickAt = onClickAt
        if textView.textStorage?.isEqual(to: text) != true {
            context.coordinator.programmatic = true
            textView.textStorage?.setAttributedString(text)
            context.coordinator.programmatic = false
        }
        if clearSelection, textView.selectedRange().length > 0 {
            context.coordinator.programmatic = true
            textView.setSelectedRange(NSRange(location: NSNotFound, length: 0))
            context.coordinator.programmatic = false
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var globalLocation: Int
        var onSelectionChange: (NSRange?) -> Void
        var onClickAt: (CGFloat) -> Void
        var programmatic = false

        init(
            globalLocation: Int,
            onSelectionChange: @escaping (NSRange?) -> Void,
            onClickAt: @escaping (CGFloat) -> Void
        ) {
            self.globalLocation = globalLocation
            self.onSelectionChange = onSelectionChange
            self.onClickAt = onClickAt
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !programmatic,
                  let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            guard range.location != NSNotFound, range.length > 0 else {
                onSelectionChange(nil)
                return
            }
            onSelectionChange(NSRange(location: globalLocation + range.location, length: range.length))
        }

        @objc func handleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let view = recognizer.view, view.bounds.width > 0 else { return }
            let fraction = recognizer.location(in: view).x / view.bounds.width
            onClickAt(fraction)
        }
    }
}
#endif

// MARK: - Paper page background

/// A rounded page surface with paper fill, subtle fiber texture, and inner
/// edge shading that gives the card a tactile, book-like depth.
private struct PaperPageBackground: View {
    let fill: Color
    let isDark: Bool
    let cornerRadius: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(fill)
            .overlay(
                PaperTextureOverlay(isDark: isDark)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            )
            .overlay(
                PaperInnerShadow(isDark: isDark)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            )
            .overlay(
                PageEdgeCurl(isDark: isDark)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            )
    }
}

/// Subtle trailing-edge curl shadow that suggests the page can be lifted and
/// turned, reinforcing the physical paper metaphor without competing with text.
private struct PageEdgeCurl: View {
    let isDark: Bool

    var body: some View {
        GeometryReader { geometry in
            let edgeWidth = min(28, geometry.size.width * 0.08)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [
                        Color.black.opacity(0),
                        Color.black.opacity(isDark ? 0.10 : 0.04),
                        Color.black.opacity(isDark ? 0.18 : 0.07)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: edgeWidth)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isDark ? 0.04 : 0.18),
                                    Color.white.opacity(0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Very subtle randomized dots that break up the flat digital fill and read
/// as paper fiber. Cached as a layer via `.drawingGroup()` so it does not
/// re-render on every SwiftUI reconciliation.
private struct PaperTextureOverlay: View {
    let isDark: Bool

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 4
            for x in stride(from: 0, to: size.width, by: spacing) {
                for y in stride(from: 0, to: size.height, by: spacing) {
                    let jitterX = CGFloat.random(in: -1...1)
                    let jitterY = CGFloat.random(in: -1...1)
                    let opacity = Double.random(in: 0.001...0.025)
                    let rect = CGRect(x: x + jitterX, y: y + jitterY, width: 0.7, height: 0.7)
                    let color = isDark ? Color.white.opacity(opacity) : Color.black.opacity(opacity)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .drawingGroup()
    }
}

/// Inner edge shadow + a gentle left-side page-stack shadow to suggest the
/// page has thickness and sits on top of a stack of other pages.
private struct PaperInnerShadow: View {
    let isDark: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            // Thin inner stroke to separate the page from the canvas.
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.black.opacity(isDark ? 0.18 : 0.06), lineWidth: 1)

            // Left-edge page-stack shadow.
            LinearGradient(
                colors: [
                    Color.black.opacity(isDark ? 0.18 : 0.05),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 14)
            .allowsHitTesting(false)
        }
    }
}

private extension PagedColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
