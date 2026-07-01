//  GeoProjectionTests.swift
//  经纬度 → 局部平面米（PDR §4.4，等距近似，以候选质心为原点），供聚类/距离用。

import Foundation
@testable import TrailheadCore
import XCTest

final class GeoProjectionTests: XCTestCase {

    private func poi(_ lat: Double, _ lng: Double) -> POICandidate {
        POICandidate(id: "\(lat),\(lng)", name: "x", kind: .sight, subtype: "", lat: lat, lng: lng)
    }

    func testCentroidOfEmptyIsNil() {
        XCTAssertNil(GeoProjection.centroid(of: []))
    }

    func testCentroidAverages() {
        let c = GeoProjection.centroid(of: [poi(0, 0), poi(2, 4)])
        XCTAssertEqual(c?.lat ?? .nan, 1, accuracy: 1e-9)
        XCTAssertEqual(c?.lng ?? .nan, 2, accuracy: 1e-9)
    }

    func testPointAtOriginProjectsToZero() {
        let p = GeoProjection.project(poi(24.48, 118.09), origin: (lat: 24.48, lng: 118.09))
        XCTAssertEqual(p.x, 0, accuracy: 1e-6)
        XCTAssertEqual(p.y, 0, accuracy: 1e-6)
    }

    func testOneDegreeNorthIsAboutMetersPerDegree() {
        // 1° 纬度 ≈ 6_371_000 * π/180 ≈ 111194.9 m，x 应约 0。
        let p = GeoProjection.project(poi(1, 0), origin: (lat: 0, lng: 0))
        XCTAssertEqual(p.y, 6_371_000 * .pi / 180, accuracy: 1.0)
        XCTAssertEqual(p.x, 0, accuracy: 1e-6)
    }

    func testEastingShrinksWithLatitude() {
        // 高纬度同样经度差对应更短的东向距离（cos(lat) 收缩）。
        let atEquator = GeoProjection.project(poi(0, 1), origin: (lat: 0, lng: 0)).x
        let atHighLat = GeoProjection.project(poi(60, 1), origin: (lat: 60, lng: 0)).x
        XCTAssertEqual(atHighLat, atEquator * cos(60 * .pi / 180), accuracy: 1.0)
    }

    func testPlanarDistanceApproximatesHaversine() {
        // 城市尺度小距离：投影平面距离应逼近 haversine（差 < 0.5%）。
        let a = poi(24.4800, 118.0900)
        let b = poi(24.4900, 118.1000)
        let pts = GeoProjection.project([a, b])
        let planar = hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y)
        let geo = ItineraryDayBuilder.haversineMeters(a, b)
        XCTAssertEqual(planar, geo, accuracy: geo * 0.005)
    }

    func testProjectArrayUsesCentroidOrigin() {
        // 用质心作原点：两点投影关于原点对称，坐标和应约为 0。
        let pts = GeoProjection.project([poi(0, 0), poi(2, 2)])
        XCTAssertEqual(pts[0].x + pts[1].x, 0, accuracy: 1e-6)
        XCTAssertEqual(pts[0].y + pts[1].y, 0, accuracy: 1e-6)
    }
}
