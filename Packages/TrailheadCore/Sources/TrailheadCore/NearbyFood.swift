//  NearbyFood.swift
//  当天「附近美食推荐」挑选规则：从全城美食候选里，选出离当天景点近、评分高的若干家，
//  排除已排进当天动线的店。无坐标参照时退化为全城高分。纯函数，便于单测。

import Foundation

public enum NearbyFood {
    /// 默认参照半径（米）与条数。
    public static let defaultRadius: Double = 2500
    public static let defaultLimit = 6

    /// 从 `pool`（美食候选）里挑当天附近高分美食。
    /// - coords: 当天各景点坐标（lat, lng）。
    /// - excluding: 已排进动线的 poi id（避免与正餐重复）。
    public static func pick(_ pool: [POICandidate], nearCoords coords: [(lat: Double, lng: Double)],
                            excluding: Set<String> = [], radiusMeters: Double = defaultRadius,
                            limit: Int = defaultLimit) -> [FoodOption] {
        let foods = pool.filter { $0.kind == .food && !excluding.contains($0.id) }
        let byRating = { (a: POICandidate, b: POICandidate) in (a.rating ?? 0) > (b.rating ?? 0) }

        let candidates: [POICandidate]
        if coords.isEmpty {
            candidates = foods.sorted(by: byRating)                    // 无参照 → 全城高分
        } else {
            let near = foods.filter { f in
                coords.contains { meters(f.lat, f.lng, $0.lat, $0.lng) <= radiusMeters }
            }
            // 半径内不足时，用全城高分兜底补齐。
            let rest = foods.filter { f in !near.contains { $0.id == f.id } }
            candidates = near.sorted(by: byRating) + rest.sorted(by: byRating)
        }
        return candidates.prefix(limit).map {
            FoodOption(id: $0.id, name: $0.name, rating: $0.rating, avgPrice: $0.avgPrice,
                       subtype: $0.subtype, lat: $0.lat, lng: $0.lng)
        }
    }

    static func meters(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let radius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * radius * asin(min(1, sqrt(a)))
    }
}
