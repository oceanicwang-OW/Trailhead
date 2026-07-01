//  WaterGate.swift
//  跨水域/需摆渡判定（PDR 编排层改造 P6.3 / A1）。
//  直线阈值对短距离跨海不可靠：陆地↔离岛（如厦门本岛↔鼓浪屿）直线常 <1500m，却被 mode() 判为「步行」，
//  实际需轮渡。修法**不是抬阈值**（那会把更多短跨水段也吞进步行），而是加「水域分隔」兜底：
//  当一段的两端分处同一水域分隔区的内外两侧时，强制判为跨水域（→ 轮渡）。纯函数、确定性、可配。

import Foundation

public enum WaterGate {
    /// 一个「离岛 / 水域分隔区」，用圆（中心经纬 + 半径米）近似岛屿轮廓。
    /// 一段的两端「一个在圈内、一个在圈外」⇒ 判定为跨越该水域（需摆渡）。
    public struct Region: Sendable {
        public let name: String
        public let lat: Double
        public let lng: Double
        public let radiusMeters: Double

        public init(name: String, lat: Double, lng: Double, radiusMeters: Double) {
            self.name = name
            self.lat = lat
            self.lng = lng
            self.radiusMeters = radiusMeters
        }
    }

    /// 已知需摆渡的离岛（可配 / 后续可外置为数据源）。当前覆盖厦门·鼓浪屿（P8.2 回归用例）。
    /// 半径取 ~900m：鼓浪屿全岛约 1.8km 见方，足以罩住岛内景点，又不误伤本岛轮渡码头（距岛心 ~1.5km）。
    public static let regions: [Region] = [
        Region(name: "鼓浪屿", lat: 24.4470, lng: 118.0670, radiusMeters: 900)
    ]

    /// 两点是否跨越某个水域分隔（一端在岛内、另一端在岛外）。岛内↔岛内、岛外↔岛外均为 false。
    public static func crossesWater(_ a: POICandidate, _ b: POICandidate) -> Bool {
        for region in regions where within(a, region) != within(b, region) {
            return true
        }
        return false
    }

    static func within(_ p: POICandidate, _ region: Region) -> Bool {
        metersBetween(p.lat, p.lng, region.lat, region.lng) <= region.radiusMeters
    }

    static func metersBetween(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let radius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * radius * asin(min(1, sqrt(h)))
    }
}
