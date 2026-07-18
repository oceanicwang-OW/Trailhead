//  TOPTWReferenceSolver.swift
//  参考 Team Orienteering Problem with Time Windows 的确定性可行插入求解器。
//  与“先把全部点分簇、再处理溢出”不同，它只向多日路线插入能完整排下的高价值地点，
//  用作现有聚类 + Beam Search 的独立参考解，最后由同一质量函数择优。

import Foundation

enum TOPTWReferenceSolver {
    struct Context {
        let prefs: TripPrefs
        let weekdays: [Int?]
        let city: String
        let baseAnchor: POICandidate?
        let scores: [String: Double]
        let maxSightsPerDay: Int
        let dailyAnchorIDs: Set<String>
        let requiredPOIIDs: Set<String>
        let dailyWindows: [DailyConstraint]

        var dayCount: Int { max(1, weekdays.count) }
    }

    private struct Insertion {
        let dayIndex: Int
        let position: Int
        let route: [POICandidate]
        let gain: Double
    }

    /// 构造一组始终满足营业窗和每日时长的选择性路线。
    /// 必去点先插入；经典核心点尽量分散；其余点按“价值 - 新增交通 - 负载”逐次插入。
    static func solve(candidates: [POICandidate], context: Context) -> [[POICandidate]] {
        guard !candidates.isEmpty else { return Array(repeating: [], count: context.dayCount) }

        let lookup = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var routes = Array(repeating: [POICandidate](), count: context.dayCount)
        var selected = Set<String>()

        // 硬约束优先；同分时固定按 id，保证相同输入得到相同输出。
        let required = context.requiredPOIIDs.compactMap { lookup[$0] }.sorted {
            let left = score($0, context)
            let right = score($1, context)
            return left == right ? $0.id < $1.id : left > right
        }
        for candidate in required {
            guard let insertion = bestInsertion(of: candidate, into: routes, context: context,
                                                requireEmptyDay: false) else { continue }
            routes[insertion.dayIndex] = insertion.route
            selected.insert(candidate.id)
        }

        // 经典核心点是一日游的 seed。优先放入尚无核心点的天，避免地标挤在同一天。
        let anchors = candidates.filter {
            context.dailyAnchorIDs.contains($0.id) && !selected.contains($0.id)
        }.sorted {
            let left = score($0, context)
            let right = score($1, context)
            return left == right ? $0.id < $1.id : left > right
        }
        for candidate in anchors {
            guard let insertion = bestInsertion(of: candidate, into: routes, context: context,
                                                requireEmptyDay: true)
                    ?? bestInsertion(of: candidate, into: routes, context: context,
                                     requireEmptyDay: false) else { continue }
            routes[insertion.dayIndex] = insertion.route
            selected.insert(candidate.id)
        }

        // 无知名度元数据时也为每个空白日播一个高分种子，避免贪心把所有点堆到首日。
        let seedPool = candidates.filter { !selected.contains($0.id) }.sorted {
            let left = score($0, context)
            let right = score($1, context)
            return left == right ? $0.id < $1.id : left > right
        }
        for dayIndex in routes.indices where routes[dayIndex].isEmpty {
            guard let seed = seedPool.first(where: { !selected.contains($0.id) }),
                  let insertion = bestInsertion(of: seed, into: routes, context: context,
                                                requiredDay: dayIndex) else { continue }
            routes[insertion.dayIndex] = insertion.route
            selected.insert(seed.id)
        }

        // TOPTW 可行插入：每一轮在所有“地点 × 天 × 插入位置”中取边际收益最高者。
        while true {
            var best: (candidate: POICandidate, insertion: Insertion)?
            for candidate in candidates.sorted(by: { $0.id < $1.id }) where !selected.contains(candidate.id) {
                guard let insertion = bestInsertion(of: candidate, into: routes, context: context,
                                                    requireEmptyDay: false),
                      insertion.gain > 0 else { continue }
                if isBetter(candidate, insertion: insertion, than: best, context: context) {
                    best = (candidate, insertion)
                }
            }
            guard let best else { break }
            routes[best.insertion.dayIndex] = best.insertion.route
            selected.insert(best.candidate.id)
        }

        return routes
    }

