//  TripRepositoryTests.swift
//  PDR T1.4 验收：Trip 增删改查 + 重排。

import Foundation
import SwiftData
@testable import TrailheadCore
import XCTest

private final class RouteSpySource: POIDataSource {
    var failingPairs: Set<String> = []
    private(set) var routeCalls: [(from: String, to: String, mode: TransitMode)] = []

    func geocodeCity(_ name: String) async throws -> (adcode: String, center: (Double, Double)) {
        ("000000", (0, 0))
    }

    func searchPOI(adcode: String, tags: [String]) async throws -> [POICandidate] {
        []
    }

    func route(from: POICandidate, to: POICandidate,
               mode: TransitMode, city: String) async throws -> (minutes: Int, meters: Int, cost: Int?) {
        routeCalls.append((from.id, to.id, mode))
        if failingPairs.contains("\(from.id)-\(to.id)") {
            throw URLError(.cannotConnectToHost)
        }
        return (22, 2600, 12)
    }
}

private final class RegenerateSpySource: POIDataSource {
    var byTag: [String: [POICandidate]] = [:]
    private(set) var routePairs: [String] = []

    func geocodeCity(_ name: String) async throws -> (adcode: String, center: (Double, Double)) {
        ("110100", (0, 0))
    }

    func searchPOI(adcode: String, tags: [String]) async throws -> [POICandidate] {
        tags.flatMap { byTag[$0] ?? [] }
    }

    func route(from: POICandidate, to: POICandidate,
               mode: TransitMode, city: String) async throws -> (minutes: Int, meters: Int, cost: Int?) {
        routePairs.append("\(from.id)-\(to.id)")
        return (18, 1800, 8)
    }
}

private final class RegenerateLLM: LLMProvider {
    var responses: [String]
    private(set) var calls = 0

    init(_ responses: [String]) {
        self.responses = responses
    }

    func planItinerary(prefs: TripPrefs, candidates: [POICandidate], days: Int) async throws -> Data {
        defer { calls += 1 }
        return Data(responses[min(calls, responses.count - 1)].utf8)
    }
}

private func regenCandidate(_ id: String, kind: ItemKind = .sight,
                            lat: Double = 30.0, lng: Double = 104.0) -> POICandidate {
    POICandidate(id: id, name: id, kind: kind, subtype: kind.label, lat: lat, lng: lng)
}

final class TripRepositoryTests: XCTestCase {

    func testCreateAndCount() throws {
        let repo = TripRepository(context: try TestSupport.makeContext())
        XCTAssertEqual(try repo.count(), 0)
        try repo.create(city: "成都", nights: 3)
        try repo.create(city: "大理", nights: 2)
        XCTAssertEqual(try repo.count(), 2)
    }

    func testAllIsSortedByCreatedAtDescending() throws {
        let repo = TripRepository(context: try TestSupport.makeContext())
        let first = try repo.create(city: "成都")
        let second = try repo.create(city: "大理")

        let all = try repo.all()
        XCTAssertEqual(all.map(\.city), ["大理", "成都"])   // 后建的在前
        XCTAssertEqual(all.first?.id, second.id)
        XCTAssertEqual(all.last?.id, first.id)
    }

    func testFetchByID() throws {
        let repo = TripRepository(context: try TestSupport.makeContext())
        let trip = try repo.create(city: "成都")
        XCTAssertEqual(try repo.trip(id: trip.id)?.city, "成都")
        XCTAssertNil(try repo.trip(id: UUID()))
    }

    func testUpdatePersists() throws {
        let repo = TripRepository(context: try TestSupport.makeContext())
        let trip = try repo.create(city: "成都", status: .draft)
        trip.status = .ready
        trip.city = "成都(改)"
        try repo.save()

        let reloaded = try repo.trip(id: trip.id)
        XCTAssertEqual(reloaded?.status, .ready)
        XCTAssertEqual(reloaded?.city, "成都(改)")
    }

