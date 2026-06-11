//
//  NativeChapterDocument.swift
//  Empty
//

import Foundation

/// A small native reading model extracted from EPUB XHTML.
///
/// EPUB content is still HTML, but the reader does not need a browser for the
/// common long-form path: headings, paragraphs, quotes, list items, and images
/// are enough to build a stable SwiftUI scroll view. Complex markup can keep
/// flowing through the existing WebView fallback later if needed.
nonisolated struct NativeChapterDocument: Equatable {
    var blocks: [NativeChapterBlock]

    var textBlocks: [NativeChapterBlock] {
        blocks.filter(\.isReadableText)
    }

    var plainText: String {
        textBlocks.map(\.text).joined(separator: "\n")
    }

    func blockIDForLanding(
        _ landing: ChapterLanding,
        resumeUTF16Offset: Int,
        chapterPlainText: String?
    ) -> String? {
        switch landing {
        case .end:
            return textBlocks.last?.id ?? blocks.last?.id
        case .start:
            guard resumeUTF16Offset > 0,
                  let chapterPlainText,
                  !chapterPlainText.isEmpty else {
                return textBlocks.first?.id ?? blocks.first?.id
            }
            var prefix = ""
            var best = textBlocks.first?.id
            for block in textBlocks {
                let offset = PlainTextSearch.utf16Offset(
                    afterNormalizedPrefix: prefix,
                    in: chapterPlainText
                )
                if offset <= resumeUTF16Offset {
                    best = block.id
                } else {
                    break
                }
                prefix = prefix.isEmpty ? block.text : prefix + "\n" + block.text
            }
            return best
        }
    }

    func prefix(before blockID: String) -> String {
        var parts: [String] = []
        for block in textBlocks {
            guard block.id != blockID else { break }
            parts.append(block.text)
        }
        return parts.joined(separator: "\n")
    }

    func resolvedTextSpans(in chapterPlainText: String?) -> [String: NativeTextBlockSpan] {
        let readable = textBlocks
        guard !readable.isEmpty else { return [:] }

        let source = textSource(prefer: chapterPlainText)
        let chapterUTF16Count = source.utf16.count
        var spans: [String: NativeTextBlockSpan] = [:]
        var prefix = ""
        var runningOffset = 0

        for index in readable.indices {
            let block = readable[index]
            let suffixContext = readable[index...]
                .dropFirst()
                .prefix(2)
                .map(\.text)
                .joined(separator: "\n")
            let prefixContext = String(prefix.suffix(240))
            let suffixSnippet = String(suffixContext.prefix(240))

            var range = PlainTextSearch.utf16Range(
                of: block.text,
                prefix: prefixContext,
                suffix: suffixSnippet,
                in: source
            )

            if range == nil {
                let start = PlainTextSearch.utf16Offset(
                    afterNormalizedPrefix: prefix,
                    in: source
                )
                let prefixWithCurrent = prefix.isEmpty ? block.text : prefix + "\n" + block.text
                let end = PlainTextSearch.utf16Offset(
                    afterNormalizedPrefix: prefixWithCurrent,
                    in: source
                )
                if end > start {
                    range = start..<end
                }
            }

            if range == nil {
                let start = max(0, min(runningOffset, chapterUTF16Count))
                let end = max(start, min(start + block.text.utf16.count, chapterUTF16Count))
                range = start..<end
            }

            guard let chapterRange = range else { continue }
            spans[block.id] = NativeTextBlockSpan(
                blockID: block.id,
                chapterRange: chapterRange,
                paragraphInfo: block.readerParagraph
            )
            runningOffset = chapterRange.upperBound
            prefix = prefix.isEmpty ? block.text : prefix + "\n" + block.text
        }

        return spans
    }

    func selection(
        for blockID: String,
        localUTF16Range: Range<Int>,
        chapterPlainText: String?,
        spans: [String: NativeTextBlockSpan]
    ) -> ReaderSelection? {
        guard let block = textBlocks.first(where: { $0.id == blockID }),
              let span = spans[blockID] else {
            return nil
        }

        let blockUTF16Count = block.text.utf16.count
        let clampedLower = max(0, min(localUTF16Range.lowerBound, blockUTF16Count))
        let clampedUpper = max(clampedLower, min(localUTF16Range.upperBound, blockUTF16Count))
        guard clampedUpper > clampedLower else { return nil }

        let source = textSource(prefer: chapterPlainText)
        let absoluteLower = span.chapterRange.lowerBound + clampedLower
        let absoluteUpper = min(span.chapterRange.lowerBound + clampedUpper, source.utf16.count)
        guard absoluteUpper > absoluteLower else { return nil }
        return ReaderSelectionContext.selection(
            in: source,
            utf16Range: absoluteLower..<absoluteUpper
        )
    }

    static let empty = NativeChapterDocument(blocks: [])

    private func textSource(prefer chapterPlainText: String?) -> String {
        guard let chapterPlainText, !chapterPlainText.isEmpty else { return plainText }
        return chapterPlainText
    }
}

