import Foundation
@testable import TrailheadCore
import XCTest

final class RelaxedPlanningTests: XCTestCase {
    private func poi(_ id: String, kind: ItemKind = .sight, subtype: String = "",
                     lng: Double = 0, open: String? = nil,
                     metadata: POIVisitMetadata = .init()) -> POICandidate {
        POICandidate(id: id, name: id, kind: kind, subtype: subtype,
                     lat: 0, lng: lng, rating: 4.5, openHours: open,
                     visitMetadata: metadata)
    }

    func testRelaxedPolicyLeavesNinetyMinutesFreeAndTwoPrimarySlots() {
        let policy = DayComfortPolicy.policy(for: .relaxed)
        XCTAssertEqual(policy.maxPrimarySights, 2)
        XCTAssertEqual(policy.minimumFreeBufferMin, 90)
        XCTAssertEqual(policy.loadBudget(dayStart: 9 * 60, dayEnd: 20 * 60), 475)
    }

    func testTwoComputedDayAnchorsAreSeparated() {
        let a = poi("a", subtype: "大型综合景区")
        let b = poi("b", subtype: "大型综合景区", lng: 1)
        let ids: Set<String> = [a, b].filter { StayDuration.profile(for: $0).isDayAnchor }.reduce(into: []) {
            $0.insert($1.id)
        }
        let result = DayClusterer.cluster(sights: [a, b], days: 2, maxSightsPerDay: 3,
                                          stayMinutes: ["a": 420, "b": 420],
                                          stayBudget: 475, dayAnchorIDs: ids)
        XCTAssertEqual(result.map(\.count), [1, 1])
    }

    func testOptionalSelectorExcludesPlannedAndAssignsNearestDay() {
        let a = poi("a")
        let b = poi("b", lng: 0.01)
        let c = poi("c", lng: 1.01)
        let d = poi("d", lng: 1)
        let planned = [[PlannedStop(candidate: a, time: nil, stayMin: 60, note: nil)],
                       [PlannedStop(candidate: d, time: nil, stayMin: 60, note: nil)]]
        let options = OptionalStopSelector.assign(pool: [a, b, c, d], planned: planned,
                                                  prefs: TripPrefs())
        XCTAssertEqual(options[0].map(\.id), ["b"])
        XCTAssertEqual(options[1].map(\.id), ["c"])
    }

    func testNextStopRejectsCandidateWithoutReturnAndSafetyTime() {
        let current = poi("current")
        let candidate = poi("candidate", subtype: "博物馆", lng: 0.05)
        let exit = poi("exit", lng: 0.1)
        let context = NextStopContext(nowMinutes: 18 * 60, current: current,
                                      candidates: [candidate], exitAnchor: exit,
                                      prefs: TripPrefs(pace: .relaxed), dayEnd: 20 * 60)
        let result = NextStopRecommender.recommend(context)
        XCTAssertNil(result.continueExploring)
        XCTAssertNil(result.easyFinish)
        XCTAssertNotNil(result.endDay.reason)
    }

    func testNextStopAlwaysReturnsEndDayAndRanksFeasibleEasyFinish() {
        let current = poi("current")
        let cafe = poi("cafe", kind: .food, lng: 0.001, open: "09:00-22:00")
        let context = NextStopContext(nowMinutes: 15 * 60, current: current,
                                      candidates: [cafe], prefs: TripPrefs(pace: .relaxed))
        let result = NextStopRecommender.recommend(context)
        XCTAssertEqual(result.easyFinish?.candidate.id, "cafe")
        XCTAssertFalse(result.endDay.reason.isEmpty)
    }

    func testActiveParentScopeFiltersOutsideSight() {
        let current = poi("parent")
        let inside = poi("inside", metadata: POIVisitMetadata(providerParentID: "parent"))
        let outside = poi("outside", lng: 0.001)
        let context = NextStopContext(nowMinutes: 12 * 60, current: current,
                                      candidates: [inside, outside], activeParentScopeID: "parent",
                                      prefs: TripPrefs(pace: .relaxed))
        let result = NextStopRecommender.recommend(context)
        XCTAssertNotEqual(result.continueExploring?.candidate.id, "outside")
        XCTAssertNotEqual(result.easyFinish?.candidate.id, "outside")
    }
}
