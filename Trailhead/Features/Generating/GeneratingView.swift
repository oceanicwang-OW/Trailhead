//  GeneratingView.swift
//  FRAME 7/8 — progress ring + step list shown while the engine runs.
//  Steps map to ItineraryEngine.Stage so the real pipeline can drive this.

import SwiftUI

struct GeneratingView: View {
    var city: String = "关西"
    var progress: Double = 0.64
    var plannedDays: Int = 3
    var totalDays: Int = 5
    var steps: [Step] = Step.demo
    var onCancel: () -> Void = {}

    struct Step: Identifiable {
        enum State { case done, active, pending }
        let id = UUID(); let title: String; let state: State
        static let demo = [
            Step(title: "分析兴趣偏好", state: .done),
            Step(title: "规划每日路线", state: .done),
            Step(title: "优化交通衔接", state: .active),
            Step(title: "匹配餐饮与住宿", state: .pending),
            Step(title: "估算每日预算", state: .pending),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").foregroundStyle(Palette.green).font(.system(size: 14))
                Text("行迹 Trailhead").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary).tracking(0.3)
            }
            .padding(.top, 64)

            Spacer()
            ring
            Text("正在生成\(city)行程")
                .font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.textPrimary)
                .padding(.top, 26)
            Text("为你规划约 12 个地点的路线时间线")
                .font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                .padding(.top, 5).multilineTextAlignment(.center)
            Spacer()

            stepList.padding(.horizontal, 18)

            Button(action: onCancel) {
                Text("取消生成").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.red)
            }.buttonStyle(.plain).padding(.top, 20).padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.groupedBG)
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Palette.separator, lineWidth: 11).frame(width: 160, height: 160)
            Circle().trim(from: 0, to: progress)
                .stroke(Palette.green, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .frame(width: 160, height: 160).rotationEffect(.degrees(-90))
            VStack(spacing: 6) {
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    Text("\(Int(progress * 100))").font(.system(size: 44, weight: .bold))
                        .foregroundStyle(Palette.textPrimary)
                    Text("%").font(.system(size: 20)).foregroundStyle(Palette.textSecondary)
                }
                Text("已规划 \(plannedDays) / \(totalDays) 天")
                    .font(Typo.caption).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var stepList: some View {
        VStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                HStack(spacing: 13) {
                    stepIcon(step.state)
                    Text(step.title).font(.system(size: 15, weight: step.state == .active ? .semibold : .regular))
                        .foregroundStyle(step.state == .pending ? Palette.textTertiary : Palette.textPrimary)
                    Spacer()
                    switch step.state {
                    case .done:   Text("完成").font(Typo.caption).foregroundStyle(Palette.textSecondary)
                    case .active: Text("进行中").font(Typo.caption.weight(.semibold)).foregroundStyle(Palette.green)
                    case .pending: EmptyView()
                    }
                }
                .padding(.vertical, 11).padding(.horizontal, 14)
                if idx < steps.count - 1 {
                    Divider().padding(.leading, 51)
                }
            }
        }
        .background(Palette.cardBG, in: RoundedRectangle(cornerRadius: 18))
    }

    private func stepIcon(_ state: Step.State) -> some View {
        Group {
            switch state {
            case .done:
                Circle().fill(Palette.green).frame(width: 24, height: 24)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
            case .active:
                Circle().trim(from: 0, to: 0.7)
                    .stroke(Palette.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 24, height: 24).rotationEffect(.degrees(-90))
            case .pending:
                Circle().stroke(Palette.separator, lineWidth: 2).frame(width: 24, height: 24)
            }
        }
    }
}
