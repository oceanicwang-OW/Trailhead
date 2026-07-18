//  PlanningAssistantView.swift
//  对话式规划的自适应容器（PDR CP-3.2...3.8）。

import SwiftUI
import TrailheadCore

struct PlanningAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var coordinator: PlanningCoordinator
    let onGenerate: (TripIntent) -> Void

    @State private var showSummary = false

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header
                Divider()
                if proxy.size.width >= 680 {
                    HStack(spacing: 0) {
                        PlanningConversationView(coordinator: coordinator, onGenerate: generate)
                            .frame(minWidth: 420, maxWidth: .infinity)
                        Divider()
                        IntentSummaryView(intent: coordinator.session.intent,
                                          ambiguities: coordinator.session.pendingAmbiguities,
                                          onRemovePOI: coordinator.removePOIConstraint,
                                          onSetPOIRequirement: coordinator.setPOIRequirement)
                            .frame(width: 290)
                    }
                } else {
                    PlanningConversationView(coordinator: coordinator, onGenerate: generate)
                }
            }
            .background(Palette.groupedBG)
        }
        .frame(minWidth: 420, idealWidth: 760, minHeight: 600, idealHeight: 680)
        .sheet(isPresented: $showSummary) {
            NavigationStack {
                IntentSummaryView(intent: coordinator.session.intent,
                                  ambiguities: coordinator.session.pendingAmbiguities,
                                  onRemovePOI: coordinator.removePOIConstraint,
                                  onSetPOIRequirement: coordinator.setPOIRequirement)
                    .navigationTitle("需求摘要")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showSummary = false }
                        }
                    }
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
        }
        .task { await coordinator.resumePendingWork() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .accessibilityLabel("返回新建行程")
            VStack(alignment: .leading, spacing: 2) {
                Text("完善行程要求").font(Typo.cardTitleL)
                Text(subtitle).font(Typo.caption).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Button { showSummary = true } label: {
                Label("需求摘要", systemImage: "checklist")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.green)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(Palette.cardBG)
    }

    private var subtitle: String {
        let intent = coordinator.session.intent
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(intent.destination.name) · \(formatter.string(from: intent.startDate)) · \(intent.days)天"
    }

    private func generate() {
        coordinator.markGenerating()
        onGenerate(coordinator.session.intent)
        dismiss()
    }
}
