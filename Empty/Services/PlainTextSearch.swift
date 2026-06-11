//
//  PlainTextSearch.swift
//  Empty
//

import Foundation

/// Locates rendered-text selections inside extracted plain text.
///
/// The reader's DOM and `Chapter.text` disagree about whitespace (collapsed
/// runs, newlines vs spaces), so matching normalizes both sides while
/// keeping a map back to **original UTF-16 offsets** — the currency of
/// `TextAnchor`. Ambiguous selections disambiguate through their
/// prefix/suffix context.
nonisolated enum PlainTextSearch {
    /// UTF-16 range of `selection` in `haystack`, using `prefix`/`suffix`
    /// context to pick the right occurrence when the selection alone is
    /// ambiguous. Falls back to the first bare occurrence.
    static func utf16Range(
        of selection: String,
        prefix: String,
        suffix: String,
        in haystack: String
    ) -> Range<Int>? {
        if !prefix.isEmpty || !suffix.isEmpty {
            let contextual = prefix + selection + suffix
            if let window = utf16Range(of: contextual, in: haystack) {
                // Re-search the bare selection inside the matched window.
                let utf16 = Array(haystack.utf16)
                let slice = String(decoding: utf16[window], as: UTF16.self)
                if let inner = utf16Range(of: selection, in: slice) {
                    return (window.lowerBound + inner.lowerBound)
                        ..< (window.lowerBound + inner.upperBound)
                }
            }
        }
        return utf16Range(of: selection, in: haystack)
    }

    /// UTF-16 range of the first whitespace-insensitive occurrence of
    /// `needle` in `haystack`.
    static func utf16Range(of needle: String, in haystack: String) -> Range<Int>? {
        let h = normalize(haystack)
        let n = normalize(needle)
        guard !n.text.isEmpty, !h.text.isEmpty else { return nil }
        guard let match = h.text.range(of: n.text) else { return nil }

        let startIndex = h.text.distance(from: h.text.startIndex, to: match.lowerBound)
        let lastIndex = h.text.distance(from: h.text.startIndex, to: match.upperBound) - 1
        let startUTF16 = h.starts[startIndex]
        let endUTF16 = h.starts[lastIndex] + h.lengths[lastIndex]
        return startUTF16..<endUTF16
    }

    // MARK: - Normalization

    /// Normalized text (whitespace runs → single space, edges trimmed) plus,
    /// per normalized character, the original UTF-16 start offset and length.
    private static func normalize(
        _ string: String
    ) -> (text: String, starts: [Int], lengths: [Int]) {
        var text = ""
        var starts: [Int] = []
        var lengths: [Int] = []
        var offset = 0
        var lastWasSpace = true

        for character in string {
            let utf16Length = String(character).utf16.count
            if character.isWhitespace {
                if !lastWasSpace {
                    text.append(" ")
                    starts.append(offset)
                    lengths.append(utf16Length)
                }
                lastWasSpace = true
            } else {
                text.append(character)
                starts.append(offset)
                lengths.append(utf16Length)
                lastWasSpace = false
            }
            offset += utf16Length
        }
        if text.hasSuffix(" ") {
            text.removeLast()
            starts.removeLast()
            lengths.removeLast()
        }
        return (text, starts, lengths)
    }
}
