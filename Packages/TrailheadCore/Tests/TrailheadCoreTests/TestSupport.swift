//  TestSupport.swift
//  共享测试夹具：内存 SwiftData 容器 + 候选构造助手。

import Foundation
import SwiftData
@testable import TrailheadCore

enum TestSupport {
    /// 每个测试一个独立的临时磁盘 store（用完即弃）。
    /// 注意：① 不用 in-memory —— `@Attribute(.unique)` 唯一约束在内存配置下不
    /// 受支持、会 SIGTRAP；② 返回新建的 `ModelContext(container)` 而非
    /// `mainContext`，避免 @MainActor 隔离与测试执行线程错配。
    static func makeContext() throws -> ModelContext {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trailhead-test-\(UUID().uuidString).store")
        let config = ModelConfiguration(url: url)
        let container = try ModelContainer(
            for: Trip.self, DayPlan.self, PlanItem.self, CachedPOI.self,
            configurations: config
        )
        return ModelContext(container)
    }

    static func candidate(_ id: String, name: String = "POI", kind: ItemKind = .sight,
                          lat: Double = 34.99, lng: Double = 135.77) -> POICandidate {
        POICandidate(id: id, name: name, kind: kind, subtype: "测试",
                     lat: lat, lng: lng, rating: 4.5, openHours: "09:00-18:00", avgPrice: 120)
    }
}
