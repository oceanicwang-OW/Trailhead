//  CachedPOI.swift
//  本地 POI 缓存实体（PDR T1.2 / §4 / T2.5）。召回候选先落此表，按
//  (adcode, category) 索引、带 TTL；同城再次生成直接命中，省高德配额。

import Foundation
import SwiftData

@Model
public final class CachedPOI {
    /// 复合唯一键 `adcode|category|poiId`，避免同一 POI 在不同类目下相互覆盖。
    @Attribute(.unique) public var key: String

    public var poiId: String
    public var adcode: String
    public var category: String        // 召回所用的 tag / 类目键
    public var name: String
    public var kindRaw: String
    public var subtype: String
    public var lat: Double
    public var lng: Double             // GCJ-02
    public var rating: Double?
    public var openHours: String?
    public var avgPrice: Int?
    public var tagsRaw: String = ""    // "\n" 连接（带默认值 → 轻量迁移安全，同 DayPlan.theme 先例）
    public var photosRaw: String = ""  // "\n" 连接的图片 URL
    public var cachedAt: Date

    public init(poiId: String, adcode: String, category: String, name: String,
                kind: ItemKind, subtype: String, lat: Double, lng: Double,
                rating: Double? = nil, openHours: String? = nil, avgPrice: Int? = nil,
                tags: [String] = [], photos: [String] = [], cachedAt: Date = .now) {
        self.key = Self.makeKey(adcode: adcode, category: category, poiId: poiId)
        self.poiId = poiId
        self.adcode = adcode
        self.category = category
        self.name = name
        self.kindRaw = kind.rawValue
        self.subtype = subtype
        self.lat = lat
        self.lng = lng
        self.rating = rating
        self.openHours = openHours
        self.avgPrice = avgPrice
        self.tagsRaw = tags.joined(separator: "\n")
        self.photosRaw = photos.joined(separator: "\n")
        self.cachedAt = cachedAt
    }

    public var kind: ItemKind { ItemKind(rawValue: kindRaw) ?? .sight }
    public var tags: [String] { tagsRaw.isEmpty ? [] : tagsRaw.components(separatedBy: "\n") }
    public var photos: [String] { photosRaw.isEmpty ? [] : photosRaw.components(separatedBy: "\n") }

    public static func makeKey(adcode: String, category: String, poiId: String) -> String {
        "\(adcode)|\(category)|\(poiId)"
    }

    /// 是否超出 TTL（相对 `now`）。
    public func isExpired(ttl: TimeInterval, now: Date = .now) -> Bool {
        now.timeIntervalSince(cachedAt) > ttl
    }
}

// MARK: - 与召回候选（POICandidate）互转

extension CachedPOI {
    public convenience init(candidate c: POICandidate, adcode: String, category: String, cachedAt: Date = .now) {
        self.init(poiId: c.id, adcode: adcode, category: category, name: c.name,
                  kind: c.kind, subtype: c.subtype, lat: c.lat, lng: c.lng,
                  rating: c.rating, openHours: c.openHours, avgPrice: c.avgPrice,
                  tags: c.tags, photos: c.photos, cachedAt: cachedAt)
    }

    public var candidate: POICandidate {
        POICandidate(id: poiId, name: name, kind: kind, subtype: subtype,
                     lat: lat, lng: lng, rating: rating, openHours: openHours, avgPrice: avgPrice,
                     tags: tags, photos: photos)
    }
}
