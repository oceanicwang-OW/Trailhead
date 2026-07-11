@testable import Trailhead
import XCTest

final class RecommendationPresentationTests: XCTestCase {
    func testCollapsedRecommendationsShowOnlyTopThree() {
        XCTAssertEqual(RecommendationPresentation.visible([1, 2, 3, 4, 5], expanded: false), [1, 2, 3])
    }

    func testExpandedRecommendationsKeepAllAndOrder() {
        XCTAssertEqual(RecommendationPresentation.visible([1, 2, 3, 4], expanded: true), [1, 2, 3, 4])
    }

    func testProximityFormatsMetersAndKilometers() {
        XCTAssertEqual(RecommendationPresentation.proximity(
            meters: 850, minutes: 12, prefix: "距当天路线"), "距当天路线最近点 850 m · 约 12 分钟")
        XCTAssertEqual(RecommendationPresentation.proximity(
            meters: 1_250, minutes: 6, prefix: "距整趟路线"), "距整趟路线最近点 1.2 km · 约 6 分钟")
    }
}
