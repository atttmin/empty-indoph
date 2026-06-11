//
//  Library.swift
//  Empty
//

import Foundation
import SwiftData
import UniformTypeIdentifiers

nonisolated enum LibraryError: LocalizedError {
    case unsupportedFileType(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let ext):
            "“.\(ext)” files aren't supported. Import an EPUB or PDF."
        }
    }
}

/// Library mutations — importing files, deleting books — kept out of views
/// so the cross-store + file-store choreography lives in exactly one place.
@MainActor
struct Library {
    let modelContext: ModelContext
    let fileStore: BookFileStore

    /// Content types the importer accepts; mirrors `BookFormat`.
    static let importableContentTypes: [UTType] = [.epub, .pdf]

    init(modelContext: ModelContext, fileStore: BookFileStore) {
        self.modelContext = modelContext
        self.fileStore = fileStore
    }

    /// Default file store; throws only if Application Support is unavailable.
    init(modelContext: ModelContext) throws {
        self.init(modelContext: modelContext, fileStore: try .makeDefault())
    }

    /// Copies the file into the app container, creates the library record,
    /// and — for EPUBs — extracts real metadata, cover, and chapter text.
    @discardableResult
    func importBook(from url: URL) throws -> Book {
        guard let format = BookFormat(fileExtension: url.pathExtension) else {
            throw LibraryError.unsupportedFileType(url.pathExtension)
        }
        let book = Book(
            title: url.deletingPathExtension().lastPathComponent,
            format: format
        )
        book.fileRelativePath = try fileStore.importFile(at: url, bookID: book.id)
        modelContext.insert(book)

        if format == .epub {
            populateFromEPUB(book)
        }

        try modelContext.save()
        return book
    }

    /// Best-effort enrichment: metadata, cover, and per-chapter plain text
    /// (the AI layer's substrate). Failure never loses the import — the file
    /// is already stored, the record keeps its filename title, and the
    /// reader surfaces parse errors on open.
    private func populateFromEPUB(_ book: Book) {
        guard let relativePath = book.fileRelativePath else { return }
        let parsed: EPUBBook
        do {
            parsed = try EPUBParser().parseBook(
                at: fileStore.url(forRelativePath: relativePath),
                unzipDirectory: fileStore.unzipDirectory(forBookID: book.id)
            )
        } catch {
            return
        }

        if !parsed.metadata.title.isEmpty { book.title = parsed.metadata.title }
        if !parsed.metadata.author.isEmpty { book.author = parsed.metadata.author }
        book.languageTag = parsed.metadata.language
        book.coverThumbnailData = parsed.coverImageData

        for (index, chapter) in parsed.chapters.enumerated() {
            let record = Chapter(
                bookID: book.id,
                index: index,
                title: chapter.title,
                sourceReference: chapter.href,
                text: chapter.plainText
            )
            modelContext.insert(record)
        }
    }

    /// Deletes a book everywhere it exists: the synced record (highlights
    /// and sessions cascade with it), local derived data (chapters cascade
    /// their chunks; stray chunks swept by `bookID`), and the imported
    /// files, unzipped archive included.
    func deleteBook(_ book: Book) throws {
        let bookID = book.id

        let chapters = try modelContext.fetch(
            FetchDescriptor<Chapter>(predicate: #Predicate { $0.bookID == bookID })
        )
        for chapter in chapters {
            modelContext.delete(chapter)
        }
        let strayChunks = try modelContext.fetch(
            FetchDescriptor<Chunk>(predicate: #Predicate { $0.bookID == bookID })
        )
        for chunk in strayChunks {
            modelContext.delete(chunk)
        }

        modelContext.delete(book)
        try modelContext.save()
        try fileStore.removeFiles(forBookID: bookID)
    }
}
