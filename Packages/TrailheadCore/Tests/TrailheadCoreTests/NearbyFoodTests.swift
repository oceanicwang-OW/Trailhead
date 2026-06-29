//  NearbyFoodTests.swift
//  当天附近美食：就近 + 高分、排除已用、无坐标退化全城高分。

import Foundation
@testable import TrailheadCore
import XCTest

final class NearbyFoodTests: XCTestCase {

    private func food(_ id: String, rating: Double, lat: Double, lng: Double) -> POICandidate {
        POICandidate(id: id, name: id, kind: .food, subtype: "海鲜", lat: lat, lng: lng, rating: rating)
    }

    func testPicksNearbyHighRatedAndExcludesUsed() {
        let pool = [
            food("near_hi", rating: 4.6, lat: 24.480, lng: 118.090),   // 距参照很近
            food("near_lo", rating: 4.0, lat: 24.481, lng: 118.091),
            food("far",     rating: 4.9, lat: 25.500, lng: 119.500),   // 远（>2.5km）
            food("used",    rating: 5.0, lat: 24.480, lng: 118.090),
        ]
        let out = NearbyFood.pick(pool, nearCoords: [(24.480, 118.090)], excluding: ["used"], limit: 3)

        XCTAssertFalse(out.contains { $0.id == "used" })       // 已排进动线的排除
        XCTAssertEqual(out.first?.id, "near_hi")               // 近 + 高分优先
        XCTAssertTrue(out.contains { $0.id == "far" })         // 近的不够时远的兜底补齐
        XCTAssertLessThan(out.firstIndex { $0.id == "near_hi" }!,
                          out.firstIndex { $0.id == "far" }!)  // 近的排在远的前
    }

    func testNoCoordsFallsBackToCityWideTopRated() {
        let pool = [food("a", rating: 4.2, lat: 0, lng: 0), food("b", rating: 4.8, lat: 9, lng: 9)]
        let out = NearbyFood.pick(pool, nearCoords: [], limit: 2)
        XCTAssertEqual(out.map(\.id), ["b", "a"])              // 无参照 → 全城按评分
    }

    func testOnlyFoodKindConsidered() {
        let pool = [
            POICandidate(id: "sight", name: "x", kind: .sight, subtype: "", lat: 0, lng: 0, rating: 5.0),
            food("f", rating: 4.0, lat: 0, lng: 0),
        ]
        let out = NearbyFood.pick(pool, nearCoords: [], limit: 5)
        XCTAssertEqual(out.map(\.id), ["f"])                  // 非餐饮不入美食清单
    }
}
