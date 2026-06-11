//
//  RecapBuilder.swift
//  Empty
//

import Foundation
import SwiftData

/// Builds "previously on" recaps with a per-chapter summary cache.
///
/// The expensive half of a recap is condensing every read chapter (the map
/// pass). Those condensations are stable per chapter, so they cache on
/// `Chapter.cachedSummary`: the first recap pays for the chapters it covers,
/// every later recap only pays the final reduce over short summaries —
/// seconds instead of minutes, pennies instead of cents.
@MainActor
struct RecapBuilder {
    /// Chapters shorter than this are passed through verbatim instead of
    /// burning a model call on front matter like "Cover" pages.
    static let inlineSummaryThreshold = 200

    let modelContext: ModelContext
    /// Provider entry point — typically `service.summarize`.
    let summarize: (String, SummaryFocus) async throws -> String

    /// Recap of everything before `position`. Throws `.emptyInput` when
    /// nothing readable lies behind it.
    func recap(for book: Book, before position: ReadingPosition) async throws -> String {
        let limit = position.chapterIndex
        guard limit > 0 else { throw AIServiceError.emptyInput }

        let bookID = book.id
        let chapters = try modelContext.fetch(
            FetchDescriptor<Chapter>(
                predicate: #Predicate { $0.bookID == bookID && $0.index < limit },
                sortBy: [SortDescriptor(\.index)]
            )
        )

        var parts: [String] = []
        parts.reserveCapacity(chapters.count)
        for chapter in chapters {
            let text = chapter.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let summary: String
            if let cached = chapter.cachedSummary, !cached.isEmpty {
                summary = cached
            } else if text.count < Self.inlineSummaryThreshold {
                summary = text
            } else {
                summary = try await summarize(text, .digest)
                chapter.cachedSummary = summary
                // Persist incrementally so partial progress survives a
                // cancelled or failed recap; autosave covers stragglers.
                try? modelContext.save()
            }

            let heading: String
            if let title = chapter.title, !title.isEmpty {
                heading = title
            } else {
                heading = "Chapter \(chapter.index + 1)"
            }
            parts.append("\(heading)\n\(summary)")
        }
        guard !parts.isEmpty else { throw AIServiceError.emptyInput }

        // Final reduce: summaries are short, so this is one cheap call.
        return try await summarize(parts.joined(separator: "\n\n"), .recap)
    }
}
