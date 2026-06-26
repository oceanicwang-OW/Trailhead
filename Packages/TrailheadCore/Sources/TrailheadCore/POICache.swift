//  POICache.swift
//  (adcode, category) 维度的 POI 本地缓存，带 TTL（PDR T1.2 / T2.5）。
//  召回优先命中本地缓存；未命中或全部过期才回源高德，省配额。

import Foundation
import SwiftData

public struct POICache {
    /// 默认 7 天（PDR §4）。
    public static let defaultTTL: TimeInterval = 7 * 24 * 60 * 60

    public let context: ModelContext
    public var ttl: TimeInterval

    public init(context: ModelContext, ttl: TimeInterval = POICache.defaultTTL) {
        self.context = context
        self.ttl = ttl
    }

    /// 写入/更新一批候选（按 adcode + category）。同键覆盖并刷新时间戳。
    public func store(_ candidates: [POICandidate], adcode: String, category: String, at date: Date = .now) throws {
        for candidate in candidates {
            let key = CachedPOI.makeKey(adcode: adcode, category: category, poiId: candidate.id)
            try deleteByKey(key)   // upsert：先删旧再插新，规避 unique 冲突
            context.insert(CachedPOI(candidate: candidate, adcode: adcode, category: category, cachedAt: date))
        }
        try context.save()
    }

    /// 命中未过期缓存则返回候选；无有效缓存返回 `nil`（区别于"命中但为空"）。
    public func fetch(adcode: String, category: String, now: Date = .now) throws -> [POICandidate]? {
        let fresh = try rows(adcode: adcode, category: category).filter { !$0.isExpired(ttl: ttl, now: now) }
        return fresh.isEmpty ? nil : fresh.map(\.candidate)
    }

    /// 清理所有过期项，返回删除条数。
    @discardableResult
    public func purgeExpired(now: Date = .now) throws -> Int {
        let expired = try context.fetch(FetchDescriptor<CachedPOI>()).filter { $0.isExpired(ttl: ttl, now: now) }
        expired.forEach(context.delete)
        try context.save()
        return expired.count
    }

    /// 清空全部缓存（设置页"清除离线缓存"用，PDR T7.3）。
    public func clearAll() throws {
        try context.delete(model: CachedPOI.self)
        try context.save()
    }

    // MARK: - helpers

    private func rows(adcode: String, category: String) throws -> [CachedPOI] {
        let predicate = #Predicate<CachedPOI> { $0.adcode == adcode && $0.category == category }
        return try context.fetch(FetchDescriptor(predicate: predicate))
    }

    private func deleteByKey(_ key: String) throws {
        let predicate = #Predicate<CachedPOI> { $0.key == key }
        for row in try context.fetch(FetchDescriptor(predicate: predicate)) {
            context.delete(row)
        }
    }
}
