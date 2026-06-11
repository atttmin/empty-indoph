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
nonisolated struct CompanionAction: Identifiable, Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
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
        self.id = UUID()
        self.title = title
        self.kind = kind
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
    /// True when reader memory contributed real entries — the reply
    /// trace must disclose it (⚲ 引用了记忆).
    var citedMemory = false
}

/// One tool's catalog entry, rendered into the prompt.
nonisolated struct ReadingToolSpec: Sendable {
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
            summary: "Find a thematic link between a passage and the reader's earlier highlights.",
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

    /// Prompt-ready tool catalog.
    static var toolDocs: String {
        specs
            .map { "- \($0.name)(\($0.argumentHint)): \($0.summary)" }
            .joined(separator: "\n")
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
        let body = chunks.prefix(3)
            .map { chunk in
                let title = chunk.chapter?.title ?? "第 \(chunk.chapterIndex + 1) 章"
                return "[\(title)] \(String(chunk.text.prefix(600)))"
            }
            .joined(separator: "\n")
        return ReadingToolResult(
            observation: body,
            traceLabel: "查已读「\(query.prefix(12))」"
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
        guard var link = try ThoughtLinkFinder(modelContext: modelContext).findLink(
            passage: passage,
            book: book,
            chapterIndex: position.chapterIndex
        ) else {
            return ReadingToolResult(
                observation: "没有找到与读者既有高亮相连的内容。",
                traceLabel: "找关联"
            )
        }
        if let explained = try? await ThoughtLinkFinder(modelContext: modelContext)
            .explainLink(link) {
            link.explanation = explained
        }
        return ReadingToolResult(
            observation: "相关高亮(\(link.relatedSource)):「\(link.relatedText)」\n\(link.explanation)",
            traceLabel: "找关联"
        )
    }

    // MARK: ReaderMemory tools

    private func recallReaderMemory(query: String) throws -> ReadingToolResult {
        guard !query.isEmpty else {
            return ReadingToolResult(observation: "没有给出要回忆的主题。", traceLabel: "忆")
        }
        // Sync first so fresh highlights/cards are recallable immediately.
        let memory = ReaderMemory(modelContext: modelContext)
        try? memory.syncFromReaderData()
        let hits = try memory.recall(query: query, limit: 5)
        let observation = try memory.recallObservation(query: query)
        return ReadingToolResult(
            observation: observation,
            traceLabel: "忆「\(query.prefix(10))」",
            citedMemory: !hits.isEmpty
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
        let hits = highlights.filter {
            $0.textSnapshot.localizedCaseInsensitiveContains(keyword)
                || ($0.note?.localizedCaseInsensitiveContains(keyword) ?? false)
        }.prefix(5)
        guard !hits.isEmpty else {
            return ReadingToolResult(
                observation: "高亮里没有包含「\(keyword)」的内容。",
                traceLabel: "搜高亮「\(keyword.prefix(10))」"
            )
        }
        let body = hits.map { highlight -> String in
            let source = highlight.book?.title ?? "未知书"
            let note = highlight.note.map { " 批注:\($0.prefix(120))" } ?? ""
            return "[\(source) · 第 \(highlight.chapterIndex + 1) 章]「\(highlight.textSnapshot.prefix(160))」\(note)"
        }.joined(separator: "\n")
        return ReadingToolResult(
            observation: body,
            traceLabel: "搜高亮「\(keyword.prefix(10))」"
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
        let action = CompanionAction(
            title: "加入生词本「\(word)」",
            kind: .addVocab(word: word, sentence: "")
        )
        return ReadingToolResult(
            observation: "已把「\(word)」提交给读者确认加入生词本。不要重复提交同一个词。",
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
        var source = String(readText.suffix(4_000))
        if !topic.isEmpty {
            source = "Focus on: \(topic)\n\n" + source
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

    // MARK: Confirmed writes

    /// Executes a reader-confirmed action. Returns a short outcome line
    /// for the transcript bubble.
    func perform(_ action: CompanionAction) async throws -> String {
        switch action.kind {
        case .addVocab(let word, let sentence):
            let entry = try await VocabStore(modelContext: modelContext).lookupWithAI(
                word: word,
                sentence: sentence.isEmpty ? word : sentence,
                source: book.title
            )
            return "已加入生词本:\(entry.word) — \(entry.meaning)"
        case .saveFlashcards(let cards):
            for card in cards {
                let entry = StudyCardEntry(
                    question: card.question,
                    answer: card.answer,
                    source: book.title,
                    kind: .review
                )
                entry.book = book
                modelContext.insert(entry)
            }
            try modelContext.save()
            return "已保存 \(cards.count) 张闪卡,可在卡片/生词屏复习。"
        case .saveMemory(let title, let body, let tags):
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
            return "已记入读者记忆:\(title)"
        }
    }
}
