//
//  BookFileStore.swift
//  Empty
//

import Foundation
import OSLog

private let storeLog = OSLog(subsystem: "davirian.Empty", category: "filestore")

private func logStore(_ msg: String) {
    os_log(.info, log: storeLog, "%{public}@", msg)
    ImportLogger.write(msg)
}

/// Owns the on-disk copies of imported book files.
///
/// Layout: `<root>/<bookID>/source.<ext>` plus `<root>/<bookID>/unzipped/`
/// for extracted EPUB archives. The database stores paths relative to
/// `rootDirectory` so records survive container relocation. Default root is
/// `Application Support/Books` — backed up, not user-visible; the imported
/// file *is* the user's data.
nonisolated struct BookFileStore {
    var rootDirectory: URL

    /// Shared default instance. Safe to use from main actor; created lazily
    /// and cached because the root directory never changes during the session.
    static let `default`: BookFileStore = {
        guard let store = try? makeDefault() else {
            fatalError("Failed to initialize default BookFileStore")
        }
        return store
    }()

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

        logStore("importFile: isScoped=\(isScoped), source=\(sourceURL.path)")

        let fileManager = FileManager.default

        let appSupport = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false).path) ?? "N/A"
        logStore("sandbox appSupport: \(appSupport)")

        let relativePath = "\(bookID.uuidString)/source.\(sourceURL.pathExtension.lowercased())"
        let destination = url(forRelativePath: relativePath)
        logStore("destination: \(destination.path)")

        let dir = destination.deletingLastPathComponent()
        logStore("creating dir: \(dir.path)")

        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            logStore("directory OK")
        } catch {
            logStore("ERROR createDirectory: \(error.localizedDescription)")
            throw error
        }

        if fileManager.fileExists(atPath: destination.path) {
            do {
                try fileManager.removeItem(at: destination)
                logStore("removed existing file")
            } catch {
                logStore("ERROR removeItem: \(error.localizedDescription)")
                throw error
            }
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
            logStore("copyItem success")
        } catch {
            logStore("ERROR copyItem: \(error.localizedDescription)")
            throw error
        }

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
