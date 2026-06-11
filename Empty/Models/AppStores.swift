//
//  AppStores.swift
//  Empty
//

import Foundation
import SwiftData

/// Two-store persistence layout. The split is the architecture:
/// **sync the reader's data, not the book's content.**
///
/// - **Synced** — library metadata, reading positions, highlights, sessions
///   (`Book`, `Highlight`, `ReadingSession`). Small, precious, written to
///   sync via CloudKit. Models follow CloudKit rules: attributes defaulted
///   or optional, relationships optional, no unique constraints.
/// - **Local** — bulky derived text (`Chapter`, `Chunk`, embeddings).
///   Always re-derivable from the imported file; never leaves the device
///   (quota, copyright, privacy).
///
/// Cross-store references go through `Book.id` only. SwiftData cannot relate
/// models across stores, and that constraint is load-bearing: it keeps book
/// content out of the sync pipeline by construction.
enum AppStores {
    /// Flip to `.automatic` after adding the iCloud capability
    /// (Signing & Capabilities → + iCloud → CloudKit) to turn on sync.
    /// Until then `.none` keeps behavior identical with or without
    /// entitlements.
    /// Set to `.none` to run without an iCloud entitlement (local-only).
    /// `.automatic` once `Empty.entitlements` is linked in the Xcode target.
    private static let syncedDatabase = ModelConfiguration.CloudKitDatabase.automatic

    static let syncedSchema = Schema([
        Book.self,
        Highlight.self,
        ReadingSession.self,
        VocabEntry.self,
        StudyCardEntry.self,
        Bookmark.self,
    ])

    static let localSchema = Schema([
        Chapter.self,
        Chunk.self,
        ParagraphTranslation.self,
    ])

    /// - Parameter ephemeral: throwaway per-container stores for tests and
    ///   previews. Not `isStoredInMemoryOnly`: that backs every store with
    ///   the same `/dev/null` pseudo-file, and concurrent containers
    ///   (parallel tests) trip over the shared SQLite locks. Unique temp
    ///   files keep ephemeral containers fully isolated.
    static func makeContainer(ephemeral: Bool = false) throws -> ModelContainer {
        let synced: ModelConfiguration
        let local: ModelConfiguration
        if ephemeral {
            let base = FileManager.default.temporaryDirectory
                .appending(path: "EmptyStores-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            synced = ModelConfiguration(
                "Synced",
                schema: syncedSchema,
                url: base.appending(path: "Synced.store"),
                cloudKitDatabase: .none
            )
            local = ModelConfiguration(
                "Local",
                schema: localSchema,
                url: base.appending(path: "Local.store"),
                cloudKitDatabase: .none
            )
        } else {
            synced = ModelConfiguration(
                "Synced",
                schema: syncedSchema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: syncedDatabase
            )
            local = ModelConfiguration(
                "Local",
                schema: localSchema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
        }
        let allModels = Schema([
            Book.self,
            Highlight.self,
            ReadingSession.self,
            VocabEntry.self,
            StudyCardEntry.self,
            Bookmark.self,
            Chapter.self,
            Chunk.self,
            ParagraphTranslation.self,
        ])
        do {
            return try ModelContainer(for: allModels, configurations: synced, local)
        } catch where !ephemeral {
            // CloudKit needs a provisioned iCloud entitlement; builds signed
            // without one (CI, ad-hoc dev runs) land here. The same on-disk
            // stores reopen local-only, so data survives and sync resumes on
            // the next properly signed launch.
            let localOnlySynced = ModelConfiguration(
                "Synced",
                schema: syncedSchema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
            return try ModelContainer(
                for: allModels,
                configurations: localOnlySynced, local
            )
        }
    }
}
