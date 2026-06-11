//
//  ParagraphTranslation.swift
//  Empty
//

import Foundation
import SwiftData

/// One cached AI translation (or 导读 paraphrase, or chapter-title
/// translation), keyed by a stable hash of its source text.
///
/// Local store only: translations are derived from book content and
/// regenerable, so they never sync — same rule as `Chapter`/`Chunk`. This
/// is what makes 双语对照 open instantly on a re-read: the reader renders
/// the original immediately and fills 译文 from here, never re-translating
/// a paragraph it has seen before (the prototype's 「预译 + 永不阻塞」).
@Model
final class ParagraphTranslation {
    #Index<ParagraphTranslation>(
        [\.bookID, \.chapterIndex],
        [\.bookID, \.kindRawValue, \.textHash]
    )

    var bookID: UUID
    /// Chapter the text was first met in — for per-chapter cache stats;
    /// lookups go by hash so a repeated paragraph still hits.
    var chapterIndex: Int
    /// `TranslationKind` raw value (predicates filter on this directly).
    var kindRawValue: String
    /// `TranslationStore.hash` of the normalized source text.
    var textHash: String
    /// Target language (BCP-47-ish) the translation was made into —
    /// caches for different目标语言 never collide. Legacy rows default
    /// to 简中, which is what they were.
    var target: String = "zh-Hans"
    var translation: String
    var createdAt: Date

    var kind: TranslationKind {
        TranslationKind(rawValue: kindRawValue) ?? .bilingual
    }

    init(
        bookID: UUID,
        chapterIndex: Int,
        kind: TranslationKind,
        textHash: String,
        target: String = "zh-Hans",
        translation: String,
        createdAt: Date = Date()
    ) {
        self.bookID = bookID
        self.chapterIndex = chapterIndex
        self.kindRawValue = kind.rawValue
        self.textHash = textHash
        self.target = target
        self.translation = translation
        self.createdAt = createdAt
    }
}

/// What a cached translation is for.
nonisolated enum TranslationKind: String, CaseIterable, Sendable {
    /// Paragraph translation for 双语对照.
    case bilingual = "bi"
    /// Paragraph 导读 paraphrase.
    case companion = "comp"
    /// Chapter-title translation for the bilingual TOC.
    case title
    /// 辩难 lens counter-questions.
    case debate = "q"
    /// 文献 lens public-domain echoes.
    case sources = "src"
}
