//  VisitFeatureExtractor.swift
//  将任意 POI 的结构化元数据归一化为同一特征向量；缺失字段一律取类别中性值 0.5。

import Foundation

public enum ScopeClassifier {
    private static let venueHints = ["博物馆", "美术馆", "科技馆", "纪念馆", "展览馆", "展馆"]
    private static let districtHints = ["历史街区", "文化街区", "古镇", "古村", "步行街"]
    private static let complexHints = ["主题乐园", "游乐园", "度假区", "大型综合景区"]
    private static let islandHints = ["岛屿", "海岛景区", "洲岛"]
    private static let parkHints = ["公园", "植物园", "森林", "湿地", "自然保护区", "风景名胜"]

    public static func classify(_ candidate: POICandidate) -> POIScope {
        guard candidate.kind == .sight else { return .point }
        let text = ([candidate.subtype] + candidate.tags).joined(separator: ";")
        if islandHints.contains(where: text.contains) { return .island }
        if complexHints.contains(where: text.contains) { return .complex }
        if districtHints.contains(where: text.contains) { return .district }
        if venueHints.contains(where: text.contains) { return .venue }
        if parkHints.contains(where: text.contains) { return .park }
        return .point
    }
}

public enum VisitFeatureExtractor {
    private static let neutral = 0.5

    public static func extract(_ candidate: POICandidate) -> VisitFeatureVector {
        let metadata = candidate.visitMetadata
        let scope = ScopeClassifier.classify(candidate)
        var evidence = 0

        let area = metadata.areaSquareMeters.map {
            evidence += 1
            return logNormalize($0, lower: areaBounds(scope).0, upper: areaBounds(scope).1)
        } ?? neutral
        let content = metadata.childPOICount.map {
            evidence += 1
            return logNormalize(Double(max(0, $0) + 1), lower: 2, upper: 21)
        } ?? neutral

        let accessSignals: [Double?] = [
            boolScore(metadata.requiresReservation), boolScore(metadata.hasSecurityCheck),
            boolScore(metadata.requiresSpecialAccess),
            metadata.entranceCount.map { $0 <= 1 ? 0.8 : min(1, Double($0) / 6) },
        ]
        let access = meanKnown(accessSignals, evidence: &evidence)

        let mobilitySignals: [Double?] = [
            metadata.internalDistanceMeters.map { clamp(Double($0) / 8_000) },
            metadata.elevationGainMeters.map { clamp(Double($0) / 800) },
            boolScore(metadata.hasInternalTransit),
        ]
        let mobility = meanKnown(mobilitySignals, evidence: &evidence)

        let queueSignals: [Double?] = [
            metadata.queueRiskScore.map(clamp), metadata.popularityScore.map(clamp),
            boolScore(metadata.requiresReservation), boolScore(metadata.hasSecurityCheck),
        ]
        let queue = meanKnown(queueSignals, evidence: &evidence)
        let parentConfidence = metadata.providerParentID == nil ? 0 : 1.0
        if metadata.providerParentID != nil { evidence += 1 }

        return VisitFeatureVector(scope: scope, areaScore: area,
                                  contentDensityScore: content,
                                  accessComplexityScore: access,
                                  internalMobilityScore: mobility,
                                  queueRiskScore: queue,
                                  parentConfidence: parentConfidence,
                                  evidenceCount: evidence)
    }

    private static func areaBounds(_ scope: POIScope) -> (Double, Double) {
        switch scope {
        case .point: return (500, 50_000)
        case .venue: return (2_000, 100_000)
        case .park: return (20_000, 5_000_000)
        case .district: return (50_000, 8_000_000)
        case .complex: return (100_000, 10_000_000)
        case .island: return (100_000, 20_000_000)
        }
    }

    private static func logNormalize(_ value: Double, lower: Double, upper: Double) -> Double {
        guard value > 0, upper > lower else { return 0 }
        return clamp((log(value) - log(lower)) / (log(upper) - log(lower)))
    }

    private static func boolScore(_ value: Bool?) -> Double? { value.map { $0 ? 1 : 0 } }

    private static func meanKnown(_ values: [Double?], evidence: inout Int) -> Double {
        let known = values.compactMap { $0 }
        evidence += known.count
        guard !known.isEmpty else { return neutral }
        return known.reduce(0, +) / Double(known.count)
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}
