import Foundation
import Testing
@testable import Empty

@MainActor
struct ReaderAITaskQueueTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "reader-ai-queue-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func dedupesHeroRecapJobs() {
        let defaults = makeDefaults()
        let bookID = UUID()

        ReaderAITaskQueue.enqueueHeroRecap(bookID: bookID, chapterIndex: 2, defaults: defaults)
        ReaderAITaskQueue.enqueueHeroRecap(bookID: bookID, chapterIndex: 2, defaults: defaults)
        ReaderAITaskQueue.enqueueHeroRecap(bookID: bookID, chapterIndex: 3, defaults: defaults)

        let tasks = ReaderAITaskQueue.load(defaults: defaults)
        #expect(tasks.count == 2)
        #expect(tasks.filter { $0.chapterIndex == 2 }.count == 1)
        #expect(ReaderAITaskQueue.pendingCount(defaults: defaults) == 2)
    }

    @Test func removesMatchingHeroRecapJobsOnly() {
        let defaults = makeDefaults()
        let bookA = UUID()
        let bookB = UUID()

        ReaderAITaskQueue.enqueueHeroRecap(bookID: bookA, chapterIndex: 1, defaults: defaults)
        ReaderAITaskQueue.enqueueHeroRecap(bookID: bookA, chapterIndex: 2, defaults: defaults)
        ReaderAITaskQueue.enqueueHeroRecap(bookID: bookB, chapterIndex: 1, defaults: defaults)
        ReaderAITaskQueue.removeHeroRecap(bookID: bookA, chapterIndex: 1, defaults: defaults)

        let tasks = ReaderAITaskQueue.load(defaults: defaults)
        #expect(tasks.count == 2)
        #expect(!tasks.contains { $0.bookID == bookA && $0.chapterIndex == 1 })
        #expect(tasks.contains { $0.bookID == bookA && $0.chapterIndex == 2 })
        #expect(tasks.contains { $0.bookID == bookB && $0.chapterIndex == 1 })
    }
}
