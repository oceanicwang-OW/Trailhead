//  PlanningConflict.swift
//  硬约束失败与可试算修复选项（PDR CP-0.6）。

import Foundation

public enum PlanningConflictCode: String, Codable, Sendable {
    case contradictoryRequirement
    case unresolvedRequiredPOI
    case invalidDayWindow
    case noAllowedTransport
    case requiredPOINotFound
    case requiredPOIDropped
    case fixedVisitInfeasible
    case routeInfeasible
}
public struct RepairOption: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var detail: String
    public var patches: [IntentPatch]
    public var preservesAllRequired: Bool

    public init(id: UUID = UUID(), title: String, detail: String = "", patches: [IntentPatch] = [],
                preservesAllRequired: Bool = true) {
        self.id = id
        self.title = title
        self.detail = detail
        self.patches = patches
        self.preservesAllRequired = preservesAllRequired
    }
}

public struct PlanningConflict: Error, Codable, Equatable, Sendable, LocalizedError {
    public var code: PlanningConflictCode
    public var message: String
    public var affectedPOIIDs: [String]
    public var repairOptions: [RepairOption]

    public init(code: PlanningConflictCode, message: String,
                affectedPOIIDs: [String] = [], repairOptions: [RepairOption] = []) {
        self.code = code
        self.message = message
        self.affectedPOIIDs = affectedPOIIDs
        self.repairOptions = repairOptions
    }

    public var errorDescription: String? { message }
}
