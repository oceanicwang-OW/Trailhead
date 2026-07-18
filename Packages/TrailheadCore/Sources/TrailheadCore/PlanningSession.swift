//  PlanningSession.swift
//  对话会话、结构化 patch、合并规则与澄清策略（PDR CP-0.2...0.5）。

import Foundation

public enum PlanningSessionState: String, Codable, Sendable {
    case draft
    case clarifying
    case resolvingPOI
    case ready
    case generating
    case conflict
    case failedRecoverable
    case completed
    case cancelled
}

public enum PlanningMessageRole: String, Codable, Sendable {
    case assistant
    case user
    case system
}

public struct PlanningMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var role: PlanningMessageRole
    public var content: String
    public var createdAt: Date

    public init(id: UUID = UUID(), role: PlanningMessageRole, content: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public struct IntentAmbiguity: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var path: IntentPath?
    public var message: String
    public var isBlocking: Bool

    public init(id: UUID = UUID(), path: IntentPath? = nil, message: String, isBlocking: Bool = false) {
        self.id = id
        self.path = path
        self.message = message
        self.isBlocking = isBlocking
    }
}

public struct PlanningSession: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var state: PlanningSessionState
    public var intent: TripIntent
    public var messages: [PlanningMessage]
    public var pendingAmbiguities: [IntentAmbiguity]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), state: PlanningSessionState = .draft, intent: TripIntent,
                messages: [PlanningMessage] = [], pendingAmbiguities: [IntentAmbiguity] = [],
                createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.state = state
        self.intent = intent
        self.messages = messages
        self.pendingAmbiguities = pendingAmbiguities
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum IntentPath: String, Codable, CaseIterable, Sendable {
    case destinationName = "destination.name"
    case days
    case partyAdults = "party.adults"
    case partyChildren = "party.children"
    case partySeniors = "party.seniors"
    case preferenceTags = "preferences.tags"
    case preferenceCuisines = "preferences.cuisines"
    case preferenceLodgingType = "preferences.lodgingType"
    case preferencePace = "preferences.pace"
    case preferenceBudget = "preferences.budgetPerDay"
    case mobilityMaxWalking = "mobility.maxWalkingMinutesPerSegment"
    case mobilityAccessibility = "mobility.accessibilityRequired"
    case transportAllowedModes = "transport.allowedModes"
    case defaultDayStart = "daily.defaultStartMinute"
    case defaultDayEnd = "daily.defaultEndMinute"
    case mealIncludeTimeline = "meals.includeInTimeline"
    case mealDietaryNotes = "meals.dietaryNotes"
    case rawNotes
}

public enum IntentPatchOperation: String, Codable, Sendable {
    case set
    case remove
    case append
}

public enum IntentPatchValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case strings([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([String].self) { self = .strings(value); return }
        throw DecodingError.typeMismatch(IntentPatchValue.self, .init(codingPath: decoder.codingPath,
                                                                      debugDescription: "不支持的 patch value"))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .strings(value): try container.encode(value)
        }
    }
}

public struct IntentPatch: Codable, Hashable, Sendable {
    public var op: IntentPatchOperation
    public var path: IntentPath
    public var value: IntentPatchValue?
    public var source: IntentSource
    public var confidence: Double

    public init(op: IntentPatchOperation = .set, path: IntentPath, value: IntentPatchValue?,
                source: IntentSource, confidence: Double = 1) {
        self.op = op
        self.path = path
        self.value = value
        self.source = source
        self.confidence = confidence
    }
}

public enum IntentMergeError: Error, Equatable, LocalizedError {
    case missingValue(IntentPath)
    case invalidValue(IntentPath)

    public var errorDescription: String? {
        switch self {
        case let .missingValue(path): return "缺少 \(path.rawValue) 的值。"
        case let .invalidValue(path): return "\(path.rawValue) 的值无效。"
        }
    }
}

public enum IntentMerger {
    public static func applying(_ patches: [IntentPatch], to original: TripIntent) throws -> TripIntent {
        var result = original
        for patch in patches {
            let previous = result.fieldStates[patch.path]
            guard shouldApply(patch, over: previous) else { continue }
            try apply(patch, to: &result)
            result.fieldStates[patch.path] = IntentFieldState(
                source: patch.source,
                confidence: patch.confidence,
                isConfirmed: patch.source != .modelInferred
            )
        }
        result.revision += 1
        result.normalizeDailyConstraints()
        return result
    }

    private static func shouldApply(_ patch: IntentPatch, over previous: IntentFieldState?) -> Bool {
        guard let previous else { return true }
        if patch.source == .userExplicit { return true }
        return patch.source.rank >= previous.source.rank
    }

