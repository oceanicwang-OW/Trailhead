//  OrchestrationPipelineTests.swift
//  P8.2 端到端回归：确定性几何编排（planStops）整链。厦门本岛用例（不涉跨海——见 README
//  「已知限制」P6.3）：日内时间单调、营业窗内、空间成团分天、景点不丢、无空天。

import Foundation
@testable import TrailheadCore
import XCTest

final class OrchestrationPipelineTests: XCTestCase {

    private func sight(_ id: String, _ lat: Double, _ lng: Double, openHours: String? = nil) -> POICandidate {
        POICandidate(id: id, name: id, kind: .sight, subtype: "", lat: lat, lng: lng,
                     rating: 4.5, openHours: openHours)
    }

    private func food(_ id: String, _ lat: Double, _ lng: Double, _ rating: Double) -> POICandidate {
        POICandidate(id: id, name: id, kind: .food, subtype: "", lat: lat, lng: lng, rating: rating)
    }

    // 两个明显分离的地理团（厦门本岛西南 vs 东北），无跨海段。
    private var candidates: [POICandidate] {
        [
            sight("s1", 24.4460, 118.0800),
            sight("s2", 24.4480, 118.0820, openHours: "09:00-17:00"),
            sight("s3", 24.4450, 118.0830),
            sight("s4", 24.4850, 118.1500),
            sight("s5", 24.4870, 118.1520),
            sight("s6", 24.4840, 118.1480),
            food("f1", 24.4470, 118.0810, 4.6),
            food("f2", 24.4860, 118.1500, 4.7),
        ]
    }

    private func minutes(_ time: String?) -> Int? { ItineraryFeasibility.minutes(from: time) }

    func testTwoDayPipelineIsFeasibleAndClustered() async throws {
        let perDay = try await ItineraryDayBuilder.planStops(
            prefs: TripPrefs(pace: .relaxed), candidates: candidates, days: 2, llm: StubLLMProvider())

        XCTAssertEqual(perDay.count, 2)
        XCTAssertTrue(perDay.allSatisfy { !$0.isEmpty })                 // 无空天

        let inputIDs = Set(candidates.map(\.id))
        for day in perDay {
            // 每个停留都来自候选（无幻觉）。
            XCTAssertTrue(day.allSatisfy { inputIDs.contains($0.candidate.id) })
            // 日内时间严格递增。
            let times = day.compactMap { minutes($0.time) }
            XCTAssertEqual(times, times.sorted())
            XCTAssertEqual(Set(times).count, times.count)
            // 每日景点数 ≤ 上限（relaxed=4）。
            XCTAssertLessThanOrEqual(day.filter { $0.candidate.kind == .sight }.count, 4)
        }

        // 营业窗：s2（09:00-17:00）到达在窗内。
        if let s2 = perDay.flatMap({ $0 }).first(where: { $0.candidate.id == "s2" }),
           let arrival = minutes(s2.time) {
            XCTAssertTrue(arrival >= 9 * 60 && arrival <= 17 * 60)
        } else {
            XCTFail("s2 应在行程中")
        }

        // 全部景点不丢。
        let sightIDs = Set(perDay.flatMap { $0 }.map(\.candidate.id)).intersection(["s1", "s2", "s3", "s4", "s5", "s6"])
        XCTAssertEqual(sightIDs, ["s1", "s2", "s3", "s4", "s5", "s6"])

        // 空间成团：同团三点落在同一天（两团分处不同天）。
        let daySightSets = perDay.map { Set($0.filter { $0.candidate.kind == .sight }.map(\.candidate.id)) }
        XCTAssertTrue(daySightSets.contains(["s1", "s2", "s3"]))
        XCTAssertTrue(daySightSets.contains(["s4", "s5", "s6"]))
    }

    func testWeekdayMappingMondayFirst() {
        // 2026-07-06 为周一：Apple weekday（1=周日）→ PDR 约定（1=周一…7=周日）。
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 6
        let monday = Calendar.current.date(from: comps)!
        XCTAssertEqual(ItineraryDayBuilder.weekday(of: monday, dayOffset: 0), 1)
        XCTAssertEqual(ItineraryDayBuilder.weekday(of: monday, dayOffset: 5), 6)
        XCTAssertEqual(ItineraryDayBuilder.weekday(of: monday, dayOffset: 6), 7)
        XCTAssertNil(ItineraryDayBuilder.weekday(of: nil, dayOffset: 0))       // 无日期 → nil
    }

    func testSingleDayRegenerationPacksAllIntoOneDay() async throws {
        // days==1（单日重生成）跳过分天：同团候选全进当天、时间单调。
        let oneCluster = [
            sight("s1", 24.4460, 118.0800),
            sight("s2", 24.4480, 118.0820),
            food("f1", 24.4470, 118.0810, 4.6),
        ]
        let perDay = try await ItineraryDayBuilder.planStops(
            prefs: TripPrefs(pace: .relaxed), candidates: oneCluster, days: 1, llm: StubLLMProvider())

        XCTAssertEqual(perDay.count, 1)
        let ids = perDay[0].map(\.candidate.id)
        XCTAssertEqual(Set(ids).intersection(["s1", "s2"]), ["s1", "s2"])   // 两景点都在
        let times = perDay[0].compactMap { minutes($0.time) }
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(perDay[0].first?.time, "09:00")                       // 首点从 dayStart 起
    }
}
