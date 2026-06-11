//
//  SemanticScorerTests.swift
//  EmptyTests
//

import SwiftData
import XCTest
@testable import Empty

final class SemanticScorerTests: XCTestCase {
    // MARK: - Cosine similarity

    func testCosineIdentical() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [1, 0, 0]
        XCTAssertEqual(SemanticScorer.cosineSimilarity(a, b), 1.0, accuracy: 0.0001)
    }

    func testCosineOrthogonal() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        XCTAssertEqual(SemanticScorer.cosineSimilarity(a, b), 0.0, accuracy: 0.0001)
    }

    func testCosineOpposite() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [-1, -2, -3]
        XCTAssertEqual(SemanticScorer.cosineSimilarity(a, b), -1.0, accuracy: 0.0001)
    }

    func testCosineMismatchedLength() {
        let a: [Float] = [1, 0]
        let b: [Float] = [1, 0, 0]
        XCTAssertEqual(SemanticScorer.cosineSimilarity(a, b), 0.0, accuracy: 0.0001)
    }

    // MARK: - Embedding round-trip

    func testEmbeddingRoundTrip() throws {
        let chunk = Chunk(
            bookID: UUID(),
            ordinal: 0,
            anchor: TextAnchor(chapterIndex: 0, startUTF16: 0, endUTF16: 10),
            text: "hello"
        )
        chunk.setEmbedding(vector: [0.5, -0.25, 1.0, 0.0])
        let vec = try XCTUnwrap(chunk.embeddingVector)
        XCTAssertEqual(vec.count, 4)
        XCTAssertEqual(vec[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(vec[1], -0.25, accuracy: 0.0001)
        XCTAssertEqual(vec[2], 1.0, accuracy: 0.0001)
        XCTAssertEqual(vec[3], 0.0, accuracy: 0.0001)
    }

    func testEmbeddingNilWhenUnset() {
        let chunk = Chunk(
            bookID: UUID(),
            ordinal: 0,
            anchor: TextAnchor(chapterIndex: 0, startUTF16: 0, endUTF16: 10),
            text: "hello"
        )
        XCTAssertNil(chunk.embeddingVector)
    }

    // MARK: - Retrieval hybrid scoring (no NLEmbedding required)

    /// When no chunk has an embedding the retriever must still work via pure
    /// lexical scoring.
    @MainActor
    func testRetrieverFallsBackToLexical() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let bookID = UUID()

        let chunk1 = Chunk(
            bookID: bookID,
            ordinal: 0,
            anchor: TextAnchor(chapterIndex: 0, startUTF16: 0, endUTF16: 20),
            text: "The quick brown fox"
        )
        let chunk2 = Chunk(
            bookID: bookID,
            ordinal: 1,
            anchor: TextAnchor(chapterIndex: 0, startUTF16: 20, endUTF16: 44),
            text: "jumps over the lazy dog"
        )
        context.insert(chunk1)
        context.insert(chunk2)
        try context.save()

        let position = ReadingPosition(chapterIndex: 0, utf16Offset: 44)
        let results = try ChunkRetriever(modelContext: context).retrieve(
            question: "lazy dog",
            bookID: bookID,
            position: position,
            limit: 2
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].text, "jumps over the lazy dog")
        XCTAssertEqual(results[1].text, "The quick brown fox")
    }
}
