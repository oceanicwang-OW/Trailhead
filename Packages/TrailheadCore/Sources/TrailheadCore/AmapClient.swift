//  AmapClient.swift
//  高德 Web 服务实现（PDR T2.1–T2.4 / §5.1 / §12.1）。实现 POIDataSource：
//  geocodeCity / searchPOI(v5 place/text) / route(walk/drive/transit)。
//  · 坐标系 GCJ-02，"lng,lat" 串，与 MapKit 境内直接兼容。
//  · key 取自 Keychain（可注入，便于测试）；所有请求带 key + output=json。
//  · business 字段容错（缺失不阻塞）；识别配额/错误码抛领域错误，不静默失败。

import Foundation

// MARK: - 领域错误（PDR T2.4）

public enum AmapError: Error, Equatable {
    case missingKey
    case quotaExceeded                 // 配额/QPS 超限 → 上层降级缓存
    case apiError(code: String, message: String)
    case decoding(String)
    case emptyResult
}

// MARK: - tag → 高德类目码（PDR §12.1 静态映射）

public enum AmapCategory {
    /// 兴趣 tag → 高德 POI 类目码。未知 tag 落到「景点」。
    public static let byTag: [String: String] = [
        "美食": "050000", "餐饮": "050000",
        "景点": "110000", "历史古迹": "110000", "自然风光": "110000", "风景": "110000",
        "住宿": "100000", "酒店": "100000",
        "购物": "060000",
        "休闲娱乐": "080000", "娱乐": "080000",
    ]

    public static func code(for tag: String) -> String { byTag[tag] ?? "110000" }

    /// 高德 type 码（前两位大类）→ ItemKind。
    public static func kind(forTypeCode code: String) -> ItemKind {
        switch String(code.prefix(2)) {
        case "05": return .food
        case "10": return .lodging
        case "11", "12": return .sight
        default:   return .sight
        }
    }
}

// MARK: - AmapClient

public struct AmapClient: POIDataSource {
    /// 超限/配额类 infocode（PDR：识别后降级缓存）。
    static let quotaInfocodes: Set<String> = [
        "10003",  // DAILY_QUERY_OVER_LIMIT
        "10004",  // ACCESS_TOO_FREQUENT (QPS)
        "10019", "10020", "10021",  // 各类并发/限流
        "10044",  // USER_DAILY_QUERY_OVER_LIMIT
        "10045",  // USER_ABROAD_DAILY_QUERY_OVER_LIMIT
    ]

    private let base = URL(string: "https://restapi.amap.com")!
    private let session: URLSession
    private let keyProvider: () -> String?

    public init(session: URLSession = .shared,
                keyProvider: @escaping () -> String? = { KeychainStore.get(KeychainStore.Account.amap) }) {
        self.session = session
        self.keyProvider = keyProvider
    }

    // MARK: POIDataSource

    /// 城市名 → adcode + 中心坐标（GCJ-02）。/v3/config/district
    public func geocodeCity(_ name: String) async throws -> (adcode: String, center: (Double, Double)) {
        let json = try await get("/v3/config/district", [
            "keywords": name, "subdistrict": "0",
        ])
        guard let districts = json["districts"] as? [[String: Any]], let first = districts.first,
              let adcode = first["adcode"] as? String,
              let center = (first["center"] as? String).flatMap(Self.parseLngLat) else {
            throw AmapError.emptyResult
        }
        return (adcode, center)
    }

    /// 按兴趣 tag 召回候选（去重）。/v5/place/text，show_fields=business 拿评分/营业。
    public func searchPOI(adcode: String, tags: [String]) async throws -> [POICandidate] {
        let codes = tags.isEmpty ? ["110000"] : Set(tags.map(AmapCategory.code)).sorted()
        var seen = Set<String>()
        var out: [POICandidate] = []
        for code in codes {
            let json = try await get("/v5/place/text", [
                "types": code, "region": adcode, "city_limit": "true",
                "show_fields": "business", "page_size": "25",
            ])
            for poi in (json["pois"] as? [[String: Any]] ?? []) {
                guard let candidate = Self.parsePOI(poi), seen.insert(candidate.id).inserted else { continue }
                out.append(candidate)
            }
        }
        return out
    }

