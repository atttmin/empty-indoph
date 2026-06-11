//
//  SemanticIndexer.swift
//  Empty
//

import NaturalLanguage
import SwiftData

/// Background actor that computes on-device sentence embeddings for every
/// `Chunk` that lacks one.  Runs off the main thread so the 512-dim vector
/// math never blocks the reader UI.
///
/// Usage:
///     let indexer = SemanticIndexer(modelContainer: container)
///     let processed = try await indexer.indexChunks(for: bookID)
@ModelActor
actor SemanticIndexer {
    /// Embeds all un-indexed chunks for `bookID`.  Returns the number of
    /// chunks successfully processed (0 if `NLEmbedding` is unavailable).
    func indexChunks(for bookID: UUID) throws -> Int {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            return 0
        }

        let descriptor = FetchDescriptor<Chunk>(
            predicate: #Predicate { chunk in
                chunk.bookID == bookID && chunk.embedding == nil
            }
        )
        let chunks = try modelContext.fetch(descriptor)
        guard !chunks.isEmpty else { return 0 }

        for chunk in chunks {
            guard let vector = embedding.vector(for: chunk.text) else { continue }
            chunk.setEmbedding(vector: vector)
        }

        try modelContext.save()
        return chunks.count
    }
}
