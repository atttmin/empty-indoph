//
//  BookIndexer.swift
//  Empty
//

import Foundation
import SwiftData

/// Builds the retrieval index (chunks) for a book from its stored chapter
/// text. Idempotent: books indexed at import keep their chunks; books from
/// before the chunking pipeline get backfilled on first use.
///
/// Embedding vectors (`Chunk.embedding`) are NOT populated here — that pass
/// is compute-heavy and belongs to a background actor (backlog); retrieval
/// runs lexical-only until then.
@MainActor
struct BookIndexer {
    let modelContext: ModelContext

    /// Ensures chunks exist for `book`; returns the chunk count.
    @discardableResult
    func ensureChunks(for book: Book) throws -> Int {
        let bookID = book.id
        let existing = try modelContext.fetchCount(
            FetchDescriptor<Chunk>(predicate: #Predicate { $0.bookID == bookID })
        )
        if existing > 0 { return existing }

        let chapters = try modelContext.fetch(
            FetchDescriptor<Chapter>(
                predicate: #Predicate { $0.bookID == bookID },
                sortBy: [SortDescriptor(\.index)]
            )
        )
        guard !chapters.isEmpty else { return 0 }

        var ordinal = 0
        for chapter in chapters {
            for piece in TextChunker.chunks(of: chapter.text) {
                let chunk = Chunk(
                    bookID: bookID,
                    ordinal: ordinal,
                    anchor: TextAnchor(
                        chapterIndex: chapter.index,
                        startUTF16: piece.startUTF16,
                        endUTF16: piece.endUTF16
                    ),
                    text: piece.text
                )
                modelContext.insert(chunk)
                chunk.chapter = chapter
                ordinal += 1
            }
        }
        try modelContext.save()
        return ordinal
    }
}
