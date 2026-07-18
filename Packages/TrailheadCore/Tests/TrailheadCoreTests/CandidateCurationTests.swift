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

    func testUnratedSinksBelowHigherRatedSameKind() {
        let cands = [poi("none", .sight, nil), poi("rated", .sight, 4.9)]
        let out = CandidateCuration.curate(cands, limits: .init(sights: 5, food: 0, other: 0))
        XCTAssertEqual(out.map(\.id), ["rated", "none"])
    }

    /// 无评分不按 0 分沉底，仍应排在评分明显偏低的同类点之前。
    func testUnratedOutranksLowerRatedSameKind() {
        let cands = [poi("low", .sight, 3.1), poi("none", .sight, nil)]
        let out = CandidateCuration.curate(cands, limits: .init(sights: 5, food: 0, other: 0))
        XCTAssertEqual(out.map(\.id), ["none", "low"])
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

    func testBudgetCanLiftAffordableFood() {
        let expensive = POICandidate(id: "expensive", name: "expensive", kind: .food,
                                     subtype: "餐厅", lat: 0, lng: 0, rating: 4.8,
                                     avgPrice: 300)
        let affordable = POICandidate(id: "affordable", name: "affordable", kind: .food,
                                      subtype: "餐厅", lat: 0, lng: 0, rating: 4.5,
                                      avgPrice: 50)
        let out = CandidateCuration.curate(
            [expensive, affordable], budgetPerDay: 200,
            limits: .init(sights: 0, food: 2, other: 0)
        )

        XCTAssertEqual(out.first?.id, "affordable")
    }

    func testCuisinePreferenceLiftsMatchingFood() {
        let generic = POICandidate(id: "generic", name: "普通餐厅", kind: .food,
                                   subtype: "中餐", lat: 0, lng: 0, rating: 4.7)
        let match = POICandidate(id: "match", name: "川菜馆", kind: .food,
                                 subtype: "川菜", lat: 0, lng: 0, rating: 4.2)
        let out = CandidateCuration.curate(
            [generic, match], cuisines: ["川菜"],
            limits: .init(sights: 0, food: 2, other: 0)
        )

        XCTAssertEqual(out.first?.id, "match")
    }

    func testSubtypeDiversityAvoidsDuplicateTopK() {
        let museumA = POICandidate(id: "museum-a", name: "A", kind: .sight,
                                   subtype: "博物馆", lat: 0, lng: 0, rating: 4.9)
        let museumB = POICandidate(id: "museum-b", name: "B", kind: .sight,
                                   subtype: "博物馆", lat: 0, lng: 0, rating: 4.8)
        let park = POICandidate(id: "park", name: "C", kind: .sight,
                                subtype: "公园", lat: 0, lng: 0, rating: 4.6)
        let out = CandidateCuration.curate(
            [museumA, museumB, park], limits: .init(sights: 2, food: 0, other: 0)
        )

        XCTAssertEqual(out.map(\.id), ["museum-a", "park"])
    }

    func testPopularLandmarkOutranksHigherRatedObscureSight() {
        let obscure = POICandidate(
            id: "obscure", name: "社区小公园", kind: .sight, subtype: "公园",
            lat: 0, lng: 0, rating: 4.9,
            visitMetadata: .init(sourceTypeCode: "110000", popularityScore: 0.08)
        )
        let landmark = POICandidate(
            id: "landmark", name: "城市地标博物院", kind: .sight, subtype: "博物馆",
            lat: 0, lng: 0, rating: 4.5,
            visitMetadata: .init(sourceTypeCode: "110000", popularityScore: 0.95)
        )

        let out = CandidateCuration.curate(
            [obscure, landmark], limits: .init(sights: 2, food: 0, other: 0)
        )

        XCTAssertEqual(out.map(\.id), ["landmark", "obscure"])
    }

    func testKnownShoppingCategoryDoesNotEnterPrimarySightQuota() {
        let attraction = POICandidate(
            id: "attraction", name: "城市博物馆", kind: .sight, subtype: "博物馆",
            lat: 0, lng: 0, rating: 4.2,
            visitMetadata: .init(sourceTypeCode: "110000", popularityScore: 0.6)
        )
        let mall = POICandidate(
            id: "mall", name: "购物中心", kind: .sight, subtype: "购物中心",
            lat: 0, lng: 0, rating: 5.0,
            visitMetadata: .init(sourceTypeCode: "060100", popularityScore: 1)
        )

        let out = CandidateCuration.curate(
            [mall, attraction], limits: .init(sights: 1, food: 0, other: 0)
        )

        XCTAssertEqual(out.map(\.id), ["attraction"])
    }

    func testBusinessResidentialCategoryDoesNotEnterPrimarySightQuota() {
        let attraction = POICandidate(
            id: "attraction", name: "城市博物馆", kind: .sight, subtype: "博物馆",
            lat: 0, lng: 0, rating: 4.2,
            visitMetadata: .init(sourceTypeCode: "110000", popularityScore: 0.6)
        )
        let office = POICandidate(
            id: "office", name: "城市中心写字楼", kind: .sight, subtype: "商务写字楼",
            lat: 0, lng: 0, rating: 5.0,
            visitMetadata: .init(sourceTypeCode: "120200", popularityScore: 1)
        )

        let out = CandidateCuration.curate(
            [office, attraction], limits: .init(sights: 1, food: 0, other: 8)
        )

        XCTAssertEqual(out.map(\.id), ["attraction"])
    }

    func testMuseumFromScienceEducationCategoryRemainsPrimaryAttraction() {
        let museum = POICandidate(
            id: "museum", name: "城市博物馆", kind: .sight, subtype: "博物馆",
            lat: 0, lng: 0, rating: 4.6,
            visitMetadata: .init(sourceTypeCode: "140100", popularityScore: 0.8)
        )
        let school = POICandidate(
            id: "school", name: "城市中学", kind: .sight, subtype: "中学",
            lat: 0, lng: 0, rating: 4.9,
            visitMetadata: .init(sourceTypeCode: "141200", popularityScore: 1)
        )

        let out = CandidateCuration.curate(
            [school, museum], limits: .init(sights: 2, food: 0, other: 8)
        )

        XCTAssertEqual(out.map(\.id), ["museum"])
    }
}
