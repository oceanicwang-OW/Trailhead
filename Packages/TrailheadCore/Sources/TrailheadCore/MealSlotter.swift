//  MealSlotter.swift
//  餐饮卡点（PDR §4.6，v2 重设计 · D1）。运行在 ScheduleSimulator **第一遍之后**：
//  输入带临时时刻的景点序列，在时刻线上找跨越餐窗中点（午 12:30 / 晚 18:30）的间隙插餐，
//  不再按行程序号猜测饭点位置。选店由「就近」升级为「顺路」——按绕行代价 detour 为主、
//  评分为辅，避免选中离景点近但位于动线反方向的店。时间字段随后由第二遍模拟重新赋值。纯函数。

import Foundation

public enum MealSlotter {
    /// 午/晚餐窗（当日分钟数，可配）；插入定位取窗中点（D1）。
    public struct MealWindows: Sendable {
        public var lunchOpen: Int
        public var lunchClose: Int
        public var dinnerOpen: Int
        public var dinnerClose: Int
        public init(lunchOpen: Int = 11 * 60 + 30, lunchClose: Int = 13 * 60 + 30,
                    dinnerOpen: Int = 17 * 60 + 30, dinnerClose: Int = 19 * 60 + 30) {
            self.lunchOpen = lunchOpen; self.lunchClose = lunchClose
            self.dinnerOpen = dinnerOpen; self.dinnerClose = dinnerClose
        }
        var lunchMid: Int { (lunchOpen + lunchClose) / 2 }
        var dinnerMid: Int { (dinnerOpen + dinnerClose) / 2 }
    }

    /// 绕行代价权重 λ（每公里扣的评分等价分，D1 可配）：score = rating − λ × detour_km。
    public static let defaultDetourWeight = 0.3

    /// 在临时时刻线上插入 ≤1 午餐 + ≤1 晚餐，返回带餐饮的候选顺序（时间由第二遍模拟重赋）。
    /// 时刻线未跨越某餐窗中点（短行程）则跳过该餐；空池/候选耗尽跳过；单餐去重。
    public static func insertMeals(schedule: [ScheduledStop], foodPool: [POICandidate],
                                   usedIds: Set<String> = [],
                                   windows: MealWindows = .init(),
                                   detourWeight: Double = defaultDetourWeight) -> [POICandidate] {
        guard !schedule.isEmpty else { return [] }

        var used = usedIds
        var meals: [(afterIndex: Int, food: POICandidate)] = []
        for mid in [windows.lunchMid, windows.dinnerMid] {
            guard let anchor = anchorIndex(for: mid, in: schedule) else { continue }
            let next = anchor + 1 < schedule.count ? schedule[anchor + 1].candidate : nil
            guard let pick = pickFood(prev: schedule[anchor].candidate, next: next,
                                      pool: foodPool, used: used, detourWeight: detourWeight) else { continue }
            used.insert(pick.id)                              // 去重：晚餐不再选同一家
            meals.append((anchor, pick))
        }

        var result: [POICandidate] = []
        for (i, s) in schedule.enumerated() {
            result.append(s.candidate)
            for m in meals where m.afterIndex == i { result.append(m.food) }
        }
        return result
    }

    // MARK: - 内部

    /// 餐窗中点在时刻线上的落位：取「到达 ≤ 中点」的最后一个点（中点落在其停留区间内
    /// 或其后的行段间隙里，均插该点之后）。时刻线未跨越中点 → nil（跳过该餐）。
    private static func anchorIndex(for mid: Int, in schedule: [ScheduledStop]) -> Int? {
        guard let first = schedule.first, let last = schedule.last else { return nil }
        guard mid >= first.arrival, mid <= last.arrival + last.stayMin else { return nil }
        return schedule.lastIndex { $0.arrival <= mid }
    }

    /// 顺路选店（D1）：detour(f) = d(prev,f) + d(f,next) − d(prev,next)（next 缺则退化单边距离）；
    /// 综合分 = 评分（缺失取中性分）− λ × 绕行公里数，取最大（平手按 poi_id 破平，确定性）。
    private static func pickFood(prev: POICandidate, next: POICandidate?,
                                 pool: [POICandidate], used: Set<String>,
                                 detourWeight: Double) -> POICandidate? {
        let usable = pool.filter { $0.kind == .food && !used.contains($0.id) }
        guard !usable.isEmpty else { return nil }
        func rank(_ f: POICandidate) -> Double {
            (f.rating ?? CandidateCuration.neutralRating) - detourWeight * detourKm(f, prev: prev, next: next)
        }
        return usable.max {
            let (ra, rb) = (rank($0), rank($1))
            return ra == rb ? $0.id > $1.id : ra < rb
        }
    }

    private static func detourKm(_ f: POICandidate, prev: POICandidate, next: POICandidate?) -> Double {
        func d(_ a: POICandidate, _ b: POICandidate) -> Double { ItineraryDayBuilder.haversineMeters(a, b) }
        guard let next else { return d(prev, f) / 1000 }
        return (d(prev, f) + d(f, next) - d(prev, next)) / 1000
    }
}
