//
//  ReadingToolbox.swift
//  Empty
//
//  The reading agent's hands: a small set of tools wrapping the app's
//  existing services. Every read goes through the spoiler-safe pipelines
//  (position-capped retrieval, fully-read text only); every write is a
//  proposal the reader confirms in the UI — the agent never mutates data
//  on its own.
//

import Foundation
import SwiftData

/// A write the agent proposed and the reader can confirm with one tap.
nonisolated struct CompanionAction: Identifiable, Equatable {
    nonisolated enum Kind: Equatable {
        /// Look the word up (AI gloss) and add it to the vocabulary book.
        case addVocab(word: String, sentence: String)
        /// Insert the drafted flashcards as spaced-repetition study cards.
        case saveFlashcards([Flashcard])
        /// Save a derived theme/insight into ReaderMemory.
        case saveMemory(title: String, body: String, tags: [String])
    }

    let id: UUID
    /// Button title, e.g. 「加入生词本「resignation」」.
    var title: String
    var kind: Kind
    /// Flips after the reader confirms and the write lands.
    var isDone = false

    init(title: String, kind: Kind) {
        id = UUID()
        self.title = title
        self.kind = kind
    }
}

nonisolated enum CompanionEvidenceKind: String, Equatable {
    case passage
    case highlights
    case memory

    var label: String {
        switch self {
        case .passage:
            return "已读原文"
        case .highlights:
            return "高亮"
        case .memory:
            return "记忆"
        }
    }
}

nonisolated enum CompanionEvidenceScope: String, Equatable {
    case currentBook
    case crossBook
}

nonisolated struct CompanionEvidenceBlock: Identifiable, Equatable {
    let id: UUID
    var kind: CompanionEvidenceKind
    var title: String
    var body: String
    var scope: CompanionEvidenceScope
    var emphasisTerms: [String]

    init(
        kind: CompanionEvidenceKind,
        title: String,
        body: String,
        scope: CompanionEvidenceScope = .currentBook,
        emphasisTerms: [String] = []
    ) {
        id = UUID()
        self.kind = kind
        self.title = title
        self.body = body
        self.scope = scope
        self.emphasisTerms = emphasisTerms
    }
}

/// What one tool invocation produced: text the model reasons over, plus
/// any write proposal for the reader.
nonisolated struct ReadingToolResult {
    /// Observation fed back into the agent transcript.
    var observation: String
    /// 朱批 trace fragment shown in the UI ("查已读「simplicity」").
    var traceLabel: String
    /// Confirm-gated write, when the tool proposes one.
    var proposedAction: CompanionAction?
    /// Evidence blocks worth surfacing back to the reader UI.
    var evidenceBlocks: [CompanionEvidenceBlock] = []
    /// True when reader memory contributed real entries — the reply
    /// trace must disclose it (⚲ 引用了记忆).
    var citedMemory = false
}

/// One tool's catalog entry, rendered into the prompt.
nonisolated struct ReadingToolSpec {
    var name: String
    var summary: String
    var argumentHint: String
}

/// Executes reading tools against one book at one position.
@MainActor
struct ReadingToolbox {
    let book: Book
    let position: ReadingPosition
    let modelContext: ModelContext
    let service: any AIService
    /// Optional reader-written instruction files (global + per-book) that
    /// customize the companion's voice and constraints for this book.
    let instructions: [ReaderInstructionSource]

    static let specs: [ReadingToolSpec] = [
        ReadingToolSpec(
            name: "search_passages",
            summary: "Search the passages the reader has already read.",
            argumentHint: "what to look for"
        ),
        ReadingToolSpec(
            name: "recap_progress",
            summary: "Summarize everything read so far (previously on…).",
            argumentHint: "leave empty"
        ),
        ReadingToolSpec(
            name: "explain",
            summary: "Explain a phrase or concept using only already-read context.",
            argumentHint: "the phrase or concept"
        ),
        ReadingToolSpec(
            name: "find_link",
            summary: "Find one or more thematic echoes between a passage and the reader's earlier highlights.",
            argumentHint: "the passage or idea"
        ),
        ReadingToolSpec(
            name: "recall_reader_memory",
            summary: "Recall the reader's long-term memory: past highlights with notes, link cards, saved Q&A across all books.",
            argumentHint: "the theme or question"
        ),
        ReadingToolSpec(
            name: "search_highlights",
            summary: "Search the reader's highlight snapshots and notes by keyword.",
            argumentHint: "the keyword"
        ),
        ReadingToolSpec(
            name: "propose_memory",
            summary: "Propose saving a one-line insight into the reader's long-term memory (the reader confirms).",
            argumentHint: "the insight, one sentence"
        ),
        ReadingToolSpec(
            name: "add_vocab",
            summary: "Propose adding a word to the vocabulary book (the reader confirms).",
            argumentHint: "the single word or phrase"
        ),
        ReadingToolSpec(
            name: "make_flashcards",
            summary: "Draft up to 3 review flashcards from recently read text (the reader confirms).",
            argumentHint: "optional topic to focus on"
        ),
    ]

