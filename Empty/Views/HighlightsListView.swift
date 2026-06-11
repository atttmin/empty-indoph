//
//  HighlightsListView.swift
//  Empty
//

import SwiftData
import SwiftUI

/// All highlights of one book, in reading order. Tapping jumps the reader
/// to the highlight's chapter; swipe to delete.
struct HighlightsListView: View {
    let book: Book
    let onJump: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var highlights: [Highlight]

    init(book: Book, onJump: @escaping (Int) -> Void) {
        self.book = book
        self.onJump = onJump
        let bookID = book.id
        _highlights = Query(
            filter: #Predicate<Highlight> { $0.book?.id == bookID },
            sort: [
                SortDescriptor(\Highlight.chapterIndex),
                SortDescriptor(\Highlight.startUTF16),
            ]
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if highlights.isEmpty {
                    ContentUnavailableView {
                        Label("No Highlights", systemImage: "highlighter")
                    } description: {
                        Text("Select text while reading and tap Highlight.")
                    }
                } else {
                    List {
                        ForEach(highlights) { highlight in
                            Button {
                                onJump(highlight.chapterIndex)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(highlight.textSnapshot)
                                        .font(.callout)
                                        .lineLimit(3)
                                        .foregroundStyle(.primary)
                                    Text("Chapter \(highlight.chapterIndex + 1)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .onDelete { offsets in
                            delete(offsets.map { highlights[$0] })
                        }
                    }
                }
            }
            .navigationTitle("Highlights")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func delete(_ toDelete: [Highlight]) {
        for highlight in toDelete {
            modelContext.delete(highlight)
        }
        try? modelContext.save()
    }
}
