//  NoteWriterTests.swift
//  P7.1 LLM 补文案（PDR §8 P7）：note + 每日主题；越界忽略、畸形留空、失败降级不抛错。

import Foundation
@testable import TrailheadCore
import XCTest

final class NoteWriterTests: XCTestCase {

    // 返回固定 JSON 的假 LLM；json 为 nil 则抛错（模拟 LLM 失败）。
    private struct FakeLLM: LLMProvider {
        let json: String?
        func planItinerary(prefs: TripPrefs, candidates: [POICandidate], days: Int) async throws -> Data { Data() }
        func annotateNotes(prefs: TripPrefs, stops: [[PlannedStop]]) async throws -> Data {
            guard let json else { throw LLMError.emptyResponse }
            return Data(json.utf8)
        }
    }

    private func stop(_ id: String) -> PlannedStop {
        PlannedStop(candidate: POICandidate(id: id, name: id, kind: .sight, subtype: "", lat: 0, lng: 0),
                    time: "09:00", stayMin: 60, note: nil)
    }

    // 两天，每天两个点。
    private var stops: [[PlannedStop]] { [[stop("A"), stop("B")], [stop("C"), stop("D")]] }

    private func annotate(_ json: String?) async -> NoteWriter.Annotated {
        await NoteWriter.annotate(stops: stops, prefs: TripPrefs(), llm: FakeLLM(json: json))
    }

    func testHappyPathAppliesNotesAndThemes() async {
        let out = await annotate(#"""
        { "days": [
          { "day": 1, "theme": "老城漫步", "notes": [ {"poi_id":"A","note":"建议早到"}, {"poi_id":"B","note":"看夕阳"} ] },
          { "day": 2, "theme": "海岛慢行", "notes": [ {"poi_id":"C","note":"必点小吃"} ] }
        ] }
        """#)
        XCTAssertEqual(out.themes, ["老城漫步", "海岛慢行"])
        XCTAssertEqual(out.stops[0].map(\.note), ["建议早到", "看夕阳"])
        XCTAssertEqual(out.stops[1].map(\.note), ["必点小吃", nil])   // D 无文案 → 留空
    }

    func testUnknownPoiIdIgnored() async {
        let out = await annotate(#"""
        { "days": [ { "day": 1, "notes": [ {"poi_id":"ZZZ","note":"不存在"}, {"poi_id":"A","note":"有效"} ] } ] }
        """#)
        XCTAssertEqual(out.stops[0].map(\.note), ["有效", nil])   // 未知 id 被忽略，不误伤 A
    }

    func testCrossDayPoiIdNotApplied() async {
        // 把 C（第2天的点）塞进第1天的 notes：只在其所属天匹配，第1天不受影响。
        let out = await annotate(#"""
        { "days": [ { "day": 1, "notes": [ {"poi_id":"C","note":"串天"} ] } ] }
        """#)
        XCTAssertEqual(out.stops[0].map(\.note), [nil, nil])
        XCTAssertEqual(out.stops[1].map(\.note), [nil, nil])
    }

    func testOutOfRangeDayIgnored() async {
        let out = await annotate(#"""
        { "days": [ { "day": 9, "theme": "越界", "notes": [ {"poi_id":"A","note":"x"} ] } ] }
        """#)
        XCTAssertEqual(out.themes, [nil, nil])
        XCTAssertEqual(out.stops[0].map(\.note), [nil, nil])
    }

    func testBlankNoteAndThemeTreatedAsEmpty() async {
        let out = await annotate(#"""
        { "days": [ { "day": 1, "theme": "   ", "notes": [ {"poi_id":"A","note":"  "} ] } ] }
        """#)
        XCTAssertEqual(out.themes[0], nil)
        XCTAssertEqual(out.stops[0][0].note, nil)
    }

    func testMalformedJsonDegradesToInput() async {
        let out = await annotate("这不是 JSON")
        XCTAssertEqual(out.themes, [nil, nil])
        XCTAssertEqual(out.stops, stops)   // 原样返回
    }

    func testLLMErrorDegradesToInput() async {
        let out = await annotate(nil)   // annotateNotes 抛错
        XCTAssertEqual(out.themes, [nil, nil])
        XCTAssertEqual(out.stops, stops)
    }

    func testFencedJsonParsed() async {
        let out = await annotate("```json\n{ \"days\": [ { \"day\": 1, \"theme\": \"围栏\" } ] }\n```")
        XCTAssertEqual(out.themes[0], "围栏")   // 复用 ItineraryParser.stripFences
    }

    func testEmptyStopsShortCircuits() async {
        let out = await NoteWriter.annotate(stops: [], prefs: TripPrefs(), llm: FakeLLM(json: "{}"))
        XCTAssertTrue(out.stops.isEmpty)
        XCTAssertTrue(out.themes.isEmpty)
    }
}
