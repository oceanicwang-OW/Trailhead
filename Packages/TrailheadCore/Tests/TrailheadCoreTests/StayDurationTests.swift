//  StayDurationTests.swift
//  停留时长先验（PDR §4.2）：kind/subtype → 基准分钟，再乘 pace 系数。

import Foundation
@testable import TrailheadCore
import XCTest

final class StayDurationTests: XCTestCase {

    private func poi(_ kind: ItemKind, subtype: String = "", name: String = "x") -> POICandidate {
        POICandidate(id: "p", name: name, kind: kind, subtype: subtype, lat: 0, lng: 0)
    }

    func testSightDefaultAtRelaxed() {
        XCTAssertEqual(StayDuration.duration(for: poi(.sight), pace: .relaxed), 90)
    }

    func testFoodDefault() {
        XCTAssertEqual(StayDuration.duration(for: poi(.food), pace: .relaxed), 60)
    }

    func testOtherKindDefault() {
        // 非景非食（transit）走「其它」先验 60。
        XCTAssertEqual(StayDuration.duration(for: poi(.transit), pace: .relaxed), 60)
    }

    func testMuseumSubtypeOverridesSightBase() {
        XCTAssertEqual(StayDuration.duration(for: poi(.sight, subtype: "科教文化服务;博物馆"), pace: .relaxed), 120)
    }

    func testNatureSubtypeOverridesSightBase() {
        XCTAssertEqual(StayDuration.duration(for: poi(.sight, subtype: "风景名胜;公园广场;公园"), pace: .relaxed), 120)
    }

    func testFoodNamedLikeNatureStaysFood() {
        // 「海鲜」餐厅不因 subtype 含「海」被误判为自然景观 120，仍按餐饮 60。
        XCTAssertEqual(StayDuration.duration(for: poi(.food, subtype: "餐饮服务;海鲜", name: "老渔民海鲜"), pace: .relaxed), 60)
    }

    func testTightPaceScalesDown() {
        // 90 × 0.8 = 72
        XCTAssertEqual(StayDuration.duration(for: poi(.sight), pace: .tight), 72)
    }

    func testCasualPaceScalesUp() {
        // 90 × 1.2 = 108
        XCTAssertEqual(StayDuration.duration(for: poi(.sight), pace: .casual), 108)
    }

    func testCustomPriorsRespected() {
        let priors = StayDuration.Priors(sight: 100)
        XCTAssertEqual(StayDuration.duration(for: poi(.sight), pace: .relaxed, priors: priors), 100)
    }
}
