//  TripRepository.swift
//  Trip 的增删改查 + 行程项重排封装（PDR T1.4 / T6.1）。视图用 @Query 直驱
//  读取；写操作收口到此处，便于落库与重排一致。

import Foundation
import SwiftData

public struct TripRepository {
    public let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    // MARK: - Create

    @discardableResult
    public func create(city: String, subtitle: String = "", adcode: String = "",
                       startDate: Date = .now, nights: Int = 3, prefs: TripPrefs = .init(),
                       status: TripStatus = .draft, accentSeed: Int = 0,
                       days: [DayPlan] = []) throws -> Trip {
        let trip = Trip(city: city, subtitle: subtitle, adcode: adcode, startDate: startDate,
                        nights: nights, prefs: prefs, status: status, accentSeed: accentSeed, days: days)
        context.insert(trip)
        try context.save()
        return trip
    }

    public func insert(_ trip: Trip) throws {
        context.insert(trip)
        try context.save()
    }

    // MARK: - Read

    /// 全部行程，按创建时间倒序（与侧栏 @Query 一致）。
    public func all() throws -> [Trip] {
        try context.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }

    public func trip(id: UUID) throws -> Trip? {
        try context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })).first
    }

    public func count() throws -> Int {
        try context.fetchCount(FetchDescriptor<Trip>())
    }

    // MARK: - Update / Delete

    public func save() throws { try context.save() }

    public func delete(_ trip: Trip) throws {
        context.delete(trip)
        try context.save()
    }

    /// 清空全部行程（设置页"清除全部数据"用，PDR T7.3）。
    public func deleteAll() throws {
        try context.delete(model: Trip.self)
        try context.save()
    }

    // MARK: - Reorder（PDR T1.4 重排封装 / T6.1）

    /// 按给定 id 顺序重写某天行程项的 `order`；未列出的项 order 不变。
    public func reorder(_ day: DayPlan, orderedItemIDs ids: [UUID]) throws {
        var indexByID: [UUID: Int] = [:]
        for (index, id) in ids.enumerated() { indexByID[id] = index }
        for item in day.items where indexByID[item.id] != nil {
            item.order = indexByID[item.id]!
        }
        try context.save()
    }
}
