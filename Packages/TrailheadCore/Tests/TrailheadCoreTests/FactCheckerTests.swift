//  FactCheckerTests.swift
//  PDR T3.4：剔除非候选 poi_id；候选字段为事实来源；按天排序。

import Foundation
@testable import TrailheadCore
import XCTest

final class FactCheckerTests: XCTestCase {

    private func plan(_ json: String) throws -> ItineraryPlan {
        try ItineraryParser.parse(Data(json.utf8))
    }

    func testDropsHallucinatedPOIID() throws {
        let candidates = [TestSupport.candidate("A"), TestSupport.candidate("B")]
        let p = try plan(#"{"days":[{"day":1,"items":[{"poi_id":"A"},{"poi_id":"GHOST"},{"poi_id":"B"}]}]}"#)

        let perDay = FactChecker.reconcile(p, candidates: candidates)
        XCTAssertEqual(perDay.count, 1)
        XCTAssertEqual(perDay[0].map(\.candidate.id), ["A", "B"])   // GHOST 被剔除
    }

    func testBackfillsFromCandidateNotLLM() throws {
        let real = TestSupport.candidate("A", name: "故宫", lat: 39.918, lng: 116.397)
        let p = try plan(#"{"days":[{"day":1,"items":[{"poi_id":"A","note":"建议早到"}]}]}"#)

        let stop = try XCTUnwrap(FactChecker.reconcile(p, candidates: [real]).first?.first)
        XCTAssertEqual(stop.candidate.name, "故宫")        // 名称以候选为准
        XCTAssertEqual(stop.candidate.lat, 39.918)         // 坐标以候选为准
        XCTAssertEqual(stop.note, "建议早到")               // 贴士来自 LLM
    }

    func testSortsByDay() throws {
        let candidates = [TestSupport.candidate("A"), TestSupport.candidate("B")]
        let p = try plan(#"{"days":[{"day":2,"items":[{"poi_id":"B"}]},{"day":1,"items":[{"poi_id":"A"}]}]}"#)

        let perDay = FactChecker.reconcile(p, candidates: candidates)
        XCTAssertEqual(perDay.map { $0.map(\.candidate.id) }, [["A"], ["B"]])   // day1 在前
    }
}
