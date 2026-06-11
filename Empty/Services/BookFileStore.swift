//
//  BookFileStore.swift
//  Empty
//

import Foundation

/// Owns the on-disk copies of imported book files.
///
/// Layout: `<root>/<bookID>/source.<ext>` plus `<root>/<bookID>/unzipped/`
/// for extracted EPUB archives. The database stores paths relative to
/// `rootDirectory` so records survive container relocation. Default root is
/// `Application Support/Books` — backed up, not user-visible; the imported
/// file *is* the user's data.
nonisolated struct BookFileStore: Sendable {
    var rootDirectory: URL

    /// Standard store under Application Support.
    static func makeDefault() throws -> BookFileStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return BookFileStore(
            rootDirectory: support.appending(path: "Books", directoryHint: .isDirectory)
        )
    }

    func url(forRelativePath relativePath: String) -> URL {
        rootDirectory.appending(path: relativePath)
    }

    /// Directory holding an EPUB's extracted archive; created lazily by the
    /// parser on first read.
    func unzipDirectory(forBookID bookID: UUID) -> URL {
        rootDirectory.appending(
            path: "\(bookID.uuidString)/unzipped",
            directoryHint: .isDirectory
        )
    }

    /// Copies the file at `sourceURL` into the store, handling
    /// security-scoped URLs from `fileImporter`. Returns the relative path
    /// to persist on `Book`.
    func importFile(at sourceURL: URL, bookID: UUID) throws -> String {
        let isScoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isScoped { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let relativePath = "\(bookID.uuidString)/source.\(sourceURL.pathExtension.lowercased())"
        let destination = url(forRelativePath: relativePath)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return relativePath
    }

    /// Removes every file belonging to `bookID` (source and unzipped
    /// archive); an absent directory is fine.
    func removeFiles(forBookID bookID: UUID) throws {
        let directory = rootDirectory.appending(
            path: bookID.uuidString,
            directoryHint: .isDirectory
        )
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
