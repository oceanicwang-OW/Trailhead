//  ScheduleSimulator.swift
//  时间前向模拟 + 可行性（PDR §4.7，v2 含 D2/D3/D5）。把 time/stayMin 从大模型拍脑袋收回为
//  **确定性、可行**的产出：逐点前向推进，营业窗内落位。v2 变化：
//  - D2 当日 weekday 窗口（周闭馆判不可行）；
//  - D5 早到超 maxWait 不再干等——先与后点交换、再移末尾、仍不行才丢；
//  - D3 丢弃/截断按综合分升序牺牲低分点（而非按路径位置砍尾），且**不静默消失**——
//    全部进 spill 池，由 SpillRepair 跨天重插。
//  内部一律用「当日分钟数」Int 运算（B5），转 "HH:mm" 由 planStops 装配时进行。纯函数。

import Foundation

/// 模拟后的单点：到达时刻与停留（当日分钟数）。planStops 据此装配 PlannedStop。
public struct ScheduledStop: Equatable, Sendable {
    public let candidate: POICandidate
    public let arrival: Int      // 当日分钟数
    public let stayMin: Int
    public init(candidate: POICandidate, arrival: Int, stayMin: Int) {
        self.candidate = candidate; self.arrival = arrival; self.stayMin = stayMin
    }
}

/// 被丢出当天的点 + 原因（D3）。不静默消失，交由 SpillRepair 跨天重插。
public struct SpilledStop: Equatable, Sendable {
    public let candidate: POICandidate
    public let reason: String
    public init(candidate: POICandidate, reason: String) {
        self.candidate = candidate; self.reason = reason
    }
}

/// 单天模拟结果：可行时刻线 + 本天 spill 列表。
public struct DaySimulation: Equatable, Sendable {
    public let scheduled: [ScheduledStop]
    public let spilled: [SpilledStop]
    public init(scheduled: [ScheduledStop], spilled: [SpilledStop] = []) {
        self.scheduled = scheduled; self.spilled = spilled
    }
}

public enum ScheduleSimulator {
    /// 早到等待上限（分钟，D5 可配）：超过则交换/后移而非干等。
    public static let defaultMaxWait = 45

    /// 前向模拟一天的有序停留。openHours 未知的点不参与营业窗过滤（保守，绝不误杀）。
    /// `weekday`：1=周一…7=周日；nil = 行程无日期，营业窗退化 base 语义（D2）。
    /// `scores`：poi_id → 综合分，截断牺牲时用；缺省回退 rating ?? 中性分。
    public static func simulate(stops: [POICandidate], pace: Pace, city: String,
                                weekday: Int? = nil,
                                dayStart: Int = 9 * 60, dayEnd: Int = 20 * 60,
                                priors: StayDuration.Priors = .init(),
                                maxWait: Int = defaultMaxWait,
                                scores: [String: Double] = [:]) -> DaySimulation {
        guard !stops.isEmpty else { return DaySimulation(scheduled: []) }

        var order = stops
        var spilled: [SpilledStop] = []
        var lateSwapped: Set<String> = []    // 迟到已尝试与前点交换
        var waitSwapped: Set<String> = []    // 过等已尝试与后点交换（D5）
        var movedToEnd: Set<String> = []     // 过等已尝试移至末尾（D5）

        // 每次违规要么移除一点、要么对某点做一次性交换/后移，均有限；guard 为终止兜底。
        var guardCounter = 0
        while !order.isEmpty, guardCounter < 8 * stops.count {
            guardCounter += 1
            switch forwardPass(order, pace: pace, city: city, weekday: weekday,
                               dayStart: dayStart, dayEnd: dayEnd, priors: priors, maxWait: maxWait) {
            case .success(let scheduled):
                return DaySimulation(scheduled: scheduled, spilled: spilled)

            case .closedDay(let i):
                spilled.append(SpilledStop(candidate: order.remove(at: i), reason: "当日闭馆"))

            case .missedWindow(let i):
                // 迟到：尝试与前点交换前移一次；仍不可行则丢弃（D3 进 spill）。
                if i > 0, !lateSwapped.contains(order[i].id) {
                    lateSwapped.insert(order[i].id)
                    order.swapAt(i, i - 1)
                } else {
                    spilled.append(SpilledStop(candidate: order.remove(at: i), reason: "错过营业窗"))
                }

            case .overWait(let i):
                // D5：先与后点交换（先访问后点、回头再来）→ 再移末尾重试 → 仍不可行才丢。
                let id = order[i].id
                if i + 1 < order.count, !waitSwapped.contains(id) {
                    waitSwapped.insert(id)
                    order.swapAt(i, i + 1)
                } else if i != order.count - 1, !movedToEnd.contains(id) {
                    movedToEnd.insert(id)
                    order.append(order.remove(at: i))
                } else {
                    spilled.append(SpilledStop(candidate: order.remove(at: i), reason: "开门等待超限"))
                }

            case .overflow:
                // D3：超 dayEnd 不按位置砍尾——从当天仍在列表的点中牺牲综合分最低者
                // （平手按 poi_id 破平）并重新前向模拟，排尾的高分招牌得以幸存。
                let victim = (0..<order.count).min {
                    let (sa, sb) = (score(order[$0], scores), score(order[$1], scores))
                    return sa == sb ? order[$0].id < order[$1].id : sa < sb
                } ?? order.count - 1
                spilled.append(SpilledStop(candidate: order.remove(at: victim), reason: "超出当日时间窗"))
            }
        }

        // 理论不可达的兜底：把残余全部记为未编排。
        spilled.append(contentsOf: order.map { SpilledStop(candidate: $0, reason: "未能编排") })
        return DaySimulation(scheduled: [], spilled: spilled)
    }

    // MARK: - 前向扫描

    private enum PassResult {
        case success([ScheduledStop])
        case closedDay(Int)       // 当日闭馆（D2）
        case missedWindow(Int)    // 到达晚于全部窗 close
        case overWait(Int)        // 早到且等待 > maxWait（D5）
        case overflow(Int)        // 到达 > dayEnd
    }

    private static func forwardPass(_ order: [POICandidate], pace: Pace, city: String,
                                    weekday: Int?, dayStart: Int, dayEnd: Int,
                                    priors: StayDuration.Priors, maxWait: Int) -> PassResult {
        var t = dayStart
        var prev: POICandidate?
        var out: [ScheduledStop] = []

        for (i, stop) in order.enumerated() {
            let travel = prev.map { TravelEstimator.minutes(from: $0, to: stop, city: city) } ?? 0
            var arrival = t + travel

            if let windows = OpenHoursParser.schedule(stop.openHours).windows(on: weekday) {
                if windows.isEmpty { return .closedDay(i) }
                guard let w = windows.sorted(by: { $0.open < $1.open })
                    .first(where: { arrival <= $0.close }) else { return .missedWindow(i) }
                if w.open > arrival {
                    if w.open - arrival > maxWait { return .overWait(i) }
                    arrival = w.open          // 早到 ≤ maxWait → 等待到开门
                }
            }

            if arrival > dayEnd { return .overflow(i) }

            let stay = StayDuration.duration(for: stop, pace: pace, priors: priors)
            out.append(ScheduledStop(candidate: stop, arrival: arrival, stayMin: stay))
            t = arrival + stay
            prev = stop
        }
        return .success(out)
    }

    /// 牺牲排序用综合分：外部映射优先，缺省回退 rating ?? 中性分（与 P0 语义一致）。
    static func score(_ c: POICandidate, _ scores: [String: Double]) -> Double {
        scores[c.id] ?? c.rating ?? CandidateCuration.neutralRating
    }
}
