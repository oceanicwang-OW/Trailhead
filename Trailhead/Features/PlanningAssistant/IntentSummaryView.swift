//  IntentSummaryView.swift
//  用户与系统共享的结构化需求摘要（PDR DCP-03）。

import SwiftUI
import TrailheadCore

struct IntentSummaryView: View {
    let intent: TripIntent
    let ambiguities: [IntentAmbiguity]
    var onRemovePOI: ((UUID) -> Void)?
    var onSetPOIRequirement: ((POIRequirement, UUID) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryHeader
                section("基本信息", rows: basicRows)
                if !intent.poiConstraints.isEmpty { poiSection }
                section("偏好与节奏", rows: preferenceRows)
                section("交通与步行", rows: mobilityRows)
                if !ambiguities.isEmpty { ambiguitySection }
            }
            .padding(16)
        }
        .background(Palette.groupedBG)
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("需求摘要").font(Typo.display(18))
            Text("已确认 \(confirmedCount) 项\(ambiguities.isEmpty ? "" : " · \(ambiguities.count) 项待处理")")
                .font(Typo.caption).foregroundStyle(Palette.textSecondary)
        }
    }

    private var basicRows: [(String, String, String)] {
        [("mappin.and.ellipse", "目的地", intent.destination.name),
         ("calendar", "行程", "\(intent.days) 天"),
         ("person.2", "同行", partyText),
         ("clock", "每日时间", dayWindowText)]
    }

    private var preferenceRows: [(String, String, String)] {
        [("figure.walk", "节奏", intent.preferences.pace.display),
         ("heart", "兴趣", intent.preferences.tags.isEmpty ? "未指定" : intent.preferences.tags.joined(separator: "、")),
         ("fork.knife", "菜系", intent.preferences.cuisines.isEmpty ? "不限" : intent.preferences.cuisines.joined(separator: "、")),
         ("yensign.circle", "预算", "¥\(intent.preferences.budgetPerDay)/天")]
    }

    private var mobilityRows: [(String, String, String)] {
        let walk = intent.mobility.maxWalkingMinutesPerSegment.map { "单段最多 \($0) 分钟" } ?? "使用系统默认"
        let modes = intent.transport.allowedModes.sorted { $0.rawValue < $1.rawValue }.map(\.display).joined(separator: "、")
        return [("figure.walk", "步行", walk),
                ("tram", "交通", modes),
                ("accessibility", "无障碍", intent.mobility.accessibilityRequired ? "需要" : "未要求")]
    }

    private var poiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("地点要求").font(Typo.sectionHdr).foregroundStyle(Palette.textTertiary)
            ForEach(intent.poiConstraints) { constraint in
                HStack(spacing: 9) {
                    Image(systemName: constraint.resolvedPOIID == nil ? "questionmark.circle" : icon(constraint.requirement))
                        .foregroundStyle(color(constraint))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(constraint.resolvedName ?? constraint.mention).font(Typo.body)
                        Text(requirementText(constraint)).font(Typo.caption2).foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    if onRemovePOI != nil || onSetPOIRequirement != nil {
                        Menu {
                            if let onSetPOIRequirement {
                                Button("设为必去") { onSetPOIRequirement(.mustVisit, constraint.id) }
                                Button("设为优先") { onSetPOIRequirement(.preferVisit, constraint.id) }
                                Button("设为不要去") { onSetPOIRequirement(.avoidVisit, constraint.id) }
                            }
                            if let onRemovePOI {
                                Divider()
                                Button("删除这项要求", role: .destructive) { onRemovePOI(constraint.id) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(Palette.textSecondary)
                        }
                        .accessibilityLabel("编辑\(constraint.resolvedName ?? constraint.mention)的要求")
                    }
                }
                .padding(10)
                .background(Palette.cardBG, in: RoundedRectangle(cornerRadius: Metric.fieldRadius))
            }
        }
    }

    private var ambiguitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("待确认").font(Typo.sectionHdr).foregroundStyle(Palette.red)
            ForEach(ambiguities) { ambiguity in
                Label(ambiguity.message, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.caption).foregroundStyle(Palette.red)
            }
        }
    }

    private func section(_ title: String, rows: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Typo.sectionHdr).foregroundStyle(Palette.textTertiary)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 9) {
                        Image(systemName: row.0).foregroundStyle(Palette.green).frame(width: 18)
                        Text(row.1).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Text(row.2).font(Typo.caption).foregroundStyle(Palette.textPrimary).multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, 9).padding(.horizontal, 10)
                    if index < rows.count - 1 { Divider().padding(.leading, 37) }
                }
            }
            .background(Palette.cardBG, in: RoundedRectangle(cornerRadius: Metric.fieldRadius))
        }
    }

    private var confirmedCount: Int { 4 + intent.poiConstraints.filter { $0.resolvedPOIID != nil }.count }
    private var partyText: String {
        var parts = ["成人\(intent.party.adults)"]
        if intent.party.children > 0 { parts.append("儿童\(intent.party.children)") }
        if intent.party.seniors > 0 { parts.append("老人\(intent.party.seniors)") }
        return parts.joined(separator: " · ")
    }
    private var dayWindowText: String {
        guard let window = intent.dailyConstraints.first else { return "09:00–20:00" }
        return "\(clock(window.startMinute))–\(clock(window.endMinute))"
    }
    private func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
    private func icon(_ requirement: POIRequirement) -> String {
        switch requirement {
        case .mustVisit: return "pin.fill"
        case .preferVisit: return "star.fill"
        case .avoidVisit: return "nosign"
        }
    }
    private func color(_ constraint: POIConstraint) -> Color {
        if constraint.resolvedPOIID == nil { return Palette.orange }
        return constraint.requirement == .avoidVisit ? Palette.red : Palette.green
    }
    private func requirementText(_ constraint: POIConstraint) -> String {
        let status = constraint.resolvedPOIID == nil ? "待确认" : "已确认"
        switch constraint.requirement {
        case .mustVisit: return "必去 · \(status)"
        case .preferVisit: return "优先 · \(status)"
        case .avoidVisit: return "不要去 · \(status)"
        }
    }
}
