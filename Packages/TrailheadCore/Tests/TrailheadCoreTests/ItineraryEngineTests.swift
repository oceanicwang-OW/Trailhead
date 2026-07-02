//  ItineraryEngineTests.swift
//  PDR T3.5–T3.7：端到端「输入偏好 → 库里出现完整 Trip」。mock LLM + mock 数据源。

import Foundation
import SwiftData
@testable import TrailheadCore
import XCTest

// 可配置的假数据源。
private final class MockSource: POIDataSource {
    var adcode = "110100"
    var byTag: [String: [POICandidate]] = [:]
    var routeResult: (minutes: Int, meters: Int, cost: Int?) = (15, 1200, nil)
    private(set) var routeCalls = 0
    private(set) var lastRouteCity: String?

    func geocodeCity(_ name: String) async throws -> (adcode: String, center: (Double, Double)) {
        (adcode, (116.4, 39.9))
    }

    func searchPOI(adcode: String, tags: [String]) async throws -> [POICandidate] {
        tags.flatMap { byTag[$0] ?? [] }
    }

    func route(from: POICandidate, to: POICandidate,
               mode: TransitMode, city: String) async throws -> (minutes: Int, meters: Int, cost: Int?) {
        routeCalls += 1
        lastRouteCity = city
        return routeResult
    }
}

// 按序返回 JSON 的假 LLM。
private final class MockLLM: LLMProvider {
    var responses: [String]
    private(set) var calls = 0
    init(_ responses: [String]) { self.responses = responses }
    func planItinerary(prefs: TripPrefs, candidates: [POICandidate], days: Int) async throws -> Data {
        defer { calls += 1 }
        return Data(responses[min(calls, responses.count - 1)].utf8)
    }
}

final class ItineraryEngineTests: XCTestCase {

    private func cand(_ id: String, _ kind: ItemKind = .sight, lat: Double = 39.90, lng: Double = 116.40) -> POICandidate {
        POICandidate(id: id, name: id, kind: kind, subtype: "", lat: lat, lng: lng)
    }

    private func hotel(_ id: String, rating: Double) -> POICandidate {
        POICandidate(id: id, name: id, kind: .lodging, subtype: "", lat: 24.4, lng: 118.0,
                     rating: rating, avgPrice: 500)
    }

