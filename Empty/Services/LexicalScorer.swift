//
//  LexicalScorer.swift
//  Empty
//

import Foundation

/// Dependency-free relevance scoring for retrieval: latin words plus CJK
/// characters and character-bigrams as tokens, overlap normalized by the
/// query's token count.
///
/// This is the always-available baseline ranker; semantic vectors
/// (`Chunk.embedding`) will boost it once the background indexing actor
/// lands, but lexical scoring keeps ask-the-book working everywhere —
/// simulators, fresh devices, models-not-downloaded.
nonisolated enum LexicalScorer {
    /// 0…1: fraction of the query's tokens present in `text`.
    static func score(query: String, text: String) -> Double {
        let queryTokens = tokens(of: query)
        guard !queryTokens.isEmpty else { return 0 }
        let overlap = queryTokens.intersection(tokens(of: text)).count
        return Double(overlap) / Double(queryTokens.count)
    }

    /// Lowercased latin/number words, single CJK characters, and CJK
    /// bigrams (bigrams make "凶手" distinct from texts merely containing
    /// "凶" and "手" apart).
    static func tokens(of text: String) -> Set<String> {
        var result: Set<String> = []
        var word: [Character] = []
        var previousCJK: Character?

        func flushWord() {
            guard !word.isEmpty else { return }
            result.insert(String(word).lowercased())
            word.removeAll(keepingCapacity: true)
        }

        for character in text {
            guard let scalar = character.unicodeScalars.first else { continue }
            if CharacterBudget.isCJK(scalar) {
                flushWord()
                result.insert(String(character))
                if let previous = previousCJK {
                    result.insert("\(previous)\(character)")
                }
                previousCJK = character
            } else {
                previousCJK = nil
                if character.isLetter || character.isNumber {
                    word.append(character)
                } else {
                    flushWord()
                }
            }
        }
        flushWord()
        return result
    }
}
