//  POIRecall.swift
//  缓存优先的 POI 召回（PDR T2.5 / §3 第 2 步）。按 tag 分类召回：命中未过期的
//  CachedPOI 直接用，未命中才调数据源并回填缓存 → 同城再次生成 0 次网络调用。

import Foundation

public struct POIRecall {
    private let source: POIDataSource
    private let cache: POICache

    public init(source: POIDataSource, cache: POICache) {
        self.source = source
        self.cache = cache
    }

    /// 按 tags 召回候选（去重）。每个 tag 为一个缓存维度：
    /// 命中缓存 → 用缓存；未命中 → 调 `source.searchPOI(单 tag)` 并写回缓存。
    /// @MainActor：缓存读写走 ModelContext，须在主线程；网络调用经 await 仍在后台。
    @MainActor
    public func recall(adcode: String, tags: [String], now: Date = .now) async throws -> [POICandidate] {
        let categories = tags.isEmpty ? ["景点"] : Array(Set(tags)).sorted()
        var seen = Set<String>()
        var out: [POICandidate] = []
        for tag in categories {
            let candidates: [POICandidate]
            if let cached = try cache.fetch(adcode: adcode, category: tag, now: now) {
                candidates = cached
            } else {
                let fetched = try await source.searchPOI(adcode: adcode, tags: [tag])
                try cache.store(fetched, adcode: adcode, category: tag, at: now)
                candidates = fetched
            }
            for candidate in candidates where seen.insert(candidate.id).inserted {
                out.append(candidate)
            }
        }
        return out
    }
}
