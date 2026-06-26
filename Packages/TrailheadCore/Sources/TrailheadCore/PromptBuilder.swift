//  PromptBuilder.swift
//  行程编排 prompt 构造（PDR §6 / T3.2）。把候选 POI + 偏好 + JSON schema 拼成
//  消息，硬约束「只能引用候选 poi_id、不得杜撰」。T3.2 将补充专门单测与微调。

import Foundation

public enum PromptBuilder {
    /// 严格输出 schema（系统 prompt 内联给模型）。
    static let schema = #"""
    { "days": [ { "day": 1, "items": [
      { "poi_id": "<候选集中的 id>", "time": "09:00", "stay_min": 90, "note": "一句话理由" }
    ] } ] }
    """#

    public static func itineraryMessages(prefs: TripPrefs, candidates: [POICandidate], days: Int) -> [ChatMessage] {
        [ChatMessage(.system, systemPrompt(days: days)),
         ChatMessage(.user, userPrompt(prefs: prefs, candidates: candidates, days: days))]
    }

    static func systemPrompt(days: Int) -> String {
        """
        你是资深本地向导，按用户偏好把给定的候选地点编排成 \(days) 天行程。
        硬规则：
        ① 只能引用「候选 POI」里给出的 poi_id，禁止杜撰任何地点；
        ② 每天 4–6 个点，符合用户的节奏（pace）；
        ③ 同片区聚合，减少折返；
        ④ 餐饮（food）卡在饭点（午/晚）；
        ⑤ 严格输出 JSON，结构如下，不要任何额外文字：
        \(schema)
        """
    }

    static func userPrompt(prefs: TripPrefs, candidates: [POICandidate], days: Int) -> String {
        var lines = ["天数：\(days)",
                     "节奏：\(prefs.pace.display)",
                     "人均预算/天：¥\(prefs.budgetPerDay)",
                     "兴趣标签：\(prefs.tags.joined(separator: "、"))"]
        if !prefs.freeText.isEmpty { lines.append("补充要求：\(prefs.freeText)") }
        lines.append("\n候选 POI（只能从中选 poi_id）：")
        for c in candidates {
            let rating = c.rating.map { "评分\($0)" } ?? "无评分"
            let open = c.openHours.map { "营业\($0)" } ?? ""
            lines.append("- poi_id=\(c.id) | \(c.name) | \(c.kind.label)/\(c.subtype) | \(rating) \(open) | \(c.lng),\(c.lat)")
        }
        return lines.joined(separator: "\n")
    }
}
