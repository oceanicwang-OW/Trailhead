//  ItineraryFeasibility.swift
//  出口自检器（PDR §7，v2 含 D2/D3/D8）。接在 planStops 出口，每次生成强制过：
//  硬约束校验并返回**最优可行子集**（丢弃违规点），不抛错中断；软约束只记 warning/info。
//  时间一律解析回当日分钟数用 Int 比较（B5）。D2：营业窗按**当日 weekday** 判定（含周闭馆）。
//  D8：软断言换成有意义的——2-opt 未触顶收敛、无 <30° 急回折（v1 的「总长 ≤ 初始贪心序」
//  是构造保证的恒真式，验不出任何东西）。D3：spill 最终丢弃清单非空记 warning。

import Foundation

public enum ItineraryFeasibility {
    /// 自检报告：硬违规（返回子集时已丢弃对应点）、软警告（spill 丢弃等）、软提示（D8）。
    public struct Report: Equatable, Sendable {
        public var hardViolations: [String]
        public var softWarnings: [String]
        public var infos: [String]
        public var isFeasible: Bool { hardViolations.isEmpty }
        public init(hardViolations: [String] = [], softWarnings: [String] = [], infos: [String] = []) {
            self.hardViolations = hardViolations
            self.softWarnings = softWarnings
            self.infos = infos
        }
    }

    /// 校验并清理。硬：时间递增、到达在**当日**营业窗内（D2）、每日景点上限、无空天。
    /// 软：spill 丢弃清单（D3，warning）；2-opt 收敛与急回折（D8，info）。
    /// `weekdays`：天序号 → weekday（缺省/nil 退化 base 语义）；
    /// `dropped`：SpillRepair 后仍无处安放的点；`routerConverged`：各天 2-opt 是否未触顶。
    public static func check(_ perDay: [[PlannedStop]], days: Int,
                             maxSightsPerDay: Int,
                             weekdays: [Int?] = [],
                             dropped: [SpilledStop] = [],
                             routerConverged: [Bool] = []) -> (plan: [[PlannedStop]], report: Report) {
        var violations: [String] = []
        var warnings: [String] = []
        var infos: [String] = []
        var sanitized: [[PlannedStop]] = []

        for (dayIdx, day) in perDay.enumerated() {
            let weekday = dayIdx < weekdays.count ? weekdays[dayIdx] : nil
            var kept: [PlannedStop] = []
            var lastMinute = -1
            var sightCount = 0
            for s in day {
                let t = minutes(from: s.time)
                if let t, t <= lastMinute {
                    violations.append("day \(dayIdx): 时间非递增，丢弃 \(s.candidate.id)")
                    continue
                }
                // D2：按当日 weekday 取窗（周闭馆日窗为 []，任何到达都不在窗内）。
                if let windows = OpenHoursParser.schedule(s.candidate.openHours).windows(on: weekday),
                   let t, !within(t, windows) {
                    violations.append("day \(dayIdx): 到达不在当日营业窗，丢弃 \(s.candidate.id)")
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

            // D8(b)：相邻两段夹角 < 30° 的急回折（回头路代理指标）→ info。
            let turns = sharpTurns(kept)
            if turns > 0 {
                infos.append("day \(dayIdx): 检出 \(turns) 处 <30° 急回折")
            }
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

        // D8(a)：2-opt 触顶未收敛 → info。
        for (dayIdx, converged) in routerConverged.enumerated() where !converged {
            infos.append("day \(dayIdx): 2-opt 达步数上限退出（未完全收敛）")
        }

        // D3：spill 最终丢弃清单非空 → warning（附原因，供后续 UI 展示「因闭馆未排入：X」）。
        for drop in dropped {
            warnings.append("最终丢弃 \(drop.candidate.id)（\(drop.reason)）")
        }

        return (sanitized, Report(hardViolations: violations, softWarnings: warnings, infos: infos))
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

    /// D8(b)：数一天动线中「相邻两段夹角 < 30°」的顶点数。夹角取顶点处两来向的内角
    /// （直行 ≈180°、原路折返 ≈0°）；<50m 的短段跳过（同址插餐等噪声）。
    static func sharpTurns(_ day: [PlannedStop]) -> Int {
        let pois = day.map(\.candidate)
        guard pois.count >= 3 else { return 0 }
        let pts = GeoProjection.project(pois)
        let cosThreshold = cos(30 * Double.pi / 180)
        var count = 0
        for i in 1..<(pts.count - 1) {
            let v1 = (x: pts[i - 1].x - pts[i].x, y: pts[i - 1].y - pts[i].y)
            let v2 = (x: pts[i + 1].x - pts[i].x, y: pts[i + 1].y - pts[i].y)
            let l1 = hypot(v1.x, v1.y)
            let l2 = hypot(v2.x, v2.y)
            guard l1 > 50, l2 > 50 else { continue }
            let cosAngle = (v1.x * v2.x + v1.y * v2.y) / (l1 * l2)
            if cosAngle > cosThreshold { count += 1 }      // cos 单调递减：cos>cos30° ⇔ 夹角<30°
        }
        return count
    }
}
