//  TripIntent.swift
//  对话式规划的结构化需求契约（PDR CP-0.1 / CP-4.1）。

import Foundation

public struct DestinationIntent: Codable, Hashable, Sendable {
    public var name: String
    public var adcode: String?

    public init(name: String = "", adcode: String? = nil) {
        self.name = name
        self.adcode = adcode
    }
}

public struct TravelParty: Codable, Hashable, Sendable {
    public var adults: Int
    public var children: Int
    public var seniors: Int

    public init(adults: Int = 1, children: Int = 0, seniors: Int = 0) {
        self.adults = max(0, adults)
        self.children = max(0, children)
        self.seniors = max(0, seniors)
    }
}

public enum IntentSource: String, Codable, CaseIterable, Sendable {
    case userExplicit
    case userConfirmed
    case modelInferred
    case systemDefault

    var rank: Int {
        switch self {
        case .systemDefault: 0
        case .modelInferred: 1
        case .userConfirmed: 2
        case .userExplicit: 3
        }
    }
}

public enum ConstraintPriority: String, Codable, Sendable {
    case hard
    case soft
}

public enum POIRequirement: String, Codable, CaseIterable, Sendable {
    case mustVisit
    case preferVisit
    case avoidVisit
}

public struct POIConstraint: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var mention: String
    public var resolvedPOIID: String?
    public var resolvedName: String?
    public var requirement: POIRequirement
    public var assignedDay: Int?
    public var fixedArrivalMinute: Int?
    public var minimumStayMinutes: Int?
    public var source: IntentSource

    public init(id: UUID = UUID(), mention: String, resolvedPOIID: String? = nil,
                resolvedName: String? = nil, requirement: POIRequirement,
                assignedDay: Int? = nil, fixedArrivalMinute: Int? = nil,
                minimumStayMinutes: Int? = nil, source: IntentSource = .userExplicit) {
        self.id = id
        self.mention = mention
        self.resolvedPOIID = resolvedPOIID
        self.resolvedName = resolvedName
        self.requirement = requirement
        self.assignedDay = assignedDay
        self.fixedArrivalMinute = fixedArrivalMinute
        self.minimumStayMinutes = minimumStayMinutes
        self.source = source
    }
}

public struct DailyConstraint: Codable, Hashable, Sendable, Identifiable {
    public var dayIndex: Int
    public var startMinute: Int
    public var endMinute: Int
    public var startAnchorPOIID: String?
    public var endAnchorPOIID: String?

    public var id: Int { dayIndex }

    public init(dayIndex: Int, startMinute: Int = 9 * 60, endMinute: Int = 20 * 60,
                startAnchorPOIID: String? = nil, endAnchorPOIID: String? = nil) {
        self.dayIndex = max(0, dayIndex)
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.startAnchorPOIID = startAnchorPOIID
        self.endAnchorPOIID = endAnchorPOIID
    }
}

public struct MobilityConstraint: Codable, Hashable, Sendable {
    public var maxWalkingMinutesPerSegment: Int?
    public var accessibilityRequired: Bool

    public init(maxWalkingMinutesPerSegment: Int? = nil, accessibilityRequired: Bool = false) {
        self.maxWalkingMinutesPerSegment = maxWalkingMinutesPerSegment
        self.accessibilityRequired = accessibilityRequired
    }
}

public struct TransportConstraint: Codable, Hashable, Sendable {
    public var allowedModes: Set<TransitMode>

    public init(allowedModes: Set<TransitMode> = Set(TransitMode.allCases)) {
        self.allowedModes = allowedModes
    }
}

public struct MealConstraint: Codable, Hashable, Sendable {
    public var includeInTimeline: Bool
    public var lunchWindow: ClosedRange<Int>
    public var dinnerWindow: ClosedRange<Int>
    public var dietaryNotes: String

    public init(includeInTimeline: Bool = true,
                lunchWindow: ClosedRange<Int> = 11 * 60 + 30...13 * 60 + 30,
                dinnerWindow: ClosedRange<Int> = 17 * 60 + 30...19 * 60 + 30,
                dietaryNotes: String = "") {
        self.includeInTimeline = includeInTimeline
        self.lunchWindow = lunchWindow
        self.dinnerWindow = dinnerWindow
        self.dietaryNotes = dietaryNotes
    }
}

