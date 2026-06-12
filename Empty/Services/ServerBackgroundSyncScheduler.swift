//
//  ServerBackgroundSyncScheduler.swift
//  Empty
//

import Foundation

#if os(iOS)
import BackgroundTasks
#endif

nonisolated enum ServerBackgroundSyncTrigger: String, Codable, Equatable, Sendable {
    case interval
    case retry
}

nonisolated struct ServerBackgroundSyncPlan: Equatable, Sendable {
    var earliestBeginDate: Date
    var trigger: ServerBackgroundSyncTrigger
}

nonisolated enum ServerBackgroundSyncPlanner {
    static let taskIdentifier = "davirian.Empty.server-sync"

    static func makePlan(
        isEphemeral: Bool,
        autoSyncEnabled: Bool,
        isContractReady: Bool,
        retryAt: Date?,
        lastAutoSyncAt: Date?,
        intervalSeconds: Int,
        now: Date = Date()
    ) -> ServerBackgroundSyncPlan? {
        guard !isEphemeral, autoSyncEnabled, isContractReady else {
            return nil
        }
        if let retryAt, retryAt > now {
            return ServerBackgroundSyncPlan(earliestBeginDate: retryAt, trigger: .retry)
        }

        let normalizedInterval = max(intervalSeconds, 30)
        let base = lastAutoSyncAt ?? now
        let scheduledAt = max(now, base.addingTimeInterval(TimeInterval(normalizedInterval)))
        return ServerBackgroundSyncPlan(earliestBeginDate: scheduledAt, trigger: .interval)
    }
}

final class ServerBackgroundSyncScheduler {
    private var backgroundAction: (@Sendable () async -> Void)?

    #if os(macOS)
    private var activityScheduler: NSBackgroundActivityScheduler?
    #endif

    func installAction(_ action: @escaping @Sendable () async -> Void) {
        backgroundAction = action
    }

    func schedule(_ plan: ServerBackgroundSyncPlan) {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: ServerBackgroundSyncPlanner.taskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: ServerBackgroundSyncPlanner.taskIdentifier)
        request.earliestBeginDate = plan.earliestBeginDate
        try? BGTaskScheduler.shared.submit(request)
        #elseif os(macOS)
        activityScheduler?.invalidate()
        let scheduler = NSBackgroundActivityScheduler(identifier: ServerBackgroundSyncPlanner.taskIdentifier)
        scheduler.repeats = false
        scheduler.interval = max(plan.earliestBeginDate.timeIntervalSinceNow, 60)
        scheduler.tolerance = min(max(scheduler.interval * 0.25, 15), 300)
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            guard let self else {
                completion(.finished)
                return
            }
            Task {
                await self.runScheduledActionIfAvailable()
                completion(.finished)
            }
        }
        activityScheduler = scheduler
        #endif
    }

    func cancel() {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: ServerBackgroundSyncPlanner.taskIdentifier)
        #elseif os(macOS)
        activityScheduler?.invalidate()
        activityScheduler = nil
        #endif
    }

    func runScheduledActionIfAvailable() async {
        guard let backgroundAction else { return }
        await backgroundAction()
    }
}
