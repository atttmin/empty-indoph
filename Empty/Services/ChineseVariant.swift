//
//  ChineseVariant.swift
//  Empty
//
//  P1 繁简: render-layer simplified→traditional conversion via the
//  system ICU transliterator — no bundled word tables, fully offline.
//  Source files are never modified; the toggle converts at display time.
//

import Foundation

nonisolated enum ChineseVariant {
    private static let hansToHant = StringTransform("Hans-Hant")

    /// Simplified → traditional (万→萬). Returns the input unchanged when
    /// the transform is unavailable.
    static func traditional(_ text: String) -> String {
        text.applyingTransform(hansToHant, reverse: false) ?? text
    }
}
