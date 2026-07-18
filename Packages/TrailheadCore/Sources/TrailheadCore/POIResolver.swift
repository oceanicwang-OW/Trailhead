//  POIResolver.swift
//  用户点名地点的高德落地、匹配和消歧（PDR CP-2.*）。

import Foundation

public enum POIResolution: Sendable {
    case resolved(POICandidate)
    case ambiguous([POICandidate])
    case notFound
}

public protocol POIResolving {
    func resolve(mention: String, adcode: String,
                 anchor: (lat: Double, lng: Double)?) async throws -> POIResolution
}

public struct POIResolver: POIResolving {
    private let source: POIDataSource
    private let autoResolveThreshold: Double
    private let minimumMargin: Double

    public init(source: POIDataSource, autoResolveThreshold: Double = 0.82, minimumMargin: Double = 0.12) {
        self.source = source
        self.autoResolveThreshold = autoResolveThreshold
        self.minimumMargin = minimumMargin
    }

    public func resolve(mention: String, adcode: String,
                        anchor: (lat: Double, lng: Double)? = nil) async throws -> POIResolution {
        let candidates = try await source.searchPOI(keywords: mention, adcode: adcode)
        guard !candidates.isEmpty else { return .notFound }
        let scored: [(candidate: POICandidate, value: Double)] = candidates.map { candidate in
            (candidate: candidate, value: score(candidate, mention: mention, anchor: anchor))
        }
        let ranked = scored.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.candidate.id < rhs.candidate.id : lhs.value > rhs.value
        }
        let best = ranked[0]
        let margin = best.value - (ranked.dropFirst().first?.value ?? 0)
        if best.value >= autoResolveThreshold, margin >= minimumMargin {
            return .resolved(best.candidate)
        }
        return .ambiguous(Array(ranked.prefix(4).map { $0.candidate }))
    }

    private func score(_ candidate: POICandidate, mention: String,
                       anchor: (lat: Double, lng: Double)?) -> Double {
        let name = Self.normalized(candidate.name)
        let query = Self.normalized(mention)
        let nameScore: Double
        if name == query {
            nameScore = 1
        } else if name.contains(query) || query.contains(name) {
            nameScore = 0.86
        } else {
            let overlap = Set(name).intersection(Set(query)).count
            let union = max(1, Set(name).union(Set(query)).count)
            nameScore = Double(overlap) / Double(union)
        }
        let rating = min(1, max(0, (candidate.rating ?? 4) / 5))
        let distanceScore: Double
        if let anchor {
            let temporary = POICandidate(id: "__anchor__", name: "", kind: .sight, subtype: "",
                                         lat: anchor.lat, lng: anchor.lng)
            let meters = ItineraryDayBuilder.haversineMeters(temporary, candidate)
            distanceScore = max(0, 1 - meters / 50_000)
        } else {
            distanceScore = 0.5
        }
        // adcode 已经在搜索请求中限定，因此 cityConsistency 为 1。
        return 0.7 * nameScore + 0.15 + 0.1 * rating + 0.05 * distanceScore
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}
