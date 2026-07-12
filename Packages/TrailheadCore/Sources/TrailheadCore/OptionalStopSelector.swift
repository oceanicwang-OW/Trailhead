//  OptionalStopSelector.swift
//  将未进入主行程的优质景点分配给距离最近的一天，不预占正式时间。

import Foundation

public enum OptionalStopSelector {
    public static func assign(pool: [POICandidate], planned: [[PlannedStop]],
                              prefs: TripPrefs, perDayLimit: Int = 6) -> [[OptionalVisitOption]] {
        guard !planned.isEmpty else { return [] }
        let used = Set(planned.flatMap { $0.map(\.candidate.id) })
        var buckets = Array(repeating: [(option: OptionalVisitOption, score: Double)](), count: planned.count)

        for candidate in pool where candidate.kind == .sight && !used.contains(candidate.id) {
            let nearest = planned.indices.compactMap { day -> (Int, Double)? in
                let distance = planned[day].map {
                    NearbyFood.meters(candidate.lat, candidate.lng, $0.candidate.lat, $0.candidate.lng)
                }.min()
                return distance.map { (day, $0) }
            }.min { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1 }
            guard let (day, distance) = nearest else { continue }
            let profile = StayDuration.profile(for: candidate)
            let meters = Int(distance.rounded())
            let minutes = NearbyFood.estimatedMinutes(for: meters)
            let quality = candidate.rating ?? CandidateCuration.neutralRating
            let interest = CandidateCuration.matchesPreference(candidate, tags: prefs.tags) ? 1.0 : 0
            let relaxedFit = max(0, 1 - Double(profile.duration.comfortable) / 480)
            let proximity = max(0, 1 - distance / 10_000)
            let score = quality + interest + 0.5 * relaxedFit + 0.5 * proximity
            let option = OptionalVisitOption(
                id: candidate.id, name: candidate.name, subtype: candidate.subtype,
                lat: candidate.lat, lng: candidate.lng, rating: candidate.rating,
                tags: candidate.tags, photos: candidate.photos,
                minimumMinutes: profile.duration.minimum,
                comfortableMinutes: profile.duration.comfortable,
                extendedMinutes: profile.duration.extended,
                distanceMeters: meters, estimatedMinutes: minutes
            )
            buckets[day].append((option, score))
        }

        return buckets.map { bucket in
            bucket.sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.option.id < rhs.option.id : lhs.score > rhs.score
            }.prefix(max(0, perDayLimit)).map(\.option)
        }
    }
}
