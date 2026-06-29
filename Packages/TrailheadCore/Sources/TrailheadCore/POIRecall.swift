//  POIRecall.swift
//  缓存优先的 POI 召回（PDR T2.5 / §3 第 2 步）。按 tag 分类召回：命中未过期的
//  CachedPOI 直接用，未命中才调数据源并回填缓存 → 同城再次生成 0 次网络调用。
//  freeText 指定的具体地点（如「鼓浪屿」）先经关键词召回注入，保证进候选池。

import Foundation

public struct POIRecall {
    private let source: POIDataSource
    private let cache: POICache

    public init(source: POIDataSource, cache: POICache) {
        self.source = source
        self.cache = cache
    }

    /// 召回候选（去重）。先注入 freeText 关键词命中（用户点名的地点优先进池），
    /// 再按 tags 分类召回。每个维度（kw:<词> 或 tag）独立缓存，命中即省网络调用。
    /// @MainActor：缓存读写走 ModelContext，须在主线程；网络调用经 await 仍在后台。
    @MainActor
    public func recall(adcode: String, tags: [String], freeText: String = "", now: Date = .now) async throws -> [POICandidate] {
        var seen = Set<String>()
        var out: [POICandidate] = []

        // ① freeText 关键词命中：用户点名的具体地点优先进池。
        for keyword in POIKeywordExtractor.keywords(from: freeText) {
            let hits = try await fetchCached(adcode: adcode, category: "kw:\(keyword)", now: now) {
                try await source.searchPOI(keywords: keyword, adcode: adcode)
            }
            append(hits, into: &out, seen: &seen)
        }

        // ② 标签召回（每个 tag 一个缓存维度）。
        let categories = tags.isEmpty ? ["景点"] : Array(Set(tags)).sorted()
        for tag in categories {
            let candidates = try await fetchCached(adcode: adcode, category: tag, now: now) {
                try await source.searchPOI(adcode: adcode, tags: [tag])
            }
            append(candidates, into: &out, seen: &seen)
        }
        return out
    }

    /// 命中未过期缓存 → 直接用；否则回源并写回缓存。
    @MainActor
    private func fetchCached(adcode: String, category: String, now: Date,
                             fetch: () async throws -> [POICandidate]) async throws -> [POICandidate] {
        if let cached = try cache.fetch(adcode: adcode, category: category, now: now) { return cached }
        let fresh = try await fetch()
        try cache.store(fresh, adcode: adcode, category: category, at: now)
        return fresh
    }

    private func append(_ candidates: [POICandidate], into out: inout [POICandidate], seen: inout Set<String>) {
        for candidate in candidates where seen.insert(candidate.id).inserted {
            out.append(candidate)
        }
    }
}

// MARK: - freeText 关键词抽取

public enum POIKeywordExtractor {
    /// 句中的意向/连接词，剔除后剩具体地点名。
    static let stopwords: Set<String> = [
        "我", "想", "去", "想去", "要去", "喜欢", "希望", "打算", "顺便", "再", "和", "还有",
        "想要", "行程", "安排", "一定", "必须", "看看", "逛逛", "地方", "比较", "最好",
    ]
    /// token 开头的意向词前缀，剥掉后取地点名（「我想去鼓浪屿」→「鼓浪屿」）。
    static let leadingVerbs = ["我想去", "我要去", "想去", "要去", "我想", "去", "想", "到"]
    static let maxKeywords = 5

    /// 从 freeText 抽取可用于高德关键词搜索的地点名（最多 `maxKeywords` 个，去重）。
    public static func keywords(from freeText: String) -> [String] {
        let separators = CharacterSet(charactersIn: "、，,。.;；!！?？\n\t /（）()【】[]「」\"'")
        var out: [String] = []
        var seen = Set<String>()
        for rawToken in freeText.components(separatedBy: separators) {
            var token = rawToken.trimmingCharacters(in: .whitespaces)
            for verb in leadingVerbs where token.hasPrefix(verb) {
                token = String(token.dropFirst(verb.count))
                break
            }
            guard token.count >= 2, !stopwords.contains(token), seen.insert(token).inserted else { continue }
            out.append(token)
            if out.count >= maxKeywords { break }
        }
        return out
    }
}
