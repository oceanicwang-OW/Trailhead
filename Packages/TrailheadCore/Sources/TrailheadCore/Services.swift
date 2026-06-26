//  Services.swift
//  架构缝（PDR 阶段 2–3）。KeychainStore 真实；网络 client 与引擎为协议 + 桩，
//  真实实现落地后替换注入，视图层零改动。

import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(Security)
import Security
#endif

// MARK: - KeychainStore (PDR T1.3, real)

public enum KeychainStore {
    private static let service = "app.trailhead.keys"

    public static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query; add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public enum Account { public static let amap = "amap_web_key"; public static let llm = "llm_api_key" }
}

// MARK: - POI / route data source (PDR T2)

public struct POICandidate: Identifiable, Hashable, Sendable {
    public let id: String           // amap poi id
    public var name: String
    public var kind: ItemKind
    public var subtype: String
    public var lat: Double
    public var lng: Double
    public var rating: Double?
    public var openHours: String?
    public var avgPrice: Int?

    public init(id: String, name: String, kind: ItemKind, subtype: String,
                lat: Double, lng: Double, rating: Double? = nil,
                openHours: String? = nil, avgPrice: Int? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.subtype = subtype
        self.lat = lat
        self.lng = lng
        self.rating = rating
        self.openHours = openHours
        self.avgPrice = avgPrice
    }
}

public protocol POIDataSource {
    func geocodeCity(_ name: String) async throws -> (adcode: String, center: (Double, Double))
    func searchPOI(adcode: String, tags: [String]) async throws -> [POICandidate]
    func route(from: POICandidate, to: POICandidate, mode: TransitMode) async throws -> (minutes: Int, meters: Int, cost: Int?)
}

/// Stub used until AmapClient lands (PDR T2.1–T2.5).
public struct StubPOISource: POIDataSource {
    public init() {}
    public func geocodeCity(_ name: String) async throws -> (adcode: String, center: (Double, Double)) {
        ("STUB", (34.9956, 135.7741))
    }
    public func searchPOI(adcode: String, tags: [String]) async throws -> [POICandidate] { [] }
    public func route(from: POICandidate, to: POICandidate, mode: TransitMode) async throws -> (minutes: Int, meters: Int, cost: Int?) {
        (15, 1200, nil)
    }
}

// MARK: - LLM provider (PDR T3.1, swappable: DeepSeek / 通义 / Kimi / Claude)

public protocol LLMProvider {
    /// Returns a JSON itinerary that references only the given candidate poi ids.
    func planItinerary(prefs: TripPrefs, candidates: [POICandidate], days: Int) async throws -> Data
}

public struct StubLLMProvider: LLMProvider {
    public init() {}
    public func planItinerary(prefs: TripPrefs, candidates: [POICandidate], days: Int) async throws -> Data {
        Data("{\"days\":[]}".utf8)
    }
}
