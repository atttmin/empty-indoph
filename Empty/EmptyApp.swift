//
//  EmptyApp.swift
//  Empty
//

import SwiftData
import SwiftUI

@main
struct EmptyApp: App {
    let container: ModelContainer

    init() {
        do {
            // Unit-test hosts get a throwaway container: tests must never
            // touch (or contend with a running app for) the real stores —
            // parallel test clones racing the production SQLite/CloudKit
            // locks crashed whole suites at 0.000s.
            let isTestHost = ProcessInfo.processInfo
                .environment["XCTestConfigurationFilePath"] != nil
            container = try AppStores.makeContainer(ephemeral: isTestHost)
        } catch {
            // No degraded mode without persistence — fail loudly at launch.
            fatalError("Failed to set up persistence: \(error)")
        }
    }

    var body: some Scene {
        #if os(macOS)
        // The Mac "深读工作台": hidden title bar so the sidebar runs the
        // full window height, traffic lights floating over it.
        WindowGroup {
            MacRootView()
        }
        .modelContainer(container)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 860)
        #else
        WindowGroup {
            IOSRootView()
        }
        .modelContainer(container)
        #endif
    }
}
