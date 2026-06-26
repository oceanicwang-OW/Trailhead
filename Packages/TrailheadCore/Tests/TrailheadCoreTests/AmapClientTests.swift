//  AmapClientTests.swift
//  PDR T2.1–T2.4 验收：用 URLProtocol 拦截高德响应，离线测 URL 拼接 / 解析 /
//  business 容错 / 配额错误。不需要真 key。

import Foundation
@testable import TrailheadCore
import XCTest

// MockURLProtocol 定义在 TestSupport.swift（多个测试共享）。

final class AmapClientTests: XCTestCase {

    private func makeClient(key: String? = "TESTKEY") -> AmapClient {
        AmapClient(session: TestSupport.mockSession(), keyProvider: { key })
    }

    private func queryValue(_ name: String, in req: URLRequest) -> String? {
        URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    // T2.1 ---------------------------------------------------------------

    func testGeocodeCity() async throws {
        MockURLProtocol.stub(#"{"status":"1","info":"OK","infocode":"10000","districts":[{"adcode":"110000","name":"北京市","center":"116.405285,39.904989"}]}"#)
        let (adcode, center) = try await makeClient().geocodeCity("北京")

        XCTAssertEqual(adcode, "110000")
        XCTAssertEqual(center.0, 116.405285, accuracy: 1e-6)   // lng
        XCTAssertEqual(center.1, 39.904989, accuracy: 1e-6)    // lat

        let req = MockURLProtocol.requests.first
        XCTAssertEqual(req?.url?.path, "/v3/config/district")
        XCTAssertEqual(queryValue("keywords", in: req!), "北京")
        XCTAssertEqual(queryValue("key", in: req!), "TESTKEY")
        XCTAssertEqual(queryValue("output", in: req!), "json")
    }

    // T2.2 ---------------------------------------------------------------

    func testSearchPOIParsesBusiness() async throws {
        MockURLProtocol.stub(#"{"status":"1","info":"OK","infocode":"10000","pois":[{"id":"B0FFG","name":"故宫博物院","location":"116.397,39.918","type":"风景名胜;公园广场;公园","typecode":"110000","business":{"rating":"4.8","opentime2":"08:30-17:00","cost":"60"}}]}"#)
        let pois = try await makeClient().searchPOI(adcode: "110000", tags: ["历史古迹"])

        XCTAssertEqual(pois.count, 1)
        let p = try XCTUnwrap(pois.first)
        XCTAssertEqual(p.id, "B0FFG")
        XCTAssertEqual(p.name, "故宫博物院")
        XCTAssertEqual(p.kind, .sight)            // typecode 11 → sight
        XCTAssertEqual(p.subtype, "公园")          // type 串末段
        XCTAssertEqual(p.lng, 116.397, accuracy: 1e-6)
        XCTAssertEqual(p.lat, 39.918, accuracy: 1e-6)
        XCTAssertEqual(p.rating, 4.8)
        XCTAssertEqual(p.openHours, "08:30-17:00")
        XCTAssertEqual(p.avgPrice, 60)

        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path, "/v5/place/text")
        XCTAssertEqual(queryValue("types", in: MockURLProtocol.requests.first!), "110000")
        XCTAssertEqual(queryValue("region", in: MockURLProtocol.requests.first!), "110000")
    }

    func testSearchPOIToleratesMissingBusiness() async throws {
        MockURLProtocol.stub(#"{"status":"1","info":"OK","infocode":"10000","pois":[{"id":"B1","name":"小馆","location":"116.4,39.9","type":"餐饮服务;中餐厅","typecode":"050000"}]}"#)
        let pois = try await makeClient().searchPOI(adcode: "110000", tags: ["美食"])
        let p = try XCTUnwrap(pois.first)

        XCTAssertEqual(p.kind, .food)             // typecode 05 → food
        XCTAssertNil(p.rating)                    // 无 business 不阻塞
        XCTAssertNil(p.openHours)
        XCTAssertNil(p.avgPrice)
    }

    func testSearchPOIMapsTagsAndDedupes() async throws {
        // 两个 tag → 两个类目码 → 两次请求；同 id 去重为 1。
        MockURLProtocol.stub(#"{"status":"1","info":"OK","infocode":"10000","pois":[{"id":"DUP","name":"X","location":"116.4,39.9","type":"a;b","typecode":"110000"}]}"#)
        let pois = try await makeClient().searchPOI(adcode: "110000", tags: ["美食", "历史古迹"])

        XCTAssertEqual(pois.count, 1)             // 去重
        let types = MockURLProtocol.requests.compactMap { queryValue("types", in: $0) }.sorted()
        XCTAssertEqual(types, ["050000", "110000"])   // tag→类目映射
    }

    // T2.3 ---------------------------------------------------------------

    func testRouteWalking() async throws {
        MockURLProtocol.stub(#"{"status":"1","info":"OK","infocode":"10000","route":{"paths":[{"distance":"900","cost":{"duration":"720"}}]}}"#)
        let r = try await makeClient().route(from: poi("A"), to: poi("B"), mode: .walk)
        XCTAssertEqual(r.meters, 900)
        XCTAssertEqual(r.minutes, 12)             // 720s / 60
        XCTAssertNil(r.cost)
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path, "/v5/direction/walking")
    }

    func testRouteDrivingWithTolls() async throws {
        MockURLProtocol.stub(#"{"status":"1","info":"OK","infocode":"10000","route":{"paths":[{"distance":"4200","cost":{"duration":"1080","tolls":"15"}}]}}"#)
        let r = try await makeClient().route(from: poi("A"), to: poi("B"), mode: .drive)
        XCTAssertEqual(r.meters, 4200)
        XCTAssertEqual(r.minutes, 18)
        XCTAssertEqual(r.cost, 15)
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path, "/v5/direction/driving")
    }

    func testRouteTransitUsesCity() async throws {
        MockURLProtocol.stub(#"{"status":"1","info":"OK","infocode":"10000","route":{"transits":[{"distance":"5000","cost":{"duration":"1500","transit_fee":"6"}}]}}"#)
        let r = try await makeClient().route(from: poi("A"), to: poi("B"), mode: .metro, city: "510100")
        XCTAssertEqual(r.meters, 5000)
        XCTAssertEqual(r.minutes, 25)
        XCTAssertEqual(r.cost, 6)
        let req = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(req.url?.path, "/v5/direction/transit/integrated")
        XCTAssertEqual(queryValue("city1", in: req), "510100")   // city 已用于 city1/city2
        XCTAssertEqual(queryValue("city2", in: req), "510100")
    }

    func testTransitWithoutCityFallsBackToDriving() async throws {
        MockURLProtocol.stub(#"{"status":"1","info":"OK","infocode":"10000","route":{"paths":[{"distance":"4200","cost":{"duration":"1080"}}]}}"#)
        let r = try await makeClient().route(from: poi("A"), to: poi("B"), mode: .metro, city: "")
        XCTAssertEqual(r.meters, 4200)
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path, "/v5/direction/driving")  // 无 city → 退化驾车
    }

    // T2.4 ---------------------------------------------------------------

    func testQuotaExceededThrowsDomainError() async throws {
        MockURLProtocol.stub(#"{"status":"0","info":"USER_DAILY_QUERY_OVER_LIMIT","infocode":"10044"}"#)
        await assertThrows(.quotaExceeded) { try await self.makeClient().geocodeCity("北京") }
    }

    func testInvalidKeyThrowsApiError() async throws {
        MockURLProtocol.stub(#"{"status":"0","info":"INVALID_USER_KEY","infocode":"10001"}"#)
        await assertThrows(.apiError(code: "10001", message: "INVALID_USER_KEY")) {
            try await self.makeClient().geocodeCity("北京")
        }
    }

    func testMissingKeyThrowsBeforeRequest() async throws {
        MockURLProtocol.stub("{}")
        await assertThrows(.missingKey) { try await self.makeClient(key: nil).geocodeCity("北京") }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)   // 无 key 不发请求
    }

    // helpers ------------------------------------------------------------

    private func poi(_ id: String) -> POICandidate {
        POICandidate(id: id, name: id, kind: .sight, subtype: "", lat: 39.9, lng: 116.4)
    }

    private func assertThrows(_ expected: AmapError, _ body: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected to throw \(expected)", file: file, line: line) }
        catch let e as AmapError { XCTAssertEqual(e, expected, file: file, line: line) }
        catch { XCTFail("wrong error: \(error)", file: file, line: line) }
    }
}