    func testDeleteRemovesTrip() throws {
        let repo = TripRepository(context: try TestSupport.makeContext())
        let trip = try repo.create(city: "成都")
        try repo.delete(trip)
        XCTAssertEqual(try repo.count(), 0)
        XCTAssertNil(try repo.trip(id: trip.id))
    }

    func testDeleteAllEmptiesStore() throws {
        let repo = TripRepository(context: try TestSupport.makeContext())
        try repo.create(city: "成都")
        try repo.create(city: "大理")
        try repo.deleteAll()
        XCTAssertEqual(try repo.count(), 0)
    }

    func testCascadeDeletesDaysAndItems() throws {
        let ctx = try TestSupport.makeContext()
        let repo = TripRepository(context: ctx)
        let day = DayPlan(dayIndex: 0, items: [
            .poi(0, kind: .sight, time: "09:00", name: "A", subtype: "", note: "", stay: ""),
            .poi(1, kind: .food, time: "12:00", name: "B", subtype: "", note: "", stay: ""),
        ])
        let trip = try repo.create(city: "成都", days: [day])
        try repo.delete(trip)

        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<DayPlan>()), 0)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<PlanItem>()), 0)
    }

    func testReorderRewritesItemOrder() throws {
        let ctx = try TestSupport.makeContext()
        let repo = TripRepository(context: ctx)
        let i0 = PlanItem.poi(0, kind: .sight, time: "09:00", name: "A", subtype: "", note: "", stay: "")
        let i1 = PlanItem.poi(1, kind: .food, time: "12:00", name: "B", subtype: "", note: "", stay: "")
        let i2 = PlanItem.poi(2, kind: .sight, time: "15:00", name: "C", subtype: "", note: "", stay: "")
        let day = DayPlan(dayIndex: 0, items: [i0, i1, i2])
        try repo.create(city: "成都", days: [day])

        // 反转顺序：C, B, A
        try repo.reorder(day, orderedItemIDs: [i2.id, i1.id, i0.id])

        XCTAssertEqual(day.sortedItems.map(\.name), ["C", "B", "A"])
        XCTAssertEqual(i2.order, 0)
        XCTAssertEqual(i1.order, 1)
        XCTAssertEqual(i0.order, 2)
    }

    func testReorderSurvivesRefetch() throws {
        let ctx = try TestSupport.makeContext()
        let repo = TripRepository(context: ctx)
        let i0 = PlanItem.poi(0, kind: .sight, time: "09:00", name: "A", subtype: "", note: "", stay: "")
        let i1 = PlanItem.poi(1, kind: .food, time: "12:00", name: "B", subtype: "", note: "", stay: "")
        let day = DayPlan(dayIndex: 0, items: [i0, i1])
        let trip = try repo.create(city: "成都", days: [day])

        try repo.reorder(day, orderedItemIDs: [i1.id, i0.id])

        let reloaded = try repo.trip(id: trip.id)
        let names = reloaded?.sortedDays.first?.sortedItems.map(\.name)
        XCTAssertEqual(names, ["B", "A"])
    }

    func testReorderPOIsKeepsTransitSlots() throws {
        let ctx = try TestSupport.makeContext()
        let repo = TripRepository(context: ctx)
        let a = PlanItem.poi(0, kind: .sight, time: "09:00", name: "A", subtype: "", note: "", stay: "")
        let transitAB = PlanItem.transit(1, mode: .walk, desc: "A 到 B", minutes: 12, meters: 900)
        let b = PlanItem.poi(2, kind: .food, time: "12:00", name: "B", subtype: "", note: "", stay: "")
        let transitBC = PlanItem.transit(3, mode: .metro, desc: "B 到 C", minutes: 20, meters: 3500)
        let c = PlanItem.poi(4, kind: .sight, time: "15:00", name: "C", subtype: "", note: "", stay: "")
        let day = DayPlan(dayIndex: 0, items: [a, transitAB, b, transitBC, c])
        try repo.create(city: "成都", days: [day])

        try repo.reorderPOIs(day, orderedPOIIDs: [c.id, a.id, b.id])

        let sorted = day.sortedItems
        XCTAssertEqual(sorted.map(\.kind), [.sight, .transit, .sight, .transit, .food])
        XCTAssertEqual(sorted.map(\.name), ["C", nil, "A", nil, "B"])
        XCTAssertEqual(sorted.map(\.order), [0, 1, 2, 3, 4])
        XCTAssertEqual(sorted[1].transitDesc, "A 到 B")
        XCTAssertEqual(sorted[3].transitDesc, "B 到 C")
    }

    func testDeletePOIRebuildsTransitBetweenRemainingPOIs() async throws {
        let ctx = try TestSupport.makeContext()
        let repo = TripRepository(context: ctx)
        let source = RouteSpySource()
        let a = PlanItem.poi(0, kind: .sight, time: "09:00", name: "A", subtype: "景点", note: "", stay: "")
        a.poiId = "A"; a.lat = 30.0; a.lng = 104.0
        let transitAB = PlanItem.transit(1, mode: .walk, desc: "A 到 B", minutes: 12, meters: 900)
        let b = PlanItem.poi(2, kind: .food, time: "12:00", name: "B", subtype: "餐厅", note: "", stay: "")
        b.poiId = "B"; b.lat = 30.01; b.lng = 104.01
        let transitBC = PlanItem.transit(3, mode: .metro, desc: "B 到 C", minutes: 20, meters: 3500)
        let c = PlanItem.poi(4, kind: .sight, time: "15:00", name: "C", subtype: "景点", note: "", stay: "")
        c.poiId = "C"; c.lat = 30.04; c.lng = 104.04
        let day = DayPlan(dayIndex: 0, items: [a, transitAB, b, transitBC, c])
        try repo.create(city: "成都", days: [day])

        try await repo.deletePOI(b, from: day, routeUsing: source, adcode: "510100")

        let sorted = day.sortedItems
        XCTAssertEqual(sorted.map(\.kind), [.sight, .transit, .sight])
        XCTAssertEqual(sorted.map(\.name), ["A", nil, "C"])
        XCTAssertEqual(sorted.map(\.order), [0, 1, 2])
        XCTAssertEqual(sorted[1].transitMode, .metro)   // 有 adcode → 公交
        XCTAssertEqual(sorted[1].transitDesc, "地铁")
        XCTAssertEqual(sorted[1].transitMinutes, 22)
        XCTAssertEqual(sorted[1].transitMeters, 2600)
        XCTAssertEqual(sorted[1].transitCost, 12)
        XCTAssertEqual(source.routeCalls.map { "\($0.from)-\($0.to)" }, ["A-C"])
    }

    func testReplacePOIUpdatesTargetAndRebuildsTransit() async throws {
        let ctx = try TestSupport.makeContext()
        let repo = TripRepository(context: ctx)
        let source = RouteSpySource()
        let a = PlanItem.poi(0, kind: .sight, time: "09:00", name: "A", subtype: "景点", note: "", stay: "")
        a.poiId = "A"; a.lat = 30.0; a.lng = 104.0
        let transitAB = PlanItem.transit(1, mode: .walk, desc: "A 到 B", minutes: 12, meters: 900)
        let b = PlanItem.poi(2, kind: .food, time: "12:00", name: "B", subtype: "餐厅", note: "old note", stay: "约 1 小时")
        b.poiId = "B"; b.lat = 30.01; b.lng = 104.01
        let originalID = b.id
        let transitBC = PlanItem.transit(3, mode: .metro, desc: "B 到 C", minutes: 20, meters: 3500)
        let c = PlanItem.poi(4, kind: .sight, time: "15:00", name: "C", subtype: "景点", note: "", stay: "")
        c.poiId = "C"; c.lat = 30.04; c.lng = 104.04
        let day = DayPlan(dayIndex: 0, items: [a, transitAB, b, transitBC, c])
        try repo.create(city: "成都", days: [day])

        let replacement = POICandidate(id: "X", name: "X Cafe", kind: .food, subtype: "咖啡", lat: 30.02, lng: 104.02)
        try await repo.replacePOI(b, with: replacement, in: day, routeUsing: source)

        let sorted = day.sortedItems
        XCTAssertEqual(sorted.map(\.kind), [.sight, .transit, .food, .transit, .sight])
        XCTAssertEqual(sorted.map(\.name), ["A", nil, "X Cafe", nil, "C"])
        XCTAssertEqual(sorted.map(\.order), [0, 1, 2, 3, 4])
        XCTAssertEqual(sorted[2].id, originalID)
        XCTAssertEqual(sorted[2].poiId, "X")
        XCTAssertEqual(sorted[2].subtype, "咖啡")
        XCTAssertEqual(sorted[2].lat, 30.02)
        XCTAssertEqual(sorted[2].lng, 104.02)
        XCTAssertEqual(sorted[2].plannedTime, "12:00")
        XCTAssertEqual(sorted[2].stayLabel, "约 1 小时")
        XCTAssertEqual(sorted[2].note, "old note")
        XCTAssertEqual(source.routeCalls.map { "\($0.from)-\($0.to)" }, ["A-X", "X-C"])
    }

    func testReplacePOISkipsFailedRouteSegmentAndStillSaves() async throws {
        let ctx = try TestSupport.makeContext()
        let repo = TripRepository(context: ctx)
        let source = RouteSpySource()
        source.failingPairs = ["A-X"]
        let a = PlanItem.poi(0, kind: .sight, time: "09:00", name: "A", subtype: "景点", note: "", stay: "")
        a.poiId = "A"; a.lat = 30.0; a.lng = 104.0
        let b = PlanItem.poi(1, kind: .food, time: "12:00", name: "B", subtype: "餐厅", note: "", stay: "")
        b.poiId = "B"; b.lat = 30.01; b.lng = 104.01
        let c = PlanItem.poi(2, kind: .sight, time: "15:00", name: "C", subtype: "景点", note: "", stay: "")
        c.poiId = "C"; c.lat = 30.04; c.lng = 104.04
        let day = DayPlan(dayIndex: 0, items: [a, b, c])
        try repo.create(city: "成都", days: [day])

        let replacement = POICandidate(id: "X", name: "X Cafe", kind: .food, subtype: "咖啡", lat: 30.02, lng: 104.02)
        try await repo.replacePOI(b, with: replacement, in: day, routeUsing: source)

        let sorted = day.sortedItems
        XCTAssertEqual(sorted.map(\.kind), [.sight, .food, .transit, .sight])
        XCTAssertEqual(sorted.map(\.name), ["A", "X Cafe", nil, "C"])
        XCTAssertEqual(source.routeCalls.map { "\($0.from)-\($0.to)" }, ["A-X", "X-C"])
    }

    func testRegenerateDayReplacesOnlySelectedDay() async throws {
        let ctx = try TestSupport.makeContext()
        let repo = TripRepository(context: ctx)
        let source = RegenerateSpySource()
        // v2（D1）：插餐基于临时时刻线——3 景点使时刻线跨越午窗中点 12:30，午餐才会插入。
        source.byTag = ["景点": [
            regenCandidate("X", kind: .sight, lat: 30.0, lng: 104.0),
            regenCandidate("Z", kind: .sight, lat: 30.01, lng: 104.01),
            regenCandidate("W", kind: .sight, lat: 30.02, lng: 104.02),
            regenCandidate("Y", kind: .food, lat: 30.015, lng: 104.015),
        ]]
        let llm = RegenerateLLM([
            #"{"days":[{"day":1,"items":[{"poi_id":"X","time":"10:00","stay_min":90,"note":"new"},{"poi_id":"GHOST"}]}]}"#,
        ])

        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let oldA = PlanItem.poi(0, kind: .sight, time: "09:00", name: "Old A", subtype: "景点", note: "", stay: "")
        oldA.poiId = "OLD-A"; oldA.lat = 30.0; oldA.lng = 104.0
        let oldB = PlanItem.poi(1, kind: .food, time: "12:00", name: "Old B", subtype: "餐饮", note: "", stay: "")
        oldB.poiId = "OLD-B"; oldB.lat = 30.01; oldB.lng = 104.01
        let day0 = DayPlan(dayIndex: 0, date: originalDate, cityLabel: "成都", items: [oldA, oldB])
        let untouched = PlanItem.poi(0, kind: .sight, time: "09:00", name: "Keep", subtype: "景点", note: "", stay: "")
        untouched.poiId = "KEEP"; untouched.lat = 31.0; untouched.lng = 105.0
        let day1 = DayPlan(dayIndex: 1, date: originalDate.addingTimeInterval(86_400), cityLabel: "成都", items: [untouched])
        let trip = try repo.create(city: "成都", adcode: "510100", nights: 1,
                                   prefs: TripPrefs(tags: ["景点"]), days: [day0, day1])
        let oldDay0IDs = Set(day0.items.map(\.id))

        try await repo.regenerateDay(day0, in: trip, source: source, llm: llm)

        XCTAssertEqual(trip.sortedDays.count, 2)
        XCTAssertEqual(day0.dayIndex, 0)
        XCTAssertEqual(day0.date, originalDate)
        XCTAssertEqual(day0.cityLabel, "成都")
        XCTAssertEqual(day1.sortedItems.compactMap(\.poiId), ["KEEP"])

        let regenerated = day0.sortedItems
        // 动线 X→Z→(午餐 Y 顺路)→W；相邻点间补交通段。
        XCTAssertEqual(regenerated.compactMap(\.poiId), ["X", "Z", "Y", "W"])
        XCTAssertEqual(regenerated.map(\.kind),
                       [.sight, .transit, .sight, .transit, .food, .transit, .sight])
        XCTAssertEqual(regenerated.map(\.order), Array(0..<7))
        // 时间/停留改由确定性模拟器产出：首点从 dayStart 09:00 起、景点默认停留 90 分；note 留空（P7 未做）。
        XCTAssertEqual(regenerated[0].plannedTime, "09:00")
        XCTAssertEqual(regenerated[0].stayLabel, "约 1.5 小时")
        XCTAssertNil(regenerated[0].note)
        XCTAssertTrue(regenerated.allSatisfy { !oldDay0IDs.contains($0.id) })
        XCTAssertEqual(source.routePairs, ["X-Z", "Z-Y", "Y-W"])
    }

    func testRegenerateDayExcludesPOIsAlreadyUsedByOtherDays() async throws {
        // D9：单日重生成必须排除其余各天已排的 poi_id——即便它是召回池里评分最高的点。
        let ctx = try TestSupport.makeContext()
        let repo = TripRepository(context: ctx)
        let source = RegenerateSpySource()
        source.byTag = ["景点": [
            regenCandidate("SHARED", kind: .sight, lat: 30.0, lng: 104.0),
            regenCandidate("X", kind: .sight, lat: 30.005, lng: 104.005),
        ]]
        let llm = RegenerateLLM([#"{"days":[]}"#])

        let oldA = PlanItem.poi(0, kind: .sight, time: "09:00", name: "Old A", subtype: "景点", note: "", stay: "")
        oldA.poiId = "OLD-A"; oldA.lat = 30.0; oldA.lng = 104.0
        let day0 = DayPlan(dayIndex: 0, items: [oldA])
        let sharedItem = PlanItem.poi(0, kind: .sight, time: "09:00", name: "Shared", subtype: "景点", note: "", stay: "")
        sharedItem.poiId = "SHARED"; sharedItem.lat = 30.0; sharedItem.lng = 104.0
        let day1 = DayPlan(dayIndex: 1, items: [sharedItem])
        let trip = try repo.create(city: "成都", adcode: "510100", nights: 1,
                                   prefs: TripPrefs(tags: ["景点"]), days: [day0, day1])

        try await repo.regenerateDay(day0, in: trip, source: source, llm: llm)

        XCTAssertEqual(day0.sortedItems.compactMap(\.poiId), ["X"])            // SHARED 被排除
        XCTAssertEqual(day1.sortedItems.compactMap(\.poiId), ["SHARED"])       // 其它天不动
    }

    func testRegenerateDayNoCandidatesLeavesExistingItems() async throws {
        let ctx = try TestSupport.makeContext()
        let repo = TripRepository(context: ctx)
        let source = RegenerateSpySource()
        let llm = RegenerateLLM([
            #"{"days":[{"day":1,"items":[{"poi_id":"X"}]}]}"#,
        ])
        let oldA = PlanItem.poi(0, kind: .sight, time: "09:00", name: "Old A", subtype: "景点", note: "", stay: "")
        oldA.poiId = "OLD-A"; oldA.lat = 30.0; oldA.lng = 104.0
        let oldB = PlanItem.poi(1, kind: .food, time: "12:00", name: "Old B", subtype: "餐饮", note: "", stay: "")
        oldB.poiId = "OLD-B"; oldB.lat = 30.01; oldB.lng = 104.01
        let day = DayPlan(dayIndex: 0, items: [oldA, oldB])
        let trip = try repo.create(city: "成都", adcode: "510100",
                                   prefs: TripPrefs(tags: ["景点"]), days: [day])
        let oldIDs = day.sortedItems.map(\.id)

        do {
            try await repo.regenerateDay(day, in: trip, source: source, llm: llm)
            XCTFail("Expected noCandidates")
        } catch ItineraryEngine.EngineError.noCandidates {
            XCTAssertEqual(day.sortedItems.map(\.id), oldIDs)
            XCTAssertEqual(day.sortedItems.compactMap(\.poiId), ["OLD-A", "OLD-B"])
            XCTAssertEqual(llm.calls, 0)
        }
    }

    func testRegenerateDayEmptyPlanLeavesExistingItems() async throws {
        let ctx = try TestSupport.makeContext()
        let repo = TripRepository(context: ctx)
        let source = RegenerateSpySource()
        // 只有餐饮、无景点 → 无地理锚点，几何流水线产出空天 → emptyPlan（不删旧、不调 LLM）。
        source.byTag = ["景点": [regenCandidate("X", kind: .food)]]
        let llm = RegenerateLLM([#"{"days":[]}"#])
        let oldA = PlanItem.poi(0, kind: .sight, time: "09:00", name: "Old A", subtype: "景点", note: "", stay: "")
        oldA.poiId = "OLD-A"; oldA.lat = 30.0; oldA.lng = 104.0
        let oldB = PlanItem.poi(1, kind: .food, time: "12:00", name: "Old B", subtype: "餐饮", note: "", stay: "")
        oldB.poiId = "OLD-B"; oldB.lat = 30.01; oldB.lng = 104.01
        let day = DayPlan(dayIndex: 0, items: [oldA, oldB])
        let trip = try repo.create(city: "成都", adcode: "510100",
                                   prefs: TripPrefs(tags: ["景点"]), days: [day])
        let oldIDs = day.sortedItems.map(\.id)

        do {
            try await repo.regenerateDay(day, in: trip, source: source, llm: llm)
            XCTFail("Expected emptyPlan")
        } catch ItineraryEngine.EngineError.emptyPlan {
            XCTAssertEqual(day.sortedItems.map(\.id), oldIDs)
            XCTAssertEqual(day.sortedItems.compactMap(\.poiId), ["OLD-A", "OLD-B"])
            XCTAssertEqual(llm.calls, 0)                 // 几何流水线不调用 LLM
        }
    }
}
