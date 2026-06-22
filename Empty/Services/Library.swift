//
//  Library.swift
//  Empty
//

import Foundation
import OSLog
import SwiftData
import UniformTypeIdentifiers

private let importLog = OSLog(subsystem: "davirian.Empty", category: "import")

private func logImport(_ msg: String) {
    os_log(.info, log: importLog, "%{public}@", msg)
    ImportLogger.write(msg)
}

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
        logImport("importBook called: \(url.path)")

        guard let format = BookFormat(fileExtension: url.pathExtension) else {
            logImport("ERROR: unsupported extension \(url.pathExtension)")
            throw LibraryError.unsupportedFileType(url.pathExtension)
        }
        logImport("format: \(format.rawValue)")

        let book = Book(
            title: url.deletingPathExtension().lastPathComponent,
            format: format
        )

        do {
            book.fileRelativePath = try fileStore.importFile(at: url, bookID: book.id)
            logImport("file copied, relativePath: \(book.fileRelativePath ?? "nil")")
        } catch {
            logImport("ERROR fileStore.importFile: \(error.localizedDescription)")
            throw error
        }

        modelContext.insert(book)

        switch format {
        case .epub:
            populateFromEPUB(book)
        case .pdf:
            populateFromPDF(book)
        }

        do {
            try modelContext.save()
            logImport("modelContext.save OK")
        } catch {
            logImport("ERROR modelContext.save: \(error.localizedDescription)")
            throw error
        }

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
            // Import is the one path that needs every chapter's plain text
            // for the AI layer, so we load all spine content here.
            parsed = try EPUBParser().parseBook(
                at: fileStore.url(forRelativePath: relativePath),
                unzipDirectory: fileStore.unzipDirectory(forBookID: book.id),
                loadContent: true
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

    /// Best-effort enrichment for PDFs: metadata, cover, and one `Chapter`
    /// row per page (the AI layer's substrate).
    private func populateFromPDF(_ book: Book) {
        guard let relativePath = book.fileRelativePath else { return }
        let parsed: ParsedPDF
        do {
            parsed = try PDFParser().parseBook(
                at: fileStore.url(forRelativePath: relativePath)
            )
        } catch {
            return
        }

        if !parsed.metadata.title.isEmpty { book.title = parsed.metadata.title }
        if !parsed.metadata.author.isEmpty { book.author = parsed.metadata.author }
        book.coverThumbnailData = parsed.coverImageData

        for page in parsed.pages {
            let record = Chapter(
                bookID: book.id,
                index: page.index,
                title: page.title,
                sourceReference: String(page.index),
                text: page.text
            )
            modelContext.insert(record)
        }
    }

    /// Ensures per-page `Chapter` rows exist (import backfill or re-parse).
    /// Returns sorted page titles for the reader UI.
    @discardableResult
    static func ensurePDFChapters(
        for book: Book,
        at fileURL: URL,
        in modelContext: ModelContext
    ) throws -> [String] {
        let bookID = book.id
        let existing = try modelContext.fetch(
            FetchDescriptor<Chapter>(
                predicate: #Predicate { $0.bookID == bookID },
                sortBy: [SortDescriptor(\.index)]
            )
        )
        if !existing.isEmpty {
            return existing.map { $0.title ?? "Page \($0.index + 1)" }
        }

        let parsed = try PDFParser().parseBook(at: fileURL)
        guard !parsed.pages.isEmpty else {
            throw PDFParser.ParseError.noPages
        }

        if !parsed.metadata.title.isEmpty, book.title.isEmpty
            || book.title == fileURL.deletingPathExtension().lastPathComponent {
            book.title = parsed.metadata.title
        }
        if !parsed.metadata.author.isEmpty { book.author = parsed.metadata.author }
        if book.coverThumbnailData == nil {
            book.coverThumbnailData = parsed.coverImageData
        }

        for page in parsed.pages {
            let record = Chapter(
                bookID: book.id,
                index: page.index,
                title: page.title,
                sourceReference: String(page.index),
                text: page.text
            )
            modelContext.insert(record)
        }
        try modelContext.save()
        return parsed.pages.map(\.title)
    }

    /// Deletes a book everywhere it exists: the reader-data record (highlights
    /// and sessions cascade with it), local derived data (chapters cascade
    /// their chunks; stray chunks and cached translations swept by
    /// `bookID`), and the imported files, unzipped archive included.
    ///
    /// Removing the library record is the operation that must always
    /// succeed — including for a corrupted or partially-imported book.
    /// On-disk file removal is therefore best-effort: a locked or damaged
    /// file directory is swept when it can be and otherwise left behind
    /// rather than blocking the delete. Returns the file-removal error (if
    /// any) for diagnostics, but the book is gone from the library either
    /// way.
    @discardableResult
    func deleteBook(_ book: Book) throws -> Error? {
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
        let translations = try modelContext.fetch(
            FetchDescriptor<ParagraphTranslation>(
                predicate: #Predicate { $0.bookID == bookID }
            )
        )
        for translation in translations {
            modelContext.delete(translation)
        }

        modelContext.delete(book)
        try modelContext.save()

        // Best effort — never let a damaged file keep the book in the library.
        do {
            try fileStore.removeFiles(forBookID: bookID)
            return nil
        } catch {
            return error
        }
    }
}
