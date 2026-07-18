import Foundation
@testable import TrailheadCore
import XCTest

final class TOPTWReferenceSolverTests: XCTestCase {
    private func poi(_ id: String, rating: Double, lng: Double,
                     openHours: String? = nil) -> POICandidate {
        POICandidate(id: id, name: id, kind: .sight, subtype: "景点",
                     lat: 0, lng: lng, rating: rating, openHours: openHours)
    }

    private func context(days: Int = 2, weekdays: [Int?] = [nil, nil],
                         scores: [String: Double], maxPerDay: Int = 2,
                         required: Set<String> = []) -> TOPTWReferenceSolver.Context {
        TOPTWReferenceSolver.Context(
            prefs: TripPrefs(pace: .relaxed), weekdays: Array(weekdays.prefix(days)), city: "",
            baseAnchor: nil, scores: scores, maxSightsPerDay: maxPerDay,
            dailyAnchorIDs: [], requiredPOIIDs: required, dailyWindows: []
        )
    }

    func testReferenceSolverSelectsHigherValuePointsWhenCapacityIsLimited() {
        let candidates = [
            poi("high-a", rating: 5, lng: 0),
            poi("high-b", rating: 4.9, lng: 0.01),
            poi("low-a", rating: 2, lng: 0.02),
            poi("low-b", rating: 1, lng: 0.03),
            poi("lowest", rating: 0.5, lng: 0.04),
        ]
        let scores = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.rating!) })

        let routes = TOPTWReferenceSolver.solve(
            candidates: candidates, context: context(scores: scores, maxPerDay: 2)
        )
        let selected = Set(routes.flatMap { $0 }.map(\.id))

        XCTAssertEqual(routes.map(\.count), [2, 2])
        XCTAssertTrue(selected.contains("high-a"))
        XCTAssertTrue(selected.contains("high-b"))
        XCTAssertFalse(selected.contains("lowest"))
    }

    func testReferenceSolverPlacesMondayClosedMuseumOnTuesday() {
        let museum = poi("museum", rating: 5, lng: 0,
                         openHours: "09:00-17:00，周一闭馆")
        let park = poi("park", rating: 4, lng: 0.01)
        let scores = ["museum": 5.0, "park": 4.0]

        let routes = TOPTWReferenceSolver.solve(
            candidates: [museum, park],
            context: context(weekdays: [1, 2], scores: scores, maxPerDay: 1)
        )

        XCTAssertFalse(routes[0].contains(where: { $0.id == "museum" }))
        XCTAssertTrue(routes[1].contains(where: { $0.id == "museum" }))
    }

    func testReferenceSolverIsDeterministicAndPreservesRequiredPoint() {
        let candidates = [
            poi("a", rating: 4, lng: 0),
            poi("b", rating: 3, lng: 0.01),
            poi("required", rating: 1, lng: 0.02),
        ]
        let scores = ["a": 4.0, "b": 3.0, "required": 1_001.0]
        let ctx = context(scores: scores, maxPerDay: 1, required: ["required"])

        let first = TOPTWReferenceSolver.solve(candidates: candidates, context: ctx)
        let second = TOPTWReferenceSolver.solve(candidates: candidates, context: ctx)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.flatMap { $0 }.contains(where: { $0.id == "required" }))
    }

    func testPortfolioChoosesFeasibleHigherValueReference() {
        let high = poi("high", rating: 5, lng: 0)
        let low = poi("low", rating: 1, lng: 0)
        let ctx = context(days: 1, weekdays: [nil], scores: ["high": 5, "low": 1], maxPerDay: 1)

        let chosen = ItinerarySolutionPortfolio.choose(
            incumbent: [[low]], reference: [[high]], context: ctx, hasFixedVisits: false
        )

        XCTAssertEqual(chosen.flatMap { $0 }.map(\.id), ["high"])
    }

    func testPortfolioRejectsReferenceThatDropsRequiredPoint() {
        let required = poi("required", rating: 1, lng: 0)
        let high = poi("high", rating: 5, lng: 0)
        let ctx = context(days: 1, weekdays: [nil],
                          scores: ["required": 1_001, "high": 5],
                          maxPerDay: 1, required: ["required"])

        let chosen = ItinerarySolutionPortfolio.choose(
            incumbent: [[required]], reference: [[high]], context: ctx, hasFixedVisits: false
        )

        XCTAssertEqual(chosen.flatMap { $0 }.map(\.id), ["required"])
    }
}
