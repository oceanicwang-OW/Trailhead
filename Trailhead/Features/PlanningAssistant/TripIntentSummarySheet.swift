//  TripIntentSummarySheet.swift
//  已生成行程的需求快照与重新规划入口（PDR DCP-08）。

import SwiftUI
import TrailheadCore

struct IntentSummaryPresentation: Identifiable {
    let id = UUID()
    let intent: TripIntent
}

extension RouteTimelineView {
    func planningRequirementButton(_ intent: TripIntent) -> some View {
        let count = intent.poiConstraints.count + intent.fieldStates.count
        return Button {
            intentSummaryPresentation = IntentSummaryPresentation(intent: intent)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "checklist")
                Text("已按 \(count) 项要求规划")
                Spacer()
                Image(systemName: "chevron.right").font(Typo.caption2)
            }
            .font(Typo.caption.weight(.semibold))
            .foregroundStyle(Palette.green)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Palette.green.opacity(0.08), in: RoundedRectangle(cornerRadius: Metric.fieldRadius))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18).padding(.bottom, 10)
    }
}

struct TripIntentSummarySheet: View {
    @Environment(\.dismiss) private var dismiss
    let intent: TripIntent
    let onAdjust: ((TripIntent) -> Void)?

    var body: some View {
        NavigationStack {
            IntentSummaryView(intent: intent, ambiguities: [])
                .safeAreaInset(edge: .bottom) {
                    if let onAdjust {
                        Button {
                            dismiss()
                            onAdjust(intent)
                        } label: {
                            Text("调整要求并重新规划")
                                .font(Typo.cardTitle).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).frame(height: 42)
                                .background(Palette.green, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .padding(14)
                        .background(Palette.cardBG)
                    }
                }
                .navigationTitle("本次规划要求")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .frame(minWidth: 360, idealWidth: 440, minHeight: 520)
    }
}
