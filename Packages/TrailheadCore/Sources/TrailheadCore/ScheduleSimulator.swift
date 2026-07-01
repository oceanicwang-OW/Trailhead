//  ScheduleSimulator.swift
//  时间前向模拟 + 可行性（PDR §4.7）。把 time/stayMin 从大模型拍脑袋收回为**确定性、可行**的产出：
//  逐点前向推进，营业窗内落位（早到等待、错过丢弃、超 dayEnd 截断尾部）。
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

public enum ScheduleSimulator {
    /// 前向模拟一天的有序停留。openHours 未知的点不参与营业窗过滤（保守，绝不误杀）。
    public static func simulate(stops: [POICandidate], pace: Pace, city: String,
                                dayStart: Int = 9 * 60, dayEnd: Int = 20 * 60,
                                priors: StayDuration.Priors = .init()) -> [ScheduledStop] {
        var t = dayStart
        var prev: POICandidate?
        var result: [ScheduledStop] = []

        for stop in stops {
            let travel = prev.map { TravelEstimator.minutes(from: $0, to: stop, city: city) } ?? 0
            let rawArrival = t + travel

            var arrival = rawArrival
            if let windows = OpenHoursParser.parse(stop.openHours) {
                guard let feasible = feasibleArrival(rawArrival, windows) else {
                    continue                                  // 错过营业窗 → 丢弃，prev/t 不变
                }
                arrival = feasible                            // 早到则等待到开门
            }

            if arrival > dayEnd { break }                     // 超出活动窗 → 截断当天尾部

            let stay = StayDuration.duration(for: stop, pace: pace, priors: priors)
            result.append(ScheduledStop(candidate: stop, arrival: arrival, stayMin: stay))
            t = arrival + stay
            prev = stop
        }
        return result
    }

    /// 选一个尚未错过的营业窗：取最早（open 升序）且 `arrival ≤ close` 的窗，早到则等到 open。
    /// 全部错过返回 nil（不可行）。全天/跨夜窗为 (0,1440)，永不过滤。
    private static func feasibleArrival(_ arrival: Int, _ windows: [OpenHoursParser.Window]) -> Int? {
        for w in windows.sorted(by: { $0.open < $1.open }) where arrival <= w.close {
            return max(arrival, w.open)
        }
        return nil
    }
}
