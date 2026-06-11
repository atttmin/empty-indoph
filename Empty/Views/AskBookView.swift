//
//  AskBookView.swift
//  Empty
//

import SwiftData
import SwiftUI

/// Ask-the-book: question in, grounded answer out — strictly from passages
/// the reader has already passed. Retrieval is database-filtered by
/// position (`ChunkRetriever`), so spoilers can't leak by construction;
/// the provider only ever sees already-read text.
struct AskBookView: View {
    let book: Book
    let position: ReadingPosition

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private enum Phase {
        case preparing
        case ready
        case thinking
        case answered(GroundedAnswer, sources: [Chunk])
        case failed(String)
        case nothingRead
    }

    @State private var phase: Phase = .preparing
    @State private var question = ""
    @State private var routeNote: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Ask about what you've read…",
                        text: $question,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .onSubmit(ask)

                    Button {
                        ask()
                    } label: {
                        if case .thinking = phase {
                            ProgressView()
                        } else {
                            Text("Ask")
                        }
                    }
                    .disabled(!canAsk)
                }

                switch phase {
                case .preparing:
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Preparing the book index…")
                                .foregroundStyle(.secondary)
                        }
                    }
                case .nothingRead:
                    Section {
                        Text("The answer pool is what you've already read — read a little first.")
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                case .answered(let answer, let sources):
                    Section("Answer") {
                        Text(answer.text)
                            .textSelection(.enabled)
                        if let routeNote {
                            Text(routeNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !sources.isEmpty {
                        Section("Sources (already read)") {
                            ForEach(sources, id: \.ordinal) { chunk in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(sourceTitle(for: chunk))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(String(chunk.text.prefix(120)))
                                        .font(.caption)
                                        .lineLimit(3)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                case .ready, .thinking:
                    EmptyView()
                }
            }
            .navigationTitle("Ask the Book")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { prepare() }
        }
    }

    private var canAsk: Bool {
        let hasQuestion = !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch phase {
        case .preparing, .thinking, .nothingRead:
            return false
        case .ready, .answered, .failed:
            return hasQuestion
        }
    }

    private func sourceTitle(for chunk: Chunk) -> String {
        if let title = chunk.chapter?.title, !title.isEmpty {
            return title
        }
        return "Chapter \(chunk.chapterIndex + 1)"
    }

    private func prepare() {
        do {
            let chunkCount = try BookIndexer(modelContext: modelContext).ensureChunks(for: book)
            if chunkCount == 0 {
                phase = .failed("This book has no extracted text to search.")
            } else if position.chapterIndex == 0 {
                phase = .nothingRead
            } else {
                phase = .ready
            }
            // Fire-and-forget semantic backfill; never blocks the sheet.
            let container = modelContext.container
            Task.detached {
                let indexer = SemanticIndexer(modelContainer: container)
                _ = try? await indexer.indexChunks(for: book.id)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func ask() {
        guard canAsk else { return }
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .thinking
        routeNote = nil
        Task {
            do {
                let chunks = try ChunkRetriever(modelContext: modelContext).retrieve(
                    question: asked,
                    bookID: book.id,
                    position: position
                )
                guard !chunks.isEmpty else {
                    phase = .nothingRead
                    return
                }
                let passages = chunks.map { GroundedPassage(id: $0.ordinal, text: $0.text) }
                let resolution = AIProviderSettings.load().resolveUsableService()
                let answer = try await resolution.service.answer(
                    question: asked,
                    groundedIn: passages
                )
                let cited = answer.citedPassageIDs.compactMap { id in
                    chunks.first { $0.ordinal == id }
                }
                routeNote = resolution.fellBack
                    ? "Generated with the \(resolution.route == .cloud ? "cloud provider" : "on-device model") (preferred route unavailable)."
                    : nil
                phase = .answered(answer, sources: cited.isEmpty ? chunks : cited)
            } catch is CancellationError {
                // Sheet dismissed mid-flight.
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
