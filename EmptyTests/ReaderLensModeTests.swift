//
//  ReaderLensModeTests.swift
//  EmptyTests
//

import Testing
@testable import Empty

struct ReaderLensModeTests {
    @Test func bilingualLensKeepsTitleCachingAndQualityGate() {
        let lens = ReaderLensMode.bilingual

        #expect(lens.translationKind == .bilingual)
        #expect(lens.aiNoteKind == .bilingual)
        #expect(lens.inlineNoteKind == .bilingual)
        #expect(lens.guideLoadingText == "生成双语对照…")
        #expect(lens.guideTitle == "今译")
        #expect(lens.pretranslatesTitles)
        #expect(lens.skipsTargetLanguageParagraphs)
        #expect(!lens.shouldStore(note: "原文即白话", original: "原文即白话"))
    }

    @Test func companionLensesUseOwnGuideAndCacheRules() {
        let companion = ReaderLensMode.companion
        let debate = ReaderLensMode.debate
        let sources = ReaderLensMode.sources

        #expect(companion.guideLoadingText == "生成导读…")
        #expect(companion.guideTitle == "导读")
        #expect(!companion.pretranslatesTitles)
        #expect(!companion.skipsTargetLanguageParagraphs)
        #expect(companion.shouldStore(note: "指出这一段在铺垫。", original: "原文"))

        #expect(debate.translationKind == .debate)
        #expect(debate.aiNoteKind == .debate)
        #expect(debate.guideTitle == "辩难")

        #expect(sources.translationKind == .sources)
        #expect(sources.aiNoteKind == .sources)
        #expect(sources.guideTitle == "文献")
    }

#if os(macOS)
    @Test func macReadingModesMapToSharedLenses() {
        #expect(MacReadingMode.original.lensMode == nil)
        #expect(MacReadingMode.bilingual.lensMode == .bilingual)
        #expect(MacReadingMode.companion.lensMode == .companion)
        #expect(MacReadingMode.debate.lensMode == .debate)
        #expect(MacReadingMode.sources.lensMode == .sources)
    }
#endif
}
