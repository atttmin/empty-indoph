//
//  EPUBTypes.swift
//  Empty
//

import Foundation

/// Dublin Core metadata extracted from an EPUB's OPF file.
nonisolated struct EPUBMetadata {
    var title: String = ""
    var author: String = ""
    var language: String?
    var identifier: String?
    var publisher: String?
    var description: String?
    /// Absolute path of the cover image inside the unzipped book, when the
    /// OPF declares one.
    var coverImagePath: String?
}

/// One spine item: raw XHTML for the reader, plain text for the AI layer.
nonisolated struct EPUBChapter {
    let title: String
    /// Manifest href, relative to the OPF directory.
    let href: String
    /// Raw XHTML, rendered by the reader's web view.
    let content: String

    /// Tag-stripped plain text — the substrate for `Chapter.text`, chunking,
    /// and position anchors.
    var plainText: String {
        HTMLPlainText.extract(from: content)
    }
}

/// A fully parsed EPUB, ready for reading.
nonisolated struct EPUBBook {
    let metadata: EPUBMetadata
    let chapters: [EPUBChapter]
    let coverImageData: Data?
    /// Root of the unzipped archive; chapter resource URLs resolve against it.
    let basePath: URL
}

/// Crude but dependable XHTML → plain text. Good enough for chunking and AI
/// prompts; the reader renders the original XHTML, so fidelity here only
/// affects derived text, never reading.
nonisolated enum HTMLPlainText {
    static func extract(from html: String) -> String {
        var text = html
        // Drop non-content blocks entirely. (?s) lets `.` cross newlines.
        for tag in ["head", "script", "style"] {
            text = text.replacingOccurrences(
                of: "(?s)<\(tag)[^>]*>.*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // Block-level closings become newlines so paragraphs survive.
        text = text.replacingOccurrences(
            of: "</(p|div|h1|h2|h3|h4|h5|h6|li|blockquote|tr|section|article)>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<br[^>]*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        // Strip every remaining tag, then decode common entities.
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        text = decodeEntities(in: text)

        // Collapse blank-line runs and trim line edges.
        var lines: [String] = []
        var lastWasBlank = true
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !lastWasBlank { lines.append("") }
                lastWasBlank = true
            } else {
                lines.append(line)
                lastWasBlank = false
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func decodeEntities(in text: String) -> String {
        var result = text
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
            ("&amp;", "&"), // last, so "&amp;lt;" decodes in two steps
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}
