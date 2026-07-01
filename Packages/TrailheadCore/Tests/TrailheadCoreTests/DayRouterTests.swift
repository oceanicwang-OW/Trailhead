//  DayRouterTests.swift
//  簇内排序（PDR §4.5）：贪心最近邻 + 2-opt 开放路径，haversine 距离。
//  验收：点不丢、方形用例达最优（消交叉）、不比原序差、锚点决定起点。

import Foundation
@testable import TrailheadCore
import XCTest

final class DayRouterTests: XCTestCase {

    private func poi(_ id: String, _ lat: Double, _ lng: Double) -> POICandidate {
        POICandidate(id: id, name: id, kind: .sight, subtype: "", lat: lat, lng: lng)
    }

    private func pathLen(_ s: [POICandidate]) -> Double {
        (0..<max(0, s.count - 1)).reduce(0.0) { $0 + ItineraryDayBuilder.haversineMeters(s[$1], s[$1 + 1]) }
    }

    func testEmptyAndSingleUnchanged() {
        XCTAssertEqual(DayRouter.route([]).map(\.id), [])
        XCTAssertEqual(DayRouter.route([poi("a", 0, 0)]).map(\.id), ["a"])
    }

    func testPreservesAllPoints() {
        let cands = [poi("a", 0, 0), poi("b", 1, 3), poi("c", 2, 1), poi("d", 0, 2), poi("e", 3, 3)]
        let out = DayRouter.route(cands)
        XCTAssertEqual(Set(out.map(\.id)), Set(["a", "b", "c", "d", "e"]))
        XCTAssertEqual(out.count, 5)                        // 不丢不重
    }

    func testRectangleReachesOptimalNoCrossing() {
        let a = poi("A", 0, 0), b = poi("B", 0, 1), c = poi("C", 2, 0), d = poi("D", 2, 1)
        let crossedInput = [a, c, b, d]                     // 原序含交叉、路径偏长
        let routed = DayRouter.route(crossedInput)
        let optimal = pathLen([a, b, d, c])                 // 两短边 + 一长边

        XCTAssertEqual(Set(routed.map(\.id)), Set(["A", "B", "C", "D"]))
        XCTAssertLessThanOrEqual(pathLen(routed), pathLen(crossedInput))   // 不比原序差
        XCTAssertEqual(pathLen(routed), optimal, accuracy: optimal * 0.001) // 达最优、无交叉
    }

    func testEntryAnchorDeterminesStart() {
        let a = poi("A", 0, 0), b = poi("B", 0, 1), c = poi("C", 2, 0)
        // 锚点贴近 C → 当天从 C 起（天间衔接）。
        let routed = DayRouter.route([a, b, c], entryAnchor: (lat: 2, lng: 0.05))
        XCTAssertEqual(routed.first?.id, "C")
        XCTAssertEqual(Set(routed.map(\.id)), Set(["A", "B", "C"]))
    }
}
