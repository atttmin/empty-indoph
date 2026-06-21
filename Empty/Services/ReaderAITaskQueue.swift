import Foundation
import SwiftData

struct ReaderAITask: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case heroRecap
    }

    var id: UUID = UUID()
    var kind: Kind
    var bookID: UUID
    var chapterIndex: Int
    var enqueuedAt: Date = Date()
}

@MainActor
enum ReaderAITaskQueue {
    private static let storageKey = "reader.ai.queue.v1"

    static func load(defaults: UserDefaults = .standard) -> [ReaderAITask] {
        guard let data = defaults.data(forKey: storageKey),
              let tasks = try? JSONDecoder().decode([ReaderAITask].self, from: data) else {
            return []
        }
        return tasks
    }

    static func save(_ tasks: [ReaderAITask], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func pendingCount(defaults: UserDefaults = .standard) -> Int {
        load(defaults: defaults).count
    }

    static func enqueueHeroRecap(
        bookID: UUID,
        chapterIndex: Int,
        defaults: UserDefaults = .standard
    ) {
        var tasks = load(defaults: defaults)
        guard !tasks.contains(where: {
            $0.kind == .heroRecap && $0.bookID == bookID && $0.chapterIndex == chapterIndex
        }) else { return }
        tasks.append(ReaderAITask(kind: .heroRecap, bookID: bookID, chapterIndex: chapterIndex))
        save(tasks, defaults: defaults)
    }

    static func removeHeroRecap(
        bookID: UUID,
        chapterIndex: Int,
        defaults: UserDefaults = .standard
    ) {
        let remaining = load(defaults: defaults).filter {
            !($0.kind == .heroRecap && $0.bookID == bookID && $0.chapterIndex == chapterIndex)
        }
        save(remaining, defaults: defaults)
    }

    static func processPending(
        modelContext: ModelContext,
        defaults: UserDefaults = .standard
    ) async -> Int {
        let tasks = load(defaults: defaults)
        guard !tasks.isEmpty else { return 0 }

        let resolution = AIProviderRegistry.load().resolveUsableService(feature: .recap)
        guard resolution.service.availability.isAvailable else { return 0 }

        var remaining: [ReaderAITask] = []
        var completed = 0

        for task in tasks {
            switch task.kind {
            case .heroRecap:
                do {
                    guard let book = try modelContext.fetch(
                        FetchDescriptor<Book>(predicate: #Predicate { $0.id == task.bookID })
                    ).first else {
                        continue
                    }

                    let recap = try await RecapBuilder(
                        modelContext: modelContext,
                        summarize: { text, focus in
                            try await resolution.service.summarize(text, focus: focus)
                        }
                    ).recap(
                        for: book,
                        before: ReadingPosition(chapterIndex: task.chapterIndex, utf16Offset: 0)
                    )

                    let trimmed = recap.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        book.cachedHeroRecap = trimmed
                        book.cachedHeroRecapChapterIndex = task.chapterIndex
                        try? modelContext.save()
                    }
                    completed += 1
                } catch {
                    remaining.append(task)
                }
            }
        }

        save(remaining, defaults: defaults)
        return completed
    }
}
