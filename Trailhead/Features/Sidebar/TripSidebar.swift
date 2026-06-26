//  TripSidebar.swift
//  Left column: the trip library, grouped into 即将出行 / 草稿 / 历史,
//  matching the macOS sidebar in the mockup.

import SwiftData
import SwiftUI
import TrailheadCore

struct TripSidebar: View {
    let trips: [Trip]
    @Binding var selection: Trip?
    var onNewTrip: () -> Void = {}

    private var upcoming: [Trip] { trips.filter { $0.status == .ready || $0.status == .generating } }
    private var drafts:   [Trip] { trips.filter { $0.status == .draft } }
    private var history:  [Trip] { trips.filter { $0.status == .done } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                section("即将出行", upcoming)
                if !drafts.isEmpty { section("草稿", drafts) }
                if !history.isEmpty { section("历史", history, dimmed: true) }
            }
            .padding(.horizontal, 12).padding(.vertical, 14)
        }
        .background(Palette.sidebarBG)
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Trip], dimmed: Bool = false) -> some View {
        Text(title.uppercased())
            .font(Typo.sectionHdr)
            .tracking(0.5)
            .foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, 8).padding(.top, title == "即将出行" ? 0 : 16).padding(.bottom, 8)
        ForEach(items, id: \.id) { trip in
            row(trip).opacity(dimmed ? 0.62 : 1)
                .contentShape(Rectangle())
                .onTapGesture { selection = trip }
        }
    }

    private func row(_ trip: Trip) -> some View {
        let on = selection?.id == trip.id
        return HStack(spacing: 11) {
            swatch(trip)
            VStack(alignment: .leading, spacing: 1) {
                Text(trip.city)
                    .font(.system(size: 13.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(Palette.textPrimary)
                Text(dateRange(trip))
                    .font(.system(size: 11))
                    .foregroundStyle(trip.status == .draft ? Palette.textTertiary : Palette.textSecondary)
            }
            Spacer(minLength: 0)
            if trip.status == .ready || trip.status == .generating {
                Text("\(trip.dayCount)天")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(on ? Palette.green : Palette.textMuted)
                    .padding(.vertical, 2).padding(.horizontal, 6)
                    .background((on ? Palette.green : Palette.textMuted).opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 8)
        .background(on ? Palette.green.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 9))
    }

    private func swatch(_ trip: Trip) -> some View {
        let colors = SampleData.swatches[trip.accentSeed % SampleData.swatches.count]
        return RoundedRectangle(cornerRadius: 8)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 34, height: 34)
            .overlay(
                Image(systemName: icon(for: trip))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            )
    }

    private func icon(for trip: Trip) -> String {
        switch trip.accentSeed % 5 {
        case 0: return "mappin.and.ellipse"
        case 1: return "chart.line.uptrend.xyaxis"
        case 2: return "paperplane.fill"
        case 3: return "square.grid.2x2"
        default: return "globe.asia.australia"
        }
    }

    private func dateRange(_ trip: Trip) -> String {
        if trip.status == .draft { return trip.subtitle }
        if trip.status == .done { return trip.subtitle }
        let f = DateFormatter(); f.dateFormat = "M/d"
        let end = Calendar.current.date(byAdding: .day, value: trip.nights, to: trip.startDate) ?? trip.startDate
        return "\(f.string(from: trip.startDate)) – \(f.string(from: end))"
    }
}
