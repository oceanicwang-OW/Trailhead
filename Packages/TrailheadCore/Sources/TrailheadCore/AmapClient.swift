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
        "休闲娱乐": "080000", "娱乐": "080000", "夜生活": "080000", "动漫文化": "080000",
    ]

    public static func code(for tag: String) -> String { byTag[tag] ?? "110000" }

    /// 类目码 → 规范类别名（与码 1:1），用于召回去重，避免同码 tag 多次回源。
    static let canonicalByCode: [String: String] = [
        "050000": "美食", "100000": "住宿", "110000": "景点",
        "060000": "购物", "080000": "休闲娱乐",
    ]

    /// 把任意兴趣 tag 收敛到规范类别名（历史古迹/自然风光… → 景点）。
    public static func canonicalCategory(for tag: String) -> String {
        canonicalByCode[code(for: tag)] ?? "景点"
    }

    /// 规范类别 → 关键词搜索词。住宿用「酒店」更准；其余用类别名本身。
    /// 关键词查询比类目码查询能稳定捞到高点评地标（types 默认序把冷门点排前）。
    static let searchTermByCategory: [String: String] = [
        "美食": "美食", "景点": "景点", "住宿": "酒店",
        "购物": "购物", "休闲娱乐": "休闲娱乐",
    ]

    public static func searchTerm(for tag: String) -> String {
        if let term = searchTermByCategory[tag] { return term }            // 规范类别（美食/景点/住宿…）
        if byTag[tag] != nil { return searchTermByCategory[canonicalCategory(for: tag)] ?? tag }  // 已知兴趣 tag
        return tag   // 菜系/住宿类型等自由词 → 原样作关键词（如「海鲜」「民宿」）
    }

    /// 召回类别集：吃住玩三支柱（美食/住宿/景点）必含，并入用户兴趣 tag 的规范类别，按码去重。
    public static func recallCategories(forTags tags: [String]) -> [String] {
        var set: Set<String> = ["美食", "住宿", "景点"]
        for tag in tags { set.insert(canonicalCategory(for: tag)) }
        return set.sorted()
    }

    /// 含口味/菜系与住宿类型的召回类别集：
    /// 有菜系偏好则用菜系词替代通用「美食」；有住宿类型则用类型词替代通用「住宿」。
    public static func recallCategories(for prefs: TripPrefs) -> [String] {
        var set = Set(recallCategories(forTags: prefs.tags))
        if !prefs.cuisines.isEmpty { set.remove("美食"); set.formUnion(prefs.cuisines) }
        if !prefs.lodgingType.isEmpty { set.remove("住宿"); set.insert(prefs.lodgingType) }
        return set.sorted()
    }

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

// MARK: - 请求节流器（QPS 限速，PDR T8.2）

