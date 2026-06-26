//  POIRecallTests.swift
//  PDR T2.5 验收：缓存优先；二次同城召回 0 次网络调用。

import Foundation
@testable import TrailheadCore
import XCTest

/// 记录调用次数的假数据源。
private final class SpyPOISource: POIDataSource {
    private(set) var searchCalls: [(adcode: String, tags: [String])] = []
    var byCategory: [String: [POICandidate]] = [:]

    func geocodeCity(_ name: String) async throws -> (adcode: String, center: (Double, Double)) {
        ("000000", (0, 0))
    }

    var failWithQuota = false
    func searchPOI(adcode: String, tags: [String]) async throws -> [POICandidate] {
        searchCalls.append((adcode, tags))
        if failWithQuota { throw AmapError.quotaExceeded }
        return tags.flatMap { byCategory[$0] ?? [] }
    }

    func route(from: POICandidate, to: POICandidate,
               mode: TransitMode, city: String) async throws -> (minutes: Int, meters: Int, cost: Int?) {
        (10, 1000, nil)
    }
}

final class POIRecallTests: XCTestCase {

    private func candidate(_ id: String) -> POICandidate {
        POICandidate(id: id, name: id, kind: .sight, subtype: "", lat: 1, lng: 2)
    }

    func testFirstRecallHitsSourceAndFillsCache() async throws {
        let spy = SpyPOISource()
        spy.byCategory = ["美食": [candidate("F1"), candidate("F2")]]
        let cache = POICache(context: try TestSupport.makeContext())
        let recall = POIRecall(source: spy, cache: cache)

        let result = try await recall.recall(adcode: "110100", tags: ["美食"])

        XCTAssertEqual(result.map(\.id), ["F1", "F2"])
        XCTAssertEqual(spy.searchCalls.count, 1)                       // 首次回源
        XCTAssertEqual(try cache.fetch(adcode: "110100", category: "美食")?.count, 2)  // 已回填
    }

    func testSecondRecallHitsCacheZeroNetwork() async throws {
        let spy = SpyPOISource()
        spy.byCategory = ["美食": [candidate("F1")]]
        let cache = POICache(context: try TestSupport.makeContext())
        let recall = POIRecall(source: spy, cache: cache)

        _ = try await recall.recall(adcode: "110100", tags: ["美食"])
        _ = try await recall.recall(adcode: "110100", tags: ["美食"])   // 同城二次

        XCTAssertEqual(spy.searchCalls.count, 1)   // 关键：第二次 0 次网络调用
    }

    func testEachTagIsIndependentlyCachedAndDeduped() async throws {
        let spy = SpyPOISource()
        spy.byCategory = [
            "美食": [candidate("A"), candidate("DUP")],
            "历史古迹": [candidate("DUP"), candidate("B")],
        ]
        let cache = POICache(context: try TestSupport.makeContext())
        let recall = POIRecall(source: spy, cache: cache)

        let result = try await recall.recall(adcode: "110100", tags: ["美食", "历史古迹"])

        XCTAssertEqual(spy.searchCalls.count, 2)                 // 每 tag 一次
        XCTAssertEqual(Set(result.map(\.id)), ["A", "B", "DUP"]) // 跨 tag 去重
        XCTAssertEqual(result.filter { $0.id == "DUP" }.count, 1)
    }

    func testExpiredCacheTriggersRefetch() async throws {
        let spy = SpyPOISource()
        spy.byCategory = ["美食": [candidate("F1")]]
        let cache = POICache(context: try TestSupport.makeContext(), ttl: 7 * 24 * 60 * 60)
        let recall = POIRecall(source: spy, cache: cache)
        let day0 = Date()

        _ = try await recall.recall(adcode: "110100", tags: ["美食"], now: day0)
        // 8 天后：缓存过期 → 重新回源
        _ = try await recall.recall(adcode: "110100", tags: ["美食"],
                                    now: day0.addingTimeInterval(8 * 24 * 60 * 60))

        XCTAssertEqual(spy.searchCalls.count, 2)
    }

    func testQuotaErrorStillServesCachedCandidates() async throws {
        // PDR T8.2 降级：缓存有数据时，即便数据源配额耗尽也能返回缓存。
        let cache = POICache(context: try TestSupport.makeContext())
        try cache.store([candidate("F1")], adcode: "110100", category: "美食")

        let spy = SpyPOISource()
        spy.failWithQuota = true
        let recall = POIRecall(source: spy, cache: cache)

        let result = try await recall.recall(adcode: "110100", tags: ["美食"])
        XCTAssertEqual(result.map(\.id), ["F1"])     // 命中缓存
        XCTAssertEqual(spy.searchCalls.count, 0)     // 未触达数据源（不会抛配额错误）
    }

    func testDifferentCityDoesNotHitOtherCityCache() async throws {
        let spy = SpyPOISource()
        spy.byCategory = ["美食": [candidate("F1")]]
        let cache = POICache(context: try TestSupport.makeContext())
        let recall = POIRecall(source: spy, cache: cache)

        _ = try await recall.recall(adcode: "110100", tags: ["美食"])   // 北京
        _ = try await recall.recall(adcode: "510100", tags: ["美食"])   // 成都

        XCTAssertEqual(spy.searchCalls.count, 2)   // 异城互不命中
    }
}
