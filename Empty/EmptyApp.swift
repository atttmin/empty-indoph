//
//  EmptyApp.swift
//  Empty
//

import SwiftData
import SwiftUI

@main
struct EmptyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appSession = AppSession()

    var body: some Scene {
        #if os(macOS)
        // The Mac "深读工作台": hidden title bar so the sidebar runs the
        // full window height, traffic lights floating over it.
        WindowGroup {
            MacRootView()
                .id(appSession.containerRevision)
                .environmentObject(appSession)
        }
        .modelContainer(appSession.container)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 860)
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            appSession.handleScenePhase(newPhase)
        }
        #else
        WindowGroup {
            IOSRootView()
                .id(appSession.containerRevision)
                .environmentObject(appSession)
        }
        .modelContainer(appSession.container)
        .backgroundTask(.appRefresh(ServerBackgroundSyncPlanner.taskIdentifier)) {
            await appSession.runScheduledBackgroundServerSync()
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            appSession.handleScenePhase(newPhase)
        }
        #endif
    }
}
