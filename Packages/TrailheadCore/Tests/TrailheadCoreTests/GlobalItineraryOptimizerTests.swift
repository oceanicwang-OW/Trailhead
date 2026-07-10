import Foundation
@testable import TrailheadCore
import XCTest

final class GlobalItineraryOptimizerTests: XCTestCase {
    private func poi(_ id: String, _ lng: Double) -> POICandidate {
        POICandidate(id: id, name: id, kind: .sight, subtype: "景点",
                     lat: 0, lng: lng, rating: 4.5)
    }

    func testBeamSearchGroupsNearbyPointsAcrossDays() {
        let westA = poi("west-a", 0)
        let westB = poi("west-b", 0.01)
        let eastA = poi("east-a", 1)
        let eastB = poi("east-b", 1.01)
        let mixed = [[westA, eastA], [westB, eastB]]

        let optimized = GlobalItineraryOptimizer.optimize(
            clusters: mixed, prefs: TripPrefs(pace: .relaxed),
            weekdays: [nil, nil], city: "110100", maxSightsPerDay: 2
        )
        let sets = optimized.map { Set($0.map(\.id)) }

        XCTAssertTrue(sets.contains(["west-a", "west-b"]))
        XCTAssertTrue(sets.contains(["east-a", "east-b"]))
    }

    func testBeamSearchIsDeterministicAndPreservesAllPoints() {
        let input = [[poi("a", 0), poi("d", 1)],
                     [poi("b", 0.01), poi("c", 1.01)]]
        let first = GlobalItineraryOptimizer.optimize(
            clusters: input, prefs: TripPrefs(), weekdays: [nil, nil],
            city: "", maxSightsPerDay: 2
        )
        let second = GlobalItineraryOptimizer.optimize(
            clusters: input, prefs: TripPrefs(), weekdays: [nil, nil],
            city: "", maxSightsPerDay: 2
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first.flatMap { $0 }.map(\.id)), ["a", "b", "c", "d"])
    }
}
