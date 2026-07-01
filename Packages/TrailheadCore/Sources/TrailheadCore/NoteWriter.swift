//  NoteWriter.swift
//  P7.1 LLM 降级为文案（PDR §8 P7 / 未决②）。几何流水线排定顺序/时间/停留后，
//  这里作为**可选、非破坏性**的最后一步，只为定稿 stops 补 note + 每日主题：
//  - 越界忽略：LLM 引用了不存在的 day / poi_id，直接跳过，绝不改动几何；
//  - 畸形留空：LLM 报错或 JSON 解析失败，整体降级为「note 保持原样、主题 nil」，永不抛错。
//  纯编排（无 ModelContext），把「排得对」（确定性几何）与「说得好」（LLM 文案）彻底解耦。

import Foundation

public enum NoteWriter {
    /// 补文案结果：stops 的 note 已就位（其余字段原样）；themes 与 stops 天序对齐（缺失为 nil）。
    public struct Annotated: Sendable {
        public let stops: [[PlannedStop]]
        public let themes: [String?]
    }

    /// 为定稿行程补 note + 每日主题。任何失败都降级为原样返回，不抛错（P7 为锦上添花）。
    public static func annotate(stops: [[PlannedStop]], prefs: TripPrefs, llm: LLMProvider) async -> Annotated {
        let emptyThemes = [String?](repeating: nil, count: stops.count)
        guard stops.contains(where: { !$0.isEmpty }) else { return Annotated(stops: stops, themes: emptyThemes) }

        guard let data = try? await llm.annotateNotes(prefs: prefs, stops: stops),
              let sheet = try? JSONDecoder().decode(NoteSheet.self, from: ItineraryParser.stripFences(data)) else {
            return Annotated(stops: stops, themes: emptyThemes)   // 报错 / 畸形 → 留空降级
        }

        // LLM 用 1-based day；越界（不在行程天数内）的整天直接丢弃。
        var themeByIndex = [Int: String]()
        var notesByIndex = [Int: [String: String]]()
        for dayNotes in sheet.days {
            let index = dayNotes.day - 1
            guard stops.indices.contains(index) else { continue }
            if let theme = clean(dayNotes.theme) { themeByIndex[index] = theme }
            var perPOI = notesByIndex[index] ?? [:]
            for entry in dayNotes.notes ?? [] where clean(entry.note) != nil {
                perPOI[entry.poiId] = clean(entry.note)   // 未知 poi_id 会在下方匹配时自然忽略
            }
            notesByIndex[index] = perPOI
        }

        let annotatedStops = stops.enumerated().map { index, day -> [PlannedStop] in
            let perPOI = notesByIndex[index] ?? [:]
            return day.map { stop in
                guard let note = perPOI[stop.candidate.id] else { return stop }   // 无文案 → 原样
                return PlannedStop(candidate: stop.candidate, time: stop.time, stayMin: stop.stayMin, note: note)
            }
        }
        let themes = stops.indices.map { themeByIndex[$0] }
        return Annotated(stops: annotatedStops, themes: themes)
    }

    /// 去空白；空串视为无（畸形留空）。
    static func clean(_ s: String?) -> String? {
        guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// NoteWriter 的 LLM 输出结构（见 PromptBuilder.noteSchema）。
struct NoteSheet: Codable {
    struct Note: Codable {
        let poiId: String
        let note: String?
        enum CodingKeys: String, CodingKey { case poiId = "poi_id", note }
    }
    struct DayNotes: Codable {
        let day: Int
        let theme: String?
        let notes: [Note]?
    }
    let days: [DayNotes]
}
