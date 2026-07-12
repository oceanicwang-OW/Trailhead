@testable import Trailhead
import TrailheadCore
import XCTest

final class GenerationExperienceTests: XCTestCase {
    func testDraftDefaultsToThreeDaysAndClampsSupportedRange() {
        XCTAssertEqual(NewTripDraft().days, 3)
        XCTAssertEqual(NewTripDraft(days: 0).days, 1)
        XCTAssertEqual(NewTripDraft(days: 99).days, 14)
    }

    func testDraftRemembersLastSelectedDays() throws {
        let suite = "GenerationExperienceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(NewTripDraft.rememberedDays(defaults: defaults), 3)
        NewTripDraft(days: 6).rememberDays(defaults: defaults)
        XCTAssertEqual(NewTripDraft.rememberedDays(defaults: defaults), 6)
    }

    func testDraftBuildsPreferencesWithoutLosingSelections() {
        let draft = NewTripDraft(selectedTags: ["摄影", "美食"],
                                 selectedCuisines: ["川菜"],
                                 lodgingType: "民宿",
                                 pace: .tight,
                                 budget: 850)

        XCTAssertEqual(draft.preferences.tags, ["摄影", "美食"])
        XCTAssertEqual(draft.preferences.cuisines, ["川菜"])
        XCTAssertEqual(draft.preferences.lodgingType, "民宿")
        XCTAssertEqual(draft.preferences.pace, .tight)
        XCTAssertEqual(draft.preferences.budgetPerDay, 850)
    }

    func testEstimateScalesWithTripLength() {
        let short = GenerationEstimate(days: 3)
        let long = GenerationEstimate(days: 8)

        XCTAssertLessThan(short.maximumSeconds, long.maximumSeconds)
        XCTAssertLessThan(short.maximumAmapCalls, long.maximumAmapCalls)
        XCTAssertTrue(short.callsText.contains("DeepSeek"))
    }

    func testQualitySummaryCountsVerifiedAndEstimatedTransit() {
        let sightA = PlanItem.poi(0, kind: .sight, time: "09:00", name: "A",
                                  subtype: "", note: "", stay: "")
        let verified = PlanItem.transit(1, mode: .walk, desc: "步行", minutes: 10, meters: 700)
        let sightB = PlanItem.poi(2, kind: .sight, time: "10:00", name: "B",
                                  subtype: "", note: "", stay: "")
        let estimated = PlanItem.transit(3, mode: .taxi, desc: "出租车", minutes: 20, meters: 5_000)
        estimated.transitReliability = .estimated
        let day = DayPlan(dayIndex: 0, items: [sightA, verified, sightB, estimated])
        let trip = Trip(city: "成都", nights: 0, days: [day])

        let summary = RouteQualitySummary(trip: trip)

        XCTAssertEqual(summary.routePoints, 2)
        XCTAssertEqual(summary.verifiedTransitSegments, 1)
        XCTAssertEqual(summary.estimatedTransitSegments, 1)
        XCTAssertEqual(summary.text, "2 个路线点 · 1 段真实交通 · 1 段估算")
    }

    func testFailureMessageNamesStageAndCacheReuse() {
        let message = RootView.failureMessage(ItineraryEngine.EngineError.emptyPlan, stage: .routing)

        XCTAssertTrue(message.contains("失败阶段：规划路线"))
        XCTAssertTrue(message.contains("复用已缓存地点"))
    }
}
