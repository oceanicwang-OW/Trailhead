//  TimelineComponents.swift
//  The "route timeline" signature: a 3pt green spine threading POI nodes,
//  with transport segments between them. Geometry mirrors Trailhead.dc.html.

import SwiftUI
import TrailheadCore

// MARK: - Spine gutter

/// Draws the continuous vertical spine for one row, with a node overlaid.
/// Stacking rows with no gaps makes the spine read as one continuous line.
private struct SpineGutter<Node: View>: View {
    var width: CGFloat
    var spineColor: Color = Palette.green
    /// when true the spine below the node switches to a dashed purple (lodging → next day)
    var dashedPurpleBelow: Bool = false
    @ViewBuilder var node: () -> Node

    var body: some View {
        ZStack(alignment: .top) {
            // solid spine
            Rectangle()
                .fill(spineColor)
                .frame(width: Metric.spineWidth)
                .frame(maxHeight: .infinity)
                .offset(x: spineOffset)
            node()
        }
        .frame(width: width)
    }
    private var spineOffset: CGFloat {
        // center the 3pt spine on x≈30 within a 64pt gutter (≈ -2 from center)
        (Metric.spineX + Metric.spineWidth / 2) - width / 2
    }
}

// MARK: - Nodes

private struct POINode: View {
    var color: Color
    var selected: Bool
    var body: some View {
        ZStack {
            if selected {
                Circle().fill(Palette.blue)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle().fill(Palette.canvasBG).frame(width: 26, height: 26)
                    )
                    .overlay(
                        Circle().stroke(Palette.blue.opacity(0.35), lineWidth: 2)
                            .frame(width: 26, height: 26)
                    )
            } else {
                Circle().fill(color)
                    .frame(width: 16, height: 16)
                    .background(
                        Circle().fill(Palette.canvasBG).frame(width: 22, height: 22)
                    )
            }
        }
        .padding(.top, 10)
    }
}

private struct TransitNode: View {
    var systemImage: String
    var body: some View {
        Circle()
            .fill(Palette.cardBG)
            .frame(width: 27, height: 27)
            .overlay(Circle().stroke(Palette.cardStroke, lineWidth: 1.5))
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.slate)
            )
    }
}

// MARK: - POI card

struct POICard: View {
    let item: PlanItem
    var selected: Bool = false
    var gutter: CGFloat = Metric.gutter

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            SpineGutter(width: gutter,
                        dashedPurpleBelow: item.kind == .lodging) {
                POINode(color: item.kind.color, selected: selected)
            }
            card
                .padding(.top, 4)
                .padding(.bottom, 14)
                .padding(.trailing, 18)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(item.plannedTime ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Palette.blue : Palette.textMuted)
                Spacer()
                Text("\(item.kind.label) · \(item.subtype ?? "")")
                    .font(Typo.tag)
                    .foregroundStyle(item.kind.color)
                    .padding(.vertical, 2).padding(.horizontal, 7)
                    .background(item.kind.color.opacity(0.12), in: Capsule())
            }
            Text(item.name ?? "")
                .font(Typo.cardTitle)
                .foregroundStyle(Palette.textPrimary)
            if item.visitStatus != .planned {
                Label(statusText, systemImage: statusIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.visitStatus == .completed ? Palette.green : Palette.textMuted)
            }
            if let range = durationRange {
                Text(range)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.green)
            }
            if let note = item.note, !note.isEmpty {
                Text(note)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.vertical, 11).padding(.horizontal, 13)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Metric.cardRadius)
                .stroke(selected ? Palette.blue.opacity(0.5)
                                 : (item.kind == .lodging ? Palette.purple.opacity(0.28)
                                                          : Palette.cardStroke),
                        lineWidth: selected ? 1 : 0.5)
        )
        .shadow(color: selected ? Palette.blue.opacity(0.28) : .black.opacity(0.05),
                radius: selected ? 7 : 1.5, y: selected ? 4 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Metric.cardRadius)
            .fill(item.kind == .lodging
                  ? Color(light: Color(hex: 0xFAF8FF), dark: Palette.cardBG)
                  : Palette.cardBG)
    }

    private var durationRange: String? {
        guard let minimum = item.minimumStayMinutes,
              let comfortable = item.comfortableStayMinutes else { return item.stayLabel }
        func text(_ minutes: Int) -> String {
            if minutes < 60 { return "\(minutes) 分钟" }
            let hours = Double(minutes) / 60
            return hours == hours.rounded()
                ? "\(Int(hours)) 小时"
                : String(format: "%.1f 小时", hours)
        }
        let reserved = item.plannedStayMinutes.map { " · 当前预留 \(text($0))" } ?? ""
        return "建议游玩 \(text(minimum))～\(text(comfortable))\(reserved)"
    }

    private var statusText: String {
        switch item.visitStatus {
        case .planned: return "未开始"
        case .visiting: return "游玩中"
        case .completed: return "已完成"
        case .skipped: return "已跳过"
        }
    }

    private var statusIcon: String {
        switch item.visitStatus {
        case .planned: return "clock"
        case .visiting: return "figure.walk"
        case .completed: return "checkmark.circle.fill"
        case .skipped: return "forward.end.fill"
        }
    }
}