public struct IntentFieldState: Codable, Hashable, Sendable {
    public var source: IntentSource
    public var confidence: Double
    public var isConfirmed: Bool

    public init(source: IntentSource, confidence: Double = 1, isConfirmed: Bool = true) {
        self.source = source
        self.confidence = min(1, max(0, confidence))
        self.isConfirmed = isConfirmed
    }
}

public struct TripIntent: Codable, Hashable, Sendable {
    public var destination: DestinationIntent
    public var startDate: Date
    public var days: Int
    public var party: TravelParty
    public var preferences: TripPrefs
    public var poiConstraints: [POIConstraint]
    public var dailyConstraints: [DailyConstraint]
    public var mobility: MobilityConstraint
    public var transport: TransportConstraint
    public var meals: MealConstraint
    public var rawNotes: String
    public var fieldStates: [IntentPath: IntentFieldState]
    public var revision: Int

    public init(destination: DestinationIntent = .init(), startDate: Date = .now, days: Int = 3,
                party: TravelParty = .init(), preferences: TripPrefs = .init(),
                poiConstraints: [POIConstraint] = [], dailyConstraints: [DailyConstraint] = [],
                mobility: MobilityConstraint = .init(), transport: TransportConstraint = .init(),
                meals: MealConstraint = .init(), rawNotes: String = "",
                fieldStates: [IntentPath: IntentFieldState] = [:], revision: Int = 0) {
        self.destination = destination
        self.startDate = startDate
        self.days = min(14, max(1, days))
        self.party = party
        self.preferences = preferences
        self.poiConstraints = poiConstraints
        self.dailyConstraints = dailyConstraints.isEmpty
            ? (0..<min(14, max(1, days))).map { DailyConstraint(dayIndex: $0) }
            : dailyConstraints
        self.mobility = mobility
        self.transport = transport
        self.meals = meals
        self.rawNotes = rawNotes
        self.fieldStates = fieldStates
        self.revision = revision
        normalizeDailyConstraints()
    }

    public var requiredPOIIDs: Set<String> {
        Set(poiConstraints.compactMap { $0.requirement == .mustVisit ? $0.resolvedPOIID : nil })
    }

    public var preferredPOIIDs: Set<String> {
        Set(poiConstraints.compactMap { $0.requirement == .preferVisit ? $0.resolvedPOIID : nil })
    }

    public var excludedPOIIDs: Set<String> {
        Set(poiConstraints.compactMap { $0.requirement == .avoidVisit ? $0.resolvedPOIID : nil })
    }

    public mutating func normalizeDailyConstraints() {
        let byDay = Dictionary(dailyConstraints.map { ($0.dayIndex, $0) }, uniquingKeysWith: { latest, _ in latest })
        dailyConstraints = (0..<days).map { byDay[$0] ?? DailyConstraint(dayIndex: $0) }
    }
}

public struct FixedVisit: Codable, Hashable, Sendable {
    public var poiID: String
    public var dayIndex: Int
    public var arrivalMinute: Int
    public var minimumStayMinutes: Int?
}

public struct DayAnchors: Codable, Hashable, Sendable {
    public var startPOIID: String?
    public var endPOIID: String?
}

public struct PlanningConstraints: Codable, Hashable, Sendable {
    public var requiredPOIIDs: Set<String>
    public var preferredPOIIDs: Set<String>
    public var excludedPOIIDs: Set<String>
    public var fixedVisits: [FixedVisit]
    public var dailyWindows: [DailyConstraint]
    public var dailyAnchors: [DayAnchors]
    public var allowedModes: Set<TransitMode>
    public var maxWalkingMinutesPerSegment: Int?
    public var accessibilityRequired: Bool

