//  TestSupport.swift
//  共享测试夹具：内存外的临时 SwiftData 容器、候选构造助手、Mock URLProtocol。

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

    /// 走 MockURLProtocol 的离线 session。
    static func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - Mock URLProtocol（离线拦截 HTTP，支持按序返回多个响应、捕获请求体）

final class MockURLProtocol: URLProtocol {
    struct Stubbed { let status: Int; let body: Data }

    static var requests: [URLRequest] = []
    static var requestBodies: [Data] = []
    private static var queue: [Stubbed] = []

    /// 单一响应。
    static func stub(_ json: String, status: Int = 200) {
        reset(); queue = [Stubbed(status: status, body: Data(json.utf8))]
    }

    /// 按序响应（用于重试场景）；最后一个会被复用。
    static func stubSequence(_ responses: [(status: Int, json: String)]) {
        reset(); queue = responses.map { Stubbed(status: $0.status, body: Data($0.json.utf8)) }
    }

    static func reset() { requests = []; requestBodies = []; queue = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.requests.append(request)
        MockURLProtocol.requestBodies.append(Self.readBody(request))

        let stub = MockURLProtocol.queue.count > 1
            ? MockURLProtocol.queue.removeFirst()
            : (MockURLProtocol.queue.first ?? Stubbed(status: 200, body: Data()))

        let resp = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                   httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession 常把 httpBody 转成 stream，URLProtocol 里 httpBody 可能为 nil → 读 stream。
    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        return data
    }
}