// MARK: - Transport row

struct TransportRow: View {
    let item: PlanItem
    var gutter: CGFloat = Metric.gutter

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            SpineGutter(width: gutter) {
                TransitNode(systemImage: icon)
                    .frame(maxHeight: .infinity)        // vertically centered on spine
            }
            HStack(spacing: 6) {
                Text(item.transitLine)
                    .font(Typo.caption2)
                    .foregroundStyle(Palette.textMuted)
                if item.transitReliability == .estimated {
                    Text("估算 · 待校准")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.transitReliability == .estimated
                ? "\(item.transitLine)，估算，待联网校准"
                : item.transitLine)
            Spacer(minLength: 0)
        }
        .padding(.top, -6)   // tuck under the previous card (mockup uses margin-top:-6)
    }

    private var icon: String {
        switch item.transitMode {
        case .walk:  return "figure.walk"
        case .metro: return "tram.fill"
        case .bus:   return "bus.fill"
        case .taxi:  return "car.fill"
        case .drive: return "car.fill"
        case .train: return "train.side.front.car"
        case .ferry: return "ferry.fill"
        case .none:  return "arrow.down"
        }
    }
}

// MARK: - Replacement candidates

struct ReplacementCandidateSheet: View {
    let candidates: [POICandidate]
    let loading: Bool
    let error: String?
    let applyingReplacementItemID: UUID?
    let onClose: () -> Void
    let onRetry: () -> Void
    let onApply: (POICandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
        }
        .padding(18)
        .frame(minWidth: 360, idealWidth: 420, minHeight: 300)
    }

    private var header: some View {
        HStack {
            Text("替换地点")
                .font(Typo.display(18, .bold))
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Button("关闭", action: onClose)
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textMuted)
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if let error {
            errorView(error)
        } else if candidates.isEmpty {
            Text("没有可替换的候选")
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            candidateList
        }
    }

    private var candidateList: some View {
        List(candidates) { candidate in
            Button {
                onApply(candidate)
            } label: {
                candidateRow(candidate)
            }
            .buttonStyle(.plain)
            .disabled(applyingReplacementItemID != nil)
        }
        .listStyle(.plain)
        .frame(minHeight: 240)
    }

    private func errorView(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(error)
                .font(.system(size: 13))
                .foregroundStyle(.red)
            Button("重试", action: onRetry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func candidateRow(_ candidate: POICandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(candidate.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text(candidateMetadata(candidate))
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, 6)
    }

    private func candidateMetadata(_ candidate: POICandidate) -> String {
        var parts = [candidate.subtype.isEmpty ? candidate.kind.label : candidate.subtype]
        if let rating = candidate.rating { parts.append(String(format: "%.1f 分", rating)) }
        if let avgPrice = candidate.avgPrice { parts.append("¥\(avgPrice)") }
        if let openHours = candidate.openHours, !openHours.isEmpty { parts.append(openHours) }
        return parts.joined(separator: " · ")
    }
}
