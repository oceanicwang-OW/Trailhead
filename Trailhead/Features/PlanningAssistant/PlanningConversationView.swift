//  PlanningConversationView.swift
//  消息、快捷回答、POI 消歧和确认卡（PDR DCP-02 / 04 / 05 / 07）。

import SwiftUI
import TrailheadCore

struct PlanningConversationView: View {
    @ObservedObject var coordinator: PlanningCoordinator
    let onGenerate: () -> Void

    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            messages
            Divider()
            composer
        }
        .background(Palette.canvasBG)
    }

    private var messages: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(coordinator.session.messages) { message in
                    PlanningMessageBubble(message: message).id(message.id)
                }
                if coordinator.session.messages.count == 1 { quickReplies }
                if coordinator.isInterpreting { interpretingRow }
                if let pending = coordinator.pendingPOIResolution {
                    POIDisambiguationCard(pending: pending,
                                          onSelect: { candidate in
                                              Task { await coordinator.selectPOI(candidate) }
                                          },
                                          onSkip: coordinator.skipPendingPOI)
                }
                if let error = coordinator.errorMessage, coordinator.lastConflict == nil {
                    errorCard(error)
                }
                if let conflict = coordinator.lastConflict {
                    PlanningConflictCard(conflict: conflict) { option in
                        try? coordinator.applyRepair(option)
                    }
                }
                if coordinator.session.state == .ready {
                    PlanningConfirmationCard(intent: coordinator.session.intent, onGenerate: onGenerate)
                }
            }
            .padding(18)
        }
    }

    private var quickReplies: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快速补充").font(Typo.caption2).foregroundStyle(Palette.textSecondary)
            FlowLayout(spacing: 8) {
                ForEach(["有老人同行", "带儿童", "不想走太多", "有固定预约", "都没有"], id: \.self) { reply in
                    Button(reply) { Task { await coordinator.send(reply) } }
                        .buttonStyle(.plain)
                        .font(Typo.caption)
                        .padding(.vertical, 8).padding(.horizontal, 12)
                        .background(Palette.fieldBG, in: Capsule())
                }
            }
        }
    }

    private var interpretingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在整理你的要求…").font(Typo.caption).foregroundStyle(Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func errorCard(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(error).font(Typo.body)
                Text("内容已保留，可以修改后重新发送，或按已确认设置继续。")
                    .font(Typo.caption).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(12)
        .background(Palette.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: Metric.cardRadius))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("补充要求，或回答上面的问题…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.vertical, 10).padding(.horizontal, 12)
                .background(Palette.fieldBG, in: RoundedRectangle(cornerRadius: Metric.fieldRadius))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(canSend ? Palette.green : Palette.textMuted, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("发送要求")
        }
        .padding(14)
        .background(Palette.cardBG)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !coordinator.isInterpreting
    }

    private func send() {
        let message = input
        guard canSend else { return }
        input = ""
        Task { await coordinator.send(message) }
    }
}

private struct PlanningConflictCard: View {
    let conflict: PlanningConflict
    let onApply: (RepairOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("有一项要求无法同时满足", systemImage: "exclamationmark.triangle.fill")
                .font(Typo.cardTitle).foregroundStyle(Palette.red)
            Text(conflict.message).font(Typo.body).foregroundStyle(Palette.textPrimary)
            ForEach(conflict.repairOptions) { option in
                Button { onApply(option) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title).font(Typo.body.weight(.semibold))
                            if !option.detail.isEmpty {
                                Text(option.detail).font(Typo.caption2).foregroundStyle(Palette.textSecondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                    }
                    .foregroundStyle(Palette.textPrimary)
                    .padding(10)
                    .background(Palette.fieldBG, in: RoundedRectangle(cornerRadius: Metric.fieldRadius))
                }
                .buttonStyle(.plain)
            }
            Text("也可以在下方输入新的调整办法。")
                .font(Typo.caption).foregroundStyle(Palette.textSecondary)
        }
        .padding(14)
        .background(Palette.red.opacity(0.06), in: RoundedRectangle(cornerRadius: Metric.cardRadiusL))
        .overlay(RoundedRectangle(cornerRadius: Metric.cardRadiusL).stroke(Palette.red.opacity(0.25)))
    }
}

private struct PlanningMessageBubble: View {
    let message: PlanningMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 64) }
            VStack(alignment: .leading, spacing: 6) {
                if message.role == .assistant {
                    Label("行迹助手", systemImage: "sparkles")
                        .font(Typo.caption2.weight(.semibold)).foregroundStyle(Palette.green)
                }
                Text(message.content).font(Typo.body).foregroundStyle(Palette.textPrimary)
            }
            .padding(11)
            .background(message.role == .user ? Palette.green.opacity(0.12) : Palette.cardBG,
                        in: RoundedRectangle(cornerRadius: Metric.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Metric.cardRadius).stroke(Palette.cardStroke, lineWidth: 0.5))
            if message.role != .user { Spacer(minLength: 64) }
        }
    }
}

private struct POIDisambiguationCard: View {
    let pending: PendingPOIResolution
    let onSelect: (POICandidate) -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("你说的“\(pending.mention)”是哪个？").font(Typo.cardTitle)
            ForEach(pending.candidates) { candidate in
                Button { onSelect(candidate) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: candidate.kind == .food ? "fork.knife" : "mappin.circle.fill")
                            .foregroundStyle(candidate.kind.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.name).font(Typo.body.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                            Text([candidate.kind.label, candidate.subtype].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(Typo.caption2).foregroundStyle(Palette.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(Typo.caption2).foregroundStyle(Palette.textTertiary)
                    }
                    .padding(10)
                    .background(Palette.fieldBG, in: RoundedRectangle(cornerRadius: Metric.fieldRadius))
                }
                .buttonStyle(.plain)
            }
            if pending.canSkip {
                Button("都不是，换个说法", action: onSkip)
                    .font(Typo.caption).foregroundStyle(Palette.textSecondary)
            } else {
                Text("必去地点需要先确认；若都不正确，请在下方补充更完整的名称。")
                    .font(Typo.caption2).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(14)
        .background(Palette.cardBG, in: RoundedRectangle(cornerRadius: Metric.cardRadiusL))
        .overlay(RoundedRectangle(cornerRadius: Metric.cardRadiusL).stroke(Palette.green.opacity(0.25)))
    }
}

private struct PlanningConfirmationCard: View {
    let intent: TripIntent
    let onGenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("规划需求已准备好", systemImage: "checkmark.circle.fill")
                .font(Typo.cardTitle).foregroundStyle(Palette.green)
            Text(summary).font(Typo.caption).foregroundStyle(Palette.textSecondary)
            Button("按这些要求生成", action: onGenerate)
                .buttonStyle(.plain)
                .font(Typo.cardTitle).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(Palette.green, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
        .background(Palette.cardBG, in: RoundedRectangle(cornerRadius: Metric.cardRadiusL))
        .overlay(RoundedRectangle(cornerRadius: Metric.cardRadiusL).stroke(Palette.green.opacity(0.3)))
    }

    private var summary: String {
        let required = intent.poiConstraints.filter { $0.requirement == .mustVisit }.count
        let excluded = intent.poiConstraints.filter { $0.requirement == .avoidVisit }.count
        return "\(intent.days) 天 · \(required) 个必去 · \(excluded) 个排除地点 · \(intent.preferences.pace.display)"
    }
}