    /// 相邻两点路径规划。mode 决定端点：步行/驾车/公交。
    public func route(from: POICandidate, to: POICandidate,
                      mode: TransitMode) async throws -> (minutes: Int, meters: Int, cost: Int?) {
        let origin = Self.lngLat(from), destination = Self.lngLat(to)
        switch mode {
        case .walk:
            return try await pathRoute("/v5/direction/walking", origin, destination)
        case .drive, .taxi:
            return try await pathRoute("/v5/direction/driving", origin, destination)
        case .metro, .bus, .train:
            return try await transitRoute(origin, destination)
        }
    }

    // MARK: - 请求与解析

    private func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        guard let key = keyProvider(), !key.isEmpty else { throw AmapError.missingKey }
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = (query.merging(["key": key, "output": "json"]) { a, _ in a })
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, _) = try await session.data(from: comps.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AmapError.decoding("响应非 JSON 对象")
        }
        try Self.checkStatus(json)
        return json
    }

    /// 校验高德 status/infocode；非 1 或配额码 → 领域错误。
    static func checkStatus(_ json: [String: Any]) throws {
        let infocode = json["infocode"] as? String ?? ""
        let status = json["status"] as? String ?? ""
        if status == "1", infocode == "10000" { return }
        if quotaInfocodes.contains(infocode) { throw AmapError.quotaExceeded }
        throw AmapError.apiError(code: infocode, message: json["info"] as? String ?? "未知错误")
    }

    private func pathRoute(_ path: String, _ origin: String, _ destination: String) async throws
        -> (minutes: Int, meters: Int, cost: Int?) {
        let json = try await get(path, ["origin": origin, "destination": destination])
        guard let route = json["route"] as? [String: Any],
              let p = (route["paths"] as? [[String: Any]])?.first else { throw AmapError.emptyResult }
        let meters = Self.int(p["distance"]) ?? 0
        let minutes = (Self.duration(in: p) ?? 0) / 60
        let cost = Self.int((p["cost"] as? [String: Any])?["tolls"])
        return (minutes, meters, cost.flatMap { $0 > 0 ? $0 : nil })
    }

    private func transitRoute(_ origin: String, _ destination: String) async throws
        -> (minutes: Int, meters: Int, cost: Int?) {
        let json = try await get("/v5/direction/transit/integrated", [
            "origin": origin, "destination": destination, "city1": "", "city2": "",
        ])
        guard let route = json["route"] as? [String: Any],
              let t = (route["transits"] as? [[String: Any]])?.first else { throw AmapError.emptyResult }
        let meters = Self.int(t["distance"]) ?? 0
        let minutes = (Self.duration(in: t) ?? 0) / 60
        let cost = Self.int((t["cost"] as? [String: Any])?["transit_fee"]) ?? Self.int(t["cost"])
        return (minutes, meters, cost.flatMap { $0 > 0 ? $0 : nil })
    }

    // MARK: - 字段解析助手（对高德不一致结构容错）

    static func parsePOI(_ poi: [String: Any]) -> POICandidate? {
        guard let id = poi["id"] as? String,
              let name = poi["name"] as? String,
              let loc = (poi["location"] as? String).flatMap(parseLngLat) else { return nil }
        let typeCode = (poi["typecode"] as? String) ?? ""
        let business = poi["business"] as? [String: Any]   // 可能缺失/为数组 → nil，不阻塞
        return POICandidate(
            id: id, name: name,
            kind: AmapCategory.kind(forTypeCode: typeCode),
            subtype: (poi["type"] as? String)?.split(separator: ";").last.map(String.init) ?? "",
            lat: loc.1, lng: loc.0,
            rating: double(business?["rating"]),
            openHours: business?["opentime2"] as? String ?? business?["opentime"] as? String,
            avgPrice: int(business?["cost"])
        )
    }

    /// "lng,lat" → (lng, lat)。
    static func parseLngLat(_ s: String) -> (Double, Double)? {
        let parts = s.split(separator: ",")
        guard parts.count == 2, let lng = Double(parts[0]), let lat = Double(parts[1]) else { return nil }
        return (lng, lat)
    }

    static func lngLat(_ c: POICandidate) -> String { "\(c.lng),\(c.lat)" }

    /// v5 时长在 cost.duration（秒）；老结构在 duration。
    static func duration(in node: [String: Any]) -> Int? {
        int((node["cost"] as? [String: Any])?["duration"]) ?? int(node["duration"])
    }

    static func int(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s) ?? Double(s).map(Int.init) }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    static func double(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let s = any as? String { return Double(s) }
        if let i = any as? Int { return Double(i) }
        return nil
    }
}
