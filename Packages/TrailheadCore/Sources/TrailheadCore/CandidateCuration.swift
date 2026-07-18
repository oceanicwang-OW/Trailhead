//  CandidateCuration.swift
//  行程候选「确定性筛选规则」（PDR §3 第 3 步前置）。
//  目的：把「选哪些点」从大模型的自由裁量收回为**规则**——景点以城市代表性优先，
//  再叠加真实点评分与个人偏好；餐饮仅作为独立候选池供午/晚餐顺路插入。
//  freeText 点名的点豁免筛选、必定保留。任何城市都稳定输出「经典景点为主 + 餐饮为辅」。

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
    static let preferenceBoost = 0.75
    static let cuisineBoost = 0.75
    static let affordableBoost = 0.25
    static let subtypeRepeatPenalty = 0.35
    static let popularityBoost = 2.5

    /// 无评分时给略低于常规优质点的保守分；若同时有高热度/地标证据，仍可进入经典景点前列。
    static let neutralRating = 3.7

    /// 高置信的城市地标/官方景区词。只作加分信号，不靠名称硬编码具体城市。
    private static let iconicHints = [
        "世界遗产", "世界文化遗产", "世界自然遗产", "国家级", "国家公园",
        "5A", "AAAAA", "4A", "AAAA", "必游", "必去", "地标", "名胜",
        "国家博物馆", "国家重点", "著名", "热门", "人气",
    ]
    private static let attractionHints = [
        "博物院", "博物馆", "纪念馆", "风景区", "名胜区", "遗址", "故居",
        "展览馆", "美术馆", "科技馆", "天文馆", "文化馆",
        "古城", "古镇", "宫", "陵", "长城", "国家森林公园",
    ]

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
                              pinned: Set<String> = [], required: Set<String> = [],
                              preferred: Set<String> = [], excluded: Set<String> = [],
                              limits: Limits = .init()) -> [POICandidate] {
        let protected = pinned.union(required)
        let nonLodging = candidates.filter { $0.kind != .lodging && !excluded.contains($0.id) }
        let pins = nonLodging.filter { protected.contains($0.id) }   // 点名/必去，豁免筛选
        func topRated(_ pool: [POICandidate], _ limit: Int) -> [POICandidate] {
            var remaining = pool.filter { !protected.contains($0.id) }
            var selected: [POICandidate] = []
            while !remaining.isEmpty, selected.count < max(0, limit) {
                let best = remaining.indices.max { a, b in
                    let sa = diversifiedScore(remaining[a], selected: selected, tags: tags,
                                              cuisines: cuisines, budgetPerDay: budgetPerDay)
                        + (preferred.contains(remaining[a].id) ? 1.25 : 0)
                    let sb = diversifiedScore(remaining[b], selected: selected, tags: tags,
                                              cuisines: cuisines, budgetPerDay: budgetPerDay)
                        + (preferred.contains(remaining[b].id) ? 1.25 : 0)
                    return sa == sb ? remaining[a].id > remaining[b].id : sa < sb
                } ?? 0
                selected.append(remaining.remove(at: best))
            }
            return selected
        }
        let sights = topRated(nonLodging.filter(isPrimaryAttraction), limits.sights)
        let food   = topRated(nonLodging.filter { $0.kind == .food }, limits.food)
        let other  = topRated(nonLodging.filter(isAuxiliaryActivity), limits.other)
        return pins + sights + food + other
    }

    /// 综合排序分：有评分用评分（无评分按中性分处理，不再沉底），命中偏好再加权。
    static func score(_ c: POICandidate, tags: [String],
                      cuisines: [String] = [], budgetPerDay: Int? = nil) -> Double {
        var result = c.rating ?? neutralRating
        if isPrimaryAttraction(c) { result += fameScore(c) }
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

    /// 经典景点优先分：显式/代理热度为主，官方地标标签为辅。
    /// 返回值独立于用户偏好，可用于跨天选择每天的核心景点。
    static func fameScore(_ c: POICandidate) -> Double {
        guard isPrimaryAttraction(c) else { return 0 }
        let popularity = min(1, max(0, c.visitMetadata.popularityScore ?? 0))
        let text = ([c.name, c.subtype] + c.tags).joined(separator: ";")
        let iconic = iconicHints.contains(where: { text.localizedCaseInsensitiveContains($0) }) ? 1.0 : 0
        // 通用“博物馆/风景区”只能提供弱证据，避免同类词反过来压过子类型多样性。
        let attraction = attractionHints.contains(where: { text.localizedCaseInsensitiveContains($0) }) ? 0.05 : 0
        return popularity * popularityBoost + iconic + attraction
    }

    /// 高德 11（风景名胜）直接进入主景点池；14（科教文化）仅保留博物馆、
    /// 美术馆等具有游览属性的场馆，学校/培训机构不进入。12 是商务住宅，不能当作景点。
    /// 旧缓存、测试桩及其它数据源没有原始类目码时，
    /// 继续按 `.sight` 兼容；点名/必去地点仍由调用方的 protected 规则兜底。
    static func isPrimaryAttraction(_ c: POICandidate) -> Bool {
        guard c.kind == .sight else { return false }
        guard let code = c.visitMetadata.sourceTypeCode, !code.isEmpty else { return true }
        let category = String(code.prefix(2))
        if category == "11" { return true }
        guard category == "14" else { return false }
        let text = ([c.name, c.subtype] + c.tags).joined(separator: ";")
        return attractionHints.contains { text.localizedCaseInsensitiveContains($0) }
    }

    /// 购物与休闲娱乐可留作“附近可选”，但商务住宅、交通设施、公司等泛搜索噪声
    /// 不应进入候选，更不能出现在用户看到的备选列表。
    private static func isAuxiliaryActivity(_ c: POICandidate) -> Bool {
        guard !isPrimaryAttraction(c), c.kind != .food, c.kind != .lodging else { return false }
        guard let code = c.visitMetadata.sourceTypeCode, !code.isEmpty else {
            return c.kind == .transit
        }
        return ["06", "08"].contains(String(code.prefix(2)))
    }

    /// 选每日核心景点时使用的稳定排序分，不受子类型多样性惩罚影响。
    static func classicPriorityScore(_ c: POICandidate) -> Double {
        fameScore(c) + (c.rating ?? neutralRating) / 5
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
