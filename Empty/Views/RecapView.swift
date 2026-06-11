//
//  RecapView.swift
//  Empty
//

import SwiftData
import SwiftUI

/// Result cache for one recap, keyed by the position it covered; the reader
/// keeps it across sheet openings and it invalidates by position mismatch.
nonisolated struct RecapCache: Equatable {
    var position: ReadingPosition
    var text: String
}

/// "Previously on…" — summarizes only the chapters BEHIND the reader's
/// current position (spoiler-safe by construction) through whichever AI
/// provider is configured, on-device or cloud.
struct RecapView: View {
    let book: Book
    let position: ReadingPosition
    @Binding var cache: RecapCache?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private enum Phase {
        case loading
        case nothingRead
        case failed(String)
        case ready(String)
    }

    @State private var phase: Phase = .loading
    @State private var routeNote: String?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Summarizing what you've read…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                case .nothingRead:
                    ContentUnavailableView {
                        Label("Nothing to Recap", systemImage: "book")
                    } description: {
                        Text("The recap covers chapters behind your current position. Read a little first.")
                    }
                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await generate() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                case .ready(let recap):
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(recap)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let routeNote {
                                Text(routeNote)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Previously On")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await generateIfNeeded() }
        }
    }

    private func generateIfNeeded() async {
        if let cache, cache.position == position {
            phase = .ready(cache.text)
            return
        }
        await generate()
    }

    private func generate() async {
        phase = .loading
        do {
            let resolution = AIProviderSettings.load().resolveUsableService()
            let service = resolution.service
            let builder = RecapBuilder(
                modelContext: modelContext,
                summarize: { text, focus in
                    try await service.summarize(text, focus: focus)
                }
            )
            let recap = try await builder.recap(for: book, before: position)
            routeNote = resolution.fellBack
                ? Self.fallbackNote(for: resolution.route)
                : nil
            cache = RecapCache(position: position, text: recap)
            phase = .ready(recap)
        } catch is CancellationError {
            // Sheet dismissed mid-flight; nothing to show.
        } catch AIServiceError.emptyInput {
            phase = .nothingRead
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private static func fallbackNote(for route: AIProviderMode) -> String {
        switch route {
        case .cloud:
            "On-device model unavailable — generated with the cloud provider."
        case .onDevice:
            "Cloud provider unavailable — generated with the on-device model."
        }
    }
}
