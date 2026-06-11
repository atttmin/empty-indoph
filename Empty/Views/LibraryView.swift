//
//  LibraryView.swift
//  Empty
//

import SwiftData
import SwiftUI

/// The library: every imported book, newest first. Import copies the file
/// into the app container, parses EPUB metadata and chapter text, and the
/// row opens the reader.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]

    @State private var isImporterPresented = false
    @State private var isDiagnosticsPresented = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Import Book", systemImage: "plus") {
                            isImporterPresented = true
                        }
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button("AI Status", systemImage: "sparkles") {
                            isDiagnosticsPresented = true
                        }
                    }
                }
                .fileImporter(
                    isPresented: $isImporterPresented,
                    allowedContentTypes: Library.importableContentTypes,
                    allowsMultipleSelection: true,
                    onCompletion: handleImport
                )
                .sheet(isPresented: $isDiagnosticsPresented) {
                    AIDiagnosticsView()
                }
                .alert(
                    "Something Went Wrong",
                    isPresented: Binding(
                        get: { errorMessage != nil },
                        set: { if !$0 { errorMessage = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if books.isEmpty {
            ContentUnavailableView {
                Label("No Books Yet", systemImage: "books.vertical")
            } description: {
                Text("Import an EPUB or PDF to start your library.")
            } actions: {
                Button("Import Book") { isImporterPresented = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                ForEach(books) { book in
                    NavigationLink {
                        ReadingView(book: book)
                    } label: {
                        BookRow(book: book)
                    }
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            delete([book])
                        }
                    }
                }
                .onDelete { offsets in
                    delete(offsets.map { books[$0] })
                }
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            let library = try Library(modelContext: modelContext)
            for url in try result.get() {
                try library.importBook(from: url)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ booksToDelete: [Book]) {
        do {
            let library = try Library(modelContext: modelContext)
            for book in booksToDelete {
                try library.deleteBook(book)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BookRow: View {
    let book: Book

    var body: some View {
        HStack(spacing: 12) {
            CoverThumbnail(data: book.coverThumbnailData)

            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(book.format.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                if book.progressFraction > 0 {
                    Text(
                        book.progressFraction,
                        format: .percent.precision(.fractionLength(0))
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CoverThumbnail: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = Self.platformImage(from: data) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "book.closed")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 40, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private static func platformImage(from data: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: data).map(Image.init(uiImage:))
        #else
        NSImage(data: data).map(Image.init(nsImage:))
        #endif
    }
}

#Preview {
    LibraryView()
        .modelContainer(try! AppStores.makeContainer(ephemeral: true))
}