    private static func bestInsertion(of candidate: POICandidate, into routes: [[POICandidate]],
                                      context: Context, requireEmptyDay: Bool = false,
                                      requiredDay: Int? = nil) -> Insertion? {
        var best: Insertion?
        for dayIndex in routes.indices {
            if let requiredDay, requiredDay != dayIndex { continue }
            if requireEmptyDay, !routes[dayIndex].isEmpty { continue }
            if routes[dayIndex].count >= context.maxSightsPerDay { continue }
            if context.dailyAnchorIDs.contains(candidate.id),
               routes[dayIndex].contains(where: { context.dailyAnchorIDs.contains($0.id) }) { continue }

            for position in 0...routes[dayIndex].count {
                var proposed = routes[dayIndex]
                proposed.insert(candidate, at: position)
                guard let feasibleRoute = feasibleRoute(proposed, dayIndex: dayIndex, context: context) else {
                    continue
                }
                let addedTravel = routeTravel(feasibleRoute, context: context)
                    - routeTravel(routes[dayIndex], context: context)
                // 分值是主目标；交通与单日堆叠是次目标。只惩罚新增交通，路线变短则完整奖励。
                let gain = 100 * score(candidate, context)
                    - 1.5 * Double(addedTravel)
                    - 8 * Double(routes[dayIndex].count * routes[dayIndex].count)
                let insertion = Insertion(dayIndex: dayIndex, position: position,
                                          route: feasibleRoute, gain: gain)
                if isBetter(insertion, than: best) { best = insertion }
            }
        }
        return best
    }

    /// ScheduleSimulator 可能为早闭馆点做一次邻位交换；把模拟后的实际顺序带回路线。
    private static func feasibleRoute(_ route: [POICandidate], dayIndex: Int,
                                      context: Context) -> [POICandidate]? {
        let window = context.dailyWindows.first { $0.dayIndex == dayIndex }
        let simulation = ScheduleSimulator.simulate(
            stops: route, pace: context.prefs.pace, city: context.city,
            weekday: context.weekdays.indices.contains(dayIndex) ? context.weekdays[dayIndex] : nil,
            dayStart: window?.startMinute ?? ItineraryDayBuilder.dayStart,
            dayEnd: window?.endMinute ?? ItineraryDayBuilder.dayEnd,
            scores: context.scores, entryAnchor: context.baseAnchor, exitAnchor: context.baseAnchor,
            comfortPolicy: DayComfortPolicy.policy(for: context.prefs.pace)
        )
        guard simulation.spilled.isEmpty, simulation.scheduled.count == route.count else { return nil }
        return simulation.scheduled.map(\.candidate)
    }

    private static func routeTravel(_ route: [POICandidate], context: Context) -> Int {
        guard !route.isEmpty else { return 0 }
        var minutes = 0
        var previous = context.baseAnchor
        for stop in route {
            if let previous {
                minutes += TravelEstimator.minutes(from: previous, to: stop, city: context.city)
            }
            previous = stop
        }
        if let last = route.last, let base = context.baseAnchor {
            minutes += TravelEstimator.minutes(from: last, to: base, city: context.city)
        }
        return minutes
    }

    private static func score(_ candidate: POICandidate, _ context: Context) -> Double {
        ScheduleSimulator.score(candidate, context.scores)
    }

    private static func isBetter(_ candidate: POICandidate, insertion: Insertion,
                                 than current: (candidate: POICandidate, insertion: Insertion)?,
                                 context: Context) -> Bool {
        guard let current else { return true }
        if abs(insertion.gain - current.insertion.gain) > 1e-9 {
            return insertion.gain > current.insertion.gain
        }
        let leftScore = score(candidate, context)
        let rightScore = score(current.candidate, context)
        if abs(leftScore - rightScore) > 1e-9 { return leftScore > rightScore }
        if candidate.id != current.candidate.id { return candidate.id < current.candidate.id }
        return isBetter(insertion, than: current.insertion)
    }

    private static func isBetter(_ candidate: Insertion, than current: Insertion?) -> Bool {
        guard let current else { return true }
        if abs(candidate.gain - current.gain) > 1e-9 { return candidate.gain > current.gain }
        if candidate.dayIndex != current.dayIndex { return candidate.dayIndex < current.dayIndex }
        if candidate.position != current.position { return candidate.position < current.position }
        return candidate.route.map(\.id).joined(separator: "|")
            < current.route.map(\.id).joined(separator: "|")
    }
}

