//  FoodLodgingOptionTests.swift
//  美食/住宿清单模型：老数据（无 tags/photos 字段）容错解码 + 新字段编解码往返 +
//  lodgingShortlist 字段透传。

import Foundation
@testable import TrailheadCore
import XCTest

final class FoodLodgingOptionTests: XCTestCase {

    func testFoodOptionDecodesLegacyJSONWithoutNewFields() throws {
        // 上线前存量数据没有 tags/photos/openHours —— 缺失取默认，不丢整份清单。
        let legacy = #"[{"id":"B1","name":"老店","rating":4.6,"avgPrice":80,"subtype":"闽菜","lat":24.4,"lng":118.1}]"#
        let options = try JSONDecoder().decode([FoodOption].self, from: Data(legacy.utf8))

        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options.first?.name, "老店")
        XCTAssertEqual(options.first?.tags, [])
        XCTAssertEqual(options.first?.photos, [])
        XCTAssertNil(options.first?.openHours)
    }

    func testLodgingOptionDecodesLegacyJSONWithoutNewFields() throws {
        let legacy = #"[{"id":"H1","name":"海边酒店","rating":4.8,"avgPrice":450,"lat":24.4,"lng":118.1}]"#
        let options = try JSONDecoder().decode([LodgingOption].self, from: Data(legacy.utf8))

        XCTAssertEqual(options.first?.name, "海边酒店")
        XCTAssertEqual(options.first?.tags, [])
        XCTAssertEqual(options.first?.photos, [])
    }

    func testFoodOptionRoundtripsNewFields() throws {
        let option = FoodOption(id: "B1", name: "老店", rating: 4.6, avgPrice: 80, subtype: "闽菜",
                                lat: 24.4, lng: 118.1, tags: ["佛跳墙"], photos: ["https://x/1.jpg"],
                                openHours: "10:00-22:00")
        let decoded = try JSONDecoder().decode(FoodOption.self, from: JSONEncoder().encode(option))
        XCTAssertEqual(decoded, option)
    }

    func testLodgingOptionRoundtripsNewFields() throws {
        let option = LodgingOption(id: "H1", name: "海边酒店", rating: 4.8, avgPrice: 450,
                                   lat: 24.4, lng: 118.1, tags: ["近地铁", "免费停车"],
                                   photos: ["https://x/1.jpg"])
        let decoded = try JSONDecoder().decode(LodgingOption.self, from: JSONEncoder().encode(option))
        XCTAssertEqual(decoded, option)
    }

    @MainActor
    func testLodgingShortlistCarriesTagsAndPhotos() {   // ItineraryEngine 为 @MainActor
        let pool = [POICandidate(id: "H1", name: "海边酒店", kind: .lodging, subtype: "酒店",
                                 lat: 24.4, lng: 118.1, rating: 4.8,
                                 tags: ["近地铁"], photos: ["https://x/1.jpg"])]
        let out = ItineraryEngine.lodgingShortlist(from: pool)

        XCTAssertEqual(out.first?.tags, ["近地铁"])            // 环境/服务标签带到清单
        XCTAssertEqual(out.first?.photos, ["https://x/1.jpg"])
    }

    @MainActor
    func testLodgingShortlistRespectsDailyBudget() {
        let expensive = POICandidate(id: "expensive", name: "高价酒店", kind: .lodging,
                                     subtype: "豪华型", lat: 0, lng: 0, rating: 4.9,
                                     avgPrice: 600)
        let affordable = POICandidate(id: "affordable", name: "经济酒店", kind: .lodging,
                                      subtype: "经济型", lat: 0, lng: 0, rating: 4.7,
                                      avgPrice: 200)

        let out = ItineraryEngine.lodgingShortlist(
            from: [expensive, affordable], prefs: TripPrefs(budgetPerDay: 400)
        )

        XCTAssertEqual(out.first?.id, "affordable")
    }

    @MainActor
    func testLodgingShortlistFiltersRemoteSubcitiesAroundFinalRoute() {
        let downtown = POICandidate(id: "downtown", name: "苏州市区酒店", kind: .lodging,
                                    subtype: "舒适型", lat: 31.31, lng: 120.62, rating: 4.6,
                                    avgPrice: 360)
        let kunshan = POICandidate(id: "kunshan", name: "昆山酒店", kind: .lodging,
                                   subtype: "舒适型", lat: 31.39, lng: 120.98, rating: 4.9,
                                   avgPrice: 320)
        let zhangjiagang = POICandidate(id: "zhangjiagang", name: "张家港酒店", kind: .lodging,
                                        subtype: "豪华型", lat: 31.86, lng: 120.54, rating: 5.0,
                                        avgPrice: 500)

        let out = ItineraryEngine.lodgingShortlist(
            from: [zhangjiagang, kunshan, downtown], prefs: TripPrefs(),
            routeCoords: [(31.30, 120.60), (31.32, 120.64)]
        )

        XCTAssertEqual(out.map(\.id), ["downtown"])
        XCTAssertNotNil(out.first?.distanceMeters)
        XCTAssertNotNil(out.first?.estimatedMinutes)
    }

    @MainActor
    func testNamedRemoteLodgingIsExemptFromDistanceFilter() {
        let remote = POICandidate(id: "remote", name: "张家港指定酒店", kind: .lodging,
                                  subtype: "酒店", lat: 31.86, lng: 120.54, rating: 4.5)

        let out = ItineraryEngine.lodgingShortlist(
            from: [remote], prefs: TripPrefs(freeText: "想住张家港指定酒店"),
            routeCoords: [(31.30, 120.60)]
        )

        XCTAssertEqual(out.map(\.id), ["remote"])
    }

    @MainActor
    func testLodgingShortlistFirstThreeCoverAvailablePriceBands() {
        let pool = [
            POICandidate(id: "mid1", name: "中档一", kind: .lodging, subtype: "舒适型",
                         lat: 31.301, lng: 120.601, rating: 4.9, avgPrice: 420),
            POICandidate(id: "mid2", name: "中档二", kind: .lodging, subtype: "舒适型",
                         lat: 31.302, lng: 120.602, rating: 4.8, avgPrice: 450),
            POICandidate(id: "low", name: "经济型", kind: .lodging, subtype: "经济型",
                         lat: 31.305, lng: 120.605, rating: 4.6, avgPrice: 180),
            POICandidate(id: "high", name: "高档型", kind: .lodging, subtype: "豪华型",
                         lat: 31.306, lng: 120.606, rating: 4.7, avgPrice: 780),
        ]

        let out = ItineraryEngine.lodgingShortlist(
            from: pool, prefs: TripPrefs(budgetPerDay: 800), routeCoords: [(31.30, 120.60)]
        )

        XCTAssertEqual(Set(out.prefix(3).map(\.id)), ["mid1", "low", "high"])
    }
}
