//
//  Book.swift
//  Empty
//

import Foundation
import SwiftData

/// Source format of an imported book file. Raw values double as file
/// extensions.
nonisolated enum BookFormat: String, Codable, CaseIterable, Sendable {
    case epub
    case pdf

    init?(fileExtension: String) {
        self.init(rawValue: fileExtension.lowercased())
    }
}

/// A book in the user's library.
///
/// Lives in the **synced** store (see `AppStores`): metadata, reading
/// position, highlights, and sessions are the reader's own data and sync via
/// CloudKit once the iCloud capability is enabled. The imported file and all
/// text derived from it (`Chapter`, `Chunk`) stay in the local store and
/// reference this book by `id` — cross-store object relationships don't
/// exist, by design.
///
/// CloudKit rules apply to everything in the synced store: every attribute
/// defaulted or optional, every relationship optional, no unique constraints.
@Model
final class Book {
    /// Stable identity for cross-store references (`Chapter.bookID`,
    /// `Chunk.bookID`) and file-store directories.
    var id: UUID = UUID()

    var title: String = ""
    var author: String = ""
    /// BCP-47 tag of the book text when known (e.g. "en", "zh-Hans");
    /// lets AI prompts and TTS match the book's language.
    var languageTag: String?

    private var formatRawValue: String = BookFormat.epub.rawValue
    var format: BookFormat {
        get { BookFormat(rawValue: formatRawValue) ?? .epub }
        set { formatRawValue = newValue.rawValue }
    }

    /// Imported file's path relative to `BookFileStore.rootDirectory`;
    /// `nil` on a device that synced the metadata but doesn't hold the file.
    var fileRelativePath: String?

    /// Small JPEG thumbnail so a synced library still shows covers on
    /// devices without the source file.
    @Attribute(.externalStorage) var coverThumbnailData: Data?

    var addedAt: Date = Date()
    var lastOpenedAt: Date?

    private var positionChapterIndex: Int = 0
    private var positionUTF16Offset: Int = 0
    /// Current reading position — the upper bound every spoiler-safe AI
    /// feature filters against.
    var position: ReadingPosition {
        get {
            ReadingPosition(
                chapterIndex: positionChapterIndex,
                utf16Offset: positionUTF16Offset
            )
        }
        set {
            positionChapterIndex = newValue.chapterIndex
            positionUTF16Offset = newValue.utf16Offset
        }
    }

    /// Cached 0…1 fraction for library UI; maintained by the reader.
    var progressFraction: Double = 0

    /// Cached "朱批 · 上次读到" teaser for the library hero — a spoiler-safe
    /// recap of everything before the current chapter. Regenerated when
    /// `cachedHeroRecapChapterIndex` no longer matches the position.
    var cachedHeroRecap: String?
    /// Chapter index `cachedHeroRecap` was built for.
    var cachedHeroRecapChapterIndex: Int?

    @Relationship(deleteRule: .cascade, inverse: \Highlight.book)
    var highlights: [Highlight]?

    @Relationship(deleteRule: .cascade, inverse: \ReadingSession.book)
    var sessions: [ReadingSession]?

    // CloudKit requires every relationship to carry an inverse; without this
    // the `.automatic` synced container fails to initialize at launch.
    @Relationship(deleteRule: .cascade, inverse: \StudyCardEntry.book)
    var studyCards: [StudyCardEntry]?

    @Relationship(deleteRule: .cascade, inverse: \Bookmark.book)
    var bookmarks: [Bookmark]?

    init(title: String, author: String = "", format: BookFormat) {
        self.title = title
        self.author = author
        self.formatRawValue = format.rawValue
    }
}
