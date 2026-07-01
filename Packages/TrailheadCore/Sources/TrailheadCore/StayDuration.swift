//  StayDuration.swift
//  停留时长先验（PDR §4.2）。把「每点待多久」从大模型的 stay_min 收回为**确定性规则**：
//  按 kind/subtype 取基准分钟，再按 TripPrefs.pace 缩放（紧凑↔随性）。纯函数，便于单测。

import Foundation

public enum StayDuration {
    /// 各类停留基准分钟（可配）。subtype 命中 museum/nature 优先于 kind。
    public struct Priors: Sendable {
        public var sight: Int      // 一般景点
        public var museum: Int     // 博物馆/展馆
        public var nature: Int     // 公园/自然
        public var food: Int       // 餐饮
        public var other: Int      // 其它（非景非食非住）
        public init(sight: Int = 90, museum: Int = 120, nature: Int = 120,
                    food: Int = 60, other: Int = 60) {
            self.sight = sight; self.museum = museum; self.nature = nature
            self.food = food; self.other = other
        }
    }

    /// 博物馆/展馆类 subtype 关键词（命中 → museum 先验）。
    static let museumHints = ["博物馆", "展馆", "展览", "美术", "科技馆", "纪念馆"]
    /// 公园/自然类 subtype 关键词（命中 → nature 先验）。
    static let natureHints = ["公园", "植物园", "山", "湖", "海", "沙滩", "森林", "湿地", "岛", "风景", "自然", "瀑", "峡"]

    /// pace 系数（B2）：紧凑压缩、随性拉长；缩放基准时长让偏好落到每点停留上。
    static func paceFactor(_ pace: Pace) -> Double {
        switch pace {
        case .tight:   return 0.8
        case .relaxed: return 1.0
        case .casual:  return 1.2
        }
    }

    /// 停留分钟 = 基准（kind/subtype）× pace 系数，四舍五入取整。
    public static func duration(for c: POICandidate, pace: Pace, priors: Priors = .init()) -> Int {
        Int((Double(baseMinutes(for: c, priors: priors)) * paceFactor(pace)).rounded())
    }

    /// 基准分钟：餐饮恒取 food；景点内再按 subtype 细分 museum/nature，否则 sight；其余取 other。
    /// 只用 subtype 判定 museum/nature，避免餐厅名（如「海鲜」）被误判为自然景观。
    static func baseMinutes(for c: POICandidate, priors: Priors) -> Int {
        switch c.kind {
        case .food:
            return priors.food
        case .sight:
            if museumHints.contains(where: { c.subtype.contains($0) }) { return priors.museum }
            if natureHints.contains(where: { c.subtype.contains($0) }) { return priors.nature }
            return priors.sight
        default:
            return priors.other
        }
    }
}
