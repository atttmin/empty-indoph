//
//  LanguageSettings.swift
//  Empty
//
//  语言设置 per the design prototype: a global target language that
//  译文/释义/朱回答 all follow, a source language that defaults to
//  per-paragraph auto-detection (mixed-language quotes each translate
//  correctly), an always-on same-language skip, and per-book overrides
//  (a French textbook can run 法→英 while the global target stays 中文).
//

import Foundation
import NaturalLanguage

nonisolated struct LanguageSettings: Codable, Equatable, Sendable {
    enum Source: Codable, Equatable, Sendable {
        /// Per-paragraph detection (推荐) — mixed-language quotes work.
        case auto
        /// The whole book treated as one language (BCP-47-ish id).
        case manual(String)
    }

    /// BCP-47 target for translations; 释义/朱回答 follow unless fixed.
    var target: String = "zh-Hans"
    var source: Source = .auto
    /// Per-feature fixes; nil = 跟随目标.
    var vocabTarget: String?
    var chatTarget: String?

    /// The picker's offer, in design order.
    static let targetOptions: [(id: String, native: String)] = [
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("en", "English"),
        ("ja", "日本語"),
    ]

    static let sourceOptions: [(id: String, label: String)] = [
        ("en", "英文"), ("zh", "中文"), ("ja", "日文"),
        ("fr", "法文"), ("de", "德文"), ("es", "西文"),
    ]

    static func displayName(for id: String) -> String {
        targetOptions.first { $0.id == id }?.native
            ?? sourceOptions.first { $0.id == id }?.label
            ?? id
    }

    /// English name the prompts use.
    static func promptName(for id: String) -> String {
        switch id {
        case "zh-Hans": "Simplified Chinese"
        case "zh-Hant": "Traditional Chinese"
        case "en": "English"
        case "ja": "Japanese"
        case "fr": "French"
        case "de": "German"
        case "es": "Spanish"
        default: id
        }
    }

    func resolvedVocabTarget() -> String { vocabTarget ?? target }
    func resolvedChatTarget() -> String { chatTarget ?? target }

    // MARK: Persistence

    private static let storageKey = "lang.settings.v1"
    private static let bookOverridesKey = "lang.book.overrides.v1"

    static func load(defaults: UserDefaults = .standard) -> LanguageSettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(LanguageSettings.self, from: data)
        else { return LanguageSettings() }
        return settings
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// 本书覆盖 (Aa 面板底部): per-book target/source, remembered on the
    /// book dimension.
    struct BookOverride: Codable, Equatable, Sendable {
        var target: String?
        var source: Source?
    }

    static func bookOverride(
        for bookID: UUID,
        defaults: UserDefaults = .standard
    ) -> BookOverride? {
        guard let data = defaults.data(forKey: bookOverridesKey),
              let all = try? JSONDecoder().decode([String: BookOverride].self, from: data)
        else { return nil }
        return all[bookID.uuidString]
    }

    static func setBookOverride(
        _ override: BookOverride?,
        for bookID: UUID,
        defaults: UserDefaults = .standard
    ) {
        var all = (defaults.data(forKey: bookOverridesKey))
            .flatMap { try? JSONDecoder().decode([String: BookOverride].self, from: $0) }
            ?? [:]
        if let override, override != BookOverride() {
            all[bookID.uuidString] = override
        } else {
            all.removeValue(forKey: bookID.uuidString)
        }
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: bookOverridesKey)
        }
    }

    /// Global settings with the book's override applied.
    static func effective(
        for bookID: UUID,
        defaults: UserDefaults = .standard
    ) -> LanguageSettings {
        var settings = load(defaults: defaults)
        if let override = bookOverride(for: bookID, defaults: defaults) {
            if let target = override.target { settings.target = target }
            if let source = override.source { settings.source = source }
        }
        return settings
    }
}

/// Per-paragraph language detection (NLLanguageRecognizer — local, free).
nonisolated enum LanguageDetect {
    /// Dominant language id of a paragraph ("en", "zh", "fr", …), nil
    /// when the recognizer can't tell (very short fragments).
    static func dominant(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return nil }
        guard let language = NLLanguageRecognizer.dominantLanguage(for: trimmed) else {
            return nil
        }
        let raw = language.rawValue
        // Collapse script variants to the family used for skip decisions.
        if raw.hasPrefix("zh") { return "zh" }
        return String(raw.prefix(2))
    }

    /// 同语言跳过 (always on): a paragraph already in the target language
    /// gets no translation block.
    static func matchesTarget(textLanguage: String?, target: String) -> Bool {
        guard let textLanguage else { return false }
        if target.hasPrefix("zh") { return textLanguage == "zh" }
        return textLanguage == String(target.prefix(2))
    }

    /// The language to declare as源 for a paragraph under the settings:
    /// manual wins; otherwise per-paragraph detection.
    static func sourceLanguage(
        of text: String,
        settings: LanguageSettings
    ) -> String? {
        switch settings.source {
        case .manual(let language): return language
        case .auto: return dominant(text)
        }
    }
}
