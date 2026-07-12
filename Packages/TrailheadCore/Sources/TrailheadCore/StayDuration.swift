//  StayDuration.swift
//  停留时长兼容入口。默认走 VisitProfileResolver 的通用范围/特征模型；Priors 仅保留给
//  既有调用方和定向测试，不参与正常行程生成。

import Foundation

public enum StayDuration {
    /// 各类停留基准分钟（可配）。subtype 命中 museum/nature 优先于 kind。
    public struct Priors: Equatable, Sendable {
        public var sight: Int      // 一般景点
        public var museum: Int     // 博物馆/展馆
        public var nature: Int     // 公园/自然
        public var food: Int       // 餐饮
        public var other: Int      // 其它（非景非食非住）
        public init(sight: Int = 105, museum: Int = 165, nature: Int = 210,
                    food: Int = 75, other: Int = 60) {
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

    /// 默认配置使用通用弹性时长模型；显式自定义 Priors 保留旧的可预测覆盖语义。
    public static func duration(for c: POICandidate, pace: Pace, priors: Priors = .init()) -> Int {
        if priors == Priors() {
            return VisitProfileResolver.selectedMinutes(for: c, pace: pace)
        }
        return Int((Double(baseMinutes(for: c, priors: priors)) * paceFactor(pace)).rounded())
    }

    public static func profile(for candidate: POICandidate,
                               override: VisitDurationOverride? = nil) -> VisitProfile {
        VisitProfileResolver.resolve(candidate, override: override)
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
