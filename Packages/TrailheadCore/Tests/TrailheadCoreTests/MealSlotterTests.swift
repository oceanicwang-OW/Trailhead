//  MealSlotterTests.swift
//  餐饮卡点（PDR §4.6 v2 · D1）：基于第一遍模拟的临时时刻线定位餐窗中点插餐，
//  顺路绕行代价选店。验收：≤1午+≤1晚、去重、未跨餐窗跳过、反方向近店不敌顺路店、
//  第二遍模拟后午餐落位 12:00–13:30 区间。

import Foundation
@testable import TrailheadCore
import XCTest

final class MealSlotterTests: XCTestCase {
    private let schedulingPriors = StayDuration.Priors(sight: 90, museum: 120, nature: 120,
                                                       food: 60, other: 60)

    private func sight(_ id: String, _ lat: Double, _ lng: Double,
                       subtype: String = "") -> POICandidate {
        POICandidate(id: id, name: id, kind: .sight, subtype: subtype, lat: lat, lng: lng)
    }

    private func food(_ id: String, _ lat: Double, _ lng: Double, _ rating: Double?) -> POICandidate {
        POICandidate(id: id, name: id, kind: .food, subtype: "", lat: lat, lng: lng, rating: rating)
    }

    /// 第一遍模拟：给景点赋临时时刻线（relaxed 景点 90 分、博物馆 120 分）。
    private func firstPass(_ stops: [POICandidate]) -> [ScheduledStop] {
        ScheduleSimulator.simulate(stops: stops, pace: .relaxed, city: "",
                                   priors: schedulingPriors).scheduled
    }

    func testEmptyScheduleGetsNoMeals() {
        XCTAssertTrue(MealSlotter.insertMeals(schedule: [], foodPool: [food("f", 0, 0, 4.5)]).isEmpty)
    }

    func testTimelineNotCrossingLunchSkipsMeal() {
        // 单景点 09:00–10:30，未跨午窗中点 12:30 → 不插餐（短行程跳过）。
        let out = MealSlotter.insertMeals(schedule: firstPass([sight("s0", 0, 0)]),
                                          foodPool: [food("f", 0, 0, 4.5)])
        XCTAssertEqual(out.map(\.id), ["s0"])
    }

    func testEmptyFoodPoolLeavesSightsUnchanged() {
        let stops = [sight("s0", 0, 0), sight("s1", 0, 0.001), sight("s2", 0, 0.002)]
        let out = MealSlotter.insertMeals(schedule: firstPass(stops), foodPool: [])
        XCTAssertEqual(out.map(\.id), ["s0", "s1", "s2"])
    }

    func testLunchInsertedAtWindowMidpoint() {
        // 09:00/10:30/12:00 三点（各停 90 分）：午窗中点 12:30 落在 s2 停留区间内 → 插 s2 之后。
        let stops = [sight("s0", 0, 0), sight("s1", 0, 0), sight("s2", 0, 0)]
        let out = MealSlotter.insertMeals(schedule: firstPass(stops),
                                          foodPool: [food("lunch", 0, 0, 4.5)])
        XCTAssertEqual(out.map(\.id), ["s0", "s1", "s2", "lunch"])
    }

    func testLunchAndDinnerBothInsertedOnLongDay() {
        // 5 个博物馆（各 120 分）：09/11/13/15/17 点到达，时刻线至 19:00，跨午晚两个中点。
        let stops = (0..<5).map { sight("m\($0)", 0, 0, subtype: "博物馆") }
        let out = MealSlotter.insertMeals(schedule: firstPass(stops),
                                          foodPool: [food("f1", 0, 0, 4.5), food("f2", 0, 0, 4.6)])
        let foods = out.filter { $0.kind == .food }
        XCTAssertEqual(foods.count, 2)                                    // ≤1午 + ≤1晚
        XCTAssertEqual(Set(foods.map(\.id)).count, 2)                     // 两餐不同店
        // 午餐插在 12:30 所在停留点（m1，11:00–13:00）之后。
        XCTAssertEqual(out.prefix(3).map(\.id), ["m0", "m1", foods[0].id])
    }

