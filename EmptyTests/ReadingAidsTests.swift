//
//  ReadingAidsTests.swift
//  EmptyTests
//
//  Helpers behind the Mac prototype's reading aids: chapter outline
//  parsing, vocabulary cloze, reading-time estimates, the review-queue
//  forecast, and study-card kinds.
//

import Foundation
import Testing
@testable import Empty

struct ChapterOutlineTests {
    @Test func parsesPlainPipeFormat() throws {
        let outline = try #require(ChapterOutline.parse(
            """
            选址记|梭罗如何挑中瓦尔登湖,以及"买下"农场的想象实验。
            生活宣言|全书最著名的段落:为什么要「刻意地生活」。
            简化论|对铁路、邮件、新闻等"现代加速"的批判。
            """
        ))
        #expect(outline.parts.count == 3)
        #expect(outline.parts[0].title == "选址记")
        #expect(outline.parts[2].detail.contains("批判"))
    }

    @Test func toleratesListOrnaments() throws {
        let outline = try #require(ChapterOutline.parse(
            """
            ① 开端|主人公受邀赴宴。
            2. 转折|一封信改变了局面。
            - 结尾|众人散去,真相未明。
            """
        ))
        #expect(outline.parts.map(\.title) == ["开端", "转折", "结尾"])
    }

    @Test func rejectsUnstructuredText() {
        #expect(ChapterOutline.parse("这一章讲了很多事情,但没有结构。") == nil)
        #expect(ChapterOutline.parse("只有|一行") == nil)
        #expect(ChapterOutline.parse("") == nil)
    }

    @Test func roundTripsThroughSerialization() throws {
        let original = try #require(ChapterOutline.parse("甲|一\n乙|二\n丙|三"))
        let reparsed = try #require(ChapterOutline.parse(original.serialized))
        #expect(reparsed == original)
    }

    @Test func partIndexMapsThirds() {
        #expect(ChapterOutline.partIndex(forProgress: 0) == 0)
        #expect(ChapterOutline.partIndex(forProgress: 0.32) == 0)
        #expect(ChapterOutline.partIndex(forProgress: 0.5) == 1)
        #expect(ChapterOutline.partIndex(forProgress: 0.9) == 2)
        #expect(ChapterOutline.partIndex(forProgress: 1) == 2)
    }
}

struct VocabClozeTests {
    @Test func blanksTheWordCaseInsensitively() {
        let sentence = "Nor did I wish to practise resignation, unless it was quite necessary."
        let blanked = VocabCloze.blank(sentence, word: "Resignation")
        #expect(blanked == "Nor did I wish to practise ______, unless it was quite necessary.")
    }

    @Test func blanksEveryOccurrence() {
        let blanked = VocabCloze.blank("Simplicity, simplicity, simplicity!", word: "simplicity")
        #expect(blanked == "______, ______, ______!")
    }

    @Test func leavesSentenceAloneWhenWordAbsent() {
        let sentence = "Our life is frittered away by detail."
        #expect(VocabCloze.blank(sentence, word: "marrow") == sentence)
        #expect(VocabCloze.blank(sentence, word: "  ") == sentence)
    }
}

struct ReadingTimeEstimateTests {
    @Test func estimatesByLanguage() {
        // ~2,600 utf16 units of English ≈ 2 minutes; same length of
        // Chinese reads much slower.
        #expect(ReadingTimeEstimate.minutes(utf16Length: 2_600, languageTag: "en") == 2)
        #expect(ReadingTimeEstimate.minutes(utf16Length: 2_600, languageTag: "zh-Hans") > 5)
        #expect(ReadingTimeEstimate.minutes(utf16Length: 0, languageTag: "en") == 0)
        #expect(ReadingTimeEstimate.minutes(utf16Length: 10, languageTag: "en") == 1)
    }

    @Test func remainingLabelUsesHalfHourSteps() {
        let label = ReadingTimeEstimate.remainingLabel(
            totalUTF16Length: 1_300 * 60 * 5, // ≈ 5 hours of English
            progressFraction: 0.1,            // 4.5 hours left
            languageTag: "en"
        )
        #expect(label == "剩余约 4.5 小时")
    }

    @Test func remainingLabelSwitchesToMinutes() {
        let label = ReadingTimeEstimate.remainingLabel(
            totalUTF16Length: 1_300 * 40,
            progressFraction: 0.5,
            languageTag: "en"
        )
        #expect(label == "剩余约 20 分钟")
    }

    @Test func remainingLabelNilWhenDone() {
        #expect(ReadingTimeEstimate.remainingLabel(
            totalUTF16Length: 10_000,
            progressFraction: 1,
            languageTag: "en"
        ) == nil)
        #expect(ReadingTimeEstimate.remainingLabel(
            totalUTF16Length: 0,
            progressFraction: 0,
            languageTag: "en"
        ) == nil)
    }
}

struct VocabQueueForecastTests {
    private let calendar = Calendar.current

    @Test func groupsUpcomingReviewsByDay() throws {
        let now = Date()
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: now))
        let dayAfter = try #require(calendar.date(byAdding: .day, value: 2, to: now))

        let label = VocabQueueForecast.describe(
            dueDates: [tomorrow, tomorrow, dayAfter],
            now: now,
            calendar: calendar
        )
        #expect(label == "明天 2 词 · 后天 1 词")
    }

    @Test func namesFarDatesByMonthAndDay() throws {
        let now = Date()
        let far = try #require(calendar.date(byAdding: .day, value: 9, to: now))
        let comps = calendar.dateComponents([.month, .day], from: calendar.startOfDay(for: far))

        let label = VocabQueueForecast.describe(dueDates: [far], now: now, calendar: calendar)
        #expect(label == "\(comps.month!)月\(comps.day!)日 1 词")
    }

    @Test func emptyWhenNothingScheduled() {
        let now = Date()
        #expect(VocabQueueForecast.describe(dueDates: [], now: now) == "")
        #expect(VocabQueueForecast.describe(
            dueDates: [now.addingTimeInterval(-60)],
            now: now
        ) == "")
    }
}

@MainActor
struct StudyCardKindTests {
    @Test func defaultsToReviewKind() {
        let card = StudyCardEntry(question: "Q", answer: "A")
        #expect(card.kind == .review)
    }

    @Test func roundTripsQaAndLinkKinds() {
        let qa = StudyCardEntry(question: "Q", answer: "A", kind: .qa)
        #expect(qa.kind == .qa)
        let link = StudyCardEntry(question: "Q", answer: "A", kind: .link)
        link.kind = .review
        #expect(link.kind == .review)
    }
}
