//
//  ReaderMemoryTests.swift
//  EmptyTests
//
//  Phase 1/2/1b of READER-MEMORY-PLAN: idempotent ingest from reader
//  data, persisted local semantic embeddings, recall with provenance, the
//  amnesia master switch, and the confirm-gated propose_memory write.
//

import Foundation
import SwiftData
import Testing
@testable import Empty

@MainActor
struct ReaderMemoryTests {
    private func makeFixture() throws -> (ModelContainer, Book) {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let book = Book(title: "Walden", format: .epub)
        context.insert(book)
        context.insert(Chapter(bookID: book.id, index: 0, text: "做减法，把生活削到只剩本质。简单是核心。"))
        try context.save()
        return (container, book)
    }

    @Test func ingestIsIdempotentAndSkipsNotelessHighlights() throws {
        let (container, book) = try makeFixture()
        let context = container.mainContext
        let store = HighlightStore(modelContext: context)

        // One highlight WITH a note, one without.
        let noted = try store.createHighlight(
            book: book, chapterIndex: 0, selection: "做减法"
        )
        try store.updateNote(noted, note: "减法是核心方法论")
        try store.createHighlight(book: book, chapterIndex: 0, selection: "简单是核心")

        let memory = ReaderMemory(modelContext: context)
        let first = try memory.syncFromReaderData()
        #expect(first == 1)

        // Second sync creates nothing new; note edits update in place.
        try store.updateNote(noted, note: "减法是唯一的方法论")
        let second = try memory.syncFromReaderData()
        #expect(second == 0)
        let items = try context.fetch(FetchDescriptor<MemoryItem>())
        #expect(items.count == 1)
        #expect(items[0].body.contains("唯一的方法论"))
        #expect(items[0].sourceLabel == "Walden · 第 1 章")

        _ = container
    }

    @Test func recallFindsLinkCardsAndMasterSwitchSilencesIt() throws {
        let (container, book) = try makeFixture()
        let context = container.mainContext
        let card = StudyCardEntry(
            question: "不争之争：道德经与马斯克传的呼应",
            answer: "两者都把退让看作竞争策略。",
            source: "道德经 ⟷ 马斯克传",
            kind: .link
        )
        card.book = book
        context.insert(card)
        try context.save()

        let memory = ReaderMemory(modelContext: context)
        try memory.syncFromReaderData()

        let hits = try memory.recall(query: "不争 竞争 策略")
        #expect(!hits.isEmpty)
        #expect(hits[0].kind == .thoughtLink)
        #expect(hits[0].sourceLabel == "道德经 ⟷ 马斯克传")

        // 总开关一关即失忆 — entries survive, recall goes blank.
        UserDefaults.standard.set(false, forKey: ReaderMemory.enabledKey)
        defer { UserDefaults.standard.removeObject(forKey: ReaderMemory.enabledKey) }
        #expect(try memory.recall(query: "不争 竞争 策略").isEmpty)
        #expect(try memory.recallObservation(query: "不争").contains("已关闭"))
        #expect(try context.fetch(FetchDescriptor<MemoryItem>()).count == 1)

        _ = container
    }

    @Test func proposeMemoryIsConfirmGated() async throws {
        let (container, book) = try makeFixture()
        let context = container.mainContext
        let toolbox = ReadingToolbox(
            book: book,
            position: ReadingPosition(chapterIndex: 1, utf16Offset: 0),
            modelContext: context,
            service: NullAIService()
        )

        let result = try await toolbox.run(
            "propose_memory", argument: "读者持续关注「减法」主题"
        )
        #expect(result.proposedAction != nil)
        #expect(try context.fetch(FetchDescriptor<MemoryItem>()).isEmpty)

        // Reader confirms → the theme lands, pre-confirmed.
        let outcome = try await toolbox.perform(result.proposedAction!)
        #expect(outcome.contains("已记入"))
        let items = try context.fetch(FetchDescriptor<MemoryItem>())
        #expect(items.count == 1)
        #expect(items[0].kind == .theme)
        #expect(items[0].isUserConfirmed)

        _ = container
    }

    @Test func recallReaderMemoryToolFlagsCitations() async throws {
        let (container, book) = try makeFixture()
        let context = container.mainContext
        let noted = try HighlightStore(modelContext: context).createHighlight(
            book: book, chapterIndex: 0, selection: "做减法"
        )
        try HighlightStore(modelContext: context).updateNote(noted, note: "减法主题")
        let toolbox = ReadingToolbox(
            book: book,
            position: ReadingPosition(chapterIndex: 1, utf16Offset: 0),
            modelContext: context,
            service: NullAIService()
        )

        let hit = try await toolbox.run("recall_reader_memory", argument: "减法")
        #expect(hit.citedMemory)
        #expect(hit.observation.contains("高亮批注"))

        // Cross-language query: no lexical overlap and a different
        // embedding model → deterministically no recall.
        let miss = try await toolbox.run("recall_reader_memory", argument: "quantum entanglement")
        #expect(!miss.citedMemory)

        _ = container
    }

