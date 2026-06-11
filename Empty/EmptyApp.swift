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
            container = try AppStores.makeContainer()
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
            LibraryView()
        }
        .modelContainer(container)
        #endif
    }
}
