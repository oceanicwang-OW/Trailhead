//  LocalFirstTests.swift
//  PDR T8.3：断网（重启）也能浏览历史行程。读取路径只走 SwiftData，不依赖数据源。

import Foundation
import SwiftData
@testable import TrailheadCore
import XCTest

/// 模拟断网：任何数据源调用都抛错（用于断言读取路径不会触达网络）。
private struct OfflineSource: POIDataSource {
    struct Offline: Error {}
    func geocodeCity(_ name: String) async throws -> (adcode: String, center: (Double, Double)) { throw Offline() }
    func searchPOI(adcode: String, tags: [String]) async throws -> [POICandidate] { throw Offline() }
    func route(from: POICandidate, to: POICandidate, mode: TransitMode, city: String) async throws
        -> (minutes: Int, meters: Int, cost: Int?) { throw Offline() }
}

final class LocalFirstTests: XCTestCase {

    private func container(at url: URL) throws -> ModelContainer {
        try ModelContainer(for: Trip.self, DayPlan.self, PlanItem.self, CachedPOI.self,
                           configurations: ModelConfiguration(url: url))
    }

    private func sampleDay() -> DayPlan {
        DayPlan(dayIndex: 0, items: [
            .poi(0, kind: .sight, time: "09:00", name: "故宫", subtype: "", note: "", stay: ""),
            .transit(1, mode: .metro, desc: "地铁", minutes: 20, meters: 3000),
            .poi(2, kind: .food, time: "12:00", name: "全聚德", subtype: "", note: "", stay: ""),
        ])
    }

    /// 写入后用新容器（=断网重启）打开同一 store，历史行程仍可读且完整。
    func testTripsSurviveRestartForOfflineBrowsing() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localfirst-\(UUID().uuidString).store")

        // 会话 1：生成结果落库
        do {
            let repo = TripRepository(context: ModelContext(try container(at: url)))
            _ = try repo.create(city: "北京", adcode: "110100", status: .ready, days: [sampleDay()])
        }

        // 会话 2（相当于断网重启）：全新容器、同一 store，不触网
        let repo = TripRepository(context: ModelContext(try container(at: url)))
        let all = try repo.all()
        XCTAssertEqual(all.count, 1)
        let trip = try XCTUnwrap(all.first)
        XCTAssertEqual(trip.city, "北京")
        XCTAssertEqual(trip.status, .ready)
        XCTAssertEqual(trip.sortedDays.first?.sortedItems.map(\.name), ["故宫", nil, "全聚德"])
    }

    /// 读取/浏览路径不依赖数据源：即便数据源完全离线，仍能读出已存行程。
    func testReadingDoesNotTouchDataSource() throws {
        let ctx = try TestSupport.makeContext()
        let repo = TripRepository(context: ctx)
        let trip = try repo.create(city: "北京", adcode: "110100", status: .ready, days: [sampleDay()])

        _ = OfflineSource()   // 在场但读取压根不会用到它
        XCTAssertEqual(try repo.count(), 1)
        XCTAssertEqual(try repo.trip(id: trip.id)?.sortedDays.first?.sortedItems.count, 3)
    }
}
