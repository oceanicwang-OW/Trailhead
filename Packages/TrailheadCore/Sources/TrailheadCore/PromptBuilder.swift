//  PromptBuilder.swift
//  行程编排 prompt 构造（PDR §6 / T3.2）。把候选 POI + 偏好 + JSON schema 拼成
//  消息，硬约束「只能引用候选 poi_id、不得杜撰」。T3.2 将补充专门单测与微调。

import Foundation

public enum PromptBuilder {
    /// 无评分 POI 的排序中性分（高德景点常缺 rating，避免地标被沉底）。
    static let unratedScore = 4.0

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
        你在为「一位独自旅行的个人游客」按其偏好把候选地点编排成 \(days) 天行程。
        候选 POI 已由系统按真实点评分筛选并降序排列——它们都是当地高分热门地点，请充分采用。
        硬规则：
        ① 只能引用「候选 POI」里给出的 poi_id，禁止杜撰任何地点；
        ② 必须优先选用评分最高的知名地标：整趟要尽量覆盖候选里评分靠前的景点，
           每天至少安排 2–3 个高分景点；不得因「片区聚合/减少折返」而丢掉高分地标，
           宁可多花点交通时间也要把当地招牌排进去；
        ③ 每天 4–6 个点，符合用户的节奏（pace）；
        ④ 餐饮（food）卡在饭点（午/晚），优先适合一人用餐的店；
        ⑤ 景点与餐饮搭配、类型轮换，别把同一类型堆在一起；同等知名度下，就近聚合减少折返；
        ⑥ 住宿不在此处编排（单独成清单），不要排入每日动线；
        ⑦ note 用一句话说明推荐理由，可结合该点的评分/类型/特色；
        ⑧ 严格输出 JSON，结构如下，不要任何额外文字：
        \(schema)
        """
    }

    // MARK: - P7 NoteWriter（只补文案，不动几何）

    /// NoteWriter 输出 schema：每天一个主题 + 若干贴士，poi_id 必须来自给定行程，不得新增/删除/改序。
    static let noteSchema = #"""
    { "days": [ { "day": 1, "theme": "一句话主题", "notes": [
      { "poi_id": "<行程中已有的 id>", "note": "一句话贴士" }
    ] } ] }
    """#

    public static func noteMessages(prefs: TripPrefs, stops: [[PlannedStop]]) -> [ChatMessage] {
        [ChatMessage(.system, noteSystemPrompt()),
         ChatMessage(.user, noteUserPrompt(prefs: prefs, stops: stops))]
    }

    static func noteSystemPrompt() -> String {
        """
        行程的顺序、时间、停留都已由系统排定且不可更改。你的唯一任务是「配文案」：
        ① 为每一天起一个简短主题（theme，≤12 字，概括当天调性，如「老城人文漫步」）；
        ② 为每个地点写一句话贴士（note，≤30 字，结合类型/特色/时段，实用不套话）；
        ③ 只能引用给定行程里已存在的 poi_id，禁止新增、删除或改动地点与顺序；
        ④ 拿不准的点可省略其 note（宁缺毋滥）；
        ⑤ 严格输出 JSON，结构如下，不要任何额外文字：
        \(noteSchema)
        """
    }

    static func noteUserPrompt(prefs: TripPrefs, stops: [[PlannedStop]]) -> String {
        var lines = ["旅行者偏好——节奏：\(prefs.pace.display)；兴趣：\(prefs.tags.joined(separator: "、"))"]
        if !prefs.freeText.isEmpty { lines.append("补充：\(prefs.freeText)") }
        lines.append("\n已排定行程（只为这些 poi_id 配文案）：")
        for (index, day) in stops.enumerated() {
            lines.append("第 \(index + 1) 天：")
            for stop in day {
                let time = stop.time.map { "\($0) " } ?? ""
                lines.append("- \(time)poi_id=\(stop.candidate.id) | \(stop.candidate.name) | "
                    + "\(stop.candidate.kind.label)/\(stop.candidate.subtype)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func userPrompt(prefs: TripPrefs, candidates: [POICandidate], days: Int) -> String {
        var lines = ["天数：\(days)",
                     "节奏：\(prefs.pace.display)",
                     "人均预算/天：¥\(prefs.budgetPerDay)",
                     "兴趣标签：\(prefs.tags.joined(separator: "、"))"]
        if !prefs.cuisines.isEmpty { lines.append("口味/菜系：\(prefs.cuisines.joined(separator: "、"))") }
        if !prefs.lodgingType.isEmpty { lines.append("住宿类型：\(prefs.lodgingType)") }
        if !prefs.freeText.isEmpty { lines.append("补充要求：\(prefs.freeText)") }
        lines.append("\n候选 POI（已按评分降序，只能从中选 poi_id）：")
        // 高德景点常无 rating，按中性分排序，避免「知名但无评分」的地标被沉底。
        let ranked = candidates.sorted { ($0.rating ?? unratedScore) > ($1.rating ?? unratedScore) }
        for c in ranked {
            let rating = c.rating.map { "评分\($0)" } ?? "无评分"
            let open = c.openHours.map { "营业\($0)" } ?? ""
            lines.append("- poi_id=\(c.id) | \(c.name) | \(c.kind.label)/\(c.subtype) | \(rating) \(open) | \(c.lng),\(c.lat)")
        }
        return lines.joined(separator: "\n")
    }
}
