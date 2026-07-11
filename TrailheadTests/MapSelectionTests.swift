import TrailheadCore
@testable import Trailhead
import XCTest

final class MapSelectionTests: XCTestCase {
    func testItinerarySelectionExposesOnlyItineraryID() {
        let id = UUID()
        let selection = MapSelection.itinerary(id)

        XCTAssertEqual(selection.itineraryID, id)
        XCTAssertNil(selection.recommendationFocus)
        XCTAssertFalse(selection.matchesRecommendation("food-1"))
    }

    func testRecommendationSelectionExposesOnlyMatchingFocus() {
        let focus = MapFocus(id: "food-1", name: "餐厅", lat: 31.2, lng: 121.5, kind: .food)
        let selection = MapSelection.recommendation(focus)

        XCTAssertNil(selection.itineraryID)
        XCTAssertEqual(selection.recommendationFocus, focus)
        XCTAssertTrue(selection.matchesRecommendation("food-1"))
        XCTAssertFalse(selection.matchesRecommendation("food-2"))
    }
}
