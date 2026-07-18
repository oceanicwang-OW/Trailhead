//  GlobalItineraryOptimizer.swift
//  分天后的确定性 Beam Search：在“跨天移动/两天交换”邻域中统一评估交通、营业窗、
//  酒店往返、每日容量与 POI 价值。以现有 k-means 结果为初始解，不引入随机源。

import Foundation

public enum GlobalItineraryOptimizer {
    public static func optimize(clusters: [[POICandidate]], prefs: TripPrefs,
                                weekdays: [Int?], city: String,
                                baseAnchor: POICandidate? = nil,
                                maxSightsPerDay: Int,
                                dailyAnchorIDs: Set<String> = [],
                                beamWidth: Int = 8, depth: Int = 4) -> [[POICandidate]] {
        guard clusters.count > 1, clusters.flatMap({ $0 }).count > 2 else { return clusters }

        let scores = Dictionary(clusters.flatMap { $0 }.map {
            ($0.id, CandidateCuration.score($0, tags: prefs.tags, cuisines: prefs.cuisines,
                                            budgetPerDay: prefs.budgetPerDay))
        }, uniquingKeysWith: { a, _ in a })
        var beam = [clusters]
        var best = clusters
        var bestScore = objective(clusters, prefs: prefs, weekdays: weekdays, city: city,
                                  baseAnchor: baseAnchor, scores: scores)

        for _ in 0..<max(1, depth) {
            var unique: [String: [[POICandidate]]] = [:]
            for state in beam {
                for neighbor in neighbors(of: state, maxPerDay: maxSightsPerDay,
                                          dailyAnchorIDs: dailyAnchorIDs) {
                    unique[signature(neighbor)] = neighbor
                }
            }
            guard !unique.isEmpty else { break }
            let ranked = unique.values.sorted {
                let left = objective($0, prefs: prefs, weekdays: weekdays, city: city,
                                     baseAnchor: baseAnchor, scores: scores)
                let right = objective($1, prefs: prefs, weekdays: weekdays, city: city,
                                      baseAnchor: baseAnchor, scores: scores)
                return left == right ? signature($0) < signature($1) : left > right
            }
            beam = Array(ranked.prefix(max(1, beamWidth)))
            if let candidate = beam.first {
                let candidateScore = objective(candidate, prefs: prefs, weekdays: weekdays, city: city,
                                               baseAnchor: baseAnchor, scores: scores)
                if candidateScore > bestScore + 1e-9 {
                    best = candidate
                    bestScore = candidateScore
                }
            }
        }
        return best
    }

    private static func neighbors(of state: [[POICandidate]], maxPerDay: Int,
                                  dailyAnchorIDs: Set<String>) -> [[[POICandidate]]] {
        var result: [[[POICandidate]]] = []

        for source in state.indices where state[source].count > 1 {
            for itemIndex in state[source].indices {
                for target in state.indices where target != source && state[target].count < maxPerDay {
                    var next = state
                    let item = next[source].remove(at: itemIndex)
                    next[target].append(item)
                    next[target].sort { $0.id < $1.id }
                    if anchorsRemainDistributed(next, anchorIDs: dailyAnchorIDs) { result.append(next) }
                }
            }
        }

        for left in state.indices {
            for right in state.indices where right > left {
                for leftIndex in state[left].indices {
                    for rightIndex in state[right].indices {
                        var next = state
                        let temporary = next[left][leftIndex]
                        next[left][leftIndex] = next[right][rightIndex]
                        next[right][rightIndex] = temporary
                        next[left].sort { $0.id < $1.id }
                        next[right].sort { $0.id < $1.id }
                        if anchorsRemainDistributed(next, anchorIDs: dailyAnchorIDs) { result.append(next) }
                    }
                }
            }
        }
        return result
    }

    /// 核心景点数不超过天数时，每天最多一个核心点；由此保证优化交通时不会把两个
    /// 城市地标合并到同一天、让另一天只剩冷门补充点。
    private static func anchorsRemainDistributed(_ state: [[POICandidate]],
                                                 anchorIDs: Set<String>) -> Bool {
        guard !anchorIDs.isEmpty else { return true }
        return state.allSatisfy { day in
            day.lazy.filter { anchorIDs.contains($0.id) }.prefix(2).count <= 1
        }
    }

    private static func objective(_ clusters: [[POICandidate]], prefs: TripPrefs,
                                  weekdays: [Int?], city: String,
                                  baseAnchor: POICandidate?, scores: [String: Double]) -> Double {
        var total = 0.0
        let baseCoordinate = baseAnchor.map { (lat: $0.lat, lng: $0.lng) }
        for (dayIndex, cluster) in clusters.enumerated() {
            let routed = DayRouter.route(cluster, entryAnchor: baseCoordinate,
                                         exitAnchor: baseCoordinate)
            let simulation = ScheduleSimulator.simulate(
                stops: routed, pace: prefs.pace, city: city,
                weekday: weekdays.indices.contains(dayIndex) ? weekdays[dayIndex] : nil,
                dayStart: ItineraryDayBuilder.dayStart, dayEnd: ItineraryDayBuilder.dayEnd,
                scores: scores, entryAnchor: baseAnchor, exitAnchor: baseAnchor,
                comfortPolicy: DayComfortPolicy.policy(for: prefs.pace)
            )
            total += simulation.scheduled.reduce(0) {
                $0 + 100 * ScheduleSimulator.score($1.candidate, scores)
            }
            total -= simulation.spilled.reduce(0) {
                $0 + 10_000 + 1_000 * ScheduleSimulator.score($1.candidate, scores)
            }
            total -= approximateTravelMinutes(routed, city: city, baseAnchor: baseAnchor)
            total -= Double(cluster.count * cluster.count) * 2
        }
        return total
    }

    private static func approximateTravelMinutes(_ route: [POICandidate], city: String,
                                                 baseAnchor: POICandidate?) -> Double {
        guard !route.isEmpty else { return 0 }
        var total = 0
        var previous = baseAnchor
        for stop in route {
            if let previous { total += TravelEstimator.minutes(from: previous, to: stop, city: city) }
            previous = stop
        }
        if let last = route.last, let baseAnchor {
            total += TravelEstimator.minutes(from: last, to: baseAnchor, city: city)
        }
        return Double(total)
    }

    private static func signature(_ state: [[POICandidate]]) -> String {
        state.map { $0.map(\.id).sorted().joined(separator: ",") }.joined(separator: "|")
    }
}
