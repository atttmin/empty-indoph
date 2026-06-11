//
//  VocabSchedulerTests.swift
//  EmptyTests
//

import Foundation
import Testing
@testable import Empty

@MainActor
struct VocabSchedulerTests {
    private func makeEntry(stage: Int = 1) -> VocabEntry {
        let entry = VocabEntry(word: "resignation", meaning: "听天由命;逆来顺受")
        entry.stage = stage
        return entry
    }

    @Test func goodPromotesOneRungAndDoublesInterval() {
        let entry = makeEntry(stage: 3) // 4-day rung
        let now = Date()

        entry.applyReview(.good, now: now)

        #expect(entry.stage == 4)
        #expect(entry.intervalDays == 7)
        let expected = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        #expect(abs(entry.dueAt.timeIntervalSince(expected)) < 1)
    }

    @Test func goodSaturatesAtTopRung() {
        let entry = makeEntry(stage: VocabEntry.ladderDays.count)

        entry.applyReview(.good)

        #expect(entry.stage == VocabEntry.ladderDays.count)
        #expect(entry.intervalDays == 30)
    }

    @Test func forgotDemotesToFirstRung() {
        let entry = makeEntry(stage: 5)
        let now = Date()

        entry.applyReview(.forgot, now: now)

        #expect(entry.stage == 1)
        #expect(entry.intervalDays == 1)
        let expected = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        #expect(abs(entry.dueAt.timeIntervalSince(expected)) < 1)
    }

    @Test func fuzzyKeepsStageAndReschedulesSameInterval() {
        let entry = makeEntry(stage: 2)
        let now = Date()

        entry.applyReview(.fuzzy, now: now)

        #expect(entry.stage == 2)
        #expect(entry.intervalDays == 2)
        let expected = Calendar.current.date(byAdding: .day, value: 2, to: now)!
        #expect(abs(entry.dueAt.timeIntervalSince(expected)) < 1)
    }

    @Test func reviewStampsLastReviewedAt() {
        let entry = makeEntry()
        let now = Date()

        entry.applyReview(.good, now: now)

        #expect(entry.lastReviewedAt == now)
    }

    @Test func corruptStageIsClampedNotCrashing() {
        let tooHigh = makeEntry(stage: 99)
        #expect(tooHigh.intervalDays == 30)
        tooHigh.applyReview(.good)
        #expect(tooHigh.stage == VocabEntry.ladderDays.count)

        let tooLow = makeEntry(stage: -3)
        #expect(tooLow.intervalDays == 1)
        tooLow.applyReview(.fuzzy)
        #expect(tooLow.stage == 1)
    }

    @Test func newEntryIsDueImmediatelyAtStageOne() {
        let entry = makeEntry()
        #expect(entry.stage == 1)
        #expect(entry.intervalDays == 1)
        #expect(entry.nextIntervalDays == 2)
        #expect(entry.dueAt <= Date())
        #expect(!entry.isStable)
    }

    @Test func stabilityBeginsAtSevenDayRung() {
        #expect(!makeEntry(stage: 3).isStable)
        #expect(makeEntry(stage: 4).isStable)
    }
}
