//  GeoProjection.swift
//  经纬度 → 局部平面米（PDR §4.4）。等距圆柱近似：以候选质心为原点，把度差换成米，
//  供 DayClusterer 聚类与簇内距离计算用。城市尺度小范围内与 haversine 误差可忽略。纯函数。

import Foundation

public enum GeoProjection {
    /// 投影后的平面坐标，单位米（x=东向，y=北向）。
    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// 每纬度对应米数（与 haversine 同用 6_371_000 半径，保持两处距离口径一致）。
    static let metersPerDegree = 6_371_000.0 * .pi / 180

    /// 候选质心（经纬算术平均）；空数组返回 nil。
    public static func centroid(of candidates: [POICandidate]) -> (lat: Double, lng: Double)? {
        guard !candidates.isEmpty else { return nil }
        let n = Double(candidates.count)
        let lat = candidates.reduce(0) { $0 + $1.lat } / n
        let lng = candidates.reduce(0) { $0 + $1.lng } / n
        return (lat, lng)
    }

    /// 单点投影：北向 = 纬度差×米/度；东向按原点纬度 cos 收缩（高纬同经度差对应更短距离）。
    public static func project(_ c: POICandidate, origin: (lat: Double, lng: Double)) -> Point {
        let y = (c.lat - origin.lat) * metersPerDegree
        let x = (c.lng - origin.lng) * metersPerDegree * cos(origin.lat * .pi / 180)
        return Point(x: x, y: y)
    }

    /// 以质心为原点批量投影；空数组返回空。
    public static func project(_ candidates: [POICandidate]) -> [Point] {
        guard let origin = centroid(of: candidates) else { return [] }
        return candidates.map { project($0, origin: origin) }
    }
}
