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

        let localRange = clampedLower..<clampedUpper
        let selectionText = utf16Slice(block.text, range: localRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectionText.isEmpty else { return nil }

        let source = textSource(prefer: chapterPlainText)
        let absoluteLower = span.chapterRange.lowerBound + localRange.lowerBound
        let absoluteUpper = min(span.chapterRange.lowerBound + localRange.upperBound, source.utf16.count)
        guard absoluteUpper > absoluteLower else { return nil }

        let prefixStart = max(0, absoluteLower - 180)
        let suffixEnd = min(source.utf16.count, absoluteUpper + 180)
        return ReaderSelection(
            text: selectionText,
            prefix: utf16Slice(source, range: prefixStart..<absoluteLower),
            suffix: utf16Slice(source, range: absoluteUpper..<suffixEnd)
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
}

nonisolated enum NativeChapterBlock: Equatable, Identifiable {
    case heading(id: String, level: Int, text: String)
    case paragraph(id: String, paragraphIndex: Int, text: String)
    case quote(id: String, paragraphIndex: Int, text: String)
    case listItem(id: String, paragraphIndex: Int, text: String)
    case image(id: String, source: String, alt: String?)

    var id: String {
        switch self {
        case .heading(let id, _, _),
             .paragraph(let id, _, _),
             .quote(let id, _, _),
             .listItem(let id, _, _),
             .image(let id, _, _):
            id
        }
    }

    var text: String {
        switch self {
        case .heading(_, _, let text),
             .paragraph(_, _, let text),
             .quote(_, _, let text),
             .listItem(_, _, let text):
            text
        case .image(_, _, let alt):
            alt ?? ""
        }
    }

    var readerParagraph: ReaderParagraph? {
        switch self {
        case .paragraph(_, let index, let text),
             .quote(_, let index, let text),
             .listItem(_, let index, let text):
            ReaderParagraph(idx: index, text: text)
        case .heading, .image:
            nil
        }
    }

    var isReadableText: Bool {
        switch self {
        case .heading, .paragraph, .quote, .listItem:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image:
            return false
        }
    }
}

/// Parses EPUB XHTML into `NativeChapterDocument` without executing script or
/// relying on WebKit layout. EPUB spine documents are XHTML, so XMLParser is a
/// reliable fast path for normal books; on malformed input we fall back to the
/// existing plain-text extraction instead of yielding an empty reader.
nonisolated enum NativeChapterParser {
    static func parse(_ chapter: EPUBChapter) -> NativeChapterDocument {
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
            of: "(?i)<(p|h1|h2|h3|h4|h5|h6|blockquote|li)\\b",
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
    }

    private enum Kind {
        case heading(level: Int)
        case paragraph
        case quote
        case listItem
    }

    private let chapterHref: String
    private var blocks: [NativeChapterBlock] = []
    private var current: Draft?
    private var currentBlockDepth = 0
    private var skipDepth = 0
    private var paragraphIndex = 0
    private var blockOrdinal = 0

    init(chapterHref: String) {
        self.chapterHref = chapterHref
    }

    func parse(_ html: String) -> NativeChapterDocument? {
        guard let data = sanitize(html).data(using: .utf8) else { return nil }
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = self
        guard xmlParser.parse() else { return nil }
        finishCurrentBlock()
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

        if tag == "br" {
            appendText("\n")
            return
        }

        if tag == "img" || tag == "image" {
            appendImage(attributeDict)
            return
        }

        guard let kind = Self.kind(for: tag) else { return }
        if current == nil {
            current = Draft(
                tag: tag,
                id: attributeDict["id"] ?? generatedID(prefix: tag),
                kind: kind
            )
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
        guard current != nil, Self.kind(for: tag) != nil else { return }
        currentBlockDepth -= 1
        if currentBlockDepth <= 0 {
            finishCurrentBlock()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        appendText(string)
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
        let alt = attributes["alt"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if current != nil, let alt, !alt.isEmpty {
            appendText(" " + alt + " ")
            return
        }
        blocks.append(.image(id: generatedID(prefix: "img"), source: source, alt: alt))
    }

    private func finishCurrentBlock() {
        guard let draft = current else { return }
        current = nil
        currentBlockDepth = 0

        let text = normalize(draft.text)
        guard !text.isEmpty else { return }

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
            blocks.append(.listItem(id: draft.id, paragraphIndex: paragraphIndex, text: text))
            paragraphIndex += 1
        }
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
                of: "[ \\t\\r\\n]+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        case "p": return .paragraph
        case "blockquote": return .quote
        case "li": return .listItem
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
