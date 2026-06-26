//  RouteTimelineView.swift
//  Center column of the macOS main screen (and the iOS trip page body):
//  a day header, day-tabs, and the scrolling route timeline for the selected day.

import SwiftUI
import TrailheadCore

struct RouteTimelineView: View {
    let trip: Trip
    @Binding var selectedDayIndex: Int
    @Binding var selectedItemID: UUID?
    var gutter: CGFloat = Metric.gutter
    var showDayTabs: Bool = true

    private var day: DayPlan? {
        trip.sortedDays.first { $0.dayIndex == selectedDayIndex } ?? trip.sortedDays.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if showDayTabs { dayTabs.padding(.horizontal, 18).padding(.bottom, 6) }
                if let day { timeline(for: day) }
            }
            .padding(.bottom, 28)
        }
        .background(Palette.canvasBG)
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("Day \(selectedDayIndex + 1)")
                    .font(Typo.display(19, .bold))
                    .foregroundStyle(Palette.textPrimary)
                Text(daySubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
    }

    private var daySubtitle: String {
        guard let day else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEEE · M/d"
        return "\(f.string(from: day.date)) · \(day.cityLabel)"
    }

    private var dayTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(trip.sortedDays, id: \.id) { d in
                    let on = d.dayIndex == selectedDayIndex
                    Text("D\(d.dayIndex + 1)")
                        .font(.system(size: 13, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? .white : Palette.textMuted)
                        .frame(width: 46, height: 30)
                        .background(on ? Palette.green : Palette.fieldBG,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { withAnimation(.snappy) { selectedDayIndex = d.dayIndex } }
                }
                editButton
            }
        }
    }

    private var editButton: some View {
        HStack(spacing: 5) {
            Image(systemName: "pencil").font(.system(size: 11, weight: .semibold))
            Text("编辑").font(.system(size: 12.5))
        }
        .foregroundStyle(Palette.textMuted)
        .frame(height: 30).padding(.horizontal, 12)
        .background(Palette.fieldBG, in: RoundedRectangle(cornerRadius: 8))
    }

    private func timeline(for day: DayPlan) -> some View {
        VStack(spacing: 0) {
            ForEach(day.sortedItems, id: \.id) { item in
                if item.kind == .transit {
                    TransportRow(item: item, gutter: gutter)
                } else {
                    POICard(item: item,
                            selected: selectedItemID == item.id,
                            gutter: gutter)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedItemID = item.id }
                }
            }
        }
        .padding(.top, 4)
    }
}
