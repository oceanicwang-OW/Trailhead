//  ScheduleSimulatorTests.swift
//  时间前向模拟（PDR §4.7，v2 含 D2/D3/D5）：赋 time/stayMin，营业窗过滤（等待/交换/丢弃），
//  周闭馆判不可行，早到过等交换/后移，截断按最低分牺牲进 spill。内部一律当日分钟数 Int（B5）。

import Foundation
@testable import TrailheadCore
import XCTest

final class ScheduleSimulatorTests: XCTestCase {

    private func poi(_ id: String, _ lat: Double, _ lng: Double,
                     kind: ItemKind = .sight, openHours: String? = nil,
                     rating: Double? = nil) -> POICandidate {
        POICandidate(id: id, name: id, kind: kind, subtype: "", lat: lat, lng: lng,
                     rating: rating, openHours: openHours)
    }

    private let start = 9 * 60      // 09:00
    private let end = 20 * 60       // 20:00

    func testEmptyReturnsEmpty() {
        let out = ScheduleSimulator.simulate(stops: [], pace: .relaxed, city: "")
        XCTAssertTrue(out.scheduled.isEmpty)
        XCTAssertTrue(out.spilled.isEmpty)
    }

    func testFirstStopStartsAtDayStartWithStay() {
        let out = ScheduleSimulator.simulate(stops: [poi("a", 0, 0)], pace: .relaxed, city: "",
                                             dayStart: start, dayEnd: end)
        XCTAssertEqual(out.scheduled.first?.arrival, start)                          // 首点从 dayStart 起
        XCTAssertEqual(out.scheduled.first?.stayMin,
                       StayDuration.duration(for: poi("a", 0, 0), pace: .relaxed))
    }

    func testEarlyArrivalWithinMaxWaitWaitsForOpen() {
        // 首点 09:30 开门 → 09:00 到达等 30 分（≤ maxWait 45）→ 09:30 落位。
        let out = ScheduleSimulator.simulate(stops: [poi("late", 0, 0, openHours: "09:30-18:00")],
                                             pace: .relaxed, city: "", dayStart: start, dayEnd: end)
        XCTAssertEqual(out.scheduled.first?.arrival, 9 * 60 + 30)
        XCTAssertTrue(out.spilled.isEmpty)
    }

    func testOverWaitTriggersSwapWithNextStop() {
        // D5：首点 11:00 才开门（等待 120 > 45）→ 与后点交换（先访问 b，回头再来 a）。
        // b 停留 90 分（relaxed 景点）→ 回到 a 时 10:30，等 30 分 ≤ maxWait → 11:00 落位。
        let a = poi("a", 0, 0, openHours: "11:00-18:00")
        let b = poi("b", 0, 0)
        let out = ScheduleSimulator.simulate(stops: [a, b], pace: .relaxed, city: "",
                                             dayStart: start, dayEnd: end)
        XCTAssertEqual(out.scheduled.map(\.candidate.id), ["b", "a"])
        XCTAssertEqual(out.scheduled.last?.arrival, 11 * 60)
        XCTAssertTrue(out.spilled.isEmpty)
    }

    func testOverWaitLonePointIsSpilled() {
        // D5 对称分支：单点日 11:00 开门、无点可换/可垫 → 丢进 spill（不再干等 2 小时）。
        let out = ScheduleSimulator.simulate(stops: [poi("late", 0, 0, openHours: "11:00-18:00")],
                                             pace: .relaxed, city: "", dayStart: start, dayEnd: end)
        XCTAssertTrue(out.scheduled.isEmpty)
        XCTAssertEqual(out.spilled.map(\.candidate.id), ["late"])
        XCTAssertEqual(out.spilled.first?.reason, "开门等待超限")
    }

    func testClosedOnArrivalIsSpilled() {
        // 第二点 08:00-08:30 早闭（早于 dayStart）；迟到交换前移后仍不可行 → spill。
        let first = poi("open", 0, 0)
        let closed = poi("closed", 0, 0, openHours: "08:00-08:30")
        let out = ScheduleSimulator.simulate(stops: [first, closed], pace: .relaxed, city: "",
                                             dayStart: start, dayEnd: end)
        XCTAssertEqual(out.scheduled.map(\.candidate.id), ["open"])
        XCTAssertEqual(out.spilled.map(\.candidate.id), ["closed"])
        XCTAssertEqual(out.spilled.first?.reason, "错过营业窗")
    }

