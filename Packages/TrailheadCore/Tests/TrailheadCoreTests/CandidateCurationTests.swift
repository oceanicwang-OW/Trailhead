//  CandidateCurationTests.swift
//  确定性高分筛选规则：按点评分降序、每类 top-K、住宿不在内。

import Foundation
@testable import TrailheadCore
import XCTest

final class CandidateCurationTests: XCTestCase {

    private func poi(_ id: String, _ kind: ItemKind, _ rating: Double?) -> POICandidate {
        POICandidate(id: id, name: id, kind: kind, subtype: "", lat: 0, lng: 0, rating: rating)
    }

    func testKeepsTopRatedPerKindInDescendingOrder() {
        let cands = [
            poi("S_low", .sight, 3.1), poi("S_hi", .sight, 4.9), poi("S_mid", .sight, 4.2),
            poi("F_hi", .food, 4.7), poi("F_low", .food, 3.5),
        ]
        let out = CandidateCuration.curate(cands, limits: .init(sights: 2, food: 1, other: 0))

        // 景点取前 2（4.9、4.2，丢掉 3.1），餐饮取前 1（4.7）；景点在餐饮前。
        XCTAssertEqual(out.map(\.id), ["S_hi", "S_mid", "F_hi"])
    }

    func testExcludesLodgingEvenIfPresent() {
        let cands = [poi("H", .lodging, 5.0), poi("S", .sight, 4.0)]
        let out = CandidateCuration.curate(cands)
        XCTAssertEqual(out.map(\.id), ["S"])      // 住宿不进行程候选
    }

    func testUnratedSinksBelowRatedSameKind() {
        let cands = [poi("none", .sight, nil), poi("rated", .sight, 4.0)]
        let out = CandidateCuration.curate(cands, limits: .init(sights: 5, food: 0, other: 0))
        XCTAssertEqual(out.map(\.id), ["rated", "none"])
    }

    func testPreferenceBoostLiftsMatchingSubtypeAboveHigherRated() {
        // 用户选「历史古迹」：4.5 的寺庙因加权(+1)超过 4.7 的公园。
        let temple = POICandidate(id: "temple", name: "某寺", kind: .sight, subtype: "寺庙道观",
                                  lat: 0, lng: 0, rating: 4.5)
        let park = POICandidate(id: "park", name: "某公园", kind: .sight, subtype: "公园",
                                lat: 0, lng: 0, rating: 4.7)
        let out = CandidateCuration.curate([park, temple], tags: ["历史古迹"],
                                           limits: .init(sights: 5, food: 0, other: 0))
        XCTAssertEqual(out.map(\.id), ["temple", "park"])   // 合偏好的上浮
    }

    func testPinnedSurvivesCutAndLeads() {
        // 点名的低分点（rank 之外）也豁免保留，且排在最前。
        var cands = (0..<5).map { poi("S\($0)", .sight, 4.9) }
        cands.append(poi("named", .sight, 3.0))
        let out = CandidateCuration.curate(cands, pinned: ["named"],
                                           limits: .init(sights: 3, food: 0, other: 0))
        XCTAssertEqual(out.first?.id, "named")              // 点名置前
        XCTAssertTrue(out.contains { $0.id == "named" })    // 未被 top-3 截断砍掉
    }
}
