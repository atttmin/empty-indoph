//
//  TextChunker.swift
//  Empty
//

import Foundation

/// One retrieval-sized slice of a chapter, with exact anchors.
///
/// `text` is the **verbatim** slice `startUTF16..<endUTF16` of the source —
/// the offsets are load-bearing: they feed `Chunk` anchors, spoiler-safe
/// filtering, and (later) jump-to-source navigation.
nonisolated struct TextChunk: Equatable, Sendable {
    var startUTF16: Int
    var endUTF16: Int
    var text: String
}

/// Splits chapter plain text into retrieval-sized chunks.
///
/// Cuts prefer paragraph boundaries, then sentences, then hard cuts on
/// grapheme boundaries; adjacent pieces pack greedily up to the budget.
/// Unlike `TextWindowing` (which feeds prompts and may normalize), every
/// chunk here is a verbatim slice with exact UTF-16 offsets.
nonisolated enum TextChunker {
    /// 480 characters ≈ a beefy paragraph: small enough to point at one
    /// idea, big enough to ground an answer.
    static let defaultMaxCharacters = 480

    static func chunks(
        of text: String,
        maxCharacters: Int = TextChunker.defaultMaxCharacters
    ) -> [TextChunk] {
        precondition(maxCharacters > 0, "chunk budget must be positive")

        var pieces: [Range<String.Index>] = []
        for paragraph in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let trimmed = trimWhitespace(
                paragraph.startIndex..<paragraph.endIndex,
                in: text
            ) else { continue }
            if text[trimmed].count <= maxCharacters {
                pieces.append(trimmed)
            } else {
                pieces.append(contentsOf: splitOversized(trimmed, in: text, maxCharacters: maxCharacters))
            }
        }

        // Pack adjacent pieces while the verbatim slice stays in budget.
        var chunks: [TextChunk] = []
        var currentRange: Range<String.Index>?
        func flush() {
            if let range = currentRange {
                chunks.append(makeChunk(range, in: text))
                currentRange = nil
            }
        }
        for piece in pieces {
            if let range = currentRange {
                let candidate = range.lowerBound..<piece.upperBound
                if text[candidate].count <= maxCharacters {
                    currentRange = candidate
                } else {
                    flush()
                    currentRange = piece
                }
            } else {
                currentRange = piece
            }
        }
        flush()
        return chunks
    }

    // MARK: - Pieces

    private static func splitOversized(
        _ range: Range<String.Index>,
        in text: String,
        maxCharacters: Int
    ) -> [Range<String.Index>] {
        var sentenceRanges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: range, options: [.bySentences, .substringNotRequired]) { _, subrange, _, _ in
            sentenceRanges.append(subrange)
        }
        if sentenceRanges.isEmpty {
            sentenceRanges = [range]
        }

        var result: [Range<String.Index>] = []
        for sentence in sentenceRanges {
            guard let trimmed = trimWhitespace(sentence, in: text) else { continue }
            if text[trimmed].count <= maxCharacters {
                result.append(trimmed)
            } else {
                var cursor = trimmed.lowerBound
                while cursor < trimmed.upperBound {
                    let end = text.index(
                        cursor,
                        offsetBy: maxCharacters,
                        limitedBy: trimmed.upperBound
                    ) ?? trimmed.upperBound
                    result.append(cursor..<end)
                    cursor = end
                }
            }
        }
        return result
    }

    private static func trimWhitespace(
        _ range: Range<String.Index>,
        in text: String
    ) -> Range<String.Index>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, text[lower].isWhitespace {
            lower = text.index(after: lower)
        }
        while lower < upper, text[text.index(before: upper)].isWhitespace {
            upper = text.index(before: upper)
        }
        return lower < upper ? lower..<upper : nil
    }

    private static func makeChunk(_ range: Range<String.Index>, in text: String) -> TextChunk {
        TextChunk(
            startUTF16: range.lowerBound.utf16Offset(in: text),
            endUTF16: range.upperBound.utf16Offset(in: text),
            text: String(text[range])
        )
    }
}