    private static func apply(_ patch: IntentPatch, to intent: inout TripIntent) throws {
        if patch.op == .remove {
            remove(path: patch.path, from: &intent)
            return
        }
        guard let value = patch.value else { throw IntentMergeError.missingValue(patch.path) }
        switch (patch.path, value) {
        case let (.destinationName, .string(value)):
            intent.destination.name = trimmed(value)
        case let (.days, .int(value)) where (1...14).contains(value):
            intent.days = value
        case let (.partyAdults, .int(value)) where (0...30).contains(value): intent.party.adults = value
        case let (.partyChildren, .int(value)) where (0...30).contains(value): intent.party.children = value
        case let (.partySeniors, .int(value)) where (0...30).contains(value): intent.party.seniors = value
        case let (.preferenceTags, .strings(value)): intent.preferences.tags = normalized(value)
        case let (.preferenceCuisines, .strings(value)): intent.preferences.cuisines = normalized(value)
        case let (.preferenceLodgingType, .string(value)): intent.preferences.lodgingType = trimmed(value)
        case let (.preferencePace, .string(value)):
            guard let pace = Pace(rawValue: value) else { throw IntentMergeError.invalidValue(patch.path) }
            intent.preferences.pace = pace
        case let (.preferenceBudget, .int(value)) where (0...100_000).contains(value):
            intent.preferences.budgetPerDay = value
        case let (.mobilityMaxWalking, .int(value)) where (1...240).contains(value):
            intent.mobility.maxWalkingMinutesPerSegment = value
        case let (.mobilityAccessibility, .bool(value)):
            intent.mobility.accessibilityRequired = value
        case let (.transportAllowedModes, .strings(value)):
            let modes = Set(value.compactMap(TransitMode.init(rawValue:)))
            guard !modes.isEmpty else { throw IntentMergeError.invalidValue(patch.path) }
            intent.transport.allowedModes = modes
        case let (.defaultDayStart, .int(value)) where (0..<24 * 60).contains(value):
            for index in intent.dailyConstraints.indices { intent.dailyConstraints[index].startMinute = value }
        case let (.defaultDayEnd, .int(value)) where (1...24 * 60).contains(value):
            for index in intent.dailyConstraints.indices { intent.dailyConstraints[index].endMinute = value }
        case let (.mealIncludeTimeline, .bool(value)): intent.meals.includeInTimeline = value
        case let (.mealDietaryNotes, .string(value)): intent.meals.dietaryNotes = trimmed(value)
        case let (.rawNotes, .string(value)):
            if patch.op == .append, !intent.rawNotes.isEmpty {
                intent.rawNotes += "\n\(trimmed(value))"
            } else {
                intent.rawNotes = trimmed(value)
            }
            intent.preferences.freeText = intent.rawNotes
        default:
            throw IntentMergeError.invalidValue(patch.path)
        }
    }

    private static func remove(path: IntentPath, from intent: inout TripIntent) {
        switch path {
        case .mobilityMaxWalking: intent.mobility.maxWalkingMinutesPerSegment = nil
        case .preferenceTags: intent.preferences.tags = []
        case .preferenceCuisines: intent.preferences.cuisines = []
        case .preferenceLodgingType: intent.preferences.lodgingType = ""
        case .mealDietaryNotes: intent.meals.dietaryNotes = ""
        case .rawNotes: intent.rawNotes = ""; intent.preferences.freeText = ""
        default: break
        }
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ values: [String]) -> [String] {
        Array(Set(values.map(trimmed).filter { !$0.isEmpty })).sorted()
    }
}

public enum ClarificationQuestion: String, Codable, CaseIterable, Sendable {
    case unresolvedRequiredPOI
    case conflictingPOIRequirement
    case invalidDayWindow
    case mobilityTaxiPermission
    case dailySchedule
    case mustVisit

    public var prompt: String {
        switch self {
        case .unresolvedRequiredPOI: return "先确认一下你说的必去地点具体是哪一个。"
        case .conflictingPOIRequirement: return "同一地点同时被标记为必去和不要去，请选择保留哪一项。"
        case .invalidDayWindow: return "每天的开始时间需要早于结束时间，请调整活动时间。"
        case .mobilityTaxiPermission: return "为了减少步行，可以多安排出租车接驳吗？"
        case .dailySchedule: return "你希望每天大约几点出发、几点结束？"
        case .mustVisit: return "还有必须去、最好去或明确不想去的地点吗？"
        }
    }
}

public struct ClarificationDecision: Equatable, Sendable {
    public var isReady: Bool
    public var blockingReasons: [String]
    public var question: ClarificationQuestion?
}

public enum ClarificationPolicy {
    public static func evaluate(_ intent: TripIntent) -> ClarificationDecision {
        var blockers: [String] = []
        if intent.destination.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blockers.append("目的地不能为空。")
        }
        if let unresolved = intent.poiConstraints.first(where: {
            $0.requirement == .mustVisit && $0.resolvedPOIID == nil
        }) {
            blockers.append("必去地点“\(unresolved.mention)”尚未确认。")
            return .init(isReady: false, blockingReasons: blockers, question: .unresolvedRequiredPOI)
        }
        let required = Set(intent.poiConstraints.filter { $0.requirement == .mustVisit }.map(\.mention))
        let excluded = Set(intent.poiConstraints.filter { $0.requirement == .avoidVisit }.map(\.mention))
        if !required.intersection(excluded).isEmpty {
            blockers.append("同一地点不能同时设为必去和不要去。")
            return .init(isReady: false, blockingReasons: blockers, question: .conflictingPOIRequirement)
        }
        if intent.dailyConstraints.contains(where: { $0.startMinute >= $0.endMinute }) {
            blockers.append("每日开始时间必须早于结束时间。")
            return .init(isReady: false, blockingReasons: blockers, question: .invalidDayWindow)
        }
        if intent.party.seniors > 0,
           intent.mobility.maxWalkingMinutesPerSegment == nil,
           intent.fieldStates[.mobilityMaxWalking] == nil {
            return .init(isReady: false, blockingReasons: blockers, question: .mobilityTaxiPermission)
        }
        return .init(isReady: blockers.isEmpty, blockingReasons: blockers, question: nil)
    }
}
