//  ItineraryFeasibilityTests.swift
//  出口自检器（PDR §7，v2 含 D2/D3/D8）：硬约束——时间严格递增（Int 比较）、**当日**营业窗内、
//  days≥2 无空天且≤上限。软：spill 丢弃 warning、2-opt 收敛与急回折 info。
//  失败不抛错，返回最优可行子集（丢弃违规点）+ 报告。

import Foundation
@testable import TrailheadCore
import XCTest

final class ItineraryFeasibilityTests: XCTestCase {

    private func stop(_ id: String, _ time: String, kind: ItemKind = .sight, openHours: String? = nil,
                      lat: Double = 0, lng: Double = 0) -> PlannedStop {
        PlannedStop(candidate: POICandidate(id: id, name: id, kind: kind, subtype: "",
                                            lat: lat, lng: lng, openHours: openHours),
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

    // MARK: - v2：D2 当日窗 / D3 spill 报告 / D8 软断言

    func testMondayClosedStopDroppedWithWeekday() {
        // D2：周一（weekday=1）到达「周一闭馆」的点 → 当日窗为空，硬违规丢弃；周二则保留。
        let museum = stop("museum", "10:00", openHours: "09:00-17:00，周一闭馆")
        let (mondayPlan, mondayReport) = ItineraryFeasibility.check(
            [[stop("a", "09:00"), museum]], days: 1, maxSightsPerDay: 4, weekdays: [1])
        XCTAssertEqual(ids(mondayPlan), [["a"]])
        XCTAssertFalse(mondayReport.isFeasible)

        let (tuesdayPlan, tuesdayReport) = ItineraryFeasibility.check(
            [[stop("a", "09:00"), museum]], days: 1, maxSightsPerDay: 4, weekdays: [2])
        XCTAssertEqual(ids(tuesdayPlan), [["a", "museum"]])
        XCTAssertTrue(tuesdayReport.isFeasible)
    }

    func testNoWeekdayDegradesToBaseWindow() {
        // 无日期 → 周闭馆不生效（与 v1 行为一致），base 窗内即可行。
        let museum = stop("museum", "10:00", openHours: "09:00-17:00，周一闭馆")
        let (plan, report) = ItineraryFeasibility.check([[museum]], days: 1, maxSightsPerDay: 4)
        XCTAssertEqual(ids(plan), [["museum"]])
        XCTAssertTrue(report.isFeasible)
    }

    func testDroppedSpillRecordedAsWarningNotViolation() {
        // D3：最终丢弃清单 → softWarnings（附原因），不影响 isFeasible。
        let dropped = [SpilledStop(candidate: POICandidate(id: "x", name: "x", kind: .sight,
                                                           subtype: "", lat: 0, lng: 0),
                                   reason: "当日闭馆")]
        let (_, report) = ItineraryFeasibility.check([[stop("a", "09:00")]], days: 1,
                                                     maxSightsPerDay: 4, dropped: dropped)
        XCTAssertTrue(report.isFeasible)
        XCTAssertEqual(report.softWarnings, ["最终丢弃 x（当日闭馆）"])
    }

    func testUnconvergedRouterRecordedAsInfo() {
        // D8(a)：2-opt 触顶未收敛 → info，不影响可行性。
        let (_, report) = ItineraryFeasibility.check([[stop("a", "09:00")]], days: 1,
                                                     maxSightsPerDay: 4, routerConverged: [false])
        XCTAssertTrue(report.isFeasible)
        XCTAssertEqual(report.infos, ["day 0: 2-opt 达步数上限退出（未完全收敛）"])
    }

    func testSharpTurnDetectedAsInfo() {
        // D8(b)：a→b→c 原路折返（夹角 ≈0° < 30°）→ info；不影响可行性。
        let day = [stop("a", "09:00", lat: 0, lng: 0),
                   stop("b", "10:30", lat: 0, lng: 0.02),
                   stop("c", "12:00", lat: 0, lng: 0.0005)]
        let (_, report) = ItineraryFeasibility.check([day], days: 1, maxSightsPerDay: 4)
        XCTAssertTrue(report.isFeasible)
        XCTAssertEqual(report.infos, ["day 0: 检出 1 处 <30° 急回折"])
    }

    func testStraightPathHasNoSharpTurnInfo() {
        // 直线推进（夹角 ≈180°）→ 无急回折 info。
        let day = [stop("a", "09:00", lat: 0, lng: 0),
                   stop("b", "10:30", lat: 0, lng: 0.01),
                   stop("c", "12:00", lat: 0, lng: 0.02)]
        let (_, report) = ItineraryFeasibility.check([day], days: 1, maxSightsPerDay: 4)
        XCTAssertTrue(report.infos.isEmpty)
    }
}
