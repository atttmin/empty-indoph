//
//  VocabEntry.swift
//  Empty
//

import Foundation
import SwiftData

/// Self-assessment after a review reveal.
nonisolated enum VocabReviewGrade: Sendable {
    /// Demote to stage 1 — see it again tomorrow.
    case forgot
    /// Keep the current stage and interval.
    case fuzzy
    /// Promote one stage — the interval roughly doubles.
    case good
}

/// A word the reader looked up, scheduled for spaced repetition on the
/// Ebbinghaus ladder (1 → 2 → 4 → 7 → 15 → 30 days). Synced store —
/// vocabulary is the reader's own data.
@Model
final class VocabEntry {
    /// Review intervals in days; `stage` is a 1-based index into this.
    static let ladderDays = [1, 2, 4, 7, 15, 30]

    var id: UUID = UUID()
    var word: String = ""
    /// IPA, e.g. "/ˌrezɪɡˈneɪʃn/".
    var phonetic: String?
    /// "n.", "adj.", "phr.v.", …
    var partOfSpeech: String?
    var meaning: String = ""
    /// Contextual nuance ("此处非'辞职'…").
    var note: String?
    /// The original sentence the word was met in — context beats word lists.
    var sentence: String?
    /// Where it came from, e.g. "Walden · Ch.2".
    var source: String?

    /// 1-based rung on `ladderDays`. Clamped on read so stored data can
    /// never crash the scheduler.
    var stage: Int = 1
    var dueAt: Date = Date()
    var createdAt: Date = Date()
    var lastReviewedAt: Date?

    init(
        word: String,
        meaning: String,
        phonetic: String? = nil,
        partOfSpeech: String? = nil,
        note: String? = nil,
        sentence: String? = nil,
        source: String? = nil
    ) {
        self.word = word
        self.meaning = meaning
        self.phonetic = phonetic
        self.partOfSpeech = partOfSpeech
        self.note = note
        self.sentence = sentence
        self.source = source
    }

    private var clampedStage: Int {
        min(max(stage, 1), Self.ladderDays.count)
    }

    /// Current interval in days for the entry's stage.
    var intervalDays: Int {
        Self.ladderDays[clampedStage - 1]
    }

    /// Interval the entry would move to if graded `good`.
    var nextIntervalDays: Int {
        Self.ladderDays[min(clampedStage, Self.ladderDays.count - 1)]
    }

    /// A word that climbed past the 7-day rung is considered settled.
    var isStable: Bool {
        clampedStage >= 4
    }

    /// Applies one review outcome: moves the stage per the grade and
    /// schedules the next due date from the (new) interval.
    func applyReview(_ grade: VocabReviewGrade, now: Date = Date()) {
        switch grade {
        case .forgot:
            stage = 1
        case .fuzzy:
            stage = clampedStage
        case .good:
            stage = min(clampedStage + 1, Self.ladderDays.count)
        }
        lastReviewedAt = now
        dueAt = Calendar.current.date(byAdding: .day, value: intervalDays, to: now)
            ?? now.addingTimeInterval(Double(intervalDays) * 86_400)
    }
}
