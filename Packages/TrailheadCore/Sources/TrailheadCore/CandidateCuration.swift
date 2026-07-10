//  CandidateCuration.swift
//  行程候选「确定性筛选规则」（PDR §3 第 3 步前置）。
//  目的：把「选哪些点」从大模型的自由裁量收回为**规则**——按真实高德点评分排序，
//  叠加个人偏好加权，每类只保留 top-K，大模型只能在这批点里编排顺序。
//  freeText 点名的点豁免筛选、必定保留。任何城市都稳定输出「高分 + 合偏好」结果。

import Foundation

public enum CandidateCuration {
    /// 每类保留的高分上限（够 5~7 天行程取用，又不至于让模型在大池里漏选）。
    public struct Limits {
        public var sights: Int
        public var food: Int
        public var other: Int
        public init(sights: Int = 20, food: Int = 15, other: Int = 8) {
            self.sights = sights; self.food = food; self.other = other
        }
    }

    /// 偏好加权分（命中用户兴趣标签对应的子类型 → 排序时加分，让合偏好的点上浮）。
    static let preferenceBoost = 1.0
    static let cuisineBoost = 0.75
    static let affordableBoost = 0.25
    static let subtypeRepeatPenalty = 0.35

    /// 无评分时的中性分（P0 止血）：高德常年缺评分的招牌景点不应被当作 0 分挤出 top-K。
    /// 取值对齐 `PromptBuilder.unratedScore`，同一「无评分中性分」语义应保持一致。
    static let neutralRating = 4.0

    /// 兴趣标签 → 命中判定用的子类型/名称关键词。让「历史古迹」「自然风光」等真正有区别。
    static let subtypeHints: [String: [String]] = [
        "历史古迹": ["寺", "庙", "宫", "古", "纪念", "故居", "历史", "遗址", "祠", "塔", "街区", "炮台", "陵"],
        "自然风光": ["公园", "山", "湖", "海", "沙滩", "风景", "森林", "湿地", "岛", "瀑", "峡", "温泉"],
        "温泉": ["温泉", "度假"],
        "购物": ["商业街", "购物", "商场", "市场", "步行街", "百货"],
        "动漫文化": ["博物馆", "展览", "美术", "艺术", "文化", "科技馆", "动漫"],
        "夜生活": ["酒吧", "夜市", "酒馆", "清吧", "livehouse", "夜景"],
        "亲子": ["动物园", "乐园", "游乐", "海洋", "亲子", "科技馆", "植物园"],
        "摄影": ["公园", "海", "山", "古", "风景", "观景", "教堂", "灯塔"],
    ]

    /// 规则：① 综合分 = 点评分 + 偏好加权；② 景点/餐饮各取 top-K；③ freeText 点名豁免必留；
    /// ④ 住宿应在调用前已剔除。返回顺序：点名 → 景点(高分优先) → 餐饮 → 其它。
    public static func curate(_ candidates: [POICandidate], tags: [String] = [],
                              cuisines: [String] = [], budgetPerDay: Int? = nil,
                              pinned: Set<String> = [], limits: Limits = .init()) -> [POICandidate] {
        let nonLodging = candidates.filter { $0.kind != .lodging }
        let pins = nonLodging.filter { pinned.contains($0.id) }   // freeText 点名，豁免筛选
        func topRated(_ pool: [POICandidate], _ limit: Int) -> [POICandidate] {
            var remaining = pool.filter { !pinned.contains($0.id) }
            var selected: [POICandidate] = []
            while !remaining.isEmpty, selected.count < max(0, limit) {
                let best = remaining.indices.max { a, b in
                    let sa = diversifiedScore(remaining[a], selected: selected, tags: tags,
                                              cuisines: cuisines, budgetPerDay: budgetPerDay)
                    let sb = diversifiedScore(remaining[b], selected: selected, tags: tags,
                                              cuisines: cuisines, budgetPerDay: budgetPerDay)
                    return sa == sb ? remaining[a].id > remaining[b].id : sa < sb
                } ?? 0
                selected.append(remaining.remove(at: best))
            }
            return selected
        }
        let sights = topRated(nonLodging.filter { $0.kind == .sight }, limits.sights)
        let food   = topRated(nonLodging.filter { $0.kind == .food }, limits.food)
        let other  = topRated(nonLodging.filter { $0.kind != .sight && $0.kind != .food }, limits.other)
        return pins + sights + food + other
    }

    /// 综合排序分：有评分用评分（无评分按中性分处理，不再沉底），命中偏好再加权。
    static func score(_ c: POICandidate, tags: [String],
                      cuisines: [String] = [], budgetPerDay: Int? = nil) -> Double {
        var result = c.rating ?? neutralRating
        if matchesPreference(c, tags: tags) { result += preferenceBoost }
        if c.kind == .food, matchesAny(c, terms: cuisines) { result += cuisineBoost }
        if let budgetPerDay, let price = c.avgPrice {
            let targetRatio = c.kind == .food ? 0.25 : 0.35
            let target = max(1, Double(budgetPerDay) * targetRatio)
            let ratio = Double(price) / target
            if ratio <= 1 {
                result += affordableBoost
            } else {
                result -= min(2, (ratio - 1) * 0.75)
            }
        }
        return result
    }

    private static func diversifiedScore(_ c: POICandidate, selected: [POICandidate],
                                         tags: [String], cuisines: [String],
                                         budgetPerDay: Int?) -> Double {
        let repeats = selected.filter { diversityKey($0) == diversityKey(c) }.count
        return score(c, tags: tags, cuisines: cuisines, budgetPerDay: budgetPerDay)
            - Double(repeats) * subtypeRepeatPenalty
    }

    private static func diversityKey(_ c: POICandidate) -> String {
        let subtype = c.subtype.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return subtype.isEmpty ? c.kind.rawValue : subtype
    }

    static func matchesAny(_ c: POICandidate, terms: [String]) -> Bool {
        let haystacks = [c.name, c.subtype] + c.tags
        return terms.contains { term in
            !term.isEmpty && haystacks.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    /// 候选的子类型或名称是否命中任一所选兴趣标签的关键词。
    static func matchesPreference(_ c: POICandidate, tags: [String]) -> Bool {
        let hints = tags.flatMap { subtypeHints[$0] ?? [] }
        guard !hints.isEmpty else { return false }
        return hints.contains { c.subtype.contains($0) || c.name.contains($0) }
    }
}