    public init(requiredPOIIDs: Set<String> = [], preferredPOIIDs: Set<String> = [],
                excludedPOIIDs: Set<String> = [], fixedVisits: [FixedVisit] = [],
                dailyWindows: [DailyConstraint] = [], dailyAnchors: [DayAnchors] = [],
                allowedModes: Set<TransitMode> = Set(TransitMode.allCases),
                maxWalkingMinutesPerSegment: Int? = nil, accessibilityRequired: Bool = false) {
        self.requiredPOIIDs = requiredPOIIDs
        self.preferredPOIIDs = preferredPOIIDs
        self.excludedPOIIDs = excludedPOIIDs
        self.fixedVisits = fixedVisits
        self.dailyWindows = dailyWindows
        self.dailyAnchors = dailyAnchors
        self.allowedModes = allowedModes
        self.maxWalkingMinutesPerSegment = maxWalkingMinutesPerSegment
        self.accessibilityRequired = accessibilityRequired
    }
}

public enum ConstraintCompiler {
    public static func compile(_ intent: TripIntent) throws -> PlanningConstraints {
        var required = intent.requiredPOIIDs
        let excluded = intent.excludedPOIIDs
        if let duplicate = required.intersection(excluded).sorted().first {
            throw PlanningConflict(code: .contradictoryRequirement,
                                   message: "同一地点不能同时标记为必去和不要去。",
                                   affectedPOIIDs: [duplicate])
        }
        if let unresolved = intent.poiConstraints.first(where: {
            $0.requirement == .mustVisit && $0.resolvedPOIID == nil
        }) {
            throw PlanningConflict(code: .unresolvedRequiredPOI,
                                   message: "必去地点“\(unresolved.mention)”尚未确认。")
        }
        guard intent.dailyConstraints.allSatisfy({ $0.startMinute < $0.endMinute }) else {
            throw PlanningConflict(code: .invalidDayWindow, message: "每日开始时间必须早于结束时间。")
        }
        guard !intent.transport.allowedModes.isEmpty else {
            throw PlanningConflict(code: .noAllowedTransport, message: "至少需要允许一种交通方式。")
        }

        let fixed = intent.poiConstraints.compactMap { constraint -> FixedVisit? in
            guard let poiID = constraint.resolvedPOIID,
                  let day = constraint.assignedDay,
                  let minute = constraint.fixedArrivalMinute else { return nil }
            return FixedVisit(poiID: poiID, dayIndex: day, arrivalMinute: minute,
                              minimumStayMinutes: constraint.minimumStayMinutes)
        }
        for visit in fixed {
            guard (0..<intent.days).contains(visit.dayIndex) else {
                throw PlanningConflict(code: .fixedVisitInfeasible,
                                       message: "固定预约超出了本次行程天数。",
                                       affectedPOIIDs: [visit.poiID])
            }
            let window = intent.dailyConstraints.first { $0.dayIndex == visit.dayIndex }
                ?? DailyConstraint(dayIndex: visit.dayIndex)
            guard window.startMinute <= visit.arrivalMinute,
                  visit.arrivalMinute < window.endMinute else {
                throw PlanningConflict(code: .fixedVisitInfeasible,
                                       message: "固定预约时间不在当天活动时间内。",
                                       affectedPOIIDs: [visit.poiID])
            }
        }
        // A fixed appointment is a hard constraint even when the user did not also
        // say “must visit”.  Treating it as required prevents curation, spill and
        // real-route reconciliation from silently deleting the appointment.
        required.formUnion(fixed.map(\.poiID))
        let anchors = intent.dailyConstraints.map {
            DayAnchors(startPOIID: $0.startAnchorPOIID, endPOIID: $0.endAnchorPOIID)
        }
        return PlanningConstraints(requiredPOIIDs: required,
                                   preferredPOIIDs: intent.preferredPOIIDs,
                                   excludedPOIIDs: excluded,
                                   fixedVisits: fixed,
                                   dailyWindows: intent.dailyConstraints,
                                   dailyAnchors: anchors,
                                   allowedModes: intent.transport.allowedModes,
                                   maxWalkingMinutesPerSegment: intent.mobility.maxWalkingMinutesPerSegment,
                                   accessibilityRequired: intent.mobility.accessibilityRequired)
    }
}