    func testOnPathBeatsReverseDirectionNearby() {
        // D1 顺路 > 就近：动线 s0(0,0) →(55km)→ s1(0,0.5)，午窗中点落在行段间隙。
        // reverse 离 s0 更近但在反方向（绕行 ~1.1km）；onpath 稍远但顺路（绕行 ~0）。
        let s0 = sight("s0", 0, 0, subtype: "博物馆")                     // 09:00–11:00
        let s1 = sight("s1", 0, 0.5)                                      // 到达 ~13:30
        let pool = [
            food("reverse", 0, -0.005, 4.5),
            food("onpath", 0, 0.01, 4.5),
        ]
        let out = MealSlotter.insertMeals(schedule: firstPass([s0, s1]), foodPool: pool)
        XCTAssertEqual(out.map(\.id), ["s0", "onpath", "s1"])
    }

    func testExcludesUsedIds() {
        let stops = [sight("s0", 0, 0), sight("s1", 0, 0), sight("s2", 0, 0)]
        let pool = [food("best", 0, 0, 4.8), food("second", 0, 0, 4.0)]
        let out = MealSlotter.insertMeals(schedule: firstPass(stops), foodPool: pool,
                                          usedIds: ["best"])
        XCTAssertEqual(out.filter { $0.kind == .food }.map(\.id), ["second"])
    }

    func testSingleCandidateNotDuplicatedAcrossMeals() {
        // 长天跨两餐窗但只有一家可用 → 午餐用掉后晚餐无可用，不重复。
        let stops = (0..<5).map { sight("m\($0)", 0, 0, subtype: "博物馆") }
        let out = MealSlotter.insertMeals(schedule: firstPass(stops),
                                          foodPool: [food("only", 0, 0, 4.5)])
        XCTAssertEqual(out.filter { $0.kind == .food }.map(\.id), ["only"])
    }

    func testSecondPassPlacesLunchWithinWindow() {
        // 全链验收（D1）：模拟1 → 插餐 → 模拟2，午餐实际到达落在 12:00–13:30 区间。
        let stops = [sight("s0", 0, 0), sight("s1", 0, 0), sight("s2", 0, 0)]
        let withMeals = MealSlotter.insertMeals(schedule: firstPass(stops),
                                                foodPool: [food("lunch", 0, 0, 4.5)])
        let final = ScheduleSimulator.simulate(stops: withMeals, pace: .relaxed, city: "",
                                               priors: schedulingPriors).scheduled
        guard let lunch = final.first(where: { $0.candidate.id == "lunch" }) else {
            return XCTFail("午餐应在终版时刻线中")
        }
        XCTAssertGreaterThanOrEqual(lunch.arrival, 12 * 60)
        XCTAssertLessThanOrEqual(lunch.arrival, 13 * 60 + 30)
    }

    func testCuisineAndBudgetAffectMealChoice() {
        let stops = [sight("s0", 0, 0), sight("s1", 0, 0), sight("s2", 0, 0)]
        let expensive = POICandidate(id: "expensive", name: "普通餐厅", kind: .food,
                                     subtype: "中餐", lat: 0, lng: 0, rating: 4.9,
                                     avgPrice: 300)
        let preferred = POICandidate(id: "preferred", name: "川菜馆", kind: .food,
                                     subtype: "川菜", lat: 0, lng: 0, rating: 4.4,
                                     avgPrice: 50)

        let out = MealSlotter.insertMeals(
            schedule: firstPass(stops), foodPool: [expensive, preferred],
            cuisines: ["川菜"], budgetPerDay: 200
        )

        XCTAssertEqual(out.first { $0.kind == .food }?.id, "preferred")
    }

    func testClosedRestaurantIsSkippedBeforeInsertion() {
        let stops = [sight("s0", 0, 0), sight("s1", 0, 0), sight("s2", 0, 0)]
        let closed = POICandidate(id: "closed", name: "午间不营业", kind: .food,
                                  subtype: "餐厅", lat: 0, lng: 0, rating: 5.0,
                                  openHours: "18:00-22:00")
        let open = POICandidate(id: "open", name: "午餐营业", kind: .food,
                                subtype: "餐厅", lat: 0, lng: 0, rating: 4.0,
                                openHours: "11:00-14:00")

        let out = MealSlotter.insertMeals(
            schedule: firstPass(stops), foodPool: [closed, open]
        )

        XCTAssertEqual(out.first { $0.kind == .food }?.id, "open")
    }
}
