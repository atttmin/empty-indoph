//
//  ReadingSession.swift
//  Empty
//

import Foundation
import SwiftData

/// One continuous reading sitting. Powers reading stats and gives
/// "previously on" recaps a notion of *what you read last time*.
/// Synced store.
///
/// Set `book` after inserting into a context.
@Model
final class ReadingSession {
    var id: UUID = UUID()
    var book: Book?

    var startedAt: Date = Date()
    var endedAt: Date?

    /// Metered *active* reading seconds (scroll/page activity with idle
    /// gaps dropped). 0 on legacy rows — stats fall back to wall-clock.
    var activeSeconds: Double = 0

    // Flattened `ReadingPosition`s for where the sitting started and ended.
    var startChapterIndex: Int = 0
    var startUTF16Offset: Int = 0
    var endChapterIndex: Int = 0
    var endUTF16Offset: Int = 0

    var startPosition: ReadingPosition {
        get {
            ReadingPosition(
                chapterIndex: startChapterIndex,
                utf16Offset: startUTF16Offset
            )
        }
        set {
            startChapterIndex = newValue.chapterIndex
            startUTF16Offset = newValue.utf16Offset
        }
    }

    var endPosition: ReadingPosition {
        get {
            ReadingPosition(
                chapterIndex: endChapterIndex,
                utf16Offset: endUTF16Offset
            )
        }
        set {
            endChapterIndex = newValue.chapterIndex
            endUTF16Offset = newValue.utf16Offset
        }
    }

    init(startPosition: ReadingPosition, startedAt: Date = Date()) {
        self.startedAt = startedAt
        self.startChapterIndex = startPosition.chapterIndex
        self.startUTF16Offset = startPosition.utf16Offset
        self.endChapterIndex = startPosition.chapterIndex
        self.endUTF16Offset = startPosition.utf16Offset
    }
}
