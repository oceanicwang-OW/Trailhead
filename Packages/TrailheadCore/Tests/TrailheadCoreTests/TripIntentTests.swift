@testable import TrailheadCore
import XCTest

final class TripIntentTests: XCTestCase {
    func testMergerUserExplicitOverridesModelInference() throws {
        var intent = TripIntent(destination: .init(name: "成都"))
        intent.fieldStates[.mobilityMaxWalking] = .init(source: .userExplicit)
        intent.mobility.maxWalkingMinutesPerSegment = 20

        let inferred = IntentPatch(path: .mobilityMaxWalking, value: .int(10),
                                   source: .modelInferred, confidence: 0.7)
        let unchanged = try IntentMerger.applying([inferred], to: intent)
        XCTAssertEqual(unchanged.mobility.maxWalkingMinutesPerSegment, 20)

        let explicit = IntentPatch(path: .mobilityMaxWalking, value: .int(15), source: .userExplicit)
        let changed = try IntentMerger.applying([explicit], to: unchanged)
        XCTAssertEqual(changed.mobility.maxWalkingMinutesPerSegment, 15)
    }

    func testMergerRejectsOutOfRangeDayCountWithoutMutation() {
        let intent = TripIntent(destination: .init(name: "成都"), days: 3)
        let patch = IntentPatch(path: .days, value: .int(30), source: .userExplicit)
        XCTAssertThrowsError(try IntentMerger.applying([patch], to: intent))
        XCTAssertEqual(intent.days, 3)
    }

    func testCompilerRejectsUnresolvedRequiredPOI() {
        let intent = TripIntent(destination: .init(name: "成都"),
                                poiConstraints: [.init(mention: "熊猫基地", requirement: .mustVisit)])
        XCTAssertThrowsError(try ConstraintCompiler.compile(intent)) { error in
            XCTAssertEqual((error as? PlanningConflict)?.code, .unresolvedRequiredPOI)
        }
    }

    func testCompilerSeparatesRequiredPreferredAndExcluded() throws {
        let intent = TripIntent(
            destination: .init(name: "成都"),
            poiConstraints: [
                .init(mention: "A", resolvedPOIID: "A", requirement: .mustVisit),
                .init(mention: "B", resolvedPOIID: "B", requirement: .preferVisit),
                .init(mention: "C", resolvedPOIID: "C", requirement: .avoidVisit),
            ]
        )
        let constraints = try ConstraintCompiler.compile(intent)
        XCTAssertEqual(constraints.requiredPOIIDs, ["A"])
        XCTAssertEqual(constraints.preferredPOIIDs, ["B"])
        XCTAssertEqual(constraints.excludedPOIIDs, ["C"])
    }

    func testFixedAppointmentIsAlwaysCompiledAsRequired() throws {
        let intent = TripIntent(
            destination: .init(name: "成都"),
            poiConstraints: [
                .init(mention: "博物馆", resolvedPOIID: "museum", requirement: .preferVisit,
                      assignedDay: 1, fixedArrivalMinute: 14 * 60),
            ]
        )
        let constraints = try ConstraintCompiler.compile(intent)
        XCTAssertEqual(constraints.requiredPOIIDs, ["museum"])
        XCTAssertEqual(constraints.fixedVisits.first?.arrivalMinute, 14 * 60)
    }

    func testCompilerRejectsFixedAppointmentOutsideTrip() {
        let intent = TripIntent(
            destination: .init(name: "成都"), days: 2,
            poiConstraints: [
                .init(mention: "博物馆", resolvedPOIID: "museum", requirement: .mustVisit,
                      assignedDay: 2, fixedArrivalMinute: 14 * 60),
            ]
        )
        XCTAssertThrowsError(try ConstraintCompiler.compile(intent)) { error in
            XCTAssertEqual((error as? PlanningConflict)?.code, .fixedVisitInfeasible)
        }
    }

    func testConstrainedModeHonorsAllowedModes() {
        let from = TestSupport.candidate("A", lat: 30.0, lng: 104.0)
        let to = TestSupport.candidate("B", lat: 30.01, lng: 104.01)
        let mode = ItineraryDayBuilder.constrainedMode(
            from: from, to: to, city: "510100", allowedModes: [.bus], maxWalkingMinutes: 5
        )
        XCTAssertEqual(mode, .bus)
    }

    func testPlanningSessionStoreRoundTripAndDelete() throws {
        let suite = "TripIntentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlanningSessionStore(defaults: defaults, key: "draft")
        let session = PlanningSession(intent: TripIntent(destination: .init(name: "成都")))

        try store.save(session)
        XCTAssertEqual(store.load(), session)
        store.delete()
        XCTAssertNil(store.load())
    }

    func testClarificationAsksMobilityQuestionForSeniorParty() {
        let intent = TripIntent(destination: .init(name: "成都"), party: .init(adults: 2, seniors: 2))
        let decision = ClarificationPolicy.evaluate(intent)
        XCTAssertFalse(decision.isReady)
        XCTAssertEqual(decision.question, .mobilityTaxiPermission)
    }

    func testRoundTripPreservesIntent() throws {
        let original = TripIntent(destination: .init(name: "成都"), days: 4,
                                  mobility: .init(maxWalkingMinutesPerSegment: 15),
                                  rawNotes: "不要太赶")
        let decoded = try JSONDecoder().decode(TripIntent.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