    @Test func memoryIndexerPersistsEmbeddingsForConfirmedItems() throws {
        let (container, _) = try makeFixture()
        let context = container.mainContext
        let item = MemoryItem(
            kind: .companionQA,
            title: "How does subtraction clarify attention?",
            body: "By removing noise until the core idea stays visible.",
            sourceLabel: "Walden · Notes",
            isUserConfirmed: true
        )
        context.insert(item)
        try context.save()

        let processed = try MemoryIndexer(modelContext: context).indexAll()
        let embeddings = try context.fetch(FetchDescriptor<MemoryEmbedding>())
        let canEmbed = SemanticScorer.queryVector(
            for: MemoryEmbeddingIndex.memoryText(for: item)
        ) != nil

        if canEmbed {
            #expect(processed == 1)
            #expect(embeddings.count == 1)
            #expect(embeddings[0].itemID == item.id)
            #expect(embeddings[0].embeddingVector != nil)
        } else {
            #expect(processed == 0)
            #expect(embeddings.isEmpty)
        }

        _ = container

    }

    @Test func compressesOldQaIntoThemeAndSkipsQaRecall() throws {
        let (container, book) = try makeFixture()
        let context = container.mainContext

        let qa1 = StudyCardEntry(
            question: "减法如何帮助专注？",
            answer: "减掉干扰，核心更清楚。",
            source: "Walden · 第 1 章",
            kind: .qa
        )
        qa1.book = book
        let qa2 = StudyCardEntry(
            question: "为什么减法能看清重点？",
            answer: "因为先移走噪音，只留下本质。",
            source: "Walden · 第 1 章",
            kind: .qa
        )
        qa2.book = book
        context.insert(qa1)
        context.insert(qa2)
        try context.save()

        let memory = ReaderMemory(modelContext: context)
        try memory.syncFromReaderData()
        let result = try memory.compressCompanionQAIntoThemes()

        #expect(result.themesCreated == 1)
        #expect(result.questionsCompressed == 2)

        let items = try context.fetch(FetchDescriptor<MemoryItem>())
        let qaItems = items.filter { $0.kind == .companionQA }
        let themeItems = items.filter {
            $0.kind == .theme && $0.sourceRefKind == MemoryItem.qaCompressionSourceKind
        }
        #expect(qaItems.count == 2)
        #expect(qaItems.allSatisfy { $0.isCompressedCompanionQA })
        #expect(themeItems.count == 1)
        #expect(!themeItems[0].title.isEmpty)

        let qaHits = try memory.recall(query: "减法 重点", kinds: [.companionQA])
        let themeHits = try memory.recall(query: "减法 重点", kinds: [.theme])
        #expect(qaHits.isEmpty)
        #expect(themeHits.count == 1)

        _ = container
    }


    @Test func recallUsesPersistedMemoryEmbeddings() throws {
        guard let query = SemanticScorer.queryVector(for: "subtracting complexity from life") else {
            return
        }
        let (container, _) = try makeFixture()
        let context = container.mainContext
        let item = MemoryItem(
            kind: .theme,
            title: "Quiet discipline",
            body: "Silent practice under winter trees.",
            sourceLabel: "Walden",
            isUserConfirmed: true
        )
        context.insert(item)
        let embedding = MemoryEmbedding(
            itemID: item.id,
            sourceUpdatedAt: item.updatedAt,
            languageTag: query.languageTag
        )
        embedding.setEmbedding(vector: query.vector, languageTag: query.languageTag)
        context.insert(embedding)
        try context.save()

        let hits = try ReaderMemory(modelContext: context).recall(
            query: "subtracting complexity from life",
            kinds: [.theme],
            limit: 1
        )

        #expect(hits.first?.itemID == item.id)
        _ = container
    }
}

/// Inert service for toolbox tests that never reach the model.
private final class NullAIService: AIService, @unchecked Sendable {
    var availability: AIAvailability { .available }
    func summarize(_ text: String, focus: SummaryFocus) async throws -> String { "" }
    func answer(question: String, groundedIn: [GroundedPassage]) async throws -> GroundedAnswer {
        GroundedAnswer(text: "", citedPassageIDs: [])
    }
    func inlineNote(
        for text: String,
        kind: AIInlineNoteKind,
        targetLanguage: String
    ) async throws -> String { "" }
    func flashcards(from text: String, maxCount: Int) async throws -> [Flashcard] { [] }
    func toolStep(toolDocs: String, transcript: String) async throws -> AgentStep {
        .finish(answer: "")
    }
}
