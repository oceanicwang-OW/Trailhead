//  ItineraryPlan.swift
//  LLM 行程输出的结构 + 解析（PDR T3.3 / §6 schema）。容错代码围栏，解析失败抛
//  LLMError.decoding（引擎据此重试一次）。

import Foundation

public struct ItineraryPlan: Codable, Equatable, Sendable {
    public struct Stop: Codable, Equatable, Sendable {
        public let poiId: String
        public let time: String?
        public let stayMin: Int?
        public let note: String?
        enum CodingKeys: String, CodingKey {
            case poiId = "poi_id"
            case time
            case stayMin = "stay_min"
            case note
        }
    }

    public struct Day: Codable, Equatable, Sendable {
        public let day: Int
        public let items: [Stop]
    }

    public let days: [Day]
}

public enum ItineraryParser {
    public static func parse(_ data: Data) throws -> ItineraryPlan {
        do {
            return try JSONDecoder().decode(ItineraryPlan.self, from: stripFences(data))
        } catch {
            throw LLMError.decoding("行程 JSON 解析失败：\(error.localizedDescription)")
        }
    }

    /// 去掉模型偶尔加的 ```json ... ``` 围栏与首尾空白。
    static func stripFences(_ data: Data) -> Data {
        guard var s = String(data: data, encoding: .utf8) else { return data }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") { s = String(s[s.index(after: firstNewline)...]) }
            if s.hasSuffix("```") { s = String(s.dropLast(3)) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Data(s.utf8)
    }
}