nonisolated struct NativeTextBlockSpan: Equatable {
    var blockID: String
    var chapterRange: Range<Int>
    var paragraphInfo: ReaderParagraph?

    func localRange(intersecting absoluteRange: Range<Int>) -> Range<Int>? {
        let lower = max(chapterRange.lowerBound, absoluteRange.lowerBound)
        let upper = min(chapterRange.upperBound, absoluteRange.upperBound)
        guard upper > lower else { return nil }
        return (lower - chapterRange.lowerBound)..<(upper - chapterRange.lowerBound)
    }

    func localProgress(for absoluteUTF16Offset: Int) -> CGFloat {
        let length = max(chapterRange.upperBound - chapterRange.lowerBound, 1)
        let local = max(0, min(absoluteUTF16Offset - chapterRange.lowerBound, length - 1))
        return CGFloat(local) / CGFloat(length)
    }
}

nonisolated enum ReaderSelectionContext {
    static func selection(
        in source: String,
        utf16Range: Range<Int>,
        contextWindow: Int = 180
    ) -> ReaderSelection? {
        let sourceUTF16Count = source.utf16.count
        let lower = max(0, min(utf16Range.lowerBound, sourceUTF16Count))
        let upper = max(lower, min(utf16Range.upperBound, sourceUTF16Count))
        guard upper > lower else { return nil }

        let selectionText = utf16Slice(source, range: lower..<upper)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectionText.isEmpty else { return nil }

        let prefixStart = max(0, lower - contextWindow)
        let suffixEnd = min(sourceUTF16Count, upper + contextWindow)
        return ReaderSelection(
            text: selectionText,
            prefix: utf16Slice(source, range: prefixStart..<lower),
            suffix: utf16Slice(source, range: upper..<suffixEnd)
        )
    }

    static func utf16Range(
        of selection: ReaderSelection,
        in source: String
    ) -> Range<Int>? {
        PlainTextSearch.utf16Range(
            of: selection.text,
            prefix: selection.prefix,
            suffix: selection.suffix,
            in: source
        )
    }
}
nonisolated enum NativeChapterBlock: Equatable, Identifiable {
    case heading(id: String, level: Int, text: String)
    case paragraph(id: String, paragraphIndex: Int, text: String)
    case quote(id: String, paragraphIndex: Int, text: String)
    case listItem(id: String, paragraphIndex: Int, text: String, level: Int, marker: String)
    case footnote(id: String, paragraphIndex: Int, text: String)
    case code(id: String, text: String)
    case table(id: String, rows: [[String]])
    case image(id: String, source: String, alt: String?)

    var id: String {
        switch self {
        case .heading(let id, _, _),
             .paragraph(let id, _, _),
             .quote(let id, _, _),
             .footnote(let id, _, _),
             .code(let id, _),
             .image(let id, _, _):
            id
        case .listItem(let id, _, _, _, _):
            id
        case .table(let id, _):
            id
        }
    }

    var text: String {
        switch self {
        case .heading(_, _, let text),
             .paragraph(_, _, let text),
             .quote(_, _, let text),
             .footnote(_, _, let text),
             .code(_, let text):
            text
        case .listItem(_, _, let text, _, _):
            text
        case .image(_, _, let alt):
            alt ?? ""
        case .table:
            ""
        }
    }

    var readerParagraph: ReaderParagraph? {
        switch self {
        case .paragraph(_, let index, let text),
             .quote(_, let index, let text),
             .footnote(_, let index, let text):
            ReaderParagraph(idx: index, text: text)
        case .listItem(_, let index, let text, _, _):
            ReaderParagraph(idx: index, text: text)
        case .heading, .image, .code, .table:
            nil
        }
    }

    var isReadableText: Bool {
        switch self {
        case .heading, .paragraph, .quote, .listItem, .footnote, .code:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image, .table:
            return false
        }
    }
}