enum ItinerarySolutionPortfolio {
    struct Quality: Equatable {
        let objective: Double
        let collectedScore: Double
        let scheduledCount: Int
        let travelMinutes: Int
        let emptyDays: Int
        let missingRequiredCount: Int
    }

    /// 在完全相同的排程与评分规则下比较现有解和 TOPTW 参考解。
    /// 固定到达时间需要专门的顺序约束，当前先保守沿用原算法，不让参考解破坏预约。
    static func choose(incumbent: [[POICandidate]], reference: [[POICandidate]],
                       context: TOPTWReferenceSolver.Context,
                       hasFixedVisits: Bool) -> [[POICandidate]] {
        guard !hasFixedVisits else { return incumbent }
        let incumbentQuality = quality(of: incumbent, context: context, routeBeforeSimulation: true)
        let referenceQuality = quality(of: reference, context: context, routeBeforeSimulation: false)
        guard referenceQuality.missingRequiredCount == 0 else { return incumbent }
        return referenceQuality.objective > incumbentQuality.objective + 1e-9 ? reference : incumbent
    }

    static func quality(of routes: [[POICandidate]], context: TOPTWReferenceSolver.Context,
                        routeBeforeSimulation: Bool) -> Quality {
        var collectedScore = 0.0
        var scheduledCount = 0
        var travelMinutes = 0
        var emptyDays = 0
        var scheduledIDs = Set<String>()
        var dayLoads: [Int] = []
        let baseCoordinate = context.baseAnchor.map { (lat: $0.lat, lng: $0.lng) }

        for dayIndex in 0..<context.dayCount {
            let raw = routes.indices.contains(dayIndex) ? routes[dayIndex] : []
            let route = routeBeforeSimulation
                ? DayRouter.route(raw, entryAnchor: baseCoordinate, exitAnchor: baseCoordinate)
                : raw
            let window = context.dailyWindows.first { $0.dayIndex == dayIndex }
            let simulation = ScheduleSimulator.simulate(
                stops: route, pace: context.prefs.pace, city: context.city,
                weekday: context.weekdays.indices.contains(dayIndex) ? context.weekdays[dayIndex] : nil,
                dayStart: window?.startMinute ?? ItineraryDayBuilder.dayStart,
                dayEnd: window?.endMinute ?? ItineraryDayBuilder.dayEnd,
                scores: context.scores, entryAnchor: context.baseAnchor, exitAnchor: context.baseAnchor,
                comfortPolicy: DayComfortPolicy.policy(for: context.prefs.pace)
            )
            let scheduled = simulation.scheduled.map(\.candidate)
            if scheduled.isEmpty { emptyDays += 1 }
            dayLoads.append(scheduled.count)
            scheduledCount += scheduled.count
            scheduledIDs.formUnion(scheduled.map(\.id))
            collectedScore += scheduled.reduce(0) {
                $0 + ScheduleSimulator.score($1, context.scores)
            }
            travelMinutes += routeTravel(scheduled, city: context.city, baseAnchor: context.baseAnchor)
        }

        let missingRequired = context.requiredPOIIDs.subtracting(scheduledIDs).count
        let loadSpread = (dayLoads.max() ?? 0) - (dayLoads.min() ?? 0)
        let objective = 100 * collectedScore
            - Double(travelMinutes)
            - 120 * Double(emptyDays)
            - 20 * Double(loadSpread * loadSpread)
            - 1_000_000 * Double(missingRequired)
        return Quality(objective: objective, collectedScore: collectedScore,
                       scheduledCount: scheduledCount, travelMinutes: travelMinutes,
                       emptyDays: emptyDays, missingRequiredCount: missingRequired)
    }

    private static func routeTravel(_ route: [POICandidate], city: String,
                                    baseAnchor: POICandidate?) -> Int {
        guard !route.isEmpty else { return 0 }
        var minutes = 0
        var previous = baseAnchor
        for stop in route {
            if let previous { minutes += TravelEstimator.minutes(from: previous, to: stop, city: city) }
            previous = stop
        }
        if let last = route.last, let baseAnchor {
            minutes += TravelEstimator.minutes(from: last, to: baseAnchor, city: city)
        }
        return minutes
    }
}
