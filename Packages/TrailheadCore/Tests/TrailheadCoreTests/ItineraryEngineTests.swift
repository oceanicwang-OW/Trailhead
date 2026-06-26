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

    func geocodeCity(_ name: String) async throws -> (adcode: String, center: (Double, Double)) {
        (adcode, (116.4, 39.9))
    }

    func searchPOI(adcode: String, tags: [String]) async throws -> [POICandidate] {
        tags.flatMap { byTag[$0] ?? [] }
    }

    func route(from: POICandidate, to: POICandidate,
               mode: TransitMode) async throws -> (minutes: Int, meters: Int, cost: Int?) {
        routeCalls += 1
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

    @MainActor
    func testGenerateEndToEndPersistsTrip() async throws {
        let ctx = try TestSupport.makeContext()
        let source = MockSource()
        source.byTag = ["美食": [cand("A", .sight), cand("B", .food), cand("C", .sight)]]
        let llm = MockLLM([#"{"days":[{"day":1,"items":[{"poi_id":"A","time":"09:00","stay_min":90,"note":"早到"},{"poi_id":"B","time":"12:00","stay_min":60},{"poi_id":"C","time":"15:00","stay_min":120}]}]}"#])
        let engine = ItineraryEngine(source: source, llm: llm, context: ctx)

        let trip = try await engine.generate(destination: "北京", prefs: TripPrefs(tags: ["美食"]), days: 1)

        // 落库
        XCTAssertEqual(try TripRepository(context: ctx).count(), 1)
        XCTAssertEqual(trip.city, "北京")
        XCTAssertEqual(trip.adcode, "110100")
        XCTAssertEqual(trip.status, .ready)
        XCTAssertEqual(trip.sortedDays.count, 1)

        // 3 个 POI + 2 段交通，交替排列
        let items = trip.sortedDays[0].sortedItems
        XCTAssertEqual(items.map(\.kind), [.sight, .transit, .food, .transit, .sight])
        XCTAssertEqual(items.compactMap(\.poiId), ["A", "B", "C"])
        XCTAssertEqual(items.first?.plannedTime, "09:00")
        XCTAssertEqual(items.first?.stayLabel, "约 1.5 小时")

        // 进度推进到完成
        XCTAssertEqual(engine.stage, .done)
        XCTAssertEqual(engine.progress, 1.0)
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
    func testRetriesOnceOnBadJSON() async throws {
        let ctx = try TestSupport.makeContext()
        let source = MockSource()
        source.byTag = ["景点": [cand("A")]]
        let llm = MockLLM(["这不是 JSON", #"{"days":[{"day":1,"items":[{"poi_id":"A"}]}]}"#])
        let engine = ItineraryEngine(source: source, llm: llm, context: ctx)

        let trip = try await engine.generate(destination: "北京", prefs: TripPrefs(tags: ["景点"]), days: 1)
        XCTAssertEqual(llm.calls, 2)                 // 坏 JSON → 重试一次
        XCTAssertEqual(trip.sortedDays[0].sortedItems.compactMap(\.poiId), ["A"])
    }

    @MainActor
    func testMultiDayAndTransitCounts() async throws {
        let ctx = try TestSupport.makeContext()
        let source = MockSource()
        source.byTag = ["景点": [cand("A"), cand("B"), cand("C"), cand("D")]]
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
