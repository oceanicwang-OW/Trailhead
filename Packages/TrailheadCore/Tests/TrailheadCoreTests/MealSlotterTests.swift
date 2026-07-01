//  MealSlotterTests.swift
//  餐饮卡点（PDR §4.6）：把午/晚餐就近高分插入已排序景点。运行在赋时前，按序号定位。
//  验收：≤1午+≤1晚、去重、短行程单餐、空池/轻量天跳过、就近+高分选源。

import Foundation
@testable import TrailheadCore
import XCTest

final class MealSlotterTests: XCTestCase {

    private func sight(_ id: String, _ lat: Double, _ lng: Double) -> POICandidate {
        POICandidate(id: id, name: id, kind: .sight, subtype: "", lat: lat, lng: lng)
    }

    private func food(_ id: String, _ lat: Double, _ lng: Double, _ rating: Double?) -> POICandidate {
        POICandidate(id: id, name: id, kind: .food, subtype: "", lat: lat, lng: lng, rating: rating)
    }

    func testLightDayNoSightsGetsNoMeals() {
        let out = MealSlotter.insertMeals(sights: [], foodPool: [food("f", 0, 0, 4.5)])
        XCTAssertTrue(out.isEmpty)
    }

    func testEmptyFoodPoolLeavesSightsUnchanged() {
        let sights = [sight("s0", 0, 0), sight("s1", 0, 1), sight("s2", 0, 2)]
        let out = MealSlotter.insertMeals(sights: sights, foodPool: [])
        XCTAssertEqual(out.map(\.id), ["s0", "s1", "s2"])
    }

    func testInsertsLunchMidAndDinnerEnd() {
        let sights = [sight("s0", 0, 0), sight("s1", 0, 1), sight("s2", 0, 2), sight("s3", 0, 3)]
        let pool = [food("mid", 0, 1, 4.5), food("end", 0, 3, 4.6)]
        let out = MealSlotter.insertMeals(sights: sights, foodPool: pool)

        // 午餐插在中部（s1 后），晚餐插在末尾（s3 后）。
        XCTAssertEqual(out.map(\.id), ["s0", "s1", "mid", "s2", "s3", "end"])
        XCTAssertEqual(out[2].kind, .food)
        XCTAssertEqual(out[5].kind, .food)
    }

    func testLunchAndDinnerAreDistinct() {
        let sights = [sight("s0", 0, 0), sight("s1", 0, 1), sight("s2", 0, 2)]
        // 只有一个候选餐饮 → 午餐用掉后晚餐无可用，去重不重复插同一家。
        let pool = [food("only", 0, 1, 4.5)]
        let out = MealSlotter.insertMeals(sights: sights, foodPool: pool)
        let foods = out.filter { $0.kind == .food }.map(\.id)
        XCTAssertEqual(foods, ["only"])                     // 仅一餐，不重复
    }

    func testShortTripSingleMeal() {
        let sights = [sight("s0", 0, 0), sight("s1", 0, 1)]  // 2 景点 → 单餐
        let pool = [food("a", 0, 0, 4.5), food("b", 0, 1, 4.6)]
        let out = MealSlotter.insertMeals(sights: sights, foodPool: pool)
        XCTAssertEqual(out.filter { $0.kind == .food }.count, 1)
    }

    func testPicksNearHighOverFarHighAndNearLow() {
        let sights = [sight("s0", 0, 0)]                     // 单景点 → 单餐，锚点 s0
        let pool = [
            food("nearLow", 0, 0.001, 3.0),
            food("nearHigh", 0, 0.002, 4.8),
            food("farHigh", 0, 1.0, 5.0),
        ]
        let out = MealSlotter.insertMeals(sights: sights, foodPool: pool)
        XCTAssertEqual(out.last?.id, "nearHigh")            // 就近+高分：近处高分胜出
    }

    func testExcludesUsedIds() {
        let sights = [sight("s0", 0, 0)]
        let pool = [food("nearHigh", 0, 0.002, 4.8), food("nearLow", 0, 0.001, 3.0)]
        let out = MealSlotter.insertMeals(sights: sights, foodPool: pool, usedIds: ["nearHigh"])
        XCTAssertEqual(out.last?.id, "nearLow")             // 已用的不再选
    }
}
