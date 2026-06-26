//  TripRepositoryTests.swift
//  PDR T1.4 验收：Trip 增删改查 + 重排。

import Foundation
import SwiftData
@testable import TrailheadCore
import XCTest

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
}