    /// Prompt-ready tool catalog, optionally prefixed by reader instructions.
    func toolDocs() -> String {
        let appendix = instructions.map { $0.promptAppendix() }.joined(separator: "\n\n")
        let base = Self.specs
            .map { "- \($0.name)(\($0.argumentHint)): \($0.summary)" }
            .joined(separator: "\n")
        return appendix.isEmpty ? base : "\(appendix)\n\n\(base)"
    }

    func run(_ name: String, argument: String) async throws -> ReadingToolResult {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "search_passages":
            return try searchPassages(query: trimmed)
        case "recap_progress":
            return try await recapProgress()
        case "explain":
            return try await explain(text: trimmed)
        case "find_link":
            return try await findLink(passage: trimmed)
        case "recall_reader_memory":
            return try recallReaderMemory(query: trimmed)
        case "search_highlights":
            return try searchHighlights(keyword: trimmed)
        case "propose_memory":
            return proposeMemory(insight: trimmed)
        case "add_vocab":
            return addVocab(word: trimmed)
        case "make_flashcards":
            return try await makeFlashcards(topic: trimmed)
        default:
            return ReadingToolResult(
                observation: "未知工具 \(name) — 可用工具:\(Self.specs.map(\.name).joined(separator: ", "))",
                traceLabel: "?"
            )
        }
    }

    // MARK: Read tools (spoiler-safe by construction)

    private func searchPassages(query: String) throws -> ReadingToolResult {
        guard !query.isEmpty else {
            return ReadingToolResult(observation: "搜索词为空。", traceLabel: "查已读")
        }
        _ = try BookIndexer(modelContext: modelContext).ensureChunks(for: book)
        let chunks = try ChunkRetriever(modelContext: modelContext).retrieve(
            question: query,
            bookID: book.id,
            position: position
        )
        guard !chunks.isEmpty else {
            return ReadingToolResult(
                observation: "在已读内容里没有找到与「\(query)」相关的段落。",
                traceLabel: "查已读「\(query.prefix(12))」"
            )
        }
        let emphasisTerms = queryTerms(for: query)
        let evidenceBlocks = chunks.prefix(3).map { chunk in
            CompanionEvidenceBlock(
                kind: .passage,
                title: passageSourceLabel(for: chunk),
                body: String(chunk.text.prefix(320)),
                emphasisTerms: emphasisTerms
            )
        }
        let body = evidenceBlocks.enumerated().map { index, block in
            "\(index + 1). \(block.title)\n   原文: \(block.body)"
        }.joined(separator: "\n")
        return ReadingToolResult(
            observation: "命中段落：\n\(body)",
            traceLabel: "查已读「\(query.prefix(12))」",
            evidenceBlocks: evidenceBlocks
        )
    }

    private func recapProgress() async throws -> ReadingToolResult {
        let recap = try await RecapBuilder(
            modelContext: modelContext,
            summarize: { text, focus in
                try await service.summarize(text, focus: focus)
            }
        ).recap(for: book, before: position)
        return ReadingToolResult(observation: recap, traceLabel: "回顾已读")
    }

    private func explain(text: String) async throws -> ReadingToolResult {
        guard !text.isEmpty else {
            return ReadingToolResult(observation: "没有要解释的内容。", traceLabel: "解释")
        }
        _ = try BookIndexer(modelContext: modelContext).ensureChunks(for: book)
        let chunks = (try? ChunkRetriever(modelContext: modelContext).retrieve(
            question: text,
            bookID: book.id,
            position: position
        )) ?? []
        var passages = [GroundedPassage(id: 0, text: text)]
        passages += chunks.prefix(2).map { GroundedPassage(id: $0.ordinal, text: $0.text) }
        let answer = try await service.answer(
            question: "Explain this to a thoughtful reader, in the reader's language: \(text)",
            groundedIn: passages
        )
        return ReadingToolResult(
            observation: answer.text,
            traceLabel: "解释「\(text.prefix(12))」"
        )
    }

    private func findLink(passage: String) async throws -> ReadingToolResult {
        guard !passage.isEmpty else {
            return ReadingToolResult(observation: "没有可关联的内容。", traceLabel: "找关联")
        }
        let finder = ThoughtLinkFinder(modelContext: modelContext)
        let links = try await finder.enrichLinks(
            finder.findLinks(
                passage: passage,
                book: book,
                chapterIndex: position.chapterIndex,
                limit: 3
            )
        )
        guard !links.isEmpty else {
            return ReadingToolResult(
                observation: "没有找到与读者既有高亮相连的内容。",
                traceLabel: "找关联"
            )
        }
        let summary = links.map { link in
            "• \(link.relatedSource)：「\(link.relatedText)」\n\(link.explanation)"
        }.joined(separator: "\n")
        return ReadingToolResult(
            observation: "找到 \(links.count) 条相关回声：\n\(summary)",
            traceLabel: "找关联"
        )
    }

    // MARK: ReaderMemory tools

    private func recallReaderMemory(query: String) throws -> ReadingToolResult {
        guard !query.isEmpty else {
            return ReadingToolResult(observation: "没有给出要回忆的主题。", traceLabel: "忆")
        }
        let memory = ReaderMemory(modelContext: modelContext)
        _ = try? memory.syncFromReaderData()
        let localHits = try memory.recall(query: query, bookID: book.id, limit: 3)
        let globalHits = try memory.recall(query: query, limit: 5)
        let mergedHits = mergeMemoryHits(query: query, localHits: localHits, globalHits: globalHits, limit: 5)
        guard !mergedHits.isEmpty else {
            return ReadingToolResult(
                observation: "记忆里没有与「\(query.prefix(30))」相关的条目。",
                traceLabel: "忆「\(query.prefix(10))」"
            )
        }
        let localIDs = Set(localHits.map(\.itemID))
        let emphasisTerms = queryTerms(for: query)
        let evidenceBlocks = mergedHits.map { hit in
            let isCurrentBook = localIDs.contains(hit.itemID)
            let source = hit.sourceLabel ?? (isCurrentBook ? book.title : "其他书 / 未标注来源")
            let snippet = hit.body
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CompanionEvidenceBlock(
                kind: .memory,
                title: source,
                body: String(snippet.prefix(180)),
                scope: isCurrentBook ? .currentBook : .crossBook,
                emphasisTerms: emphasisTerms
            )
        }
        let lines = evidenceBlocks.enumerated().map { index, block in
            let scope = block.scope == .currentBook ? "本书" : "跨书"
            return "\(index + 1). [\(scope) · \(block.kind.label)] \(block.title)\n   记忆: \(block.body)"
        }.joined(separator: "\n")
        return ReadingToolResult(
            observation: "相关记忆：\n\(lines)",
            traceLabel: "忆「\(query.prefix(10))」",
            evidenceBlocks: evidenceBlocks,
            citedMemory: true
        )
    }

    private func searchHighlights(keyword: String) throws -> ReadingToolResult {
        guard !keyword.isEmpty else {
            return ReadingToolResult(observation: "搜索词为空。", traceLabel: "搜高亮")
        }
        let highlights = try modelContext.fetch(
            FetchDescriptor<Highlight>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        )
        let currentBookHits = highlights.filter { $0.book?.id == book.id }
            .filter {
                $0.textSnapshot.localizedCaseInsensitiveContains(keyword)
                    || ($0.note?.localizedCaseInsensitiveContains(keyword) ?? false)
            }
        let otherBookHits = highlights.filter { $0.book?.id != book.id }
            .filter {
                $0.textSnapshot.localizedCaseInsensitiveContains(keyword)
                    || ($0.note?.localizedCaseInsensitiveContains(keyword) ?? false)
            }
        let hits: [Highlight]
        if !currentBookHits.isEmpty {
            hits = Array(currentBookHits.prefix(4))
        } else {
            hits = Array(otherBookHits.prefix(2))
        }
        guard !hits.isEmpty else {
            return ReadingToolResult(
                observation: "高亮里没有包含「\(keyword)」的内容。",
                traceLabel: "搜高亮「\(keyword.prefix(10))」"
            )
        }
        let emphasisTerms = queryTerms(for: keyword)
        let evidenceBlocks = hits.map { highlight in
            let isCurrentBook = highlight.book?.id == book.id
            let source = isCurrentBook
                ? "第 \(highlight.chapterIndex + 1) 章"
                : "《\(highlight.book?.title ?? "未知书")》 · 第 \(highlight.chapterIndex + 1) 章"
            let note = highlight.note?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let noteLine = note.map { "\n批注: \($0.prefix(110))" } ?? ""
            return CompanionEvidenceBlock(
                kind: .highlights,
                title: source,
                body: "原文: 「\(highlight.textSnapshot.prefix(140))」\(noteLine)",
                scope: isCurrentBook ? .currentBook : .crossBook,
                emphasisTerms: emphasisTerms
            )
        }
        let body = evidenceBlocks.enumerated().map { index, block in
            let scope = block.scope == .currentBook ? "本书" : "跨书"
            return "\(index + 1). [\(scope) · \(block.kind.label)] \(block.title)\n   \(block.body)"
        }.joined(separator: "\n")
        return ReadingToolResult(
            observation: "命中高亮：\n\(body)",
            traceLabel: "搜高亮「\(keyword.prefix(10))」",
            evidenceBlocks: evidenceBlocks
        )
    }

    private func proposeMemory(insight: String) -> ReadingToolResult {
        guard !insight.isEmpty else {
            return ReadingToolResult(observation: "没有给出要记住的内容。", traceLabel: "建议记住")
        }
        let action = CompanionAction(
            title: "记住:\(insight.prefix(24))…",
            kind: .saveMemory(
                title: String(insight.prefix(40)),
                body: insight,
                tags: []
            )
        )
        return ReadingToolResult(
            observation: "已把这条洞见提交给读者确认记入长期记忆。不要重复提交。",
            traceLabel: "建议记住(待确认)",
            proposedAction: action
        )
    }

    // MARK: Write tools (proposal only — the reader confirms)

    private func addVocab(word: String) -> ReadingToolResult {
        guard !word.isEmpty else {
            return ReadingToolResult(observation: "没有给出要加入的词。", traceLabel: "建议生词")
        }
        let sentence = (try? contextualSentence(for: word)) ?? ""
        let action = CompanionAction(
            title: "加入生词本「\(word)」",
            kind: .addVocab(word: word, sentence: sentence)
        )
        let contextLine = sentence.isEmpty ? "" : "\n上下文:\(sentence)"
        return ReadingToolResult(
            observation: "已把「\(word)」提交给读者确认加入生词本。不要重复提交同一个词。\(contextLine)",
            traceLabel: "建议生词(待确认)",
            proposedAction: action
        )
    }

    private func makeFlashcards(topic: String) async throws -> ReadingToolResult {
        // Most recent stretch of already-read text — never ahead of the
        // reader's position.
        let readText = try Chapter.fullyReadText(
            forBookID: book.id,
            before: position,
            in: modelContext
        )
        guard !readText.isEmpty else {
            return ReadingToolResult(
                observation: "读者还没有读过可出题的内容。",
                traceLabel: "生成闪卡"
            )
        }
        var source = String(readText.suffix(4000))
        if !topic.isEmpty {
            source = "Focus on: \(topic)\n\n" + source
        }
        if !instructions.isEmpty {
            let appendix = instructions.map { $0.promptAppendix() }.joined(separator: "\n\n")
            source = "\(appendix)\n\n" + source
        }
        let cards = try await service.flashcards(from: source, maxCount: 3)
        guard !cards.isEmpty else {
            return ReadingToolResult(
                observation: "没有生成出合适的卡片。",
                traceLabel: "生成闪卡"
            )
        }
        let action = CompanionAction(
            title: "保存 \(cards.count) 张闪卡",
            kind: .saveFlashcards(cards)
        )
        let preview = cards
            .map { "Q: \($0.question)" }
            .joined(separator: "\n")
        return ReadingToolResult(
            observation: "已起草 \(cards.count) 张闪卡,待读者确认保存:\n\(preview)",
            traceLabel: "生成闪卡(待确认)",
            proposedAction: action
        )
    }

    private func recentReadText(maxCharacters: Int) throws -> String? {
        try Chapter.recentContextExcerpt(
            forBookID: book.id,
            before: position,
            maxCharacters: maxCharacters,
            in: modelContext
        )
    }

    private func contextualSentence(for word: String) throws -> String? {
        guard !word.isEmpty,
              let excerpt = try recentReadText(maxCharacters: 1200),
              let range = excerpt.range(of: word, options: [.caseInsensitive, .diacriticInsensitive])
        else { return nil }
        let utf16 = Array(excerpt.utf16)
        let lower = max(0, range.lowerBound.utf16Offset(in: excerpt) - 70)
        let upper = min(utf16.count, range.upperBound.utf16Offset(in: excerpt) + 90)
        let snippet = String(decoding: utf16[lower ..< upper], as: UTF16.self)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? nil : snippet
    }

    private func mergeMemoryHits(
        query: String,
        localHits: [MemoryRecall],
        globalHits: [MemoryRecall],
        limit: Int
    ) -> [MemoryRecall] {
        let nonLocalGlobals = globalHits.filter { global in
            !localHits.contains(where: { $0.itemID == global.itemID })
        }
        let thematicQuery = queryTerms(for: query).count >= 2
        if localHits.count >= 2 {
            return Array(localHits.prefix(limit))
        }
        if let topLocal = localHits.first {
            guard thematicQuery else { return Array(localHits.prefix(limit)) }
            let qualifiedEchoes = nonLocalGlobals.filter {
                $0.score >= max(0.25, topLocal.score * 0.45)
            }
            return Array((localHits + qualifiedEchoes.prefix(1)).prefix(limit))
        }
        let qualifiedEchoes = nonLocalGlobals.filter {
            $0.score >= (thematicQuery ? 0.58 : 0.64)
        }
        return Array(qualifiedEchoes.prefix(min(limit, thematicQuery ? 2 : 1)))
    }

    private func passageSourceLabel(for chunk: Chunk) -> String {
        let title = if let chapterTitle = chunk.chapter?.title, !chapterTitle.isEmpty {
            chapterTitle
        } else {
            "第 \(chunk.chapterIndex + 1) 章"
        }
        return "《\(book.title)》 · \(title) · ¶\(chunk.ordinal + 1)"
    }

    private func queryTerms(for query: String) -> [String] {
        let tokens = query
            .split {
                $0.isWhitespace
                    || "，。、！？；：,.!?;:()[]{}<>“”‘’'\"/\\|".contains($0)
            }
            .map(String.init)
        let candidates = tokens.filter { $0.count >= 2 }
        let seeds = candidates.isEmpty
            ? [query.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
            : candidates
        var seen = Set<String>()
        var unique = [String]()
        for term in seeds {
            let normalized = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(normalized).inserted else { continue }
            unique.append(term)
        }
        return unique
    }

    // MARK: Confirmed writes

    /// Executes a reader-confirmed action. Returns a short outcome line
    /// for the transcript bubble.
    func perform(_ action: CompanionAction) async throws -> String {
        switch action.kind {
        case let .addVocab(word, sentence):
            let entry = try await VocabStore(modelContext: modelContext).lookupWithAI(
                word: word,
                sentence: sentence.isEmpty ? word : sentence,
                source: book.title,
                book: book,
                sourcePosition: position
            )
            return "已加入生词本:\(entry.word) — \(entry.meaning)"
        case let .saveFlashcards(cards):
            for card in cards {
                let entry = StudyCardEntry(
                    question: card.question,
                    answer: card.answer,
                    source: book.title,
                    kind: .review
                )
                entry.setSourcePosition(position)
                entry.book = book
                modelContext.insert(entry)
            }
            try modelContext.save()
            return "已保存 \(cards.count) 张闪卡,可在卡片/生词屏复习。"
        case let .saveMemory(title, body, tags):
            let item = MemoryItem(
                kind: .theme,
                title: title,
                body: body,
                bookID: book.id,
                sourceLabel: book.title,
                tags: tags,
                isUserConfirmed: true
            )
            modelContext.insert(item)
            try modelContext.save()
            _ = try MemoryEmbeddingIndex.syncEmbeddings(for: Set([item.id]), in: modelContext)
            return "已记入读者记忆:\(title)"
        }
    }
}
