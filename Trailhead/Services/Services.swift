//  Services.swift
//  Architecture seams for PDR phases 2–3. KeychainStore is real; the network
//  clients and engine are protocol + stub so the UI compiles and runs on seed
//  data today, and the real implementations drop in without touching the views.

import Foundation
#if canImport(Security)
import Security
#endif

// MARK: - KeychainStore (PDR T1.3, real)

enum KeychainStore {
    private static let service = "app.trailhead.keys"

    static func set(_ value: String, for account: String) {
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

    static func get(_ account: String) -> String? {
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

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum Account { static let amap = "amap_web_key"; static let llm = "llm_api_key" }
}

// MARK: - POI / route data source (PDR T2)

struct POICandidate: Identifiable, Hashable {
    let id: String           // amap poi id
    var name: String
    var kind: ItemKind
    var subtype: String
    var lat: Double
    var lng: Double
    var rating: Double?
    var openHours: String?
    var avgPrice: Int?
}

protocol POIDataSource {
    func geocodeCity(_ name: String) async throws -> (adcode: String, center: (Double, Double))
    func searchPOI(adcode: String, tags: [String]) async throws -> [POICandidate]
    func route(from: POICandidate, to: POICandidate, mode: TransitMode) async throws -> (minutes: Int, meters: Int, cost: Int?)
}

/// Stub used until AmapClient lands (PDR T2.1–T2.5).
struct StubPOISource: POIDataSource {
    func geocodeCity(_ name: String) async throws -> (adcode: String, center: (Double, Double)) {
        ("STUB", (34.9956, 135.7741))
    }
    func searchPOI(adcode: String, tags: [String]) async throws -> [POICandidate] { [] }
    func route(from: POICandidate, to: POICandidate, mode: TransitMode) async throws -> (minutes: Int, meters: Int, cost: Int?) {
        (15, 1200, nil)
    }
}

// MARK: - LLM provider (PDR T3.1, swappable: DeepSeek / 通义 / Kimi / Claude)

protocol LLMProvider {
    /// Returns a JSON itinerary that references only the given candidate poi ids.
    func planItinerary(prefs: TripPrefs, candidates: [POICandidate], days: Int) async throws -> Data
}

struct StubLLMProvider: LLMProvider {
    func planItinerary(prefs: TripPrefs, candidates: [POICandidate], days: Int) async throws -> Data {
        Data("{\"days\":[]}".utf8)
    }
}

// MARK: - Itinerary engine (PDR T3.6 skeleton)

@MainActor
final class ItineraryEngine: ObservableObject {
    enum Stage: String { case analyzing, routing, transit, dining, budgeting, done }
    @Published var stage: Stage = .analyzing
    @Published var progress: Double = 0

    private let poi: POIDataSource
    private let llm: LLMProvider
    init(poi: POIDataSource = StubPOISource(), llm: LLMProvider = StubLLMProvider()) {
        self.poi = poi; self.llm = llm
    }

    /// Pipeline outline (PDR §3): geocode → recall POIs → LLM plan (poi_id-locked)
    /// → route fill → FactChecker → persist. Implemented in phase 3.
    func generate(prefs: TripPrefs, destination: String) async throws -> Trip {
        // TODO(PDR T3.2–T3.6): wire the real pipeline.
        throw EngineError.notImplemented
    }
    enum EngineError: Error { case notImplemented }
}
