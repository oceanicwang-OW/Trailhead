//  ItineraryFeasibility.swift
//  出口自检器（PDR §7）。接在 planStops 出口，每次生成强制过：校验硬约束并返回**最优可行子集**
//  （丢弃违规点），不抛错中断。时间一律解析回当日分钟数用 Int 比较（B5），不踩字符串格式坑。

import Foundation

public enum ItineraryFeasibility {
    /// 自检报告：硬违规（返回子集时已丢弃对应点）与软提醒。
    public struct Report: Equatable, Sendable {
        public var hardViolations: [String]
        public var softWarnings: [String]
        public var isFeasible: Bool { hardViolations.isEmpty }
        public init(hardViolations: [String] = [], softWarnings: [String] = []) {
            self.hardViolations = hardViolations; self.softWarnings = softWarnings
        }
    }

    /// 校验并清理：时间非递增/超营业窗/超每日景点上限的点丢弃；days≥2 且景点数覆盖天数时空天记违规。
    public static func check(_ perDay: [[PlannedStop]], days: Int,
                             maxSightsPerDay: Int) -> (plan: [[PlannedStop]], report: Report) {
        var violations: [String] = []
        var sanitized: [[PlannedStop]] = []

        for (dayIdx, day) in perDay.enumerated() {
            var kept: [PlannedStop] = []
            var lastMinute = -1
            var sightCount = 0
            for s in day {
                let t = minutes(from: s.time)
                if let t, t <= lastMinute {
                    violations.append("day \(dayIdx): 时间非递增，丢弃 \(s.candidate.id)")
                    continue
                }
                if let windows = OpenHoursParser.parse(s.candidate.openHours), let t, !within(t, windows) {
                    violations.append("day \(dayIdx): 到达不在营业窗，丢弃 \(s.candidate.id)")
                    continue
                }
                if days >= 2, s.candidate.kind != .food, sightCount >= maxSightsPerDay {
                    violations.append("day \(dayIdx): 超每日景点上限，丢弃 \(s.candidate.id)")
                    continue
                }
                kept.append(s)
                if let t { lastMinute = t }
                if s.candidate.kind != .food { sightCount += 1 }
            }
            sanitized.append(kept)
        }

        // days≥2 且景点足以覆盖每天时，不允许空天（景点 < 天数则轻量天合法，见 §4.4 B3）。
        if days >= 2 {
            let totalSights = sanitized.reduce(0) { $0 + $1.filter { $0.candidate.kind != .food }.count }
            if totalSights >= days {
                for (dayIdx, day) in sanitized.enumerated()
                where !day.contains(where: { $0.candidate.kind != .food }) {
                    violations.append("day \(dayIdx): 空天（应有景点）")
                }
            }
        }

        return (sanitized, Report(hardViolations: violations))
    }

    /// "HH:mm" → 当日分钟数；格式异常返回 nil（不参与单调判定，保守不丢）。
    static func minutes(from time: String?) -> Int? {
        guard let time else { return nil }
        let parts = time.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    private static func within(_ t: Int, _ windows: [OpenHoursParser.Window]) -> Bool {
        windows.contains { t >= $0.open && t <= $0.close }
    }
}