    @MainActor
    func testGenerateEndToEndPersistsTrip() async throws {
        let ctx = try TestSupport.makeContext()
        let source = MockSource()
        // v2（D1）：插餐基于临时时刻线——3 景点使时刻线跨越午窗中点 12:30，午餐 B 才会插入。
        source.byTag = ["美食": [cand("A", .sight), cand("B", .food), cand("C", .sight), cand("D", .sight)]]
        let llm = MockLLM([#"{"days":[{"day":1,"items":[{"poi_id":"A","time":"09:00","stay_min":90,"note":"早到"},{"poi_id":"B","time":"12:00","stay_min":60},{"poi_id":"C","time":"15:00","stay_min":120}]}]}"#])
        let engine = ItineraryEngine(source: source, llm: llm, context: ctx)

        let trip = try await engine.generate(destination: "北京", prefs: TripPrefs(tags: ["美食"]), days: 1)

        // 落库
        XCTAssertEqual(try TripRepository(context: ctx).count(), 1)
        XCTAssertEqual(trip.city, "北京")
        XCTAssertEqual(trip.adcode, "110100")
        XCTAssertEqual(trip.status, .ready)
        XCTAssertEqual(trip.sortedDays.count, 1)

        // 4 个 POI + 3 段交通，交替排列；午餐 B 插在第三景点（时刻线 12:00–13:30 段）之后。
        let items = trip.sortedDays[0].sortedItems
        XCTAssertEqual(items.map(\.kind),
                       [.sight, .transit, .sight, .transit, .sight, .transit, .food])
        XCTAssertEqual(items.compactMap(\.poiId), ["A", "C", "D", "B"])
        XCTAssertEqual(items.first?.plannedTime, "09:00")
        XCTAssertEqual(items.first?.stayLabel, "约 1.5 小时")

        // 进度推进到完成
        XCTAssertEqual(engine.stage, .done)
        XCTAssertEqual(engine.progress, 1.0)
        // 城市 adcode 已串进路由（公交 city1/city2 用）
        XCTAssertEqual(source.lastRouteCity, "110100")
    }

    @MainActor
    func testHallucinatedPOIDroppedEndToEnd() async throws {
        let ctx = try TestSupport.makeContext()
        let source = MockSource()
        source.byTag = ["景点": [cand("A"), cand("B")]]
        let llm = MockLLM([#"{"days":[{"day":1,"items":[{"poi_id":"A"},{"poi_id":"GHOST"},{"poi_id":"B"}]}]}"#])
        let engine = ItineraryEngine(source: source, llm: llm, context: ctx)

        let trip = try await engine.generate(destination: "北京", prefs: TripPrefs(tags: ["景点"]), days: 1)
        let poiIDs = trip.sortedDays[0].sortedItems.compactMap(\.poiId)
        XCTAssertEqual(poiIDs, ["A", "B"])          // GHOST 不入库
    }

    @MainActor
    func testGeometryPipelineIgnoresLLM() async throws {
        // 确定性几何编排已移除 LLM：即便 LLM 只吐垃圾，也照常产出可行行程，且从不调用 LLM。
        let ctx = try TestSupport.makeContext()
        let source = MockSource()
        source.byTag = ["景点": [cand("A")]]
        let llm = MockLLM(["这不是 JSON"])
        let engine = ItineraryEngine(source: source, llm: llm, context: ctx)

        let trip = try await engine.generate(destination: "北京", prefs: TripPrefs(tags: ["景点"]), days: 1)
        XCTAssertEqual(llm.calls, 0)                 // 几何步骤不再调用 LLM
        XCTAssertEqual(trip.sortedDays[0].sortedItems.compactMap(\.poiId), ["A"])
    }

    @MainActor
    func testMultiDayAndTransitCounts() async throws {
        let ctx = try TestSupport.makeContext()
        let source = MockSource()
        // 点间留 ~430m 真实间距：mock 路网 1200m 不超过 3× 直线，不触发 P6.3 跨水回填（保持 1 段 1 次调用）。
        source.byTag = ["景点": [cand("A", lng: 116.400), cand("B", lng: 116.405),
                              cand("C", lng: 116.410), cand("D", lng: 116.415)]]
        let llm = MockLLM([#"{"days":[{"day":1,"items":[{"poi_id":"A"},{"poi_id":"B"}]},{"day":2,"items":[{"poi_id":"C"},{"poi_id":"D"}]}]}"#])
        let engine = ItineraryEngine(source: source, llm: llm, context: ctx)

        let trip = try await engine.generate(destination: "北京", prefs: TripPrefs(tags: ["景点"]), days: 2)
        XCTAssertEqual(trip.sortedDays.count, 2)
        XCTAssertEqual(trip.nights, 1)
        // 每天 2 POI → 1 段交通；共 2 次 route 调用
        XCTAssertEqual(source.routeCalls, 2)
        XCTAssertEqual(trip.sortedDays[0].sortedItems.filter { $0.kind == .transit }.count, 1)
    }

    @MainActor
    func testLodgingSplitOutOfItineraryIntoShortlist() async throws {
        let ctx = try TestSupport.makeContext()
        let source = MockSource()
        source.byTag = [
            "景点": [cand("S1", .sight)],
            "美食": [cand("F1", .food)],
            "住宿": [hotel("H1", rating: 4.8), hotel("H2", rating: 4.5)],
        ]
        // LLM 已被移出几何步骤；住宿 H1 无论如何不进动线。
        let llm = MockLLM([#"{"days":[{"day":1,"items":[{"poi_id":"S1"},{"poi_id":"F1"},{"poi_id":"H1"}]}]}"#])
        let engine = ItineraryEngine(source: source, llm: llm, context: ctx)

        let trip = try await engine.generate(destination: "厦门", prefs: TripPrefs(tags: ["美食"]), days: 1)

        let poiIDs = trip.sortedDays[0].sortedItems.compactMap(\.poiId)
        XCTAssertFalse(poiIDs.contains("H1"))                       // 住宿不进每日动线
        // v2（D1）：单景点日时刻线未跨午窗 → F1 不插入动线（转入附近美食推荐）。
        XCTAssertEqual(Set(poiIDs), ["S1"])
        XCTAssertEqual(trip.lodgingOptions.map(\.id), ["H1", "H2"]) // 按评分降序成清单
        XCTAssertEqual(trip.lodgingOptions.first?.rating, 4.8)
    }

    @MainActor
    func testNoCandidatesThrows() async throws {
        let ctx = try TestSupport.makeContext()
        let engine = ItineraryEngine(source: MockSource(), llm: MockLLM(["{}"]), context: ctx)
        do {
            _ = try await engine.generate(destination: "北京", prefs: TripPrefs(tags: ["美食"]), days: 1)
            XCTFail("expected noCandidates")
        } catch {
            XCTAssertEqual(error as? ItineraryEngine.EngineError, .noCandidates)
        }
    }
}
