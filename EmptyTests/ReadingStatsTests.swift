//
//  ReadingStatsTests.swift
//  EmptyTests
//
//  P1 统计口径: idle gaps don't count, daily buckets zero-fill, streaks
//  survive an unread "today", and speed/remaining math uses active time.
//

import Foundation
import SwiftData
import Testing
@testable import Empty

@MainActor
struct ReadingActivityMeterTests {
    @Test func capsIdleGapsAndDrains() {
        let meter = ReadingActivityMeter()
        let base = Date(timeIntervalSince1970: 1_000_000)

        meter.ping(now: base)
        meter.ping(now: base.addingTimeInterval(30))       // +30s
        meter.ping(now: base.addingTimeInterval(630))      // 10min gap → +90s cap
        meter.ping(now: base.addingTimeInterval(640))      // +10s

        #expect(meter.accumulated == 130)
        #expect(meter.drain() == 130)
        #expect(meter.accumulated == 0)
    }
}

@MainActor
struct ReadingStatsStoreTests {
    private func makeFixture() throws -> (ModelContainer, Book) {
        let container = try AppStores.makeContainer(ephemeral: true)
        let book = Book(title: "B", format: .epub)
        container.mainContext.insert(book)
        try container.mainContext.save()
        return (container, book)
    }

    private func addSession(
        _ context: ModelContext,
        book: Book,
        daysAgo: Int,
        activeSeconds: Double,
        chars: Int = 0,
        now: Date
    ) {
        let started = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        let session = ReadingSession(
            startPosition: ReadingPosition(chapterIndex: 0, utf16Offset: 0),
            startedAt: started
        )
        session.endedAt = started.addingTimeInterval(max(activeSeconds, 60))
        session.activeSeconds = activeSeconds
        session.endPosition = ReadingPosition(chapterIndex: 0, utf16Offset: chars)
        context.insert(session)
        session.book = book
    }

    @Test func bucketsDailyMinutesAndZeroFills() throws {
        let (container, book) = try makeFixture()
        let context = container.mainContext
        let now = Date()
        addSession(context, book: book, daysAgo: 0, activeSeconds: 600, now: now)
        addSession(context, book: book, daysAgo: 2, activeSeconds: 300, now: now)
        try context.save()

        let stats = try ReadingStatsStore(modelContext: context).dailyMinutes(days: 7, endingOn: now)

        #expect(stats.count == 7)
        #expect(stats.last?.minutes == 10)
        #expect(stats[4].minutes == 5)
        #expect(stats[3].minutes == 0)

        _ = container
    }

    @Test func streakSurvivesUnreadToday() throws {
        let (container, book) = try makeFixture()
        let context = container.mainContext
        let now = Date()
        // Read yesterday and the day before, nothing today.
        addSession(context, book: book, daysAgo: 1, activeSeconds: 300, now: now)
        addSession(context, book: book, daysAgo: 2, activeSeconds: 300, now: now)
        try context.save()

        let streak = try ReadingStatsStore(modelContext: context).streakDays(today: now)
        #expect(streak == 2)

        _ = container
    }

    @Test func speedUsesActiveMinutesAndFeedsRemainingEstimate() throws {
        let (container, book) = try makeFixture()
        let context = container.mainContext
        let now = Date()
        // 3000 chars over 10 active minutes → 300 chars/min.
        addSession(
            context, book: book, daysAgo: 0,
            activeSeconds: 600, chars: 3000, now: now
        )
        context.insert(Chapter(
            bookID: book.id, index: 0,
            text: String(repeating: "字", count: 6000)
        ))
        book.progressFraction = 0.5
        try context.save()

        let store = ReadingStatsStore(modelContext: context)
        #expect(try store.averageCharsPerMinute() == 300)
        // Half of 6000 chars left at 300/min → 10 minutes.
        #expect(try store.remainingMinutes(for: book) == 10)

        _ = container
    }
}
