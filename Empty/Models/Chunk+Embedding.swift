//
//  Chunk+Embedding.swift
//  Empty
//

import Foundation

extension Chunk {
    /// Decodes the little-endian Float32 blob into a `[Float]` vector.
    var embeddingVector: [Float]? {
        guard let data = embedding, !data.isEmpty else { return nil }
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            let count = bytes.count / MemoryLayout<Float>.size
            let buffer = base.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: buffer, count: count))
        }
    }

    /// Encodes a `[Double]` vector (from `NLEmbedding`) into little-endian
    /// Float32 storage.
    func setEmbedding(vector: [Double]) {
        var floats = vector.map { Float($0) }
        self.embedding = Data(bytes: &floats, count: floats.count * MemoryLayout<Float>.size)
    }
}