/// Parses EPUB XHTML into `NativeChapterDocument` without executing script or
/// relying on WebKit layout. EPUB spine documents are XHTML, so XMLParser is a
/// reliable fast path for normal books; on malformed input we fall back to the
/// existing plain-text extraction instead of yielding an empty reader.
///
/// Results memoize: reader views re-init on every parent render (notes
/// arriving, chrome fades), and re-parsing a whole chapter each time is
/// what made the app feel slow.
nonisolated enum NativeChapterParser {
    private final class DocumentBox {
        let document: NativeChapterDocument
        init(_ document: NativeChapterDocument) { self.document = document }
    }

    private final class SpansBox {
        let spans: [String: NativeTextBlockSpan]
        init(_ spans: [String: NativeTextBlockSpan]) { self.spans = spans }
    }

    // NSCache is internally thread-safe.
    nonisolated(unsafe) private static let documentCache = NSCache<NSString, DocumentBox>()
    nonisolated(unsafe) private static let spansCache = NSCache<NSString, SpansBox>()

    /// Distinguishes chapters cheaply without hashing megabytes: href +
    /// length + a content tail (catches the 繁体 conversion, whose length
    /// is often identical).
    private static func cacheKey(_ chapter: EPUBChapter) -> String {
        "\(chapter.href)|\(chapter.content.utf16.count)|\(chapter.content.suffix(24))"
    }

    static func parse(_ chapter: EPUBChapter) -> NativeChapterDocument {
        let key = cacheKey(chapter) as NSString
        if let hit = documentCache.object(forKey: key) {
            return hit.document
        }
        let document = parseUncached(chapter)
        documentCache.setObject(DocumentBox(document), forKey: key)
        return document
    }

    /// Memoized `NativeChapterDocument.resolvedTextSpans` — the per-block
    /// chapter-offset resolution is the other per-render hot spot.
    static func resolvedSpans(
        for chapter: EPUBChapter,
        document: NativeChapterDocument,
        chapterPlainText: String?
    ) -> [String: NativeTextBlockSpan] {
        let key = "\(cacheKey(chapter))|\(chapterPlainText?.utf16.count ?? -1)" as NSString
        if let hit = spansCache.object(forKey: key) {
            return hit.spans
        }
        let spans = document.resolvedTextSpans(in: chapterPlainText)
        spansCache.setObject(SpansBox(spans), forKey: key)
        return spans
    }

    private static func parseUncached(_ chapter: EPUBChapter) -> NativeChapterDocument {
        let parser = NativeChapterXMLParser(chapterHref: chapter.href)
        if let document = parser.parse(chapter.content), !document.blocks.isEmpty {
            return document
        }

        let fallback = fallbackText(from: chapter.content)
        let blocks = fallback
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { offset, text in
                NativeChapterBlock.paragraph(
                    id: "fallback-p-\(offset)",
                    paragraphIndex: offset,
                    text: text
                )
            }
        return NativeChapterDocument(blocks: blocks)
    }

    private static func fallbackText(from html: String) -> String {
        let openedBlocksMarked = html.replacingOccurrences(
            of: "(?i)<(p|h1|h2|h3|h4|h5|h6|blockquote|li|div|section|article|tr|pre)\\b",
            with: "\n<$1",
            options: .regularExpression
        )
        return HTMLPlainText.extract(from: openedBlocksMarked)
    }
}