/// 串行预约下一可发时刻：在 await 前同步占位，即使 actor 重入也能稳定限速。
actor RateLimiter {
    private let minIntervalNanos: UInt64
    private var nextAllowedNanos: UInt64 = 0

    init(minInterval: TimeInterval) {
        minIntervalNanos = UInt64((minInterval * 1_000_000_000).rounded())
    }

    func acquire() async {
        guard minIntervalNanos > 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let scheduled = max(now, nextAllowedNanos)
        nextAllowedNanos = scheduled + minIntervalNanos      // 同步占位，先于 await
        let delay = scheduled - now
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
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

    /// 单类目最多翻几页（page_size=25）。3 页 → 候选池 ~75，招牌景点更易进池。
    static let pageSize = 25

    private let base = URL(string: "https://restapi.amap.com")!
    private let session: URLSession
    private let keyProvider: () -> String?
    private let onCall: (() -> Void)?
    private let pagesPerCategory: Int
    private let limiter: RateLimiter

    /// `minRequestInterval`：相邻请求最小间隔，节流到个人 key 的 QPS 以下（默认 0.35s ≈ <3/s），
    /// 避免一次生成连发十几个请求触发高德限速（10004/10019）。测试可传 0 关闭。
    public init(session: URLSession = .shared,
                keyProvider: @escaping () -> String? = { KeychainStore.get(KeychainStore.Account.amap) },
                pagesPerCategory: Int = 3,
                minRequestInterval: TimeInterval = 0.35,
                onCall: (() -> Void)? = nil) {
        self.session = session
        self.keyProvider = keyProvider
        self.pagesPerCategory = max(1, pagesPerCategory)
        self.limiter = RateLimiter(minInterval: max(0, minRequestInterval))
        self.onCall = onCall
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

    /// 按兴趣 tag 召回候选（去重）。改用「关键词搜索」而非类目码：
    /// types 查询默认序把冷门点排前、招牌景点常漏召；keywords 查询按热度/相关性返回，
    /// 能稳定捞到高点评地标（PDR §12.1 修订）。每词翻 `pagesPerCategory` 页扩大候选池，
    /// 某页不足一页即停。show_fields=business 拿评分/营业。
    public func searchPOI(adcode: String, tags: [String]) async throws -> [POICandidate] {
        let terms = tags.isEmpty ? ["景点"] : Set(tags.map(AmapCategory.searchTerm)).sorted()
        var seen = Set<String>()
        var out: [POICandidate] = []
        for term in terms {
            for page in 1...pagesPerCategory {
                let json = try await get("/v5/place/text", [
                    "keywords": term, "region": adcode, "city_limit": "true",
                    "show_fields": "business", "page_size": "\(Self.pageSize)", "page_num": "\(page)",
                ])
                let pois = json["pois"] as? [[String: Any]] ?? []
                for poi in pois {
                    guard let candidate = Self.parsePOI(poi), seen.insert(candidate.id).inserted else { continue }
                    out.append(candidate)
                }
                if pois.count < Self.pageSize { break }   // 最后一页，停
            }
        }
        return out
    }

    /// 按关键词召回（freeText 指定的具体地点，如「鼓浪屿」）。不限类目，单页即可。
    public func searchPOI(keywords: String, adcode: String) async throws -> [POICandidate] {
        let json = try await get("/v5/place/text", [
            "keywords": keywords, "region": adcode, "city_limit": "true",
            "show_fields": "business", "page_size": "\(Self.pageSize)",
        ])
        var seen = Set<String>()
        var out: [POICandidate] = []
        for poi in (json["pois"] as? [[String: Any]] ?? []) {
            guard let candidate = Self.parsePOI(poi), seen.insert(candidate.id).inserted else { continue }
            out.append(candidate)
        }
        return out
    }

    /// 相邻两点路径规划。mode 决定端点：步行/驾车/公交。
    /// 公交需 city（city1/city2 adcode）；缺省时退化为驾车，保证有交通段。
    public func route(from: POICandidate, to: POICandidate,
                      mode: TransitMode, city: String) async throws -> (minutes: Int, meters: Int, cost: Int?) {
        let origin = Self.lngLat(from), destination = Self.lngLat(to)
        switch mode {
        case .walk:
            return try await pathRoute("/v5/direction/walking", origin, destination)
        case .drive, .taxi:
            return try await pathRoute("/v5/direction/driving", origin, destination)
        case .metro, .bus, .train:
            guard !city.isEmpty else {
                return try await pathRoute("/v5/direction/driving", origin, destination)  // 无 city 退化驾车
            }
            return try await transitRoute(origin, destination, city: city)
        }
    }

    // MARK: - 请求与解析

    private func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        guard let key = keyProvider(), !key.isEmpty else { throw AmapError.missingKey }
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = (query.merging(["key": key, "output": "json"]) { a, _ in a })
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        await limiter.acquire()   // QPS 节流：相邻请求间隔不小于 minRequestInterval
        let (data, _) = try await session.data(from: comps.url!)
        onCall?()   // 计一次高德调用（PDR T7.2）
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
        let json = try await get(path, ["origin": origin, "destination": destination, "show_fields": "cost"])
        guard let route = json["route"] as? [String: Any],
              let p = (route["paths"] as? [[String: Any]])?.first else { throw AmapError.emptyResult }
        let meters = Self.int(p["distance"]) ?? 0
        let minutes = (Self.duration(in: p) ?? 0) / 60
        let cost = Self.int((p["cost"] as? [String: Any])?["tolls"])
        return (minutes, meters, cost.flatMap { $0 > 0 ? $0 : nil })
    }

    private func transitRoute(_ origin: String, _ destination: String, city: String) async throws
        -> (minutes: Int, meters: Int, cost: Int?) {
        let json = try await get("/v5/direction/transit/integrated", [
            "origin": origin, "destination": destination, "city1": city, "city2": city,
            "show_fields": "cost",   // v5：不带则不返回 cost.duration / transit_fee
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
