//  MealSlotter.swift
//  餐饮卡点（PDR §4.6）。在已排序景点里就近插入午/晚餐。运行在 ScheduleSimulator 赋时**之前**，
//  故按行程序号（而非真实时刻）定位午/晚位置；真正的餐窗可行性由后续模拟器判定。纯函数。

import Foundation

public enum MealSlotter {
    /// 距离惩罚（每公里扣的评分等价分），用于「就近 + 高分」权衡。可配。
    public static let defaultPenaltyPerKm = 0.3

    /// 在有序景点中插入 ≤1 午餐（中部）+ ≤1 晚餐（末尾）。
    /// 短行程（<3 景点）只插单餐；无景点（轻量天）不插；空池或候选耗尽则跳过对应餐。
    public static func insertMeals(sights: [POICandidate], foodPool: [POICandidate],
                                   usedIds: Set<String> = [],
                                   penaltyPerKm: Double = defaultPenaltyPerKm) -> [POICandidate] {
        guard !sights.isEmpty else { return sights }        // 轻量天无地理锚点，不插餐

        let n = sights.count
        let lunchIdx = (n - 1) / 2                            // 中部（午）
        let dinnerIdx = n - 1                                 // 末尾（晚）
        let wantDinner = n >= 3                               // 短行程只单餐

        var used = usedIds
        let lunch = pickFood(anchor: sights[lunchIdx], pool: foodPool, used: used, penaltyPerKm: penaltyPerKm)
        if let lunch { used.insert(lunch.id) }               // 去重：晚餐不再选同一家
        let dinner = wantDinner
            ? pickFood(anchor: sights[dinnerIdx], pool: foodPool, used: used, penaltyPerKm: penaltyPerKm)
            : nil

        var result: [POICandidate] = []
        for (idx, sight) in sights.enumerated() {
            result.append(sight)
            if idx == lunchIdx, let lunch { result.append(lunch) }
            if idx == dinnerIdx, let dinner { result.append(dinner) }
        }
        return result
    }

    /// 选就近 + 高分且未被使用的餐饮：score = 评分 − 距离(km)×惩罚；取最大。
    private static func pickFood(anchor: POICandidate, pool: [POICandidate],
                                 used: Set<String>, penaltyPerKm: Double) -> POICandidate? {
        let usable = pool.filter { $0.kind == .food && !used.contains($0.id) }
        guard !usable.isEmpty else { return nil }
        return usable.max(by: { score($0, anchor, penaltyPerKm) < score($1, anchor, penaltyPerKm) })
    }

    private static func score(_ food: POICandidate, _ anchor: POICandidate, _ penaltyPerKm: Double) -> Double {
        let km = ItineraryDayBuilder.haversineMeters(anchor, food) / 1000
        return (food.rating ?? 0) - km * penaltyPerKm
    }
}
