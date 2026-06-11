import Foundation

@MainActor
final class SelectionChangeDebouncer {
    private let delay: Duration
    private var task: Task<Void, Never>?

    init(delay: Duration = .milliseconds(180)) {
        self.delay = delay
    }

    func submit(
        _ selection: Range<Int>?,
        deliver: @escaping (Range<Int>?) -> Void
    ) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            deliver(selection)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
