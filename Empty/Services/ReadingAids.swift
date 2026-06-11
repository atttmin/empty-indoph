//
//  ReadingAids.swift
//  Empty
//
//  Pure helpers behind the 01 Mac prototype's reading aids: the
//  three-part chapter overview, vocabulary cloze sentences, reading-time
//  estimates, and the review-queue forecast. Platform-neutral and
//  side-effect free so they unit-test directly.
//

import Foundation

// MARK: - Chapter outline (章节概览)

/// The structured "读前 30 秒" chapter overview: three numbered parts,
/// each a short title plus one sentence.
nonisolated struct ChapterOutline: Equatable, Sendable {
    struct Part: Equatable, Sendable {
        var title: String
        var detail: String
    }

    var parts: [Part]

    /// Prompt the reader-facing pipeline sends alongside a chapter excerpt.
    static let prompt = """
    Outline this chapter excerpt as exactly three sequential parts \
    (beginning, middle, end). Reply in Chinese, one part per line, \
    each line formatted as 标题|一句话内容, nothing else.
    """

    /// Parses model output in the `标题|一句话` line format (tolerates
    /// ①/1./- prefixes). Returns nil unless exactly three clean parts
    /// emerge — callers fall back to the flat summary.
    static func parse(_ text: String) -> ChapterOutline? {
        let parts: [Part] = text
            .components(separatedBy: .newlines)
            .compactMap { line in
                let pieces = line.components(separatedBy: "|")
                guard pieces.count >= 2 else { return nil }
                var title = pieces[0].trimmingCharacters(in: .whitespaces)
                let detail = pieces.dropFirst()
                    .joined(separator: "|")
                    .trimmingCharacters(in: .whitespaces)
                // Strip list ornaments the model may add despite the format.
                while let first = title.first,
                      first.isNumber || "①②③④⑤.、-—*# ".contains(first) {
                    title.removeFirst()
                }
                title = title.trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty, !detail.isEmpty else { return nil }
                return Part(title: title, detail: detail)
            }
        guard parts.count >= 3 else { return nil }
        return ChapterOutline(parts: Array(parts.prefix(3)))
    }

    /// Serializes back to the line format for `Chapter.cachedOutline`.
    var serialized: String {
        parts.map { "\($0.title)|\($0.detail)" }.joined(separator: "\n")
    }

    /// Which of the three parts a 0…1 intra-chapter fraction falls in.
    static func partIndex(forProgress fraction: Double) -> Int {
        min(max(Int(fraction * 3), 0), 2)
    }
}

// MARK: - Reading time (本章约 X 分钟 / 剩余约 X 小时)

nonisolated enum ReadingTimeEstimate {
    /// Reading speed in UTF-16 units per minute. CJK text carries ~one
    /// word per character (≈400 chars/min); alphabetic text spends ~6
    /// units per word at ≈220 wpm.
    static func unitsPerMinute(languageTag: String?) -> Double {
        if let tag = languageTag?.lowercased(),
           tag.hasPrefix("zh") || tag.hasPrefix("ja") || tag.hasPrefix("ko") {
            return 400
        }
        return 1_300
    }

    static func minutes(utf16Length: Int, languageTag: String?) -> Int {
        guard utf16Length > 0 else { return 0 }
        let minutes = Double(utf16Length) / unitsPerMinute(languageTag: languageTag)
        return max(1, Int(minutes.rounded()))
    }

    /// "剩余约 4.5 小时" / "剩余约 12 分钟" for the library hero; nil when
    /// there's nothing left or no text to measure.
    static func remainingLabel(
        totalUTF16Length: Int,
        progressFraction: Double,
        languageTag: String?
    ) -> String? {
        let remaining = Double(totalUTF16Length) * (1 - min(max(progressFraction, 0), 1))
        guard remaining > 0, totalUTF16Length > 0 else { return nil }
        let minutes = remaining / unitsPerMinute(languageTag: languageTag)
        if minutes < 1 { return nil }
        if minutes < 60 {
            return "剩余约 \(Int(minutes.rounded())) 分钟"
        }
        let hours = minutes / 60
        let rounded = (hours * 2).rounded() / 2 // half-hour steps, like the prototype's 4.5
        if rounded == rounded.rounded() {
            return "剩余约 \(Int(rounded)) 小时"
        }
        return String(format: "剩余约 %.1f 小时", rounded)
    }
}

// MARK: - Cloze (生词挖空)

nonisolated enum VocabCloze {
    /// Blanks every occurrence of `word` in `sentence` ("nor did I wish to
    /// practise ______"), case-insensitively, matching the prototype's
    /// recall-test cards. Falls back to the original sentence when the
    /// word never appears.
    static func blank(_ sentence: String, word: String) -> String {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sentence }
        return sentence.replacingOccurrences(
            of: trimmed,
            with: "______",
            options: [.caseInsensitive, .diacriticInsensitive]
        )
    }
}

// MARK: - Review queue forecast (下次队列)

nonisolated enum VocabQueueForecast {
    /// "下次队列:明天 2 词 · 6月24日 1 词" — the first few upcoming review
    /// days with their counts. Empty string when nothing is scheduled.
    static func describe(
        dueDates: [Date],
        now: Date = Date(),
        calendar: Calendar = .current,
        maxGroups: Int = 3,
        unit: String = "词"
    ) -> String {
        let upcoming = dueDates.filter { $0 > now }
        guard !upcoming.isEmpty else { return "" }

        var counts: [Date: Int] = [:]
        for date in upcoming {
            let day = calendar.startOfDay(for: date)
            counts[day, default: 0] += 1
        }

        let today = calendar.startOfDay(for: now)
        let groups = counts.sorted { $0.key < $1.key }.prefix(maxGroups)
        let parts = groups.map { day, count in
            let days = calendar.dateComponents([.day], from: today, to: day).day ?? 0
            let label: String
            switch days {
            case ...0: label = "今天"
            case 1: label = "明天"
            case 2: label = "后天"
            default:
                let comps = calendar.dateComponents([.month, .day], from: day)
                label = "\(comps.month ?? 1)月\(comps.day ?? 1)日"
            }
            return "\(label) \(count) \(unit)"
        }
        return parts.joined(separator: " · ")
    }
}
