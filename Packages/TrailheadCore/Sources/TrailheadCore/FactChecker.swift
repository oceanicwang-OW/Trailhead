//  FactChecker.swift
//  反幻觉兜底（PDR T3.4 / §3 第 5 步）：剔除候选集之外的 poi_id，并以高德候选的
//  原始字段为准回填（坐标/名称/类型等），不信 LLM 的事实字段。

import Foundation

/// 一个合法停留：候选（事实来源）+ LLM 给的时间/停留/贴士。
public struct PlannedStop: Equatable, Sendable {
    public let candidate: POICandidate
    public let time: String?
    public let stayMin: Int?
    public let note: String?
}

public enum FactChecker {
    /// 按天返回合法停留：丢弃非候选 poi_id；候选字段为事实来源。
    public static func reconcile(_ plan: ItineraryPlan, candidates: [POICandidate]) -> [[PlannedStop]] {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return plan.days
            .sorted { $0.day < $1.day }
            .map { day in
                day.items.compactMap { item -> PlannedStop? in
                    guard let candidate = byID[item.poiId] else { return nil }   // 非候选 → 丢弃
                    return PlannedStop(candidate: candidate, time: item.time,
                                       stayMin: item.stayMin, note: item.note)
                }
            }
    }
}
