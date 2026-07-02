//  TravelEstimatorTests.swift
//  行段时间估算（PDR §4.7 / §5，v2 含 D4 绕行系数）：haversine × circuity × 模式速度 → 分钟，
//  用于排序与卡点（非最终展示）。每段模式复用 ItineraryDayBuilder.mode()。

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

    func testCircuityTable() {
        // D4：步行 1.25 / 公交 1.40 / 驾车 1.35。
        XCTAssertEqual(TravelEstimator.circuity(for: .walk), 1.25)
        XCTAssertEqual(TravelEstimator.circuity(for: .metro), 1.40)
        XCTAssertEqual(TravelEstimator.circuity(for: .bus), 1.40)
        XCTAssertEqual(TravelEstimator.circuity(for: .drive), 1.35)
        XCTAssertEqual(TravelEstimator.circuity(for: .taxi), 1.35)
    }

    func testShortSegmentUsesWalkSpeedWithCircuity() {
        // ~1112m（<1500）→ 步行 5km/h × 绕行 1.25。
        let a = poi(0, 0), b = poi(0, 0.01)
        let meters = ItineraryDayBuilder.haversineMeters(a, b) * 1.25
        let expected = Int((meters / (5 * 1000 / 60)).rounded())
        XCTAssertEqual(TravelEstimator.minutes(from: a, to: b, city: ""), expected)
    }

    func testLongSegmentNoCityUsesDriveSpeedWithCircuity() {
        // ~5560m（>1500）、无 city → 驾车 30km/h × 绕行 1.35。
        let a = poi(0, 0), b = poi(0, 0.05)
        let meters = ItineraryDayBuilder.haversineMeters(a, b) * 1.35
        let expected = Int((meters / (30 * 1000 / 60)).rounded())
        XCTAssertEqual(TravelEstimator.minutes(from: a, to: b, city: ""), expected)
    }

    func testLongSegmentWithCityUsesTransitSpeedWithCircuity() {
        // 同段有 city → 公交 18km/h × 绕行 1.40，用时多于驾车。
        let a = poi(0, 0), b = poi(0, 0.05)
        let meters = ItineraryDayBuilder.haversineMeters(a, b) * 1.40
        let expected = Int((meters / (18 * 1000 / 60)).rounded())
        XCTAssertEqual(TravelEstimator.minutes(from: a, to: b, city: "3502"), expected)
        XCTAssertGreaterThan(TravelEstimator.minutes(from: a, to: b, city: "3502"),
                             TravelEstimator.minutes(from: a, to: b, city: ""))
    }

    func testCircuityIncreasesEstimateOverPlainHaversine() {
        // 绕行系数生效：估算用时严格大于无系数直线估算。
        let a = poi(0, 0), b = poi(0, 0.05)
        let plain = Int((ItineraryDayBuilder.haversineMeters(a, b) / (30 * 1000 / 60)).rounded())
        XCTAssertGreaterThan(TravelEstimator.minutes(from: a, to: b, city: ""), plain)
    }

    func testSamePointZeroMinutes() {
        let a = poi(1, 1)
        XCTAssertEqual(TravelEstimator.minutes(from: a, to: a, city: ""), 0)
    }
}
