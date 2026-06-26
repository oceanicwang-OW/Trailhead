//  ItineraryDayBuilder.swift
//  Shared one-day itinerary construction used by full-trip generation and T6.3 day regeneration.

import Foundation

public enum ItineraryDayBuilder {
    public static func planStops(prefs: TripPrefs, candidates: [POICandidate],
                                 days: Int, llm: LLMProvider) async throws -> [[PlannedStop]] {
        let plan = try await planWithRetry(prefs: prefs, candidates: candidates, days: days, llm: llm)
        return FactChecker.reconcile(plan, candidates: candidates)
    }

    public static func buildItems(from stops: [PlannedStop], source: POIDataSource, city: String = "") async -> [PlanItem] {
        var items: [PlanItem] = []
        var order = 0
        var previous: POICandidate?
        for stop in stops {
            if let previous {
                let mode = mode(from: previous, to: stop.candidate, city: city)
                if let segment = try? await source.route(from: previous, to: stop.candidate, mode: mode, city: city) {
                    let transit = PlanItem(order: order, kind: .transit)
                    transit.transitMode = mode
                    transit.transitDesc = mode.display
                    transit.transitMinutes = segment.minutes
                    transit.transitMeters = segment.meters
                    transit.transitCost = segment.cost
                    items.append(transit)
                    order += 1
                }
            }

            let poi = PlanItem(order: order, kind: stop.candidate.kind)
            poi.poiId = stop.candidate.id
            poi.name = stop.candidate.name
            poi.subtype = stop.candidate.subtype
            poi.lat = stop.candidate.lat
            poi.lng = stop.candidate.lng
            poi.plannedTime = stop.time
            poi.stayLabel = stop.stayMin.map(stayLabel)
            poi.note = stop.note
            items.append(poi)
            order += 1
            previous = stop.candidate
        }
        return items
    }

    private static func planWithRetry(prefs: TripPrefs, candidates: [POICandidate],
                                      days: Int, llm: LLMProvider) async throws -> ItineraryPlan {
        let first = try await llm.planItinerary(prefs: prefs, candidates: candidates, days: days)
        if let plan = try? ItineraryParser.parse(first) { return plan }
        let retry = try await llm.planItinerary(prefs: prefs, candidates: candidates, days: days)
        return try ItineraryParser.parse(retry)
    }

    static func stayLabel(_ minutes: Int) -> String {
        minutes >= 60 ? "约 \(String(format: "%g", (Double(minutes) / 60 * 10).rounded() / 10)) 小时" : "\(minutes) 分钟"
    }

    /// 短途步行；远途有 city 走公交、无 city 退化驾车（与 AmapClient.route 一致，标签不串）。
    static func mode(from: POICandidate, to: POICandidate, city: String) -> TransitMode {
        guard haversineMeters(from, to) > 1500 else { return .walk }
        return city.isEmpty ? .drive : .metro
    }

    static func haversineMeters(_ a: POICandidate, _ b: POICandidate) -> Double {
        let radius = 6_371_000.0
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLng = (b.lng - a.lng) * .pi / 180
        let lat1 = a.lat * .pi / 180
        let lat2 = b.lat * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * radius * asin(min(1, sqrt(h)))
    }
}
