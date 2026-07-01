//  ScheduleSimulatorTests.swift
//  时间前向模拟（PDR §4.7）：赋 time/stayMin，营业窗过滤（等待/丢弃/末尾截断），时间单调。
//  内部一律用当日分钟数 Int（B5）。

import Foundation
@testable import TrailheadCore
import XCTest

final class ScheduleSimulatorTests: XCTestCase {

    private func poi(_ id: String, _ lat: Double, _ lng: Double,
                     kind: ItemKind = .sight, openHours: String? = nil) -> POICandidate {
        POICandidate(id: id, name: id, kind: kind, subtype: "", lat: lat, lng: lng, openHours: openHours)
    }

    private let start = 9 * 60      // 09:00
    private let end = 20 * 60       // 20:00

    func testEmptyReturnsEmpty() {
        XCTAssertTrue(ScheduleSimulator.simulate(stops: [], pace: .relaxed, city: "").isEmpty)
    }

    func testFirstStopStartsAtDayStartWithStay() {
        let out = ScheduleSimulator.simulate(stops: [poi("a", 0, 0)], pace: .relaxed, city: "",
                                             dayStart: start, dayEnd: end)
        XCTAssertEqual(out.first?.arrival, start)                                   // 首点从 dayStart 起
        XCTAssertEqual(out.first?.stayMin, StayDuration.duration(for: poi("a", 0, 0), pace: .relaxed))
    }

    func testEarlyArrivalWaitsForOpen() {
        // 首点 11:00 才开门 → dayStart 09:00 到达需等到 11:00。
        let out = ScheduleSimulator.simulate(stops: [poi("late", 0, 0, openHours: "11:00-18:00")],
                                             pace: .relaxed, city: "", dayStart: start, dayEnd: end)
        XCTAssertEqual(out.first?.arrival, 11 * 60)
    }

    func testClosedOnArrivalIsDropped() {
        // 第二点 09:00-09:30 早闭；首点停留后到达已 > 09:30 → 丢弃第二点。
        let first = poi("open", 0, 0)
        let closed = poi("closed", 0, 0, openHours: "09:00-09:30")
        let out = ScheduleSimulator.simulate(stops: [first, closed], pace: .relaxed, city: "",
                                             dayStart: start, dayEnd: end)
        XCTAssertEqual(out.map(\.candidate.id), ["open"])
    }

    func testTruncatesTailBeyondDayEnd() {
        // dayEnd 收紧到 10:00：首点 09:00 停 90 分 → 次点到达 10:30 > dayEnd → 截断。
        let a = poi("a", 0, 0), b = poi("b", 0, 0), c = poi("c", 0, 0)
        let out = ScheduleSimulator.simulate(stops: [a, b, c], pace: .relaxed, city: "",
                                             dayStart: start, dayEnd: 10 * 60)
        XCTAssertEqual(out.map(\.candidate.id), ["a"])
    }

    func testTimesStrictlyIncreasing() {
        let stops = [poi("a", 0, 0), poi("b", 0, 0.01), poi("c", 0, 0.02), poi("d", 0, 0.03)]
        let out = ScheduleSimulator.simulate(stops: stops, pace: .relaxed, city: "",
                                             dayStart: start, dayEnd: end)
        let arrivals = out.map(\.arrival)
        XCTAssertEqual(arrivals, arrivals.sorted())
        XCTAssertEqual(Set(arrivals).count, arrivals.count)     // 严格递增（无重复）
    }

    func testAllDayNeverFiltered() {
        // 全天营业点即使很晚到达也不因营业窗被丢（保守）。
        let out = ScheduleSimulator.simulate(stops: [poi("x", 0, 0, openHours: "全天")],
                                             pace: .relaxed, city: "", dayStart: start, dayEnd: end)
        XCTAssertEqual(out.count, 1)
    }
}
