//  VisitDurationRange.swift
//  通用景点访问画像。所有 POI 使用相同特征模型，不维护具体景点名称/ID 白名单。

import Foundation

public enum POIScope: String, Codable, CaseIterable, Sendable {
    case point
    case venue
    case park
    case district
    case complex
    case island
}

public enum DurationSource: String, Codable, Sendable {
    case userOverride
    case providerMetadata
    case featureModel
    case scopeRule
    case categoryRule
    case fallback
}

public struct VisitDurationRange: Equatable, Hashable, Sendable {
    public let minimum: Int
    public let comfortable: Int
    public let extended: Int
    public let confidence: Double
    public let source: DurationSource

    public init(minimum: Int, comfortable: Int, extended: Int,
                confidence: Double, source: DurationSource) {
        let minimum = max(5, minimum)
        let comfortable = max(minimum, comfortable)
        self.minimum = minimum
        self.comfortable = comfortable
        self.extended = max(comfortable, extended)
        self.confidence = min(1, max(0, confidence))
        self.source = source
    }
}

/// 地图数据源可选提供的结构化游览元数据。所有字段均为 optional：缺失与零值语义不同。
public struct POIVisitMetadata: Codable, Equatable, Hashable, Sendable {
    public var providerParentID: String?
    public var areaSquareMeters: Double?
    public var childPOICount: Int?
    public var entranceCount: Int?
    public var internalDistanceMeters: Int?
    public var elevationGainMeters: Int?
    public var requiresReservation: Bool?
    public var hasSecurityCheck: Bool?
    public var requiresSpecialAccess: Bool?
    public var hasInternalTransit: Bool?
    public var popularityScore: Double?
    public var queueRiskScore: Double?

    public init(providerParentID: String? = nil,
                areaSquareMeters: Double? = nil,
                childPOICount: Int? = nil,
                entranceCount: Int? = nil,
                internalDistanceMeters: Int? = nil,
                elevationGainMeters: Int? = nil,
                requiresReservation: Bool? = nil,
                hasSecurityCheck: Bool? = nil,
                requiresSpecialAccess: Bool? = nil,
                hasInternalTransit: Bool? = nil,
                popularityScore: Double? = nil,
                queueRiskScore: Double? = nil) {
        self.providerParentID = providerParentID
        self.areaSquareMeters = areaSquareMeters
        self.childPOICount = childPOICount
        self.entranceCount = entranceCount
        self.internalDistanceMeters = internalDistanceMeters
        self.elevationGainMeters = elevationGainMeters
        self.requiresReservation = requiresReservation
        self.hasSecurityCheck = hasSecurityCheck
        self.requiresSpecialAccess = requiresSpecialAccess
        self.hasInternalTransit = hasInternalTransit
        self.popularityScore = popularityScore
        self.queueRiskScore = queueRiskScore
    }
}

public struct VisitFeatureVector: Equatable, Hashable, Sendable {
    public let scope: POIScope
    public let areaScore: Double
    public let contentDensityScore: Double
    public let accessComplexityScore: Double
    public let internalMobilityScore: Double
    public let queueRiskScore: Double
    public let parentConfidence: Double
    public let evidenceCount: Int
}

public struct VisitProfile: Equatable, Hashable, Sendable {
    public let scope: POIScope
    public let duration: VisitDurationRange
    public let isDayAnchor: Bool
    public let parentScopeID: String?
    public let accessBufferMin: Int
    public let exitBufferMin: Int

    public var visitCostMin: Int { accessBufferMin + duration.comfortable + exitBufferMin }
}

public struct VisitDurationOverride: Equatable, Hashable, Sendable {
    public let range: VisitDurationRange
    public init(minimum: Int, comfortable: Int, extended: Int) {
        range = VisitDurationRange(minimum: minimum, comfortable: comfortable,
                                   extended: extended, confidence: 1, source: .userOverride)
    }
}
