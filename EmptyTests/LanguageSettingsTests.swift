//
//  LanguageSettingsTests.swift
//  EmptyTests
//
//  语言设置: global target + per-book override resolution, the
//  per-paragraph 同语言跳过 detection, target-separated translation
//  caches, and the language-parametric prompts.
//

import Foundation
import SwiftData
import Testing
@testable import Empty

struct LanguageSettingsTests {
    /// Isolated defaults so tests never touch (or see) the user's settings.
    private func makeDefaults() -> UserDefaults {
        let name = "LanguageSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func persistsAndLoadsRoundTrip() {
        let defaults = makeDefaults()
        var settings = LanguageSettings()
        settings.target = "en"
        settings.source = .manual("fr")
        settings.vocabTarget = "zh-Hans"
        settings.save(defaults: defaults)

        let loaded = LanguageSettings.load(defaults: defaults)
        #expect(loaded == settings)
        #expect(loaded.resolvedVocabTarget() == "zh-Hans")
        // chatTarget nil = 跟随目标.
        #expect(loaded.resolvedChatTarget() == "en")
    }

    @Test func bookOverrideWinsAndClearsBackToGlobal() {
        let defaults = makeDefaults()
        var global = LanguageSettings()
        global.target = "zh-Hans"
        global.save(defaults: defaults)
        let bookID = UUID()

        // No override → global.
        #expect(LanguageSettings.effective(for: bookID, defaults: defaults).target == "zh-Hans")

        // 法语教材跑 法→英, 全局目标不动.
        LanguageSettings.setBookOverride(
            .init(target: "en", source: .manual("fr")),
            for: bookID, defaults: defaults
        )
        let effective = LanguageSettings.effective(for: bookID, defaults: defaults)
        #expect(effective.target == "en")
        #expect(effective.source == .manual("fr"))
        #expect(LanguageSettings.load(defaults: defaults).target == "zh-Hans")
        // Other books are untouched.
        #expect(LanguageSettings.effective(for: UUID(), defaults: defaults).target == "zh-Hans")

        // Clearing an override (all-nil) removes the entry.
        LanguageSettings.setBookOverride(nil, for: bookID, defaults: defaults)
        #expect(LanguageSettings.effective(for: bookID, defaults: defaults).target == "zh-Hans")
        #expect(LanguageSettings.bookOverride(for: bookID, defaults: defaults) == nil)
    }

    @Test func sameLanguageSkipMatchesScriptFamilies() {
        // zh-family: 简/繁 targets both treat Chinese text as "already there".
        #expect(LanguageDetect.matchesTarget(textLanguage: "zh", target: "zh-Hans"))
        #expect(LanguageDetect.matchesTarget(textLanguage: "zh", target: "zh-Hant"))
        #expect(!LanguageDetect.matchesTarget(textLanguage: "en", target: "zh-Hans"))
        #expect(LanguageDetect.matchesTarget(textLanguage: "en", target: "en"))
        #expect(!LanguageDetect.matchesTarget(textLanguage: "ja", target: "en"))
        // Undetectable (very short) paragraphs never skip — translating
        // is the safe default.
        #expect(!LanguageDetect.matchesTarget(textLanguage: nil, target: "zh-Hans"))
    }

    @Test func detectionIsPerParagraphAndManualWins() {
        let english = "I went to the woods because I wished to live deliberately."
        let chinese = "我到林中去，因为我希望活得从容笃定，只面对生活的本质。"
        #expect(LanguageDetect.dominant(english) == "en")
        #expect(LanguageDetect.dominant(chinese) == "zh")
        #expect(LanguageDetect.dominant("Hi") == nil)

        var settings = LanguageSettings()
        settings.source = .manual("fr")
        // Manual declares the whole book; detection is bypassed.
        #expect(LanguageDetect.sourceLanguage(of: english, settings: settings) == "fr")
        settings.source = .auto
        #expect(LanguageDetect.sourceLanguage(of: english, settings: settings) == "en")
    }

    @Test @MainActor func translationCacheSeparatesTargets() throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let store = TranslationStore(modelContext: container.mainContext)
        let bookID = UUID()
        let paragraph = "Simplicity, simplicity, simplicity! Let your affairs be as two or three."

        store.store(
            "简单，简单，再简单！", bookID: bookID, chapterIndex: 0,
            kind: .bilingual, text: paragraph, target: "zh-Hans"
        )
        // Same paragraph, different目标语言 → separate cache rows.
        #expect(store.lookup(bookID: bookID, kind: .bilingual, text: paragraph, target: "ja") == nil)
        store.store(
            "簡素に、簡素に、簡素に！", bookID: bookID, chapterIndex: 0,
            kind: .bilingual, text: paragraph, target: "ja"
        )
        #expect(
            store.lookup(bookID: bookID, kind: .bilingual, text: paragraph, target: "zh-Hans")
                == "简单，简单，再简单！"
        )
        #expect(
            store.lookup(bookID: bookID, kind: .bilingual, text: paragraph, target: "ja")
                == "簡素に、簡素に、簡素に！"
        )
        // Default-target callers keep hitting the legacy 简中 rows.
        #expect(store.lookup(bookID: bookID, kind: .bilingual, text: paragraph) != nil)
        _ = container
    }

    @Test func promptsCarryTheTargetLanguageName() {
        let japanese = AIInlineNotePrompt.user(
            kind: .bilingual, text: "Some paragraph.", targetLanguage: "ja"
        )
        #expect(japanese.contains("Japanese"))
        #expect(!japanese.contains("Simplified Chinese"))

        // Default stays the pre-语言设置 behavior.
        let unspecified = AIInlineNotePrompt.user(kind: .companion, text: "段落")
        #expect(unspecified.contains("Simplified Chinese"))
        #expect(LanguageSettings.promptName(for: "zh-Hant") == "Traditional Chinese")
    }
}
