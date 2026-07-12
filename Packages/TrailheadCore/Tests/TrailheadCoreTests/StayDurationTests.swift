import Foundation
@testable import TrailheadCore
import XCTest

final class StayDurationTests: XCTestCase {
    private func poi(_ kind: ItemKind, subtype: String = "", name: String = "x",
                     metadata: POIVisitMetadata = .init()) -> POICandidate {
        POICandidate(id: "p", name: name, kind: kind, subtype: subtype,
                     lat: 0, lng: 0, visitMetadata: metadata)
    }

    func testRelaxedUsesComfortableRange() {
        XCTAssertEqual(StayDuration.duration(for: poi(.sight), pace: .relaxed), 105)
        XCTAssertEqual(StayDuration.duration(for: poi(.food), pace: .relaxed), 75)
    }

    func testScopeClassificationChangesComfortableDuration() {
        XCTAssertEqual(StayDuration.duration(for: poi(.sight, subtype: "博物馆"), pace: .relaxed), 165)
        XCTAssertEqual(StayDuration.duration(for: poi(.sight, subtype: "城市公园"), pace: .relaxed), 210)
        XCTAssertEqual(StayDuration.duration(for: poi(.sight, subtype: "历史街区"), pace: .relaxed), 270)
    }

    func testFoodNameDoesNotTriggerSightScope() {
        XCTAssertEqual(StayDuration.duration(for: poi(.food, subtype: "餐饮服务;海鲜", name: "海岛餐厅"),
                                             pace: .relaxed), 75)
    }

    func testPaceSelectsInsideRangeAndRoundsToFive() {
        let candidate = poi(.sight)
        XCTAssertEqual(StayDuration.duration(for: candidate, pace: .tight), 75)
        XCTAssertEqual(StayDuration.duration(for: candidate, pace: .relaxed), 105)
        XCTAssertEqual(StayDuration.duration(for: candidate, pace: .casual), 150)
    }

    func testLargerStructuredPOIIsNotShorterThanNeutralPeer() {
        let neutral = poi(.sight)
        let large = poi(.sight, metadata: POIVisitMetadata(
            areaSquareMeters: 50_000, childPOICount: 20,
            internalDistanceMeters: 8_000, queueRiskScore: 1
        ))
        XCTAssertGreaterThan(StayDuration.duration(for: large, pace: .relaxed),
                             StayDuration.duration(for: neutral, pace: .relaxed))
    }

    func testMissingMetadataUsesNeutralNotZero() {
        let profile = StayDuration.profile(for: poi(.sight))
        XCTAssertEqual(profile.duration.comfortable, 105)
        XCTAssertGreaterThanOrEqual(profile.duration.confidence, 0.25)
    }

    func testSingleWeakNameKeywordDoesNotCreateIslandScope() {
        XCTAssertEqual(StayDuration.profile(for: poi(.sight, name: "某某岛")).scope, .point)
    }

    func testUserOverrideWinsAndRespectsPace() {
        let override = VisitDurationOverride(minimum: 100, comfortable: 200, extended: 300)
        XCTAssertEqual(VisitProfileResolver.selectedMinutes(for: poi(.sight), pace: .relaxed,
                                                            override: override), 200)
    }

    func testExplicitCustomLegacyPriorsRemainSupported() {
        let priors = StayDuration.Priors(sight: 100, museum: 120, nature: 120, food: 60, other: 60)
        XCTAssertEqual(StayDuration.duration(for: poi(.sight), pace: .relaxed, priors: priors), 100)
    }
}
