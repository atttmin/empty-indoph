//
//  ReadingStats.swift
//  Empty
//
//  P1 阅读统计 per the handoff: time only counts while the reader is
//  actually moving through text (scroll/page activity, idle gaps
//  dropped), speed is a rolling average of characters per active
//  minute, and the remaining-time estimate divides what's left of the
//  book by that speed. Everything computes locally.
//

import Foundation
import SwiftData

/// Accumulates *effective* reading time from activity pings (position
/// reports, page turns). Gaps longer than `maxGap` don't count — leaving
/// the book open on the desk isn't reading.
@MainActor
final class ReadingActivityMeter {
    /// The longest silence still considered "reading" (a slow page).
    static let maxGap: TimeInterval = 90

    private var lastActivity: Date?
    private(set) var accumulated: TimeInterval = 0

    func ping(now: Date = Date()) {
        if let last = lastActivity {
            let gap = now.timeIntervalSince(last)
            if gap > 0 {
                accumulated += min(gap, Self.maxGap)
            }
        }
        lastActivity = now
    }

    /// Returns and resets the accumulated active time (drained into
    /// `ReadingSession.activeSeconds` on each progress save).
    func drain() -> TimeInterval {
        defer { accumulated = 0 }
        return accumulated
    }
}

nonisolated struct ReadingDayStat: Equatable, Identifiable {
    var day: Date
    var minutes: Double

    var id: Date { day }
}

/// Local aggregation over `ReadingSession` rows.
@MainActor
struct ReadingStatsStore {
    let modelContext: ModelContext
    var calendar: Calendar = .current

    /// A session's effective seconds: metered active time when present;
    /// legacy sessions (recorded before metering) fall back to wall-clock
    /// capped at two hours so an overnight forgotten window can't
    /// dominate the chart.
    nonisolated static func effectiveSeconds(
        activeSeconds: Double,
        startedAt: Date,
        endedAt: Date?
    ) -> Double {
        if activeSeconds > 0 { return activeSeconds }
        guard let endedAt else { return 0 }
        return min(max(endedAt.timeIntervalSince(startedAt), 0), 2 * 3600)
    }

    /// Per-day active minutes for the `days` ending on `endingOn`
    /// (inclusive), zero-filled so charts get a full axis.
    func dailyMinutes(days: Int, endingOn: Date = Date()) throws -> [ReadingDayStat] {
        let end = calendar.startOfDay(for: endingOn)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) else {
            return []
        }
        let sessions = try modelContext.fetch(FetchDescriptor<ReadingSession>(
            predicate: #Predicate { $0.startedAt >= start }
        ))

        var buckets: [Date: Double] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startedAt)
            buckets[day, default: 0] += Self.effectiveSeconds(
                activeSeconds: session.activeSeconds,
                startedAt: session.startedAt,
                endedAt: session.endedAt
            )
        }

        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else {
                return nil
            }
            return ReadingDayStat(day: day, minutes: (buckets[day] ?? 0) / 60)
        }
    }

    /// Consecutive days (ending today or yesterday) with any reading.
    func streakDays(today: Date = Date()) throws -> Int {
        let stats = try dailyMinutes(days: 60, endingOn: today).reversed()
        var streak = 0
        for (index, stat) in stats.enumerated() {
            if stat.minutes >= 1 {
                streak += 1
            } else if index == 0 {
                // No reading yet *today* — the streak survives until
                // tomorrow; keep counting from yesterday.
                continue
            } else {
                break
            }
        }
        return streak
    }

    /// Rolling average reading speed in UTF-16 characters per active
    /// minute, from recent same-chapter sessions (cross-chapter spans
    /// don't know the chapter lengths without joining the local store).
    func averageCharsPerMinute(recentSessions: Int = 30) throws -> Double? {
        var descriptor = FetchDescriptor<ReadingSession>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = recentSessions * 3
        let sessions = try modelContext.fetch(descriptor)

        var totalChars = 0.0
        var totalMinutes = 0.0
        var counted = 0
        for session in sessions where counted < recentSessions {
            guard session.endChapterIndex == session.startChapterIndex else { continue }
            let chars = Double(session.endUTF16Offset - session.startUTF16Offset)
            let minutes = Self.effectiveSeconds(
                activeSeconds: session.activeSeconds,
                startedAt: session.startedAt,
                endedAt: session.endedAt
            ) / 60
            guard chars > 40, minutes > 0.2 else { continue }
            totalChars += chars
            totalMinutes += minutes
            counted += 1
        }
        guard totalMinutes > 0 else { return nil }
        return totalChars / totalMinutes
    }

    /// Estimated minutes to finish `book` at the reader's measured speed
    /// (nil without enough data — UI falls back to the fixed estimate).
    func remainingMinutes(for book: Book) throws -> Double? {
        guard let speed = try averageCharsPerMinute(), speed > 0 else { return nil }
        let bookID = book.id
        let chapters = try modelContext.fetch(FetchDescriptor<Chapter>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        guard !chapters.isEmpty else { return nil }
        let totalChars = chapters.reduce(0.0) { $0 + Double($1.utf16Length) }
        let remaining = totalChars * max(0, 1 - book.progressFraction)
        return remaining / speed
    }
}
