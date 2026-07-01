//  WaterGateTests.swift
//  跨水域/摆渡兜底（PDR 编排层改造 P6.3 / A1）：短距离跨海不再误判步行。
//  用例取厦门本岛·轮渡码头 ↔ 鼓浪屿（P8.2 回归场景）。

import Foundation
@testable import TrailheadCore
import XCTest

final class WaterGateTests: XCTestCase {

    private func poi(_ lat: Double, _ lng: Double) -> POICandidate {
        POICandidate(id: "\(lat),\(lng)", name: "x", kind: .sight, subtype: "", lat: lat, lng: lng)
    }

    // 鼓浪屿岛内点（岛心 900m 内）。
    private var gulangyuEast: POICandidate { poi(24.4485, 118.0700) }
    private var gulangyuWest: POICandidate { poi(24.4443, 118.0645) }
    // 厦门本岛·轮渡码头一带（岛外）。
    private var xiamenTerminal: POICandidate { poi(24.4498, 118.0819) }
    // 厦门本岛另一点。
    private var xiamenInland: POICandidate { poi(24.4600, 118.0900) }

    func testMainlandToIslandCrossesWater() {
        XCTAssertTrue(WaterGate.crossesWater(xiamenTerminal, gulangyuEast))
        XCTAssertTrue(WaterGate.crossesWater(gulangyuEast, xiamenTerminal))  // 对称
    }

    func testWithinIslandDoesNotCross() {
        XCTAssertFalse(WaterGate.crossesWater(gulangyuEast, gulangyuWest))
    }

    func testWithinMainlandDoesNotCross() {
        XCTAssertFalse(WaterGate.crossesWater(xiamenTerminal, xiamenInland))
    }

    // 核心 bug：跨海直线 <1500m，旧逻辑判「步行」，兜底后应为「轮渡」。
    func testShortCrossWaterIsFerryNotWalk() {
        let meters = ItineraryDayBuilder.haversineMeters(xiamenTerminal, gulangyuEast)
        XCTAssertLessThan(meters, 1500, "构造用例须为短距离，才能复现旧步行误判")
        XCTAssertEqual(ItineraryDayBuilder.mode(from: xiamenTerminal, to: gulangyuEast, city: "3502"), .ferry)
        XCTAssertEqual(ItineraryDayBuilder.mode(from: xiamenTerminal, to: gulangyuEast, city: ""), .ferry)
    }

    func testWithinIslandShortSegmentStillWalk() {
        let meters = ItineraryDayBuilder.haversineMeters(gulangyuEast, gulangyuWest)
        XCTAssertLessThan(meters, 1500)
        XCTAssertEqual(ItineraryDayBuilder.mode(from: gulangyuEast, to: gulangyuWest, city: "3502"), .walk)
    }

    // TravelEstimator 复用同一 mode()：跨海段自动走轮渡速度档。
    func testEstimatorUsesFerrySpeedForCrossWater() {
        let meters = ItineraryDayBuilder.haversineMeters(xiamenTerminal, gulangyuEast)
        let expected = Int((meters / (TravelEstimator.speedKmh(for: .ferry) * 1000 / 60)).rounded())
        XCTAssertEqual(TravelEstimator.minutes(from: xiamenTerminal, to: gulangyuEast, city: "3502"), expected)
    }
}
