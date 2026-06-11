//
//  Chapter.swift
//  Empty
//

import Foundation
import SwiftData

/// Extracted plain text of one reading-order chapter (EPUB spine item,
/// PDF section).
///
/// Local store only: chapter text is derived from the imported file and
/// always re-extractable, so it never syncs — CloudKit quota, and the source
/// file doesn't sync either. References its book by `bookID`; cross-store
/// relationships don't exist.
@Model
final class Chapter {
    #Index<Chapter>([\.bookID], [\.bookID, \.index])

    var bookID: UUID
    /// Zero-based reading-order index; `ReadingPosition.chapterIndex`
    /// points here.
    var index: Int
    var title: String?
    /// Where the text came from in the source file (EPUB spine href,
    /// PDF page range).
    var sourceReference: String?

    /// UTF-8 bytes of the extracted plain text, kept out of row storage.
    @Attribute(.externalStorage) private var textData: Data
    /// Cached `text.utf16.count` so position math never decodes the blob.
    private(set) var utf16Length: Int
    /// Lazily cached AI condensation of this chapter (the expensive "map"
    /// half of recap); cleared implicitly when the chapter row is rebuilt.
    var cachedSummary: String?

    var text: String {
        get { String(decoding: textData, as: UTF8.self) }
        set {
            textData = Data(newValue.utf8)
            utf16Length = newValue.utf16.count
        }
    }

    @Relationship(deleteRule: .cascade, inverse: \Chunk.chapter)
    var chunks: [Chunk] = []

    init(
        bookID: UUID,
        index: Int,
        title: String? = nil,
        sourceReference: String? = nil,
        text: String
    ) {
        self.bookID = bookID
        self.index = index
        self.title = title
        self.sourceReference = sourceReference
        self.textData = Data(text.utf8)
        self.utf16Length = text.utf16.count
    }
}

extension Chapter {
    /// Concatenated plain text of every chapter the reader has fully passed
    /// (`index < position.chapterIndex`), in reading order, each prefixed
    /// with its title so map-reduce condense passes keep chapter identity.
    /// Empty when nothing lies behind the position.
    ///
    /// Partial text of the in-progress chapter joins once positions carry
    /// real intra-chapter offsets (native-pagination milestone).
    static func fullyReadText(
        forBookID bookID: UUID,
        before position: ReadingPosition,
        in context: ModelContext
    ) throws -> String {
        let limit = position.chapterIndex
        guard limit > 0 else { return "" }

        let descriptor = FetchDescriptor<Chapter>(
            predicate: #Predicate { $0.bookID == bookID && $0.index < limit },
            sortBy: [SortDescriptor(\.index)]
        )
        let chapters = try context.fetch(descriptor)

        var parts: [String] = []
        parts.reserveCapacity(chapters.count)
        for chapter in chapters {
            let text = chapter.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let heading: String
            if let title = chapter.title, !title.isEmpty {
                heading = title
            } else {
                heading = "Chapter \(chapter.index + 1)"
            }
            parts.append("\(heading)\n\(text)")
        }
        return parts.joined(separator: "\n\n")
    }
}
