//  NextStopRecommender.swift
//  基于实际时间/位置的通用下一站推荐。硬可行性先于评分，且始终提供结束当天选项。

import Foundation

public enum NextStopKind: String, Codable, Sendable {
    case continueExploring
    case easyFinish
}

public struct NextStopOption: Equatable, Sendable {
    public let candidate: POICandidate
    public let kind: NextStopKind
    public let travelMinutes: Int
    public let suggestedMinutes: Int
    public let score: Double
    public let reason: String
}

public struct EndDayOption: Equatable, Sendable {
    public let travelMinutes: Int?
    public let reason: String
}

public struct NextStopSuggestions: Equatable, Sendable {
    public let continueExploring: NextStopOption?
    public let easyFinish: NextStopOption?
    public let endDay: EndDayOption
}

public struct NextStopContext: Sendable {
    public let nowMinutes: Int
    public let current: POICandidate
    public let completed: [POICandidate]
    public let candidates: [POICandidate]
    public let exitAnchor: POICandidate?
    public let activeParentScopeID: String?
    public let prefs: TripPrefs
    public let weekday: Int?
    public let dayEnd: Int
    public let fatigueMinutes: Int
    public let travelTimes: RouteTimeMatrix
    public let estimatedRouteKeys: Set<RouteTimeKey>

    public init(nowMinutes: Int, current: POICandidate,
                completed: [POICandidate] = [], candidates: [POICandidate],
                exitAnchor: POICandidate? = nil, activeParentScopeID: String? = nil,
                prefs: TripPrefs, weekday: Int? = nil, dayEnd: Int = 20 * 60,
                fatigueMinutes: Int = 0, travelTimes: RouteTimeMatrix = [:],
                estimatedRouteKeys: Set<RouteTimeKey> = []) {
        self.nowMinutes = nowMinutes; self.current = current; self.completed = completed
        self.candidates = candidates; self.exitAnchor = exitAnchor
        self.activeParentScopeID = activeParentScopeID; self.prefs = prefs
        self.weekday = weekday; self.dayEnd = dayEnd; self.fatigueMinutes = fatigueMinutes
        self.travelTimes = travelTimes; self.estimatedRouteKeys = estimatedRouteKeys
    }
}

public enum NextStopRecommender {
    public static func recommend(_ context: NextStopContext) -> NextStopSuggestions {
        let completedIDs = Set(context.completed.map(\.id) + [context.current.id])
        let completedSubtypes = Set(context.completed.map(\.subtype).filter { !$0.isEmpty })
        let policy = DayComfortPolicy.policy(for: context.prefs.pace)
        let exitTravel = context.exitAnchor.map { travel(context.current, $0, context) }
        let end = EndDayOption(travelMinutes: exitTravel,
                               reason: exitTravel.map { "现在结束行程，约 \($0) 分钟可返回当天结束点。" }
                                   ?? "现在结束行程，保留充足休息时间。")

        let options = context.candidates
            .filter { !completedIDs.contains($0.id) }
            .compactMap { option(for: $0, context: context, policy: policy,
                                 completedSubtypes: completedSubtypes) }
            .sorted { a, b in
                if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
                if a.travelMinutes != b.travelMinutes { return a.travelMinutes < b.travelMinutes }
                if a.suggestedMinutes != b.suggestedMinutes { return a.suggestedMinutes < b.suggestedMinutes }
                return a.candidate.id < b.candidate.id
            }

        return NextStopSuggestions(
            continueExploring: options.first(where: { $0.kind == .continueExploring }),
            easyFinish: options.first(where: { $0.kind == .easyFinish }),
            endDay: end
        )
    }

    private static func option(for candidate: POICandidate, context: NextStopContext,
                               policy: DayComfortPolicy,
                               completedSubtypes: Set<String>) -> NextStopOption? {
        let profile = StayDuration.profile(for: candidate)
        if let parent = context.activeParentScopeID,
           candidate.kind == .sight,
           candidate.visitMetadata.providerParentID != parent {
            return nil
        }

        let toKey = RouteTimeKey(fromID: context.current.id, toID: candidate.id)
        let toMinutes = travel(context.current, candidate, context)
        let isEstimated = context.estimatedRouteKeys.contains(toKey) || context.travelTimes[toKey] == nil
        let exitMinutes = context.exitAnchor.map { travel(candidate, $0, context) } ?? 0
        let safety = 45 + (isEstimated ? 15 : 0)
        let arrival = context.nowMinutes + toMinutes + profile.accessBufferMin
        let minimumFinish = arrival + profile.duration.minimum + profile.exitBufferMin
        guard minimumFinish + exitMinutes + safety <= context.dayEnd else { return nil }
        guard canFinish(candidate, arrival: arrival, stay: profile.duration.minimum,
                        exitBuffer: profile.exitBufferMin, weekday: context.weekday) else { return nil }
        if profile.duration.comfortable >= 180, arrival > policy.latestLargeAttractionStart { return nil }

        let easy = candidate.kind == .food || profile.duration.comfortable <= 90
            || profile.scope == .point || profile.scope == .district
        let kind: NextStopKind = easy ? .easyFinish : .continueExploring
        let available = context.dayEnd - arrival - exitMinutes - safety - profile.exitBufferMin
        let suggested = min(profile.duration.comfortable, max(profile.duration.minimum, available))

        let interest = CandidateCuration.matchesPreference(candidate, tags: context.prefs.tags) ? 1.0 : 0.5
        let quality = min(1, max(0, (candidate.rating ?? CandidateCuration.neutralRating) / 5))
        let routeFit = max(0, 1 - Double(toMinutes) / 60)
        let timeFit = max(0, 1 - abs(Double(available - profile.duration.comfortable))
            / Double(max(60, profile.duration.extended)))
        let diversity = completedSubtypes.contains(candidate.subtype) && !candidate.subtype.isEmpty ? 0.25 : 1
        let openingSafety = min(1, Double(max(0, context.dayEnd - minimumFinish - exitMinutes)) / 120)
        var score = 0.30 * interest + 0.20 * quality + 0.20 * routeFit
            + 0.15 * timeFit + 0.10 * diversity + 0.05 * openingSafety
        if toMinutes > policy.maxPreferredTransferMin {
            score -= min(0.25, Double(toMinutes - policy.maxPreferredTransferMin) / 60 * 0.25)
        }
        if context.fatigueMinutes > policy.continuousActivityLimitMin, !easy { score -= 0.25 }
        if isEstimated && context.dayEnd - minimumFinish - exitMinutes < 60 { score -= 0.15 }

        let reason = "从当前位置约 \(toMinutes) 分钟，建议游玩 \(profile.duration.minimum)～\(suggested) 分钟，已保留返程和安全余量。"
        return NextStopOption(candidate: candidate, kind: kind, travelMinutes: toMinutes,
                              suggestedMinutes: suggested, score: score, reason: reason)
    }

    private static func canFinish(_ candidate: POICandidate, arrival: Int, stay: Int,
                                  exitBuffer: Int, weekday: Int?) -> Bool {
        guard let windows = OpenHoursParser.schedule(candidate.openHours).windows(on: weekday) else { return true }
        return windows.contains { max(arrival, $0.open) + stay + exitBuffer <= $0.close }
    }

    private static func travel(_ from: POICandidate, _ to: POICandidate,
                               _ context: NextStopContext) -> Int {
        context.travelTimes[RouteTimeKey(fromID: from.id, toID: to.id)]
            ?? TravelEstimator.minutes(from: from, to: to, city: "")
    }
}
