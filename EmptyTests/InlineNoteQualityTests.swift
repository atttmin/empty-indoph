//
//  InlineNoteQualityTests.swift
//  EmptyTests
//
//  The lens quality gate: same-language echo "translations" and the
//  今译 sentinel never paint — a Chinese book must not show its own
//  text duplicated as a translation.
//

import Testing
@testable import Empty

struct InlineNoteQualityTests {
    @Test func realTranslationsPass() {
        #expect(InlineNoteQuality.isWorthShowing(
            note: "我走进森林，因为我想有意识地生活。",
            original: "I went to the woods because I wished to live deliberately."
        ))
        // 文言今译: meaningfully different rendering of the same idea.
        #expect(InlineNoteQuality.isWorthShowing(
            note: "最高的善像水一样，滋养万物而不与万物相争。",
            original: "上善若水。水善利万物而不争。"
        ))
    }

    @Test func echoesAndSentinelAreSuppressed() {
        // Verbatim echo.
        #expect(!InlineNoteQuality.isWorthShowing(
            note: "深读始于空白。导入一本书，朱批落在页边。",
            original: "深读始于空白。导入一本书，朱批落在页边。"
        ))
        // Punctuation/whitespace-only variation.
        #expect(!InlineNoteQuality.isWorthShowing(
            note: "深读始于空白——导入一本书,朱批落在页边",
            original: "深读始于空白。导入一本书，朱批落在页边。"
        ))
        // The 今译 nothing-to-translate sentinel.
        #expect(!InlineNoteQuality.isWorthShowing(
            note: "「原文即白话」",
            original: "读书不是把字看完。"
        ))
        // Empty.
        #expect(!InlineNoteQuality.isWorthShowing(note: "  ", original: "原文"))
    }

    @Test func marginNotesAboutTheTextPass() {
        // A 导读 margin note shares some characters with the original but
        // is a different register — must not be flagged as an echo.
        #expect(InlineNoteQuality.isWorthShowing(
            note: "立论段：作者把「空白」当作方法而非缺失，值得停一停。",
            original: "深读始于空白。导入一本书，朱批落在页边。"
        ))
    }
}
