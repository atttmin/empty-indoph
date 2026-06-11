//
//  CharacterBudget.swift
//  Empty
//

import Foundation

/// Converts a model's token budget into a character budget for a specific
/// text, because `TextWindowing` cuts by characters but context windows are
/// measured in tokens — and the chars-per-token ratio differs wildly between
/// scripts (CJK ≈ 1.6 tokens/char, Latin ≈ 0.4).
///
/// Estimates are deliberately conservative; the on-device service still
/// retries with a halved budget if a window overflows anyway.
nonisolated enum CharacterBudget {
    /// Estimated tokens-per-character density of `text`, from a bounded
    /// sample of its leading scalars.
    static func estimatedTokenDensity(of text: String) -> Double {
        var cjkCount = 0
        var otherCount = 0
        for scalar in text.unicodeScalars.prefix(6_000) {
            if isCJK(scalar) {
                cjkCount += 1
            } else {
                otherCount += 1
            }
        }
        let total = cjkCount + otherCount
        guard total > 0 else { return 0.4 }
        return (Double(cjkCount) * 1.6 + Double(otherCount) * 0.4) / Double(total)
    }

    /// Character budget that should keep a window of `text` within
    /// `tokens` tokens. Never below 500 characters.
    static func characters(forTokens tokens: Int, in text: String) -> Int {
        let density = max(estimatedTokenDensity(of: text), 0.05)
        return max(500, Int(Double(tokens) / density))
    }

    /// Shared CJK classification (also used by `LexicalScorer` tokens).
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x9FFF, // CJK radicals, kana, ideographs
             0xAC00...0xD7AF, // Hangul syllables
             0xF900...0xFAFF, // CJK compatibility ideographs
             0x20000...0x2FFFF: // CJK extensions
            true
        default:
            false
        }
    }
}
