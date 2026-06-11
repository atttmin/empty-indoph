//
//  ReaderMemory.swift
//  Empty
//
//  Phase 1 of docs/READER-MEMORY-PLAN.md: ingest reader behaviour into
//  MemoryItem rows (idempotent by sourceRefID), recall them by blended
//  lexical + semantic score with provenance, and format observations
//  for the reading agent. The master switch (设置里一关即「失忆」)
//  empties recall without deleting anything.
//

import Foundation
import SwiftData

nonisolated struct MemoryRecall: Sendable, Equatable {
    var itemID: UUID
    var kind: MemoryKind
    var title: String
    var body: String
    var sourceLabel: String?
    var score: Double
}

@MainActor
struct ReaderMemory {
    let modelContext: ModelContext

    /// 总开关 — off means the AI is amnesiac (recall returns nothing);
    /// the stored items stay untouched.
    static let enabledKey = "memory.enabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil
            ? true
            : defaults.bool(forKey: enabledKey)
    }

    // MARK: Ingest

    /// Derives MemoryItems from highlights-with-notes, link cards and
    /// saved Q&A cards. Idempotent: existing sourceRefIDs update in
    /// place instead of duplicating.
    @discardableResult
    func syncFromReaderData() throws -> Int {
        let existing = try modelContext.fetch(FetchDescriptor<MemoryItem>())
        var bySource: [UUID: MemoryItem] = [:]
        for item in existing {
            if let ref = item.sourceRefID { bySource[ref] = item }
        }
        var created = 0

        let highlights = try modelContext.fetch(FetchDescriptor<Highlight>())
        for highlight in highlights {
            guard let note = highlight.note, !note.isEmpty else { continue }
            let title = String(highlight.textSnapshot.prefix(40))
            let body = "「\(highlight.textSnapshot.prefix(160))」批注：\(note.prefix(400))"
            let label = sourceLabel(
                bookTitle: highlight.book?.title,
                chapterIndex: highlight.chapterIndex
            )
            if let item = bySource[highlight.id] {
                update(item, title: title, body: body, sourceLabel: label)
            } else {
                let item = MemoryItem(
                    kind: .highlightNote,
                    title: title,
                    body: body,
                    bookID: highlight.book?.id,
                    chapterIndex: highlight.chapterIndex,
                    sourceLabel: label,
                    sourceRefID: highlight.id,
                    sourceRefKind: "highlight",
                    isUserConfirmed: true
                )
                modelContext.insert(item)
                created += 1
            }
        }

        let cards = try modelContext.fetch(FetchDescriptor<StudyCardEntry>())
        for card in cards {
            let kind: MemoryKind
            switch card.kind {
            case .link: kind = .thoughtLink
            case .qa: kind = .companionQA
            default: continue
            }
            let title = String(card.question.prefix(60))
            let body = "\(card.question.prefix(200))\n\(card.answer.prefix(400))"
            if let item = bySource[card.id] {
                update(item, title: title, body: body, sourceLabel: card.source)
            } else {
                let item = MemoryItem(
                    kind: kind,
                    title: title,
                    body: body,
                    bookID: card.book?.id,
                    sourceLabel: card.source,
                    sourceRefID: card.id,
                    sourceRefKind: "studyCard",
                    isUserConfirmed: true
                )
                modelContext.insert(item)
                created += 1
            }
        }

        try modelContext.save()
        return created
    }

    private func update(
        _ item: MemoryItem,
        title: String,
        body: String,
        sourceLabel: String?
    ) {
        guard item.title != title || item.body != body
            || item.sourceLabel != sourceLabel else { return }
        item.title = title
        item.body = body
        item.sourceLabel = sourceLabel
        item.updatedAt = Date()
    }

    // MARK: Recall

    /// Blended recall (0.4 lexical + 0.6 semantic when embeddings are
    /// available). Unconfirmed derived items never surface; the master
    /// switch empties everything.
    func recall(
        query: String,
        kinds: Set<MemoryKind>? = nil,
        bookID: UUID? = nil,
        limit: Int = 8
    ) throws -> [MemoryRecall] {
        guard Self.isEnabled() else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let items = try modelContext.fetch(FetchDescriptor<MemoryItem>())
        let queryVector = SemanticScorer.queryVector(for: trimmed)

        var scored: [(MemoryRecall, Double)] = []
        for item in items where item.isUserConfirmed {
            if let kinds, !kinds.contains(item.kind) { continue }
            if let bookID, item.bookID != bookID { continue }
            let text = "\(item.title) \(item.body)"
            let lexical = LexicalScorer.score(query: trimmed, text: text)
            var semantic = 0.0
            if let queryVector,
               let candidate = SemanticScorer.queryVector(for: text),
               candidate.languageTag == queryVector.languageTag {
                semantic = SemanticScorer.cosineSimilarity(
                    queryVector.vector, candidate.vector
                )
            }
            // Gate on either route being individually convincing —
            // a blended floor lets weak semantic noise (量子力学 vs 减法)
            // sneak through. Short CJK fragments embed loosely, so the
            // semantic-only route needs a high bar.
            guard lexical > 0.12 || semantic > 0.55 else { continue }
            let score = queryVector == nil
                ? lexical
                : 0.4 * lexical + 0.6 * semantic
            scored.append((
                MemoryRecall(
                    itemID: item.id,
                    kind: item.kind,
                    title: item.title,
                    body: item.body,
                    sourceLabel: item.sourceLabel,
                    score: score
                ),
                score
            ))
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Tool-facing observation: provenance-stamped digest lines.
    func recallObservation(query: String, limit: Int = 5) throws -> String {
        guard Self.isEnabled() else {
            return "读者记忆已关闭（设置里可重新开启）。"
        }
        let hits = try recall(query: query, limit: limit)
        guard !hits.isEmpty else {
            return "记忆里没有与「\(query.prefix(30))」相关的条目。"
        }
        return hits.map { hit in
            let provenance = hit.sourceLabel.map { "（\($0)）" } ?? ""
            return "[\(hit.kind.title)]\(provenance) \(hit.body.prefix(200))"
        }.joined(separator: "\n")
    }

    private func sourceLabel(bookTitle: String?, chapterIndex: Int?) -> String? {
        guard let bookTitle else { return nil }
        if let chapterIndex {
            return "\(bookTitle) · 第 \(chapterIndex + 1) 章"
        }
        return bookTitle
    }
}