private nonisolated final class NativeChapterXMLParser: NSObject, XMLParserDelegate {
    private struct Draft {
        var tag: String
        var id: String
        var kind: Kind
        var text = ""
        var listLevel = 1
        var listMarker = "•"
        var isFootnote = false
    }

    private enum Kind {
        case heading(level: Int)
        case paragraph
        case quote
        case listItem
        case code
        case caption
    }

    private let chapterHref: String
    private var blocks: [NativeChapterBlock] = []
    private var current: Draft?
    private var currentBlockDepth = 0
    private var skipDepth = 0
    private var paragraphIndex = 0
    private var blockOrdinal = 0

    /// Text that appears directly inside containers (div/section/article…)
    /// rather than in a recognized block tag — many EPUBs paragraph with
    /// bare <div>s. Flushed into implicit paragraphs at container/block
    /// boundaries; `\u{2028}` marks <br> so source-formatting newlines
    /// don't split paragraphs.
    private var strayText = ""
    private var listStack: [(ordered: Bool, count: Int)] = []
    private var asideStack: [Bool] = []
    private var footnoteDepth = 0
    private var tableDepth = 0
    private var tableRows: [[String]] = []
    private var tableRow: [String]?
    private var tableCell: String?
    private var tableID = ""
    private var figureDepth = 0
    private var figureImageIndex: Int?
    private var figureCaption: String?

    init(chapterHref: String) {
        self.chapterHref = chapterHref
    }

    func parse(_ html: String) -> NativeChapterDocument? {
        guard let data = sanitize(html).data(using: .utf8) else { return nil }
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = self
        guard xmlParser.parse() else { return nil }
        finishCurrentBlock()
        if tableDepth > 0 {
            tableDepth = 0
            flushTable()
        }
        flushStray()
        return NativeChapterDocument(blocks: blocks)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let tag = localName(elementName)
        if skipDepth > 0 || Self.skippedTags.contains(tag) {
            skipDepth += 1
            return
        }

        if tableDepth > 0 {
            handleTableStart(tag, attributes: attributeDict)
            return
        }

        switch tag {
        case "br":
            if current != nil {
                appendText("\n")
            } else {
                strayText += "\u{2028}"
            }
            return
        case "img", "image":
            appendImage(attributeDict)
            return
        case "table":
            flushStray()
            finishCurrentBlock()
            tableDepth = 1
            tableRows = []
            tableRow = nil
            tableCell = nil
            tableID = attributeDict["id"] ?? generatedID(prefix: "table")
            return
        case "ul", "ol":
            if let kind = current?.kind, case .listItem = kind {
                finishCurrentBlock()
            }
            flushStray()
            listStack.append((ordered: tag == "ol", count: 0))
            return
        case "aside":
            finishCurrentBlock()
            flushStray()
            let epubType = (attributeDict["epub:type"] ?? attributeDict["type"] ?? "").lowercased()
            let isFootnote = epubType.contains("note")
            asideStack.append(isFootnote)
            if isFootnote { footnoteDepth += 1 }
            return
        case "figure":
            flushStray()
            figureDepth += 1
            figureImageIndex = nil
            figureCaption = nil
            return
        default:
            break
        }

        guard let kind = Self.kind(for: tag) else { return }
        flushStray()
        if case .listItem = kind, let openKind = current?.kind, case .listItem = openKind {
            finishCurrentBlock()
        }
        if current == nil {
            var draft = Draft(
                tag: tag,
                id: attributeDict["id"] ?? generatedID(prefix: tag),
                kind: kind
            )
            if case .listItem = kind {
                if !listStack.isEmpty {
                    listStack[listStack.count - 1].count += 1
                }
                draft.listLevel = max(listStack.count, 1)
                let ordered = listStack.last?.ordered ?? false
                draft.listMarker = ordered ? "\(listStack.last?.count ?? 1)." : "•"
            }
            draft.isFootnote = footnoteDepth > 0
            current = draft
            currentBlockDepth = 1
        } else {
            currentBlockDepth += 1
            appendText("\n")
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let tag = localName(elementName)
        if skipDepth > 0 {
            skipDepth -= 1
            return
        }

        if tableDepth > 0 {
            handleTableEnd(tag)
            return
        }

        switch tag {
        case "ul", "ol":
            if let kind = current?.kind, case .listItem = kind {
                finishCurrentBlock()
            }
            if current == nil { flushStray() }
            if !listStack.isEmpty { listStack.removeLast() }
            return
        case "aside":
            if current == nil { flushStray() }
            if let counted = asideStack.popLast(), counted {
                footnoteDepth = max(0, footnoteDepth - 1)
            }
            return
        case "figure":
            if current == nil { flushStray() }
            if let caption = figureCaption, figureImageIndex == nil {
                appendFootnoteBlock(caption, id: generatedID(prefix: "caption"))
            }
            figureDepth = max(0, figureDepth - 1)
            figureImageIndex = nil
            figureCaption = nil
            return
        case "div", "section", "article", "body", "main", "header", "footer", "dl":
            if current == nil { flushStray() }
            return
        default:
            break
        }

        guard current != nil, Self.kind(for: tag) != nil else { return }
        currentBlockDepth -= 1
        if currentBlockDepth <= 0 {
            finishCurrentBlock()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendCharacters(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        appendCharacters(string)
    }

    private func appendCharacters(_ string: String) {
        guard skipDepth == 0 else { return }
        if tableDepth > 0 {
            tableCell? += string
            return
        }
        if current != nil {
            current?.text += string
        } else {
            strayText += string
        }
    }

    private func appendText(_ text: String) {
        guard skipDepth == 0, current != nil else { return }
        current?.text += text
    }

    private func appendImage(_ attributes: [String: String]) {
        let source = attributes["src"]
            ?? attributes["href"]
            ?? attributes["xlink:href"]
        guard let source, !source.isEmpty else { return }
        var alt = attributes["alt"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if current != nil, let inlineAlt = alt, !inlineAlt.isEmpty {
            appendText(" " + inlineAlt + " ")
            return
        }
        flushStray()
        if figureDepth > 0, let caption = figureCaption, !caption.isEmpty {
            alt = caption
            figureCaption = nil
        }
        blocks.append(.image(id: generatedID(prefix: "img"), source: source, alt: alt))
        if figureDepth > 0 {
            figureImageIndex = blocks.count - 1
        }
    }

    private func flushStray() {
        guard !strayText.isEmpty else { return }
        let raw = strayText
        strayText = ""
        for line in raw.components(separatedBy: "\u{2028}") {
            let text = normalize(line)
            guard !text.isEmpty else { continue }
            if footnoteDepth > 0 {
                appendFootnoteBlock(text, id: generatedID(prefix: "note"))
            } else {
                blocks.append(.paragraph(
                    id: generatedID(prefix: "p"),
                    paragraphIndex: paragraphIndex,
                    text: text
                ))
                paragraphIndex += 1
            }
        }
    }

    private func appendFootnoteBlock(_ text: String, id: String) {
        blocks.append(.footnote(id: id, paragraphIndex: paragraphIndex, text: text))
        paragraphIndex += 1
    }

    private func finishCurrentBlock() {
        guard let draft = current else { return }
        current = nil
        currentBlockDepth = 0

        if case .code = draft.kind {
            let text = normalizeCode(draft.text)
            guard !text.isEmpty else { return }
            blocks.append(.code(id: draft.id, text: text))
            return
        }

        let text = normalize(draft.text)
        guard !text.isEmpty else { return }

        if draft.isFootnote {
            switch draft.kind {
            case .paragraph, .quote, .listItem:
                appendFootnoteBlock(text, id: draft.id)
                return
            default:
                break
            }
        }

        switch draft.kind {
        case .heading(let level):
            blocks.append(.heading(id: draft.id, level: level, text: text))
        case .paragraph:
            blocks.append(.paragraph(id: draft.id, paragraphIndex: paragraphIndex, text: text))
            paragraphIndex += 1
        case .quote:
            blocks.append(.quote(id: draft.id, paragraphIndex: paragraphIndex, text: text))
            paragraphIndex += 1
        case .listItem:
            blocks.append(.listItem(
                id: draft.id,
                paragraphIndex: paragraphIndex,
                text: text,
                level: draft.listLevel,
                marker: draft.listMarker
            ))
            paragraphIndex += 1
        case .code:
            break
        case .caption:
            if figureDepth > 0, let index = figureImageIndex,
               blocks.indices.contains(index),
               case .image(let imageID, let source, _) = blocks[index] {
                blocks[index] = .image(id: imageID, source: source, alt: text)
            } else if figureDepth > 0 {
                figureCaption = text
            } else {
                appendFootnoteBlock(text, id: draft.id)
            }
        }
    }

    // MARK: Tables

    private func handleTableStart(_ tag: String, attributes: [String: String]) {
        switch tag {
        case "table":
            tableDepth += 1
        case "tr" where tableDepth == 1:
            tableRow = []
        case "td", "th", "caption":
            if tableDepth == 1, tableCell == nil {
                tableCell = ""
            } else {
                tableCell? += " "
            }
        case "br":
            tableCell? += " "
        case "img", "image":
            let alt = attributes["alt"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let alt, !alt.isEmpty {
                tableCell? += " \(alt) "
            }
        default:
            if Self.kind(for: tag) != nil {
                tableCell? += " "
            }
        }
    }

    private func handleTableEnd(_ tag: String) {
        switch tag {
        case "table":
            tableDepth -= 1
            if tableDepth == 0 {
                flushTable()
            }
        case "caption" where tableDepth == 1:
            if let cell = tableCell {
                let text = normalize(cell)
                if !text.isEmpty {
                    tableRows.append([text])
                }
            }
            tableCell = nil
        case "td", "th":
            guard tableDepth == 1, let cell = tableCell else { return }
            tableRow?.append(normalize(cell))
            tableCell = nil
        case "tr" where tableDepth == 1:
            if let row = tableRow, row.contains(where: { !$0.isEmpty }) {
                tableRows.append(row)
            }
            tableRow = nil
        default:
            break
        }
    }

    private func flushTable() {
        defer {
            tableRows = []
            tableRow = nil
            tableCell = nil
        }
        let rows = tableRows.filter { !$0.isEmpty }
        guard !rows.isEmpty else { return }
        blocks.append(.table(id: tableID, rows: rows))
    }

    private func generatedID(prefix: String) -> String {
        defer { blockOrdinal += 1 }
        let chapter = chapterHref
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        return "native-\(chapter)-\(prefix)-\(blockOrdinal)"
    }

    private func localName(_ elementName: String) -> String {
        (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
    }

    private func normalize(_ text: String) -> String {
        HTMLPlainText.extract(from: text)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(
                of: "[ \\t\\r\\n\u{2028}]+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Code keeps its line structure and inner indentation; only blank
    /// edge lines and per-line trailing whitespace are dropped.
    private func normalizeCode(_ text: String) -> String {
        var lines = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line -> String in
                var trimmed = line
                while let last = trimmed.last, last == " " || last == "\t" {
                    trimmed.removeLast()
                }
                return trimmed
            }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private func sanitize(_ html: String) -> String {
        var result = html
        result = result.replacingOccurrences(
            of: "(?is)<!DOCTYPE[^>]*>",
            with: "",
            options: .regularExpression
        )
        let entities: [(String, String)] = [
            ("&nbsp;", "&#160;"),
            ("&mdash;", "&#8212;"),
            ("&ndash;", "&#8211;"),
            ("&hellip;", "&#8230;"),
            ("&apos;", "&#39;")
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    private static let skippedTags: Set<String> = [
        "head", "metadata", "nav", "script", "style"
    ]

    private static func kind(for tag: String) -> Kind? {
        switch tag {
        case "h1": return .heading(level: 1)
        case "h2": return .heading(level: 2)
        case "h3": return .heading(level: 3)
        case "h4": return .heading(level: 4)
        case "h5": return .heading(level: 5)
        case "h6": return .heading(level: 6)
        case "p", "dt", "dd": return .paragraph
        case "blockquote": return .quote
        case "li": return .listItem
        case "pre": return .code
        case "figcaption": return .caption
        default: return nil
        }
    }
}

private nonisolated func utf16Slice(_ string: String, range: Range<Int>) -> String {
    let utf16 = Array(string.utf16)
    let lower = max(0, min(range.lowerBound, utf16.count))
    let upper = max(lower, min(range.upperBound, utf16.count))
    return String(decoding: utf16[lower..<upper], as: UTF16.self)
}
