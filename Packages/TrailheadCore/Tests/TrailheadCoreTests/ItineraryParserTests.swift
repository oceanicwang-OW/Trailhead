//  ItineraryParserTests.swift
//  PDR T3.3：JSON 解析（含围栏容错）+ 失败抛错。

import Foundation
@testable import TrailheadCore
import XCTest

final class ItineraryParserTests: XCTestCase {

    func testParsesValidPlan() throws {
        let json = #"{"days":[{"day":1,"items":[{"poi_id":"A","time":"09:00","stay_min":90,"note":"早到"}]}]}"#
        let plan = try ItineraryParser.parse(Data(json.utf8))
        XCTAssertEqual(plan.days.count, 1)
        let stop = try XCTUnwrap(plan.days.first?.items.first)
        XCTAssertEqual(stop.poiId, "A")
        XCTAssertEqual(stop.time, "09:00")
        XCTAssertEqual(stop.stayMin, 90)
        XCTAssertEqual(stop.note, "早到")
    }

    func testToleratesMissingOptionalFields() throws {
        let plan = try ItineraryParser.parse(Data(#"{"days":[{"day":1,"items":[{"poi_id":"A"}]}]}"#.utf8))
        let stop = try XCTUnwrap(plan.days.first?.items.first)
        XCTAssertEqual(stop.poiId, "A")
        XCTAssertNil(stop.time)
        XCTAssertNil(stop.stayMin)
    }

    func testStripsCodeFences() throws {
        let fenced = "```json\n{\"days\":[{\"day\":1,\"items\":[]}]}\n```"
        let plan = try ItineraryParser.parse(Data(fenced.utf8))
        XCTAssertEqual(plan.days.count, 1)
    }

    func testThrowsOnBadJSON() {
        XCTAssertThrowsError(try ItineraryParser.parse(Data("not json".utf8))) { error in
            guard case LLMError.decoding = error else { return XCTFail("expected .decoding, got \(error)") }
        }
    }
}
