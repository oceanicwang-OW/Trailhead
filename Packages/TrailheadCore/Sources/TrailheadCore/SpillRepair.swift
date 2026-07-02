//  SpillRepair.swift
//  跨天重插（PDR §4.8，新增 · D3）。被模拟器丢出当天的点不静默消失：按综合分降序逐点尝试
//  插到其它天（按质心距离升序、最小绕行位置），目标天**重跑模拟**保证不破坏已有硬约束；
//  所有天都不可行才真正丢弃并写入最终丢弃清单（供 feasibility 报告/后续 UI 展示）。
//  典型正确结果：招牌点因「周一闭馆」（D2）被判掉后，被本模块重插到周二。纯函数、确定性。

import Foundation

public enum SpillRepair {
    /// 重插所需的模拟上下文（与 planStops 逐天模拟同参，保证重跑一致）。
    public struct Context: Sendable {
        public var pace: Pace
        public var city: String
        public var weekdays: [Int?]          // 天序号 → weekday（1=周一…7=周日；nil=无日期）
        public var dayStart: Int
        public var dayEnd: Int
        public var priors: StayDuration.Priors
        public var maxWait: Int
        public var scores: [String: Double]
        public var maxSightsPerDay: Int
        public var stayBudget: Int?          // 该天 Σ非餐停留上限（D7；nil = 不启用）

        public init(pace: Pace, city: String, weekdays: [Int?],
                    dayStart: Int = 9 * 60, dayEnd: Int = 20 * 60,
                    priors: StayDuration.Priors = .init(),
                    maxWait: Int = ScheduleSimulator.defaultMaxWait,
                    scores: [String: Double] = [:],
                    maxSightsPerDay: Int = 4, stayBudget: Int? = nil) {
            self.pace = pace; self.city = city; self.weekdays = weekdays
            self.dayStart = dayStart; self.dayEnd = dayEnd; self.priors = priors
            self.maxWait = maxWait; self.scores = scores
            self.maxSightsPerDay = maxSightsPerDay; self.stayBudget = stayBudget
        }
    }

    /// spill 按综合分降序逐点尝试跨天重插；返回修复后的各天顺序 + 最终丢弃清单。
    /// `dayOrders` 应为已通过模拟的各天可行顺序（重插成功的天会被替换为重模拟后的顺序）。
    public static func repair(dayOrders: [[POICandidate]],
                              spill: [(day: Int, stop: SpilledStop)],
                              context ctx: Context) -> (dayOrders: [[POICandidate]], dropped: [SpilledStop]) {
        guard !spill.isEmpty else { return (dayOrders, []) }
        var orders = dayOrders
        var dropped: [SpilledStop] = []

        let queue = spill.sorted {
            let (sa, sb) = (ScheduleSimulator.score($0.stop.candidate, ctx.scores),
                            ScheduleSimulator.score($1.stop.candidate, ctx.scores))
            return sa == sb ? $0.stop.candidate.id < $1.stop.candidate.id : sa > sb
        }

        for item in queue {
            let c = item.stop.candidate
            // 目标天按「候选点到该天质心距离」升序（空天视为最远，最后兜底尝试；平手按天序）。
            let targets = orders.indices.filter { $0 != item.day }.sorted {
                let (da, db) = (centroidDistance(c, orders[$0]), centroidDistance(c, orders[$1]))
                return da == db ? $0 < $1 : da < db
            }

            var placed = false
            for d in targets where hasCapacity(orders[d], adding: c, ctx: ctx) {
                var trial = orders[d]
                trial.insert(c, at: bestInsertion(c, orders[d]))
                let weekday = d < ctx.weekdays.count ? ctx.weekdays[d] : nil
                let sim = ScheduleSimulator.simulate(stops: trial, pace: ctx.pace, city: ctx.city,
                                                     weekday: weekday,
                                                     dayStart: ctx.dayStart, dayEnd: ctx.dayEnd,
                                                     priors: ctx.priors, maxWait: ctx.maxWait,
                                                     scores: ctx.scores)
                // 铁律：重插不得破坏目标天已有点（全员保留且零 spill 才接受）。
                if sim.spilled.isEmpty, sim.scheduled.count == trial.count {
                    orders[d] = sim.scheduled.map(\.candidate)
                    placed = true
                    break
                }
            }
            if !placed { dropped.append(item.stop) }
        }
        return (orders, dropped)
    }

    // MARK: - 内部

    /// 点数（非餐）与时间预算（D7）任一超限即视为满，不再接收重插。
    private static func hasCapacity(_ order: [POICandidate], adding c: POICandidate, ctx: Context) -> Bool {
        let sights = order.filter { $0.kind != .food }
        guard sights.count < ctx.maxSightsPerDay else { return false }
        if let budget = ctx.stayBudget {
            let used = sights.reduce(0) { $0 + StayDuration.duration(for: $1, pace: ctx.pace, priors: ctx.priors) }
            guard used + StayDuration.duration(for: c, pace: ctx.pace, priors: ctx.priors) <= budget else {
                return false
            }
        }
        return true
    }

    /// 候选到该天质心的距离；空天无锚点 → 最远（仅在非空天都不可行时兜底）。
    private static func centroidDistance(_ c: POICandidate, _ order: [POICandidate]) -> Double {
        guard !order.isEmpty else { return .infinity }
        let lat = order.map(\.lat).reduce(0, +) / Double(order.count)
        let lng = order.map(\.lng).reduce(0, +) / Double(order.count)
        let centroid = POICandidate(id: "__centroid__", name: "", kind: .sight, subtype: "", lat: lat, lng: lng)
        return ItineraryDayBuilder.haversineMeters(c, centroid)
    }

    /// 最小绕行插入位（0...n）：detour = d(prev,x)+d(x,next)−d(prev,next)，边界退化为单边距离。
    private static func bestInsertion(_ c: POICandidate, _ order: [POICandidate]) -> Int {
        guard !order.isEmpty else { return 0 }
        func d(_ a: POICandidate, _ b: POICandidate) -> Double { ItineraryDayBuilder.haversineMeters(a, b) }
        var best = 0
        var bestCost = Double.infinity
        for pos in 0...order.count {
            let prev = pos > 0 ? order[pos - 1] : nil
            let next = pos < order.count ? order[pos] : nil
            let cost: Double
            switch (prev, next) {
            case let (p?, n?): cost = d(p, c) + d(c, n) - d(p, n)
            case let (p?, nil): cost = d(p, c)
            case let (nil, n?): cost = d(c, n)
            default: cost = 0
            }
            if cost < bestCost - 1e-9 {
                bestCost = cost
                best = pos
            }
        }
        return best
    }
}
