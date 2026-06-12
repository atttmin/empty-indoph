//
//  ServerBackgroundSyncPlannerTests.swift
//  EmptyTests
//

import Foundation
import Testing
@testable import Empty

struct ServerBackgroundSyncPlannerTests {
    @Test func returnsNilWhenAutoSyncDisabled() {
        let plan = ServerBackgroundSyncPlanner.makePlan(
            isEphemeral: false,
            autoSyncEnabled: false,
            isContractReady: true,
            retryAt: nil,
            lastAutoSyncAt: nil,
            intervalSeconds: 120,
            now: Date(timeIntervalSince1970: 100)
        )
        #expect(plan == nil)
    }

    @Test func retryPlanWinsOverInterval() {
        let now = Date(timeIntervalSince1970: 100)
        let retryAt = now.addingTimeInterval(45)
        let plan = ServerBackgroundSyncPlanner.makePlan(
            isEphemeral: false,
            autoSyncEnabled: true,
            isContractReady: true,
            retryAt: retryAt,
            lastAutoSyncAt: now.addingTimeInterval(-300),
            intervalSeconds: 120,
            now: now
        )
        #expect(plan?.trigger == .retry)
        #expect(plan?.earliestBeginDate == retryAt)
    }

    @Test func intervalPlanUsesLastSyncAnchor() {
        let now = Date(timeIntervalSince1970: 200)
        let lastSync = Date(timeIntervalSince1970: 150)
        let plan = ServerBackgroundSyncPlanner.makePlan(
            isEphemeral: false,
            autoSyncEnabled: true,
            isContractReady: true,
            retryAt: nil,
            lastAutoSyncAt: lastSync,
            intervalSeconds: 120,
            now: now
        )
        #expect(plan?.trigger == .interval)
        #expect(plan?.earliestBeginDate == lastSync.addingTimeInterval(120))
    }

    @Test func intervalPlanNeverSchedulesInThePast() {
        let now = Date(timeIntervalSince1970: 500)
        let lastSync = Date(timeIntervalSince1970: 100)
        let plan = ServerBackgroundSyncPlanner.makePlan(
            isEphemeral: false,
            autoSyncEnabled: true,
            isContractReady: true,
            retryAt: nil,
            lastAutoSyncAt: lastSync,
            intervalSeconds: 60,
            now: now
        )
        #expect(plan?.trigger == .interval)
        #expect(plan?.earliestBeginDate == now)
    }
}
