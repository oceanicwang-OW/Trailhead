//  RootView.swift
//  Adaptive shell: NavigationSplitView (three columns) on macOS,
//  TabView + NavigationStack on iOS — matching the two device mockups.

import SwiftData
import SwiftUI
import TrailheadCore

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Trip.createdAt, order: .reverse) private var trips: [Trip]

    @State private var selection: Trip?
    @State private var dayIndex = 0
    @State private var selectedItemID: UUID?
    @State private var showNewTrip = false

    var body: some View {
        #if os(macOS)
        macOS
        #else
        iOS
        #endif
    }

    private var current: Trip? { selection ?? trips.first }

    // MARK: macOS — three columns

    #if os(macOS)
    private var macOS: some View {
        NavigationSplitView {
            TripSidebar(trips: trips, selection: bindingSelection) { showNewTrip = true }
                .navigationSplitViewColumnWidth(min: 240, ideal: Metric.sidebarWidth, max: 300)
        } content: {
            Group {
                if let trip = current {
                    RouteTimelineView(trip: trip,
                                      selectedDayIndex: $dayIndex,
                                      selectedItemID: $selectedItemID)
                        .navigationTitle(trip.city)
                        .navigationSubtitle(trip.subtitle)
                } else { emptyState }
            }
            .navigationSplitViewColumnWidth(min: 380, ideal: Metric.timelineWidth, max: 520)
            .toolbar {
                ToolbarItem { Button { showNewTrip = true } label: { Image(systemName: "plus") } }
            }
        } detail: {
            if let trip = current {
                MapInspector(trip: trip, dayIndex: dayIndex, selectedItemID: $selectedItemID)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380)
            } else { Color(Palette.canvasBG) }
        }
        .sheet(isPresented: $showNewTrip) { NewTripView() }
    }
    #endif

    // MARK: iOS — tabs

    #if os(iOS)
    private var iOS: some View {
        TabView {
            NavigationStack {
                Group {
                    if let trip = current {
                        RouteTimelineView(trip: trip,
                                          selectedDayIndex: $dayIndex,
                                          selectedItemID: $selectedItemID,
                                          gutter: Metric.gutterCompact)
                            .navigationTitle("\(trip.city) · D\(dayIndex + 1)")
                            .navigationBarTitleDisplayMode(.inline)
                    } else { emptyState }
                }
            }
            .tabItem { Label("行程", systemImage: "list.bullet.indent") }

            NavigationStack { NewTripView() }
                .tabItem { Label("新建", systemImage: "plus.circle") }

            NavigationStack { SettingsView().navigationTitle("设置") }
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(Palette.green)
    }
    #endif

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "map").font(.system(size: 40)).foregroundStyle(Palette.textTertiary)
            Text("还没有行程").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.textPrimary)
            Text("从上方新建一个，自动生成路线时间线").font(Typo.caption).foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvasBG)
    }

    private var bindingSelection: Binding<Trip?> {
        Binding(get: { current }, set: { selection = $0; dayIndex = 0; selectedItemID = nil })
    }
}
