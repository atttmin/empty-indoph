import Testing
@testable import Empty

@MainActor
struct SelectionChangeDebouncerTests {
    @Test func coalescesRapidSelectionUpdates() async throws {
        let debouncer = SelectionChangeDebouncer(delay: .milliseconds(20))
        var delivered: [Range<Int>?] = []

        debouncer.submit(0..<2) { delivered.append($0) }
        debouncer.submit(3..<6) { delivered.append($0) }

        try await Task.sleep(for: .milliseconds(60))

        #expect(delivered.count == 1)
        #expect(delivered.first! == (3..<6))
    }

    @Test func cancelPreventsPendingDelivery() async throws {
        let debouncer = SelectionChangeDebouncer(delay: .milliseconds(20))
        var delivered: [Range<Int>?] = []

        debouncer.submit(1..<4) { delivered.append($0) }
        debouncer.cancel()

        try await Task.sleep(for: .milliseconds(60))

        #expect(delivered.isEmpty)
    }
}
