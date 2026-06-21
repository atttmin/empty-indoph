//
//  VocabStore.swift
//  Empty
//

import Foundation
import SwiftData

/// Creates and looks up vocabulary entries from reader selections.
@MainActor
struct VocabStore {
    let modelContext: ModelContext

    func entries(for word: String) throws -> [VocabEntry] {
        let needle = word.lowercased()
        return try modelContext.fetch(FetchDescriptor<VocabEntry>())
            .filter { $0.word.lowercased() == needle }
    }

    func add(
        word: String,
        meaning: String,
        phonetic: String? = nil,
        partOfSpeech: String? = nil,
        note: String? = nil,
        sentence: String? = nil,
        source: String? = nil,
        book: Book? = nil,
        sourcePosition: ReadingPosition? = nil
    ) throws -> VocabEntry {
        if let existing = try entries(for: word).first {
            if !meaning.isEmpty { existing.meaning = meaning }
            if let phonetic { existing.phonetic = phonetic }
            if let partOfSpeech { existing.partOfSpeech = partOfSpeech }
            if let note { existing.note = note }
            if let sentence { existing.sentence = sentence }
            if let source { existing.source = source }
            if let book { existing.book = book }
            if let sourcePosition { existing.setSourcePosition(sourcePosition) }
            try modelContext.save()
            return existing
        }

        let entry = VocabEntry(
            word: word,
            meaning: meaning,
            phonetic: phonetic,
            partOfSpeech: partOfSpeech,
            note: note,
            sentence: sentence,
            source: source
        )
        entry.book = book
        entry.setSourcePosition(sourcePosition)
        modelContext.insert(entry)
        try modelContext.save()
        return entry
    }

    /// Uses the active AI provider to gloss a word in its sentence context.
    func lookupWithAI(
        word: String,
        sentence: String,
        source: String,
        book: Book? = nil,
        sourcePosition: ReadingPosition? = nil
    ) async throws -> VocabEntry {
        let resolution = AIProviderRegistry.load().resolveUsableService(feature: .vocab)
        let service = resolution.service
        // 释义 follows the global目标语言 unless 作用范围 fixes it.
        let glossLanguage = LanguageSettings.promptName(
            for: LanguageSettings.load().resolvedVocabTarget()
        )
        let question = """
        Explain the word "\(word)" as used in the sentence below. Reply in \(glossLanguage) \
        with four short lines:
        PHONETIC: IPA pronunciation
        POS: part of speech (e.g. n., v., adj.)
        MEANING: concise \(glossLanguage) gloss for this context
        NOTE: one sentence of nuance (what it does NOT mean here, or a cross-book echo)
        """
        let answer = try await service.answer(
            question: question,
            groundedIn: [GroundedPassage(id: 0, text: sentence)]
        )
        let parsed = Self.parseGloss(answer.text)
        return try add(
            word: word,
            meaning: parsed.meaning,
            phonetic: parsed.phonetic,
            partOfSpeech: parsed.partOfSpeech,
            note: parsed.note,
            sentence: sentence,
            source: source,
            book: book,
            sourcePosition: sourcePosition
        )
    }

    private struct ParsedGloss {
        var phonetic: String?
        var partOfSpeech: String?
        var meaning: String
        var note: String?
    }

    private static func parseGloss(_ text: String) -> ParsedGloss {
        var phonetic: String?
        var partOfSpeech: String?
        var meaning = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var note: String?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("PHONETIC:") {
                phonetic = trimmed.dropFirst("PHONETIC:".count)
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.uppercased().hasPrefix("POS:") {
                partOfSpeech = trimmed.dropFirst("POS:".count)
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.uppercased().hasPrefix("MEANING:") {
                meaning = trimmed.dropFirst("MEANING:".count)
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.uppercased().hasPrefix("NOTE:") {
                note = trimmed.dropFirst("NOTE:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return ParsedGloss(
            phonetic: phonetic,
            partOfSpeech: partOfSpeech,
            meaning: meaning,
            note: note
        )
    }
}