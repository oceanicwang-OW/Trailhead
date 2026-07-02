//  DayClustererTests.swift
//  聚类分天（PDR §4.4）：k-means（投影坐标）+ 容量约束分配 + 天序链接。
//  每天空间成团、数量均衡；sights<days 降级为轻量天不抛错；所有点不丢不重。

import Foundation
@testable import TrailheadCore
import XCTest

final class DayClustererTests: XCTestCase {

    private func poi(_ id: String, _ lat: Double, _ lng: Double) -> POICandidate {
        POICandidate(id: id, name: id, kind: .sight, subtype: "", lat: lat, lng: lng)
    }

    private func ids(_ days: [[POICandidate]]) -> [Set<String>] {
        days.map { Set($0.map(\.id)) }
    }

    func testMaxSightsPerPace() {
        XCTAssertEqual(DayClusterer.maxSights(for: .tight), 5)
        XCTAssertEqual(DayClusterer.maxSights(for: .relaxed), 4)
        XCTAssertEqual(DayClusterer.maxSights(for: .casual), 3)
    }

    func testEmptyReturnsDaysEmptyBuckets() {
        let out = DayClusterer.cluster(sights: [], days: 3, maxSightsPerDay: 4)
        XCTAssertEqual(out.count, 3)
        XCTAssertTrue(out.allSatisfy(\.isEmpty))
    }

    func testAllPointsPreservedNoDuplicates() {
        let cands = [poi("a", 0, 0), poi("b", 0.1, 0.1), poi("c", 5, 5), poi("d", 5.1, 5.1), poi("e", 2, 2)]
        let out = DayClusterer.cluster(sights: cands, days: 2, maxSightsPerDay: 4)
        let flat = out.flatMap { $0.map(\.id) }
        XCTAssertEqual(Set(flat), Set(["a", "b", "c", "d", "e"]))
        XCTAssertEqual(flat.count, 5)                       // 不丢不重
    }

    func testCountEqualsDaysEachDayOnePointWhenEqual() {
        let cands = [poi("a", 0, 0), poi("b", 0, 5), poi("c", 5, 0)]
        let out = DayClusterer.cluster(sights: cands, days: 3, maxSightsPerDay: 4)
        XCTAssertEqual(out.count, 3)
        XCTAssertTrue(out.allSatisfy { $0.count == 1 })     // 点数==天数：每天恰 1，无空天
    }

    func testBalancedEvenSplitOfSeparatedPairs() {
        // 三对相距很远的点、3 天 → 每天 2，均衡。
        let cands = [
            poi("a1", 0, 0), poi("a2", 0.001, 0.001),
            poi("b1", 0, 10), poi("b2", 0.001, 10.001),
            poi("c1", 10, 0), poi("c2", 10.001, 0.001),
        ]
        let out = DayClusterer.cluster(sights: cands, days: 3, maxSightsPerDay: 4)
        XCTAssertEqual(out.map(\.count).sorted(), [2, 2, 2])
    }

    func testSpatialGroupingKeepsClusterTogether() {
        // 两个远隔的地理团、2 天 → 同团点落在同一天。
        let cands = [
            poi("a1", 0, 0), poi("a2", 0.001, 0), poi("a3", 0, 0.001),
            poi("b1", 5, 5), poi("b2", 5.001, 5), poi("b3", 5, 5.001),
        ]
        let dayIds = ids(DayClusterer.cluster(sights: cands, days: 2, maxSightsPerDay: 4))
        XCTAssertTrue(dayIds.contains(["a1", "a2", "a3"]))
        XCTAssertTrue(dayIds.contains(["b1", "b2", "b3"]))
    }

    func testNeverExceedsMaxSightsPerDay() {
        let cands = (0..<8).map { poi("p\($0)", Double($0), Double($0)) }
        let out = DayClusterer.cluster(sights: cands, days: 2, maxSightsPerDay: 4)
        XCTAssertTrue(out.allSatisfy { $0.count <= 4 })
    }

    func testFewerSightsThanDaysDegradesToLightDays() {
        // B3：2 个景点、3 天 → 不抛错，长度=3，两非空天 + 一轻量（空）天，点不丢。
        let cands = [poi("a", 0, 0), poi("b", 5, 5)]
        let out = DayClusterer.cluster(sights: cands, days: 3, maxSightsPerDay: 4)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.filter { !$0.isEmpty }.count, 2)
        XCTAssertEqual(out.filter(\.isEmpty).count, 1)
        XCTAssertEqual(Set(out.flatMap { $0.map(\.id) }), Set(["a", "b"]))
    }

    // MARK: - D6 确定性 / D7 时间预算

    func testDeterministicSameInputSameOutput() {
        // D6：同输入两次聚类逐字段一致（无随机源）。
        let cands = (0..<9).map { poi("p\($0)", Double($0 % 3), Double($0 / 3)) }
        let scores = Dictionary(uniqueKeysWithValues: cands.enumerated().map { ($1.id, 3.5 + Double($0) * 0.1) })
        let a = DayClusterer.cluster(sights: cands, days: 3, maxSightsPerDay: 4, scores: scores)
        let b = DayClusterer.cluster(sights: cands, days: 3, maxSightsPerDay: 4, scores: scores)
        XCTAssertEqual(a.map { $0.map(\.id) }, b.map { $0.map(\.id) })
    }

    func testSeedOffsetIsExplicitDiversityKnob() {
        // 「重新生成的多样性」由显式 seedOffset 承担；同 offset 仍确定性。
        let cands = (0..<6).map { poi("p\($0)", Double($0), Double($0 % 2)) }
        let a = DayClusterer.cluster(sights: cands, days: 2, maxSightsPerDay: 4, seedOffset: 1)
        let b = DayClusterer.cluster(sights: cands, days: 2, maxSightsPerDay: 4, seedOffset: 1)
        XCTAssertEqual(a.map { $0.map(\.id) }, b.map { $0.map(\.id) })
    }

    func testTimeBudgetSplitsTwoMuseumsAcrossDays() {
        // D7：双博物馆（各 120 分）同团，时间预算 220 装不下两个（240>220）→ 拆到不同天；
        // 纯点数容量（capacity=2）看不见这一点。
        let m1 = poi("m1", 0, 0), m2 = poi("m2", 0, 0.001), s = poi("s", 5, 5)
        let stays = ["m1": 120, "m2": 120, "s": 90]
        let out = DayClusterer.cluster(sights: [m1, m2, s], days: 2, maxSightsPerDay: 4,
                                       stayMinutes: stays, stayBudget: 220)
        for day in out {
            let ids = Set(day.map(\.id))
            XCTAssertFalse(ids.isSuperset(of: ["m1", "m2"]), "双博物馆不应同日：\(ids)")
        }
        XCTAssertEqual(Set(out.flatMap { $0.map(\.id) }), ["m1", "m2", "s"])   // 不丢点
    }

    func testWithoutBudgetTwoMuseumsStayTogether() {
        // 对照组：关闭预算（nil）→ 地理同团的双博物馆仍在同一天。
        let m1 = poi("m1", 0, 0), m2 = poi("m2", 0, 0.001), s = poi("s", 5, 5)
        let out = DayClusterer.cluster(sights: [m1, m2, s], days: 2, maxSightsPerDay: 4)
        XCTAssertTrue(out.contains { Set($0.map(\.id)) == ["m1", "m2"] })
    }
}
