//  CachedPOITests.swift
//  PDR T1.2 验收：写入 / 读取 / 过期。
//  用 XCTest（而非 Swift Testing）：SwiftData 的 ModelContext 与 Swift Testing
//  的 Task 执行模型存在 actor 隔离错配，会 SIGTRAP；XCTest 在主线程稳定运行。

import Foundation
import SwiftData
@testable import TrailheadCore
import XCTest

final class CachedPOITests: XCTestCase {

    func testStoreThenFetchReturnsCandidates() throws {
        let cache = POICache(context: try TestSupport.makeContext())
        try cache.store([TestSupport.candidate("A1"), TestSupport.candidate("A2")],
                        adcode: "110100", category: "美食")

        let hit = try cache.fetch(adcode: "110100", category: "美食")
        XCTAssertEqual(hit?.count, 2)
        XCTAssertEqual(Set(hit?.map(\.id) ?? []), ["A1", "A2"])
    }

    func testMissReturnsNil() throws {
        let cache = POICache(context: try TestSupport.makeContext())
        XCTAssertNil(try cache.fetch(adcode: "110100", category: "美食"))
    }

    func testCategoryAndAdcodeAreIsolated() throws {
        let cache = POICache(context: try TestSupport.makeContext())
        try cache.store([TestSupport.candidate("A1")], adcode: "110100", category: "美食")

        XCTAssertNil(try cache.fetch(adcode: "110100", category: "历史古迹"))
        XCTAssertNil(try cache.fetch(adcode: "510100", category: "美食"))
        XCTAssertEqual(try cache.fetch(adcode: "110100", category: "美食")?.count, 1)
    }

    func testUpsertOverwritesSameKey() throws {
        let cache = POICache(context: try TestSupport.makeContext())
        try cache.store([TestSupport.candidate("A1", name: "旧名")], adcode: "110100", category: "美食")
        try cache.store([TestSupport.candidate("A1", name: "新名")], adcode: "110100", category: "美食")

        let hit = try cache.fetch(adcode: "110100", category: "美食")
        XCTAssertEqual(hit?.count, 1)
        XCTAssertEqual(hit?.first?.name, "新名")
    }

    func testExpiredEntriesAreNotReturned() throws {
        let cache = POICache(context: try TestSupport.makeContext(), ttl: 7 * 24 * 60 * 60)
        let now = Date()
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)

        try cache.store([TestSupport.candidate("A1")], adcode: "110100", category: "美食", at: eightDaysAgo)

        XCTAssertNil(try cache.fetch(adcode: "110100", category: "美食", now: now))   // 过期 → 未命中
    }

    func testFreshWithinTTLIsReturned() throws {
        let cache = POICache(context: try TestSupport.makeContext(), ttl: 7 * 24 * 60 * 60)
        let now = Date()
        let sixDaysAgo = now.addingTimeInterval(-6 * 24 * 60 * 60)

        try cache.store([TestSupport.candidate("A1")], adcode: "110100", category: "美食", at: sixDaysAgo)

        XCTAssertEqual(try cache.fetch(adcode: "110100", category: "美食", now: now)?.count, 1)
    }

    func testPurgeExpiredRemovesOnlyStale() throws {
        let cache = POICache(context: try TestSupport.makeContext(), ttl: 7 * 24 * 60 * 60)
        let now = Date()
        try cache.store([TestSupport.candidate("OLD")], adcode: "110100", category: "美食",
                        at: now.addingTimeInterval(-10 * 24 * 60 * 60))
        try cache.store([TestSupport.candidate("NEW")], adcode: "110100", category: "美食", at: now)

        let removed = try cache.purgeExpired(now: now)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try cache.fetch(adcode: "110100", category: "美食", now: now)?.map(\.id), ["NEW"])
    }

    func testClearAllEmptiesCache() throws {
        let cache = POICache(context: try TestSupport.makeContext())
        try cache.store([TestSupport.candidate("A1"), TestSupport.candidate("A2")],
                        adcode: "110100", category: "美食")
        try cache.clearAll()
        XCTAssertNil(try cache.fetch(adcode: "110100", category: "美食"))
    }
}
