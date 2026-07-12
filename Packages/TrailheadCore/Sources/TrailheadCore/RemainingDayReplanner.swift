//  RemainingDayReplanner.swift
//  固定已完成前缀，只重放尚未开始的当天后缀；不可行点降级为 optional。

import Foundation

public struct RemainingDayPlan: Equatable, Sendable {
    public let scheduled: [ScheduledStop]
    public let optional: [SpilledStop]
}

public enum RemainingDayReplanner {
    public static func replan(nowMinutes: Int, current: POICandidate,
                              remainingRequired: [POICandidate], prefs: TripPrefs,
                              city: String, weekday: Int? = nil, dayEnd: Int = 20 * 60,
                              exitAnchor: POICandidate? = nil,
                              travelTimes: RouteTimeMatrix = [:]) -> RemainingDayPlan {
        let simulation = ScheduleSimulator.simulate(
            stops: remainingRequired, pace: prefs.pace, city: city, weekday: weekday,
            dayStart: nowMinutes, dayEnd: dayEnd, scores: [:], travelTimes: travelTimes,
            entryAnchor: current, exitAnchor: exitAnchor,
            comfortPolicy: DayComfortPolicy.policy(for: prefs.pace)
        )
        return RemainingDayPlan(scheduled: simulation.scheduled, optional: simulation.spilled)
    }
}