    func testMissedWindowRescuedBySwapKeepsBothStops() {
        // 09:00-09:30 早闭点排第二会错过；与前点交换后 09:00 到达在窗内 → 两点都保住。
        let first = poi("open", 0, 0)
        let narrow = poi("narrow", 0, 0, openHours: "09:00-09:30")
        let out = ScheduleSimulator.simulate(stops: [first, narrow], pace: .relaxed, city: "",
                                             dayStart: start, dayEnd: end)
        XCTAssertEqual(out.scheduled.map(\.candidate.id), ["narrow", "open"])
        XCTAssertTrue(out.spilled.isEmpty)
    }

    func testLateArrivalRescuedBySwapWithPrevious() {
        // 迟到交换前移：b 只开到 11:00，排在 a（停 90 分）后会 10:30 到、11:00 前赶不完？
        // 10:30 ≤ close 11:00 仍可行；改用 10:00 闭门 → a 后到达 10:30 > 10:00 错过 →
        // 与 a 交换 → b 09:00 落位、a 其后，两点都保住。
        let a = poi("a", 0, 0)
        let b = poi("b", 0, 0, openHours: "09:00-10:00")
        let out = ScheduleSimulator.simulate(stops: [a, b], pace: .relaxed, city: "",
                                             dayStart: start, dayEnd: end)
        XCTAssertEqual(out.scheduled.map(\.candidate.id), ["b", "a"])
        XCTAssertTrue(out.spilled.isEmpty)
    }

    func testMondayClosedMuseumIsSpilledOnMonday() {
        // D2：博物馆「周一闭馆」——weekday=1 时判当日不可行进 spill；weekday=2 正常落位。
        let museum = poi("museum", 0, 0, openHours: "09:00-17:00，周一闭馆")
        let monday = ScheduleSimulator.simulate(stops: [museum], pace: .relaxed, city: "",
                                                weekday: 1, dayStart: start, dayEnd: end)
        XCTAssertTrue(monday.scheduled.isEmpty)
        XCTAssertEqual(monday.spilled.first?.reason, "当日闭馆")

        let tuesday = ScheduleSimulator.simulate(stops: [museum], pace: .relaxed, city: "",
                                                 weekday: 2, dayStart: start, dayEnd: end)
        XCTAssertEqual(tuesday.scheduled.map(\.candidate.id), ["museum"])
    }

    func testNoWeekdayDegradesToBaseWindows() {
        // 行程无日期（weekday=nil）→ 周闭馆不生效，退化 base 语义（与 v1 一致）。
        let museum = poi("museum", 0, 0, openHours: "09:00-17:00，周一闭馆")
        let out = ScheduleSimulator.simulate(stops: [museum], pace: .relaxed, city: "",
                                             weekday: nil, dayStart: start, dayEnd: end)
        XCTAssertEqual(out.scheduled.count, 1)
    }

    func testOverflowSacrificesLowestScoreNotTail() {
        // D3：dayEnd 11:30 只装得下两点；排尾 c 是最高分招牌 → 牺牲的应是低分 b，而非按位置砍 c。
        let a = poi("a", 0, 0, rating: 4.5)
        let b = poi("b", 0, 0, rating: 3.0)
        let c = poi("c", 0, 0, rating: 5.0)
        let out = ScheduleSimulator.simulate(stops: [a, b, c], pace: .relaxed, city: "",
                                             dayStart: start, dayEnd: 11 * 60 + 30)
        XCTAssertEqual(out.scheduled.map(\.candidate.id), ["a", "c"])
        XCTAssertEqual(out.spilled.map(\.candidate.id), ["b"])
        XCTAssertEqual(out.spilled.first?.reason, "超出当日时间窗")
    }

    func testTimesStrictlyIncreasing() {
        let stops = [poi("a", 0, 0), poi("b", 0, 0.01), poi("c", 0, 0.02), poi("d", 0, 0.03)]
        let out = ScheduleSimulator.simulate(stops: stops, pace: .relaxed, city: "",
                                             dayStart: start, dayEnd: end)
        let arrivals = out.scheduled.map(\.arrival)
        XCTAssertEqual(arrivals, arrivals.sorted())
        XCTAssertEqual(Set(arrivals).count, arrivals.count)     // 严格递增（无重复）
    }

    func testAllDayNeverFiltered() {
        // 全天营业点即使很晚到达也不因营业窗被丢（保守）。
        let out = ScheduleSimulator.simulate(stops: [poi("x", 0, 0, openHours: "全天")],
                                             pace: .relaxed, city: "", dayStart: start, dayEnd: end)
        XCTAssertEqual(out.scheduled.count, 1)
        XCTAssertTrue(out.spilled.isEmpty)
    }
}
