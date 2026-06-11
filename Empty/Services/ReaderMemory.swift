//
//  ReaderMemory.swift
//  Empty
//
//  Phase 1/2 of docs/READER-MEMORY-PLAN.md: ingest reader behaviour into
//  MemoryItem rows (idempotent by sourceRefID), recall them by blended
//  lexical + semantic score with provenance, and accept reader-confirmed
//  theme memories from the agent. The master switch (设置里一关即「失忆」)
//  empties recall without deleting anything.
//

import Foundation
import NaturalLanguage
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
        var touchedIDs: Set<UUID> = []

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
                if update(item, title: title, body: body, sourceLabel: label) {
                    touchedIDs.insert(item.id)
                }
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
                touchedIDs.insert(item.id)
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
                if update(item, title: title, body: body, sourceLabel: card.source) {
                    touchedIDs.insert(item.id)
                }
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
                touchedIDs.insert(item.id)
                created += 1
            }
        }

        try modelContext.save()
        if !touchedIDs.isEmpty {
            _ = try MemoryEmbeddingIndex.syncEmbeddings(for: touchedIDs, in: modelContext)
        }
        return created
    }

    private func update(
        _ item: MemoryItem,
        title: String,
        body: String,
        sourceLabel: String?
    ) -> Bool {
        guard item.title != title || item.body != body
            || item.sourceLabel != sourceLabel else { return false }
        item.title = title
        item.body = body
        item.sourceLabel = sourceLabel
        item.updatedAt = Date()
        return true
    }

    // MARK: Recall

    /// Blended recall (0.4 lexical + 0.6 semantic when persisted
    /// `MemoryEmbedding` rows are available). Unconfirmed derived items
    /// never surface; the master switch empties everything.
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
        let filtered = items.filter { item in
            item.isUserConfirmed
                && !item.isCompressedCompanionQA
                && (kinds == nil || kinds?.contains(item.kind) == true)
                && (bookID == nil || item.bookID == bookID)
        }
        let queryVector = SemanticScorer.queryVector(for: trimmed)
        if queryVector != nil {
            _ = try MemoryEmbeddingIndex.syncEmbeddings(
                for: Set(filtered.map(\.id)),
                in: modelContext
            )
        }
        let embeddings = try modelContext.fetch(FetchDescriptor<MemoryEmbedding>())
        let embeddingByItemID = Dictionary(uniqueKeysWithValues: embeddings.map { ($0.itemID, $0) })

        var scored: [(MemoryRecall, Double)] = []
        for item in filtered {
            let text = MemoryEmbeddingIndex.memoryText(for: item)
            let lexical = LexicalScorer.score(query: trimmed, text: text)
            var semantic = 0.0
            if let queryVector,
               let candidate = embeddingByItemID[item.id],
               candidate.languageTag == queryVector.languageTag,
               let candidateVector = candidate.embeddingVector {
                semantic = SemanticScorer.cosineSimilarity(
                    queryVector.vector, candidateVector
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

    @discardableResult
    func compressCompanionQAIntoThemes(minClusterSize: Int = 2) throws -> (themesCreated: Int, questionsCompressed: Int) {
        let items = try modelContext.fetch(FetchDescriptor<MemoryItem>())
        let candidates = items.filter {
            $0.kind == .companionQA && $0.isUserConfirmed && !$0.isCompressedCompanionQA
        }
        guard candidates.count >= minClusterSize else { return (0, 0) }

        _ = try MemoryEmbeddingIndex.syncEmbeddings(
            for: Set(candidates.map(\.id)),
            in: modelContext
        )
        let embeddings = try modelContext.fetch(FetchDescriptor<MemoryEmbedding>())
        let embeddingByItemID = Dictionary(uniqueKeysWithValues: embeddings.map { ($0.itemID, $0) })
        let clusters = qaClusters(
            from: candidates,
            embeddings: embeddingByItemID,
            minClusterSize: minClusterSize
        )
        guard !clusters.isEmpty else { return (0, 0) }

        var themesCreated = 0
        var questionsCompressed = 0
        var newThemeIDs: Set<UUID> = []
        for cluster in clusters {
            let summary = compressedThemeSummary(for: cluster)
            let theme = MemoryItem(
                kind: .theme,
                title: summary.title,
                body: summary.body,
                bookID: summary.bookID,
                chapterIndex: summary.chapterIndex,
                sourceLabel: summary.sourceLabel,
                tags: summary.tags,
                sourceRefKind: MemoryItem.qaCompressionSourceKind,
                isUserConfirmed: true
            )
            modelContext.insert(theme)
            newThemeIDs.insert(theme.id)
            themesCreated += 1
            questionsCompressed += cluster.count

            for item in cluster {
                var tags = item.tags.filter { $0 != MemoryItem.compressedCompanionQATag }
                tags.append(MemoryItem.compressedCompanionQATag)
                item.tags = Array(NSOrderedSet(array: tags)) as? [String] ?? tags
                item.updatedAt = Date()
            }
        }

        try modelContext.save()
        if !newThemeIDs.isEmpty {
            _ = try MemoryEmbeddingIndex.syncEmbeddings(for: newThemeIDs, in: modelContext)
        }
        return (themesCreated, questionsCompressed)
    }

    private func qaClusters(
        from items: [MemoryItem],
        embeddings: [UUID: MemoryEmbedding],
        minClusterSize: Int
    ) -> [[MemoryItem]] {
        var visited: Set<UUID> = []
        var clusters: [[MemoryItem]] = []

        for seed in items where !visited.contains(seed.id) {
            var cluster: [MemoryItem] = []
            var stack: [MemoryItem] = [seed]
            visited.insert(seed.id)

            while let current = stack.popLast() {
                cluster.append(current)
                for candidate in items where !visited.contains(candidate.id) {
                    guard qaItemsBelongTogether(
                        current,
                        candidate,
                        embeddings: embeddings
                    ) else { continue }
                    visited.insert(candidate.id)
                    stack.append(candidate)
                }
            }

            if cluster.count >= minClusterSize {
                clusters.append(cluster.sorted { $0.updatedAt < $1.updatedAt })
            }
        }

        return clusters
    }

    private func qaItemsBelongTogether(
        _ lhs: MemoryItem,
        _ rhs: MemoryItem,
        embeddings: [UUID: MemoryEmbedding]
    ) -> Bool {
        guard lhs.id != rhs.id else { return true }
        guard lhs.bookID == rhs.bookID else { return false }

        let lhsText = MemoryEmbeddingIndex.memoryText(for: lhs)
        let rhsText = MemoryEmbeddingIndex.memoryText(for: rhs)
        let lexical = max(
            LexicalScorer.score(query: lhsText, text: rhsText),
            LexicalScorer.score(query: rhsText, text: lhsText)
        )
        if lexical > 0.18 { return true }

        guard let lhsEmbedding = embeddings[lhs.id],
              let rhsEmbedding = embeddings[rhs.id],
              lhsEmbedding.languageTag == rhsEmbedding.languageTag,
              let lhsVector = lhsEmbedding.embeddingVector,
              let rhsVector = rhsEmbedding.embeddingVector else { return false }
        return SemanticScorer.cosineSimilarity(lhsVector, rhsVector) > 0.72
    }

    private func compressedThemeSummary(for cluster: [MemoryItem]) -> (
        title: String,
        body: String,
        tags: [String],
        sourceLabel: String?,
        bookID: UUID?,
        chapterIndex: Int?
    ) {
        let tokens = topicTokens(for: cluster)
        let title = tokens.prefix(2).joined(separator: " · ").trimmingCharacters(in: .whitespaces)
        let resolvedTitle = title.isEmpty ? "反复追问的主题" : title
        let questions = cluster
            .map { String($0.title.prefix(24)) }
            .prefix(3)
            .joined(separator: "；")
        let tokenSummary = tokens.isEmpty ? "" : "关键词：\(tokens.prefix(4).joined(separator: "、"))。"
        let body = "以下 \(cluster.count) 条旧问答反复追问：\(questions)。可长期收束为「\(resolvedTitle)」。\(tokenSummary)"
        let labels = cluster.compactMap(\.sourceLabel)
        let sourceLabel = labels.allSatisfy { $0 == labels.first } ? labels.first : labels.first.map { "\($0) 等 \(cluster.count) 条问答" }
        let bookID = cluster.allSatisfy { $0.bookID == cluster.first?.bookID } ? cluster.first?.bookID : nil
        let chapterIndex = cluster.allSatisfy { $0.chapterIndex == cluster.first?.chapterIndex } ? cluster.first?.chapterIndex : nil
        return (resolvedTitle, body, tokens, sourceLabel, bookID, chapterIndex)
    }

    private func topicTokens(for cluster: [MemoryItem]) -> [String] {
        var documentFrequency: [String: Int] = [:]
        for item in cluster {
            let tokens = Set(tokens(in: MemoryEmbeddingIndex.memoryText(for: item)))
            for token in tokens {
                documentFrequency[token, default: 0] += 1
            }
        }
        return documentFrequency
            .filter { $0.value >= 2 || cluster.count == 2 }
            .sorted {
                if $0.value == $1.value {
                    return $0.key.count > $1.key.count
                }
                return $0.value > $1.value
            }
            .map(\.key)
            .prefix(4)
            .map { $0 }
    }

    private func tokens(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text.lowercased()
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if isUsefulThemeToken(token) {
                result.append(token)
            }
            return true
        }
        return result
    }

    private func isUsefulThemeToken(_ token: String) -> Bool {
        guard token.count >= 2 else { return false }
        let lowered = token.lowercased()
        let stopwords: Set<String> = [
            "the", "and", "that", "this", "with", "from", "into", "what",
            "why", "how", "when", "then", "than", "have", "has", "had",
            "your", "their", "about", "would", "could", "should", "一个",
            "这个", "那个", "什么", "为什么", "如何", "我们", "你们", "他们"
        ]
        if stopwords.contains(lowered) { return false }
        return lowered.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.inverted.contains($0) }
    }

    private func sourceLabel(bookTitle: String?, chapterIndex: Int?) -> String? {
        guard let bookTitle else { return nil }
        if let chapterIndex {
            return "\(bookTitle) · 第 \(chapterIndex + 1) 章"
        }
        return bookTitle
    }
}
