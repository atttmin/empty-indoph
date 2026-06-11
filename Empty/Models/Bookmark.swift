//
//  Bookmark.swift
//  Empty
//

import Foundation
import SwiftData

/// A reader-placed bookmark (P0 handoff: the 目录/书签/搜索 drawer).
/// Synced store — bookmarks are reader data, like highlights.
///
/// Set `book` after inserting into a context (SwiftData relationships are
/// only safe to wire between inserted models).
@Model
final class Bookmark {
    var id: UUID = UUID()
    var book: Book?

    // Flattened `TextAnchor`-style position so queries can sort/filter.
    var chapterIndex: Int = 0
    var utf16Offset: Int = 0

    /// A short excerpt at the bookmark, shown in the drawer list.
    var snippet: String = ""

    var createdAt: Date = Date()

    init(chapterIndex: Int, utf16Offset: Int, snippet: String) {
        self.chapterIndex = chapterIndex
        self.utf16Offset = utf16Offset
        self.snippet = snippet
    }
}
