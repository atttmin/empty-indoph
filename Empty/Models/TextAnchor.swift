//
//  TextAnchor.swift
//  Empty
//

import Foundation

/// A point in a book's extracted plain text.
///
/// Offsets are **UTF-16 code units** into `Chapter.text` — the same unit as
/// `NSRange`/TextKit, stable across platforms and cheap to bridge. Every
/// position in the app (reading progress, highlights, chunks) uses this one
/// scheme; never mix in grapheme counts or serialized `String.Index`.
nonisolated struct ReadingPosition: Hashable, Codable, Sendable, Comparable {
    /// Zero-based index into the book's reading-order chapters.
    var chapterIndex: Int
    /// UTF-16 offset within that chapter's plain text.
    var utf16Offset: Int

    static let start = ReadingPosition(chapterIndex: 0, utf16Offset: 0)

    static func < (lhs: ReadingPosition, rhs: ReadingPosition) -> Bool {
        if lhs.chapterIndex != rhs.chapterIndex {
            return lhs.chapterIndex < rhs.chapterIndex
        }
        return lhs.utf16Offset < rhs.utf16Offset
    }
}

/// A contiguous range of text within one chapter.
///
/// Persisted flattened (chapter index + offsets) on models so queries can
/// filter by position; this type is the in-memory currency.
nonisolated struct TextAnchor: Hashable, Codable, Sendable {
    var chapterIndex: Int
    var startUTF16: Int
    var endUTF16: Int

    var start: ReadingPosition {
        ReadingPosition(chapterIndex: chapterIndex, utf16Offset: startUTF16)
    }

    var end: ReadingPosition {
        ReadingPosition(chapterIndex: chapterIndex, utf16Offset: endUTF16)
    }

    /// Whether the anchored text lies entirely before `position` — the
    /// spoiler-safety test: only content the reader has already passed.
    func isFullyRead(at position: ReadingPosition) -> Bool {
        end <= position
    }
}
