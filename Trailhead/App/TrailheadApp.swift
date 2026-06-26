//  TrailheadApp.swift
//  Entry point. Sets up the SwiftData container and seeds the 关西环游 sample
//  on first launch so the app renders like the handoff design immediately.

import SwiftData
import SwiftUI
import TrailheadCore

@main
struct TrailheadApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Trip.self, DayPlan.self, PlanItem.self, CachedPOI.self)
            SampleData.seedIfNeeded(container.mainContext)
        } catch {
            fatalError("Failed to set up SwiftData: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        #endif
    }
}
