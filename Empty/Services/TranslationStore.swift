//
//  TranslationStore.swift
//  Empty
//
//  Persistent cache behind 双语对照/导读: paragraph translations keyed by
//  a stable hash of their source text, so a book is never translated
//  twice and 译文 renders straight from disk on a re-read.
//

import Foundation
import SwiftData

@MainActor
struct TranslationStore {
    let modelContext: ModelContext

    // MARK: Normalization & hashing

    /// Whitespace-collapsed form, so the same paragraph hashes identically
    /// whether it came from the chapter's plain text or the page DOM.
    nonisolated static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// FNV-1a 64 over the normalized UTF-8 — stable across launches
    /// (unlike `hashValue`) and cheap enough to run per paragraph.
    nonisolated static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalize(text).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }

    // MARK: Lookup / store

    func lookup(
        bookID: UUID,
        kind: TranslationKind,
        text: String,
        target: String = "zh-Hans"
    ) -> String? {
        let textHash = Self.hash(text)
        let kindRaw = kind.rawValue
        var descriptor = FetchDescriptor<ParagraphTranslation>(
            predicate: #Predicate {
                $0.bookID == bookID
                    && $0.kindRawValue == kindRaw
                    && $0.textHash == textHash
                    && $0.target == target
            }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first?.translation
    }

    /// Upserts one translation. Saves immediately so progress survives the
    /// app quitting mid-pretranslation.
    func store(
        _ translation: String,
        bookID: UUID,
        chapterIndex: Int,
        kind: TranslationKind,
        text: String,
        target: String = "zh-Hans"
    ) {
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let textHash = Self.hash(text)
        let kindRaw = kind.rawValue
        var descriptor = FetchDescriptor<ParagraphTranslation>(
            predicate: #Predicate {
                $0.bookID == bookID
                    && $0.kindRawValue == kindRaw
                    && $0.textHash == textHash
                    && $0.target == target
            }
        )
        descriptor.fetchLimit = 1
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.translation = trimmed
        } else {
            modelContext.insert(ParagraphTranslation(
                bookID: bookID,
                chapterIndex: chapterIndex,
                kind: kind,
                textHash: textHash,
                target: target,
                translation: trimmed
            ))
        }
        try? modelContext.save()
    }

    // MARK: Stats (cache visualization)

    /// Cached-translation count for one chapter.
    func cachedCount(bookID: UUID, chapterIndex: Int, kind: TranslationKind) -> Int {
        let kindRaw = kind.rawValue
        return (try? modelContext.fetchCount(
            FetchDescriptor<ParagraphTranslation>(
                predicate: #Predicate {
                    $0.bookID == bookID
                        && $0.chapterIndex == chapterIndex
                        && $0.kindRawValue == kindRaw
                }
            )
        )) ?? 0
    }

    /// Whole-book cache footprint: entry count and stored 译文 bytes.
    func bookFootprint(bookID: UUID) -> (count: Int, bytes: Int) {
        let entries = (try? modelContext.fetch(
            FetchDescriptor<ParagraphTranslation>(
                predicate: #Predicate { $0.bookID == bookID }
            )
        )) ?? []
        let bytes = entries.reduce(0) { $0 + $1.translation.utf8.count }
        return (count: entries.count, bytes: bytes)
    }

    // MARK: Paragraph segmentation (pre-translation)

    /// Splits chapter plain text into translatable paragraphs with the
    /// same bounds the reader uses for on-demand translation (length
    /// 40…4000), capped so pre-translation cost stays predictable.
    nonisolated static func paragraphs(in text: String, cap: Int = 80) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 40 && $0.count <= 4_000 }
            .prefix(cap)
            .map { $0 }
    }
}
