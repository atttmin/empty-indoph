//
//  HighlightStore.swift
//  Empty
//

import Foundation
import SwiftData

/// Creates, lists, and deletes highlights. Anchoring goes through
/// `PlainTextSearch`: the rendered selection is located in the chapter's
/// plain text and stored as exact UTF-16 offsets plus a verbatim snapshot —
/// the snapshot keeps the highlight meaningful even if offsets ever drift.
@MainActor
struct HighlightStore {
    let modelContext: ModelContext

    /// Anchors and persists a highlight for the rendered selection.
    /// When the selection can't be located (renderer/extractor divergence),
    /// the highlight is still saved snapshot-only with an empty anchor.
    @discardableResult
    func createHighlight(
        book: Book,
        chapterIndex: Int,
        selection: String,
        prefix: String = "",
        suffix: String = ""
    ) throws -> Highlight {
        let bookID = book.id
        let chapter = try modelContext.fetch(
            FetchDescriptor<Chapter>(
                predicate: #Predicate { $0.bookID == bookID && $0.index == chapterIndex }
            )
        ).first

        var range = 0..<0
        if let chapter,
           let found = PlainTextSearch.utf16Range(
               of: selection,
               prefix: prefix,
               suffix: suffix,
               in: chapter.text
           ) {
            range = found
        }

        let highlight = Highlight(
            anchor: TextAnchor(
                chapterIndex: chapterIndex,
                startUTF16: range.lowerBound,
                endUTF16: range.upperBound
            ),
            textSnapshot: selection.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        modelContext.insert(highlight)
        highlight.book = book
        try modelContext.save()
        return highlight
    }

    /// Highlights of `book`, optionally narrowed to one chapter, in reading
    /// order.
    func highlights(for book: Book, chapterIndex: Int? = nil) throws -> [Highlight] {
        let bookID = book.id
        let predicate: Predicate<Highlight>
        if let chapterIndex {
            predicate = #Predicate { $0.book?.id == bookID && $0.chapterIndex == chapterIndex }
        } else {
            predicate = #Predicate { $0.book?.id == bookID }
        }
        return try modelContext.fetch(
            FetchDescriptor<Highlight>(
                predicate: predicate,
                sortBy: [
                    SortDescriptor(\.chapterIndex),
                    SortDescriptor(\.startUTF16),
                ]
            )
        )
    }

    func updateNote(_ highlight: Highlight, note: String?) throws {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        highlight.note = trimmed?.isEmpty == false ? trimmed : nil
        try modelContext.save()
    }

    func delete(_ highlight: Highlight) throws {
        modelContext.delete(highlight)
        try modelContext.save()
    }
}
