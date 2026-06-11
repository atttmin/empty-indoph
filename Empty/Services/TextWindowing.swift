//
//  TextWindowing.swift
//  Empty
//

import Foundation

/// Splits text into windows that fit a model's context budget.
///
/// Budgets are in **characters** — a deliberately conservative proxy for
/// tokens that holds for CJK (≈1–2 tokens/char) as well as Latin scripts.
/// Cuts prefer paragraph breaks, then sentence boundaries, then hard cuts on
/// grapheme boundaries. Content is never dropped, only whitespace.
nonisolated enum TextWindowing {
    /// Greedily packs paragraphs (split further when oversized) into windows
    /// of at most `maxCharacters` characters each.
    static func windows(for text: String, maxCharacters: Int) -> [String] {
        precondition(maxCharacters > 0, "window budget must be positive")
        var atoms: [String] = []
        for paragraph in paragraphs(of: text) {
            if paragraph.count <= maxCharacters {
                atoms.append(paragraph)
            } else {
                atoms.append(contentsOf: splitOversized(paragraph, maxCharacters: maxCharacters))
            }
        }
        return pack(atoms, maxCharacters: maxCharacters)
    }

    // MARK: - Pieces

    private static func paragraphs(of text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Sentence-splits an oversized paragraph; sentences still over budget
    /// are hard-cut on grapheme boundaries.
    private static func splitOversized(_ paragraph: String, maxCharacters: Int) -> [String] {
        var sentences: [String] = []
        paragraph.enumerateSubstrings(
            in: paragraph.startIndex..<paragraph.endIndex,
            options: .bySentences
        ) { substring, _, _, _ in
            if let substring { sentences.append(substring) }
        }
        if sentences.isEmpty { sentences = [paragraph] }

        var atoms: [String] = []
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.count <= maxCharacters {
                atoms.append(trimmed)
            } else {
                var rest = Substring(trimmed)
                while rest.count > maxCharacters {
                    let cut = rest.index(rest.startIndex, offsetBy: maxCharacters)
                    atoms.append(String(rest[..<cut]))
                    rest = rest[cut...]
                }
                if !rest.isEmpty { atoms.append(String(rest)) }
            }
        }
        return atoms
    }

    private static func pack(_ atoms: [String], maxCharacters: Int) -> [String] {
        var windows: [String] = []
        var current = ""
        for atom in atoms {
            if current.isEmpty {
                current = atom
            } else if current.count + 1 + atom.count <= maxCharacters {
                current += "\n" + atom
            } else {
                windows.append(current)
                current = atom
            }
        }
        if !current.isEmpty { windows.append(current) }
        return windows
    }
}
