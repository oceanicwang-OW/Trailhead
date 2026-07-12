//  VisitProfileResolver.swift
//  类别先验 + 通用特征模型 → 弹性时长、访问缓冲与全天 anchor 判定。

import Foundation

public enum VisitProfileResolver {
    public static func resolve(_ candidate: POICandidate,
                               override: VisitDurationOverride? = nil,
                               activeWindowMin: Int = 11 * 60) -> VisitProfile {
        let features = VisitFeatureExtractor.extract(candidate)
        let base = baseRange(for: candidate, scope: features.scope)
        let range = override?.range ?? adjusted(base, features: features)
        let access = roundTo5(10 + 25 * features.accessComplexityScore + 15 * features.queueRiskScore)
        let exit = roundTo5(5 + 15 * features.accessComplexityScore)
        let visitCost = access + range.comfortable + exit
        let anchor = Double(visitCost) >= Double(activeWindowMin) * 0.55
            || range.comfortable >= 360
            || (range.comfortable >= 300 && features.accessComplexityScore > 0.6)
        return VisitProfile(scope: features.scope, duration: range, isDayAnchor: anchor,
                            parentScopeID: candidate.visitMetadata.providerParentID,
                            accessBufferMin: min(50, max(10, access)),
                            exitBufferMin: min(25, max(5, exit)))
    }

    public static func selectedMinutes(for candidate: POICandidate, pace: Pace,
                                       override: VisitDurationOverride? = nil) -> Int {
        selectedMinutes(in: resolve(candidate, override: override).duration, pace: pace)
    }

    public static func selectedMinutes(in range: VisitDurationRange, pace: Pace) -> Int {
        let raw: Double
        switch pace {
        case .tight:
            raw = Double(range.minimum) + 0.35 * Double(range.comfortable - range.minimum)
        case .relaxed:
            raw = Double(range.comfortable)
        case .casual:
            raw = Double(range.comfortable) + 0.60 * Double(range.extended - range.comfortable)
        }
        return roundTo5(raw)
    }

    private static func baseRange(for candidate: POICandidate, scope: POIScope) -> VisitDurationRange {
        if candidate.kind == .food {
            return VisitDurationRange(minimum: 45, comfortable: 75, extended: 105,
                                      confidence: 0.55, source: .categoryRule)
        }
        guard candidate.kind == .sight else {
            return VisitDurationRange(minimum: 30, comfortable: 60, extended: 90,
                                      confidence: 0.4, source: .fallback)
        }
        let values: (Int, Int, Int)
        switch scope {
        case .point: values = (60, 105, 180)
        case .venue: values = (90, 165, 240)
        case .park: values = (90, 210, 360)
        case .district: values = (120, 270, 420)
        case .complex, .island: values = (240, 390, 480)
        }
        return VisitDurationRange(minimum: values.0, comfortable: values.1, extended: values.2,
                                  confidence: 0.5, source: .scopeRule)
    }

    private static func adjusted(_ base: VisitDurationRange,
                                 features: VisitFeatureVector) -> VisitDurationRange {
        let scale = min(1.45, max(0.75,
            0.625 + 0.25 * features.areaScore + 0.25 * features.contentDensityScore
                + 0.15 * features.internalMobilityScore + 0.10 * features.queueRiskScore))
        let minimumScale = min(1.35, scale)
        let coverage = min(1, Double(features.evidenceCount) / 8)
        let confidence = min(0.95, max(0.25, 0.25 + 0.12 * Double(features.evidenceCount)
            + 0.25 * coverage))
        return VisitDurationRange(
            minimum: roundTo5(Double(base.minimum) * minimumScale),
            comfortable: roundTo5(Double(base.comfortable) * scale),
            extended: roundTo5(Double(base.extended) * scale),
            confidence: confidence,
            source: features.evidenceCount > 0 ? .featureModel : base.source
        )
    }

    private static func roundTo5(_ value: Double) -> Int {
        max(5, Int((value / 5).rounded()) * 5)
    }
}
