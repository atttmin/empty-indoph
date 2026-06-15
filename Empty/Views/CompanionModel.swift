//
//  CompanionModel.swift
//  Empty
//
//  朱 · AI 伴读 conversation state, shared by the Mac side panel and the
//  iOS half-screen sheet: a chat over the book, grounded strictly in
//  already-read context.
//
//  Conversation state for one reader visit. Held above the panel/sheet so
//  closing and reopening keeps the thread.
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class CompanionModel {
    struct Message: Identifiable, Equatable {
        enum Role: Equatable {
            case user
            case ai
        }

        let id = UUID()
        var role: Role
        var text: String
        /// Citation chip, narrowed to the concrete hit when possible.
        var source: String?
        /// Short quoted line rendered above the answer body.
        var citation: String?
        /// Optional exact selection the reader is asking about right now.
        var focusText: String?
        /// The user question this AI answer responded to; enables 存为卡片.
        var question: String?
        /// How to read the answer: direct evidence or a synthesis over evidence.
        var analysisSummary: String?
        /// Evidence blocks worth showing under the answer.
        var evidenceBlocks: [CompanionEvidenceBlock] = []
        /// 朱批 agent trace ("查已读「…」 → 生成闪卡(待确认)").
        var steps: [String] = []
        /// Confirm-gated writes the agent proposed with this answer.
        var actions: [CompanionAction] = []
    }

    struct EvidenceSection: Identifiable, Equatable {
        var scope: CompanionEvidenceScope
        var title: String
        var blocks: [CompanionEvidenceBlock]

        var id: String {
            scope.rawValue
        }
    }

    var messages: [Message] = [
        Message(
            role: .ai,
            text: "我在。划到哪儿,问到哪儿 — 我只根据你已经读过的部分回答,不会剧透。"
        ),
    ]
    var thinking = false
    var draft = ""
    var draftFocusText: String?
    private var lastThemeProposalSignature: String?
    typealias ServiceResolution = (service: any AIService, provider: AIProvider, fellBack: Bool)
    private let resolveUsableService: @MainActor (AIFeature) -> ServiceResolution

    init(
        resolveUsableService: @escaping @MainActor (AIFeature) -> ServiceResolution = {
            AIProviderRegistry.load().resolveUsableService(feature: $0)
        }
    ) {
        self.resolveUsableService = resolveUsableService
    }

    var canProposeTheme: Bool {
        guard !thinking,
              let signature = Self.themeProposalSignature(from: messages) else { return false }
        return signature != lastThemeProposalSignature
    }

    /// Returns the imported file URL for a book, if known. Used to discover
    /// per-book instruction files (e.g. `CLAUDE.md`) in the book's container.
    private func bookFileURL(for book: Book) -> URL? {
        guard let relativePath = book.fileRelativePath else { return nil }
        return BookFileStore.default.url(forRelativePath: relativePath)
    }

    func send(
        book: Book,
        position: ReadingPosition,
        modelContext: ModelContext
    ) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !thinking else { return }
        let focusText = draftFocusText?.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        draftFocusText = nil
        messages.append(Message(role: .user, text: question))
        thinking = true

        Task {
            defer { thinking = false }
            do {
                let chunkCount = try BookIndexer(modelContext: modelContext)
                    .ensureChunks(for: book)
                guard chunkCount > 0 else {
                    messages.append(Message(
                        role: .ai,
                        text: "这本书没有可检索的文本,我帮不上忙。"
                    ))
                    return
                }
                guard try Self.hasReadableContext(
                    bookID: book.id,
                    position: position,
                    modelContext: modelContext
                ) else {
                    messages.append(Message(
                        role: .ai,
                        text: "答案池是你已经读过的部分 — 先往后读一点,再来问我。"
                    ))
                    return
                }

                let resolution = resolveUsableService(.chat)
                // 朱的回答 follows the目标语言 unless 作用范围 fixes it —
                // declared on the question itself so both the agent path
                // and the RAG fallback inherit it.
                let answerLanguage = LanguageSettings.promptName(
                    for: LanguageSettings.effective(for: book.id).resolvedChatTarget()
                )
                let directedQuestion = "\(question)\n\n(Respond in \(answerLanguage).)"
                let transcriptPrelude = try Self.transcriptPrelude(
                    for: book,
                    position: position,
                    focusText: focusText,
                    modelContext: modelContext
                )
                // Agent first: the model decides which reading tools to
                // use. Any failure falls back to plain grounded RAG so the
                // companion never dead-ends.
                do {
                    let toolbox = ReadingToolbox(
                        book: book,
                        position: position,
                        modelContext: modelContext,
                        service: resolution.service,
                        instructions: ReaderInstructionService().loadInstructions(
                            bookFileURL: bookFileURL(for: book)
                        )
                    )
                    let agent = ReadingAgent(
                        toolbox: toolbox,
                        service: resolution.service,
                        maxSteps: resolution.provider.isLocal ? 3 : 4
                    )
                    let reply = try await agent.run(
                        question: directedQuestion,
                        transcriptPrelude: transcriptPrelude
                    )
                    let fallbackSource = try? Self.contextLabel(for: book, position: position, modelContext: modelContext)
                    let source = Self.preferredSourceLabel(
                        from: reply.evidenceBlocks,
                        fallback: fallbackSource
                    )
                    let citation = Self.citationPreview(
                        from: reply.evidenceBlocks,
                        focusText: focusText
                    )
                    messages.append(Message(
                        role: .ai,
                        text: reply.text,
                        source: source,
                        citation: citation,
                        focusText: focusText,
                        question: question,
                        analysisSummary: Self.analysisSummary(
                            source: source,
                            steps: reply.steps,
                            evidenceBlocks: reply.evidenceBlocks
                        ),
                        evidenceBlocks: reply.evidenceBlocks,
                        steps: reply.steps,
                        actions: reply.actions
                    ))
                    await maybeAutoProposeTheme(for: book, service: resolution.service)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try await legacyAnswer(
                        question: question,
                        answerLanguage: answerLanguage,
                        book: book,
                        position: position,
                        focusText: focusText,
                        modelContext: modelContext,
                        service: resolution.service
                    )
                }
            } catch is CancellationError {
                // Panel torn down mid-flight.
            } catch {
                messages.append(Message(
                    role: .ai,
                    text: "出错了:\(error.localizedDescription)"
                ))
            }
        }
    }

    func proposeTheme(for book: Book) {
        guard canProposeTheme else { return }
        thinking = true

        Task {
            defer { thinking = false }
            do {
                let resolution = AIProviderRegistry.load().resolveUsableService(feature: .chat)
                let targetLanguage = LanguageSettings.promptName(
                    for: LanguageSettings.effective(for: book.id).resolvedChatTarget()
                )
                guard let proposal = try await Self.autoThemeDraft(
                    from: messages,
                    lastSignature: nil,
                    targetLanguage: targetLanguage,
                    service: resolution.service
                ) else {
                    messages.append(Message(
                        role: .ai,
                        text: "至少要有两轮有效追问,我才能替你提炼一个长期主题。"
                    ))
                    return
                }
                appendThemeProposal(
                    signature: proposal.signature,
                    draft: proposal.draft,
                    automatic: false
                )
            } catch {
                messages.append(Message(
                    role: .ai,
                    text: "这轮主题还没提炼出来:\(error.localizedDescription)"
                ))
            }
        }
    }

    private func maybeAutoProposeTheme(
        for book: Book,
        service: any AIService
    ) async {
        let targetLanguage = LanguageSettings.promptName(
            for: LanguageSettings.effective(for: book.id).resolvedChatTarget()
        )
        guard let proposal = try? await Self.autoThemeDraft(
            from: messages,
            lastSignature: lastThemeProposalSignature,
            targetLanguage: targetLanguage,
            service: service
        ) else { return }
        appendThemeProposal(
            signature: proposal.signature,
            draft: proposal.draft,
            automatic: true
        )
    }

    private func appendThemeProposal(
        signature: String,
        draft: (title: String, body: String, tags: [String]),
        automatic: Bool
    ) {
        lastThemeProposalSignature = signature
        let messageText = automatic
            ? "我顺手把这轮反复出现的问题提成了一个长期主题。想让它进入读者记忆,就点一下确认。\n\n\(draft.body)"
            : draft.body
        messages.append(Message(
            role: .ai,
            text: messageText,
            steps: ["聚合本轮问答", "提炼主题(待确认)"],
            actions: [
                CompanionAction(
                    title: "记住主题「\(draft.title)」",
                    kind: .saveMemory(
                        title: draft.title,
                        body: draft.body,
                        tags: draft.tags
                    )
                ),
            ]
        ))
    }

    static func hasReadableContext(
        bookID: UUID,
        position: ReadingPosition,
        modelContext: ModelContext
    ) throws -> Bool {
        let readText = try Chapter.fullyReadText(
            forBookID: bookID,
            before: position,
            in: modelContext
        )
        return !readText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func followUpQuestion(about text: String, maxCharacters: Int = 240) -> String {
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return "关于这段原文" }
        if normalized.count <= maxCharacters {
            return "关于这段原文：「\(normalized)」"
        }
        return "关于这段原文：「\(String(normalized.prefix(maxCharacters)))…」"
    }

    static func transcriptPrelude(
        for book: Book,
        position: ReadingPosition,
        focusText: String? = nil,
        modelContext: ModelContext
    ) throws -> String? {
        guard let excerpt = try Chapter.recentContextExcerpt(
            forBookID: book.id,
            before: position,
            maxCharacters: 900,
            in: modelContext
        ) else { return nil }
        let heading = try Chapter.chapterHeading(
            forBookID: book.id,
            chapterIndex: position.chapterIndex,
            in: modelContext
        )
        let focusBlock = focusText.map { "读者此刻想追问的原文:\n\($0)\n\n" } ?? ""
        return """
        当前书: 《\(book.title)》
        当前读到: \(heading)
        \(focusBlock)刚读过的上下文（只到当前进度）:
        \(excerpt)
        """
    }

    static func themeProposalSignature(
        from messages: [Message],
        limit: Int = 4
    ) -> String? {
        let ids = themePassages(from: messages, limit: limit).map(\.id.description)
        guard ids.count >= 2 else { return nil }
        return ids.joined(separator: "|")
    }

    static func themePassages(
        from messages: [Message],
        limit: Int = 4
    ) -> [GroundedPassage] {
        messages
            .filter { $0.role == .ai && $0.question != nil }
            .suffix(limit)
            .enumerated()
            .map { index, message in
                GroundedPassage(
                    id: index,
                    text: "Q: \(message.question ?? "")\nA: \(message.text)"
                )
            }
    }

    static func makeThemeDraft(
        from messages: [Message],
        targetLanguage: String,
        service: any AIService
    ) async throws -> (title: String, body: String, tags: [String])? {
        let passages = themePassages(from: messages)
        guard passages.count >= 2 else { return nil }
        let answer = try await service.answer(
            question: """
            Synthesize one durable reader-memory theme from these companion Q&A turns.
            Respond in \(targetLanguage) using exactly three lines:
            Title: <2-8 words or 2-10 characters>
            Summary: <1-2 sentences on the recurring concern or obsession>
            Tags: <up to 3 short tags, comma-separated; write none if empty>
            """,
            groundedIn: passages
        )
        return parseThemeDraft(answer.text)
    }

    static func autoThemeDraft(
        from messages: [Message],
        lastSignature: String?,
        targetLanguage: String,
        service: any AIService
    ) async throws -> (signature: String, draft: (title: String, body: String, tags: [String]))? {
        guard let signature = themeProposalSignature(from: messages),
              signature != lastSignature,
              let draft = try await makeThemeDraft(
                  from: messages,
                  targetLanguage: targetLanguage,
                  service: service
              ) else { return nil }
        return (signature, draft)
    }

    static func parseThemeDraft(_ text: String) -> (title: String, body: String, tags: [String]) {
        var title: String?
        var body: String?
        var tags: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Title:") {
                title = String(line.dropFirst("Title:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Summary:") {
                body = String(line.dropFirst("Summary:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Tags:") {
                let rawTags = String(line.dropFirst("Tags:".count)).trimmingCharacters(in: .whitespaces)
                if rawTags.lowercased() != "none" {
                    tags = rawTags
                        .split(whereSeparator: { [",", "，", "、"].contains($0) })
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
            }
        }

        let resolvedTitle = title?.isEmpty == false ? title! : "本轮反复追问的主题"
        let resolvedBody = body?.isEmpty == false ? body! : text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (resolvedTitle, resolvedBody, Array(tags.prefix(3)))
    }

    /// The pre-agent pipeline: spoiler-safe retrieval + one grounded answer.
    /// `answerLanguage` rides only on the model question — the retrieval
    /// query and the saved-card question stay clean.
    private func legacyAnswer(
        question: String,
        answerLanguage: String? = nil,
        book: Book,
        position: ReadingPosition,
        focusText: String? = nil,
        modelContext: ModelContext,
        service: any AIService
    ) async throws {
        let chunks = try ChunkRetriever(modelContext: modelContext).retrieve(
            question: question,
            bookID: book.id,
            position: position
        )
        guard !chunks.isEmpty else {
            messages.append(Message(
                role: .ai,
                text: "在你读过的部分里没找到相关内容。换个问法试试?"
            ))
            return
        }
        let passages = chunks.map { GroundedPassage(id: $0.ordinal, text: $0.text) }
        let answer = try await service.answer(
            question: answerLanguage.map { "\(question)\n\n(Respond in \($0).)" } ?? question,
            groundedIn: passages
        )
        let citedChunk = answer.citedPassageIDs
            .compactMap { id in chunks.first { $0.ordinal == id } }
            .first ?? chunks.first
        let sourceLabel = if let citedChunk {
            Self.sourceLabel(for: citedChunk, bookTitle: book.title)
        } else {
            try? Self.contextLabel(for: book, position: position, modelContext: modelContext)
        }
        let evidenceBlocks = Self.passageEvidenceBlocks(
            from: chunks,
            bookTitle: book.title,
            emphasisTerms: Self.queryTerms(for: question)
        )
        messages.append(Message(
            role: .ai,
            text: answer.text,
            source: sourceLabel,
            citation: Self.citationPreview(from: evidenceBlocks, focusText: focusText),
            focusText: focusText,
            question: question,
            analysisSummary: Self.analysisSummary(source: sourceLabel, steps: [], evidenceBlocks: evidenceBlocks),
            evidenceBlocks: evidenceBlocks
        ))
        await maybeAutoProposeTheme(for: book, service: service)
    }

    /// Executes one reader-confirmed agent action and marks it done on the
    /// message, appending the outcome to the conversation.
    func perform(
        actionID: UUID,
        messageID: UUID,
        book: Book,
        position: ReadingPosition,
        modelContext: ModelContext
    ) {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              let actionIndex = messages[messageIndex].actions
              .firstIndex(where: { $0.id == actionID }),
              !messages[messageIndex].actions[actionIndex].isDone
        else { return }
        let action = messages[messageIndex].actions[actionIndex]

        Task {
            do {
                let resolution = resolveUsableService(.chat)
                let toolbox = ReadingToolbox(
                    book: book,
                    position: position,
                    modelContext: modelContext,
                    service: resolution.service,
                    instructions: ReaderInstructionService().loadInstructions(
                        bookFileURL: bookFileURL(for: book)
                    )
                )
                let outcome = try await toolbox.perform(action)
                if let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
                   let actionIndex = messages[messageIndex].actions
                   .firstIndex(where: { $0.id == actionID })
                {
                    messages[messageIndex].actions[actionIndex].isDone = true
                }
                messages.append(Message(role: .ai, text: "✓ \(outcome)"))
            } catch {
                messages.append(Message(
                    role: .ai,
                    text: "这一步没做成:\(error.localizedDescription)"
                ))
            }
        }
    }

    private static func sourceTitle(for chunk: Chunk) -> String {
        if let title = chunk.chapter?.title, !title.isEmpty {
            return title
        }
        return "第 \(chunk.chapterIndex + 1) 章"
    }

    private static func sourceLabel(for chunk: Chunk, bookTitle: String) -> String {
        "《\(bookTitle)》 · \(sourceTitle(for: chunk)) · ¶\(chunk.ordinal + 1)"
    }

    static func analysisSummary(
        source: String?,
        steps: [String],
        evidenceBlocks: [CompanionEvidenceBlock]
    ) -> String? {
        if steps.contains("⚲ 引用了记忆") {
            return "朱批推断 · 基于本书证据并引用过记忆"
        }
        let currentBook = evidenceBlocks.filter { $0.scope == .currentBook }
        let crossBook = evidenceBlocks.filter { $0.scope == .crossBook }
        if !currentBook.isEmpty,
           crossBook.isEmpty,
           currentBook.allSatisfy({ $0.kind == .passage })
        {
            return "直接证据 · 当前段落"
        }
        if !crossBook.isEmpty {
            return "朱批推断 · 结合本书证据与跨书回声"
        }
        if !currentBook.isEmpty {
            return "朱批推断 · 基于本书证据"
        }
        if source != nil {
            return "直接证据 · 已读原文"
        }
        return nil
    }

    static func passageEvidenceBlocks(
        from chunks: [Chunk],
        bookTitle: String,
        emphasisTerms: [String] = []
    ) -> [CompanionEvidenceBlock] {
        chunks.prefix(2).map { chunk in
            CompanionEvidenceBlock(
                kind: .passage,
                title: sourceLabel(for: chunk, bookTitle: bookTitle),
                body: String(chunk.text.prefix(320)),
                emphasisTerms: emphasisTerms
            )
        }
    }

    static func preferredSourceLabel(
        from blocks: [CompanionEvidenceBlock],
        fallback: String?
    ) -> String? {
        blocks.first(where: { $0.scope == .currentBook })?.title ?? fallback
    }

    static func citationPreview(
        from blocks: [CompanionEvidenceBlock],
        focusText: String? = nil
    ) -> String? {
        if let focusText {
            let trimmed = focusText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(88))
            }
        }
        guard let block = blocks.first(where: { $0.scope == .currentBook }) ?? blocks.first else {
            return nil
        }
        let raw = citationBody(for: block)
        guard !raw.isEmpty else { return nil }
        return excerptPreview(from: raw, matching: block.emphasisTerms, limit: 88)
    }

    static func evidenceSections(from blocks: [CompanionEvidenceBlock]) -> [EvidenceSection] {
        let currentBook = blocks.filter { $0.scope == .currentBook }
        let crossBook = blocks.filter { $0.scope == .crossBook }
        var sections = [EvidenceSection]()
        if !currentBook.isEmpty {
            sections.append(EvidenceSection(
                scope: .currentBook,
                title: evidenceSectionTitle(for: .currentBook, blocks: currentBook),
                blocks: currentBook
            ))
        }
        if !crossBook.isEmpty {
            sections.append(EvidenceSection(
                scope: .crossBook,
                title: evidenceSectionTitle(for: .crossBook, blocks: crossBook),
                blocks: crossBook
            ))
        }
        return sections
    }

    static func emphasisRanges(
        in text: String,
        matching rawTerms: [String]
    ) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }
        let terms = rawTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        guard !terms.isEmpty else { return [] }
        var ranges = [Range<String.Index>]()
        for term in terms {
            var cursor = text.startIndex
            while cursor < text.endIndex,
                  let range = text.range(
                      of: term,
                      options: [.caseInsensitive, .diacriticInsensitive],
                      range: cursor ..< text.endIndex,
                      locale: .current
                  )
            {
                ranges.append(range)
                cursor = range.upperBound
            }
        }
        guard let first = ranges.sorted(by: { $0.lowerBound < $1.lowerBound }).first else { return [] }
        var merged = [first]
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }).dropFirst() {
            let lastIndex = merged.index(before: merged.endIndex)
            if range.lowerBound <= merged[lastIndex].upperBound {
                merged[lastIndex] = merged[lastIndex].lowerBound ..< max(merged[lastIndex].upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    static func queryTerms(for query: String) -> [String] {
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

    private static func citationBody(for block: CompanionEvidenceBlock) -> String {
        if let quoted = quotedSource(in: block.body) {
            return quoted
        }
        if let range = block.body.range(of: "原文: ") {
            return String(block.body[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = block.body.range(of: "记忆: ") {
            return String(block.body[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return block.body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func quotedSource(in text: String) -> String? {
        guard let start = text.range(of: "「"),
              let end = text.range(of: "」", range: start.upperBound ..< text.endIndex)
        else {
            return nil
        }
        return String(text[start.upperBound ..< end.lowerBound])
    }

    private static func excerptPreview(
        from text: String,
        matching terms: [String],
        limit: Int
    ) -> String {
        let trimmed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        for term in terms {
            guard let range = trimmed.range(
                of: term,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) else { continue }
            let utf16 = Array(trimmed.utf16)
            let lower = max(0, range.lowerBound.utf16Offset(in: trimmed) - 28)
            let upper = min(utf16.count, range.upperBound.utf16Offset(in: trimmed) + 44)
            let snippet = String(decoding: utf16[lower ..< upper], as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = lower > 0 ? "…" : ""
            let suffix = upper < utf16.count ? "…" : ""
            return prefix + snippet + suffix
        }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    private static func evidenceSectionTitle(
        for scope: CompanionEvidenceScope,
        blocks: [CompanionEvidenceBlock]
    ) -> String {
        switch scope {
        case .currentBook:
            return blocks.allSatisfy { $0.kind == .passage }
                ? "当前已读原文"
                : "本书证据"
        case .crossBook:
            return "跨书回声"
        }
    }

    private static func contextLabel(
        for book: Book,
        position: ReadingPosition,
        modelContext: ModelContext
    ) throws -> String {
        let heading = try Chapter.chapterHeading(
            forBookID: book.id,
            chapterIndex: position.chapterIndex,
            in: modelContext
        )
        return "《\(book.title)》 · \(heading)"
    }
}
