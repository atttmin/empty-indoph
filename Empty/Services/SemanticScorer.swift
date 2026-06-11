//
//  SemanticScorer.swift
//  Empty
//

import Foundation
import NaturalLanguage

/// On-device sentence-embedding relevance. Falls back silently when
/// `NLEmbedding` is unavailable (simulator, models-not-downloaded, etc.).
nonisolated enum SemanticScorer {
    /// Whether the device can produce sentence embeddings right now.
    static var isAvailable: Bool {
        NLEmbedding.sentenceEmbedding(for: .english) != nil
    }

    /// Returns the 512-dim Float vector for `text`, or `nil` if the
    /// embedding model is unavailable or the text is empty.
    static func queryVector(for text: String) -> [Float]? {
        guard !text.isEmpty,
              let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            return nil
        }
        guard let vector = embedding.vector(for: text) else { return nil }
        return vector.map { Float($0) }
    }

    /// Cosine similarity of two same-length Float vectors, 0…1.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0
        var normA: Double = 0
        var normB: Double = 0
        for i in a.indices {
            let av = Double(a[i])
            let bv = Double(b[i])
            dot += av * bv
            normA += av * av
            normB += bv * bv
        }
        let denom = sqrt(normA * normB)
        return denom == 0 ? 0 : dot / denom
    }
}
