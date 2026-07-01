//  ItineraryFeasibilityTests.swift
//  出口自检器（PDR §7）：硬约束——时间严格递增（Int 比较）、营业窗内、days≥2 无空天且≤上限。
//  失败不抛错，返回最优可行子集（丢弃违规点）+ 报告。

import Foundation
@testable import TrailheadCore
import XCTest

final class ItineraryFeasibilityTests: XCTestCase {

    private func stop(_ id: String, _ time: String, kind: ItemKind = .sight, openHours: String? = nil) -> PlannedStop {
        PlannedStop(candidate: POICandidate(id: id, name: id, kind: kind, subtype: "",
                                            lat: 0, lng: 0, openHours: openHours),
                    time: time, stayMin: 60, note: nil)
    }

    private func ids(_ plan: [[PlannedStop]]) -> [[String]] { plan.map { $0.map(\.candidate.id) } }

    func testFeasiblePlanPassesUnchanged() {
        let day = [stop("a", "09:00"), stop("b", "10:30"), stop("c", "12:00")]
        let (plan, report) = ItineraryFeasibility.check([day], days: 1, maxSightsPerDay: 4)
        XCTAssertTrue(report.isFeasible)
        XCTAssertEqual(ids(plan), [["a", "b", "c"]])
    }

    func testNonMonotonicTimeDropsOffender() {
        let day = [stop("a", "10:00"), stop("b", "09:30")]     // b 早于 a → 丢弃
        let (plan, report) = ItineraryFeasibility.check([day], days: 1, maxSightsPerDay: 4)
        XCTAssertEqual(ids(plan), [["a"]])
        XCTAssertFalse(report.isFeasible)
    }

    func testOutOfOpenHoursDropped() {
        let day = [stop("a", "09:00"), stop("closed", "10:00", openHours: "09:00-09:30")]
        let (plan, report) = ItineraryFeasibility.check([day], days: 1, maxSightsPerDay: 4)
        XCTAssertEqual(ids(plan), [["a"]])
        XCTAssertFalse(report.isFeasible)
    }

    func testAllDayNeverDropped() {
        let day = [stop("a", "09:00"), stop("x", "23:00", openHours: "全天")]
        let (plan, report) = ItineraryFeasibility.check([day], days: 1, maxSightsPerDay: 4)
        XCTAssertEqual(ids(plan), [["a", "x"]])
        XCTAssertTrue(report.isFeasible)
    }

    func testEmptyDayFlaggedWhenSightsCoverDays() {
        let d0 = [stop("a", "09:00"), stop("b", "10:30")]
        let d1: [PlannedStop] = []
        let (_, report) = ItineraryFeasibility.check([d0, d1], days: 2, maxSightsPerDay: 4)
        XCTAssertFalse(report.isFeasible)                       // 2 景点覆盖 2 天，空天违规
    }

    func testLightDaysAllowedWhenFewerSightsThanDays() {
        let d0 = [stop("a", "09:00")]
        let (_, report) = ItineraryFeasibility.check([d0, [], []], days: 3, maxSightsPerDay: 4)
        XCTAssertTrue(report.isFeasible)                        // 景点 < 天数 → 轻量天不判失败
    }

    func testExceedsMaxSightsPerDayDropsExcess() {
        let d0 = [stop("a", "09:00"), stop("b", "10:00"), stop("c", "11:00")]
        let d1 = [stop("d", "09:00")]
        let (plan, report) = ItineraryFeasibility.check([d0, d1], days: 2, maxSightsPerDay: 2)
        XCTAssertEqual(ids(plan), [["a", "b"], ["d"]])          // 超上限的 c 被丢
        XCTAssertFalse(report.isFeasible)
    }

    func testFoodNotCountedTowardSightCap() {
        // 上限 2 景点，中间夹一餐不占景点额度：a、b 景点 + 餐 f 全保留。
        let d0 = [stop("a", "09:00"), stop("f", "10:00", kind: .food), stop("b", "11:00")]
        let d1 = [stop("d", "09:00")]
        let (plan, _) = ItineraryFeasibility.check([d0, d1], days: 2, maxSightsPerDay: 2)
        XCTAssertEqual(ids(plan), [["a", "f", "b"], ["d"]])
    }
}
