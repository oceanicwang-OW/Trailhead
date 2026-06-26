//  TimelineComponents.swift
//  The "route timeline" signature: a 3pt green spine threading POI nodes,
//  with transport segments between them. Geometry mirrors Trailhead.dc.html.

import SwiftUI

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
            if let note = item.note, !note.isEmpty {
                Text(stayLine(note))
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

    private func stayLine(_ note: String) -> String {
        if let stay = item.stayLabel, !stay.isEmpty { return "\(note) · \(stay)" }
        return note
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
            Text(item.transitLine)
                .font(Typo.caption2)
                .foregroundStyle(Palette.textMuted)
                .padding(.vertical, 4)
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
        case .none:  return "arrow.down"
        }
    }
}
