//  TravelEstimatorTests.swift
//  行段时间估算（PDR §4.7 / §5）：haversine × 模式速度 → 分钟，用于排序与卡点（非最终展示）。
//  每段模式复用 ItineraryDayBuilder.mode()：短途步行、远途按 city 走公交/驾车。

import Foundation
@testable import TrailheadCore
import XCTest

final class TravelEstimatorTests: XCTestCase {

    private func poi(_ lat: Double, _ lng: Double) -> POICandidate {
        POICandidate(id: "\(lat),\(lng)", name: "x", kind: .sight, subtype: "", lat: lat, lng: lng)
    }

    func testSpeedTable() {
        XCTAssertEqual(TravelEstimator.speedKmh(for: .walk), 5)
        XCTAssertEqual(TravelEstimator.speedKmh(for: .metro), 18)
        XCTAssertEqual(TravelEstimator.speedKmh(for: .bus), 18)
        XCTAssertEqual(TravelEstimator.speedKmh(for: .drive), 30)
        XCTAssertEqual(TravelEstimator.speedKmh(for: .taxi), 30)
    }

    func testShortSegmentUsesWalkSpeed() {
        // ~1112m（<1500）→ 步行 5km/h。
        let a = poi(0, 0), b = poi(0, 0.01)
        let meters = ItineraryDayBuilder.haversineMeters(a, b)
        let expected = Int((meters / (5 * 1000 / 60)).rounded())
        XCTAssertEqual(TravelEstimator.minutes(from: a, to: b, city: ""), expected)
    }

    func testLongSegmentNoCityUsesDriveSpeed() {
        // ~5560m（>1500）、无 city → 驾车 30km/h。
        let a = poi(0, 0), b = poi(0, 0.05)
        let meters = ItineraryDayBuilder.haversineMeters(a, b)
        let expected = Int((meters / (30 * 1000 / 60)).rounded())
        XCTAssertEqual(TravelEstimator.minutes(from: a, to: b, city: ""), expected)
    }

    func testLongSegmentWithCityUsesTransitSpeed() {
        // 同段有 city → 公交 18km/h，用时多于驾车。
        let a = poi(0, 0), b = poi(0, 0.05)
        let meters = ItineraryDayBuilder.haversineMeters(a, b)
        let expected = Int((meters / (18 * 1000 / 60)).rounded())
        XCTAssertEqual(TravelEstimator.minutes(from: a, to: b, city: "3502"), expected)
        XCTAssertGreaterThan(TravelEstimator.minutes(from: a, to: b, city: "3502"),
                             TravelEstimator.minutes(from: a, to: b, city: ""))
    }

    func testSamePointZeroMinutes() {
        let a = poi(1, 1)
        XCTAssertEqual(TravelEstimator.minutes(from: a, to: a, city: ""), 0)
    }
}
