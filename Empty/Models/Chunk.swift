//
//  Chunk.swift
//  Empty
//

import Foundation
import SwiftData

/// Retrieval unit for AI features: spoiler-safe Q&A, recaps, cross-book
/// memory.
///
/// Pure derived data — re-chunkable from `Chapter.text` at any time — so it
/// lives in the local store and never syncs. `text` is duplicated from the
/// chapter on purpose: retrieval must not fault in whole chapters.
@Model
final class Chunk {
    #Index<Chunk>([\.bookID], [\.bookID, \.ordinal])

    var bookID: UUID
    /// Zero-based reading-order ordinal across the whole book; doubles as
    /// the passage ID in grounded prompts.
    var ordinal: Int

    // Flattened `TextAnchor`.
    var chapterIndex: Int
    var startUTF16: Int
    var endUTF16: Int

    var text: String

    /// Sentence-embedding vector (little-endian Float32 blob); `nil` until
    /// the indexing pass runs.
    var embedding: Data?

    var chapter: Chapter?

    var anchor: TextAnchor {
        TextAnchor(
            chapterIndex: chapterIndex,
            startUTF16: startUTF16,
            endUTF16: endUTF16
        )
    }

    init(bookID: UUID, ordinal: Int, anchor: TextAnchor, text: String) {
        self.bookID = bookID
        self.ordinal = ordinal
        self.chapterIndex = anchor.chapterIndex
        self.startUTF16 = anchor.startUTF16
        self.endUTF16 = anchor.endUTF16
        self.text = text
    }

    /// Selects chunks of `bookID` lying entirely before `position` — the
    /// spoiler-safety filter every position-aware AI feature builds on.
    static func fullyReadPredicate(
        bookID: UUID,
        position: ReadingPosition
    ) -> Predicate<Chunk> {
        let chapter = position.chapterIndex
        let offset = position.utf16Offset
        return #Predicate<Chunk> { chunk in
            chunk.bookID == bookID &&
                (chunk.chapterIndex < chapter ||
                    (chunk.chapterIndex == chapter && chunk.endUTF16 <= offset))
        }
    }
}
