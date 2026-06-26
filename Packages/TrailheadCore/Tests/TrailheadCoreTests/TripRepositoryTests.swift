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
               mode: TransitMode) async throws -> (minutes: Int, meters: Int, cost: Int?) {
        routeCalls.append((from.id, to.id, mode))
        if failingPairs.contains("\(from.id)-\(to.id)") {
            throw URLError(.cannotConnectToHost)
        }
        return (22, 2600, 12)
    }
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

        try await repo.deletePOI(b, from: day, routeUsing: source)

        let sorted = day.sortedItems
        XCTAssertEqual(sorted.map(\.kind), [.sight, .transit, .sight])
        XCTAssertEqual(sorted.map(\.name), ["A", nil, "C"])
        XCTAssertEqual(sorted.map(\.order), [0, 1, 2])
        XCTAssertEqual(sorted[1].transitMode, .metro)
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
}
