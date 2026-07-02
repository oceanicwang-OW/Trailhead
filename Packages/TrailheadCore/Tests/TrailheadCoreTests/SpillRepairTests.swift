//  SpillRepairTests.swift
//  跨天重插（PDR §4.8 · D3）：spill 按分数降序尝试其它天最小绕行插入 + 目标天重模拟；
//  重插不破坏已有硬约束；无处可插才进最终丢弃清单。

import Foundation
@testable import TrailheadCore
import XCTest

final class SpillRepairTests: XCTestCase {

    private func poi(_ id: String, _ lat: Double, _ lng: Double,
                     kind: ItemKind = .sight, openHours: String? = nil,
                     rating: Double? = nil) -> POICandidate {
        POICandidate(id: id, name: id, kind: kind, subtype: "", lat: lat, lng: lng,
                     rating: rating, openHours: openHours)
    }

    private func ctx(weekdays: [Int?], maxSights: Int = 4, budget: Int? = nil) -> SpillRepair.Context {
        SpillRepair.Context(pace: .relaxed, city: "", weekdays: weekdays,
                            maxSightsPerDay: maxSights, stayBudget: budget)
    }

    func testMondayClosedMuseumReinsertedToTuesday() {
        // D2+D3 主场景：周一闭馆的招牌博物馆被 day0（周一）丢出 → 重插到 day1（周二）。
        let museum = poi("museum", 0, 0.001, openHours: "09:00-17:00，周一闭馆", rating: 5.0)
        let orders = [[poi("s1", 0, 0)], [poi("s2", 0, 0.002)]]
        let (repaired, dropped) = SpillRepair.repair(
            dayOrders: orders,
            spill: [(day: 0, stop: SpilledStop(candidate: museum, reason: "当日闭馆"))],
            context: ctx(weekdays: [1, 2]))

        XCTAssertTrue(dropped.isEmpty)
        XCTAssertFalse(repaired[0].contains { $0.id == "museum" })       // 不回原天
        XCTAssertTrue(repaired[1].contains { $0.id == "museum" })        // 落到周二
        XCTAssertTrue(repaired[1].contains { $0.id == "s2" })            // 不破坏已有点
    }

    func testNoFeasibleDayGoesToDroppedWithoutSideEffects() {
        // 目标天同样闭馆（周一）→ 无处可插 → 进丢弃清单，其它天原样不动。
        let museum = poi("museum", 0, 0.001, openHours: "09:00-17:00，周一闭馆", rating: 5.0)
        let orders = [[poi("s1", 0, 0)], [poi("s2", 0, 0.002)]]
        let (repaired, dropped) = SpillRepair.repair(
            dayOrders: orders,
            spill: [(day: 0, stop: SpilledStop(candidate: museum, reason: "当日闭馆"))],
            context: ctx(weekdays: [1, 1]))

        XCTAssertEqual(dropped.map(\.candidate.id), ["museum"])
        XCTAssertEqual(repaired[0].map(\.id), ["s1"])
        XCTAssertEqual(repaired[1].map(\.id), ["s2"])
    }

    func testFullDayByCapacityIsSkipped() {
        // 目标天点数已达上限 → 跳过 → 丢弃。
        let extra = poi("extra", 0, 0.001, rating: 4.0)
        let orders = [[poi("s1", 0, 0)], [poi("s2", 0, 0.002)]]
        let (_, dropped) = SpillRepair.repair(
            dayOrders: orders,
            spill: [(day: 0, stop: SpilledStop(candidate: extra, reason: "超出当日时间窗"))],
            context: ctx(weekdays: [nil, nil], maxSights: 1))

        XCTAssertEqual(dropped.map(\.candidate.id), ["extra"])
    }

    func testTimeBudgetFullIsSkipped() {
        // D7 时间预算：目标天 Σ停留已够满（s2 relaxed 景点 90 分，预算 120，再插 90 分超）→ 丢弃。
        let extra = poi("extra", 0, 0.001, rating: 4.0)
        let orders = [[poi("s1", 0, 0)], [poi("s2", 0, 0.002)]]
        let (_, dropped) = SpillRepair.repair(
            dayOrders: orders,
            spill: [(day: 0, stop: SpilledStop(candidate: extra, reason: "超出当日时间窗"))],
            context: ctx(weekdays: [nil, nil], budget: 120))

        XCTAssertEqual(dropped.map(\.candidate.id), ["extra"])
    }

    func testInsertsAtMinimalDetourPosition() {
        // day1 动线 a(0,0) → b(0,0.02)；spill 点在两者中间 (0,0.01) → 应插在 a、b 之间。
        let mid = poi("mid", 0, 0.01, rating: 4.0)
        let orders = [[poi("far", 1, 1)], [poi("a", 0, 0), poi("b", 0, 0.02)]]
        let (repaired, dropped) = SpillRepair.repair(
            dayOrders: orders,
            spill: [(day: 0, stop: SpilledStop(candidate: mid, reason: "超出当日时间窗"))],
            context: ctx(weekdays: [nil, nil]))

        XCTAssertTrue(dropped.isEmpty)
        XCTAssertEqual(repaired[1].map(\.id), ["a", "mid", "b"])
    }

    func testHigherScorePlacedFirstWhenOnlyOneSlot() {
        // 两个 spill、目标天只剩一个空位 → 高分者占位，低分者丢弃。
        let high = poi("high", 0, 0.001, rating: 5.0)
        let low = poi("low", 0, 0.001, rating: 3.0)
        let orders = [[poi("s1", 0, 0)], [poi("s2", 0, 0.002)]]
        let (repaired, dropped) = SpillRepair.repair(
            dayOrders: orders,
            spill: [(day: 0, stop: SpilledStop(candidate: low, reason: "超出当日时间窗")),
                    (day: 0, stop: SpilledStop(candidate: high, reason: "超出当日时间窗"))],
            context: ctx(weekdays: [nil, nil], maxSights: 2))

        XCTAssertTrue(repaired[1].contains { $0.id == "high" })
        XCTAssertEqual(dropped.map(\.candidate.id), ["low"])
    }
}
