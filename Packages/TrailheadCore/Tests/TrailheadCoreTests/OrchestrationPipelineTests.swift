//  OrchestrationPipelineTests.swift
//  P8.2 端到端回归：确定性几何编排（planStops）整链 + P6.3 跨水段回填。
//  日内时间单调、营业窗内、空间成团分天、景点不丢、无空天、短距跨水不误判步行。

import Foundation
@testable import TrailheadCore
import XCTest

/// P6.3 桩数据源：步行路线可配置为「严重绕行」或「直接失败」，模拟跨水（轮渡）场景。
private final class CrossWaterSpySource: POIDataSource {
    var walkMeters = 6000            // 步行路网距离（>3× 直线即触发回填）
    var walkFails = false
    private(set) var requestedModes: [TransitMode] = []

    func geocodeCity(_ name: String) async throws -> (adcode: String, center: (Double, Double)) {
        ("350200", (24.44, 118.08))
    }
    func searchPOI(adcode: String, tags: [String]) async throws -> [POICandidate] { [] }
    func route(from: POICandidate, to: POICandidate,
               mode: TransitMode, city: String) async throws -> (minutes: Int, meters: Int, cost: Int?) {
        requestedModes.append(mode)
        if mode == .walk {
            if walkFails { throw URLError(.badServerResponse) }
            return (75, walkMeters, nil)
        }
        return (12, 3200, 8)
    }
}

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

    // MARK: - P6.3 短距跨水回填（A1：不抬 1500m 阈值；已配置离岛由 WaterGate 判轮渡，
    // 本组覆盖**未配置进 WaterGate** 的跨水段——由 routedSegment 真实路线回填兜底。
    // 坐标刻意取 WaterGate.regions 之外（长江口某处），mode() 初判仍为步行。

    @MainActor
    func testShortCrossWaterSegmentBackfillsToNonWalk() async {
        // 未配置离岛的短距跨水：直线 ~700m 初判步行，但步行路网 6km（>3× 直线）→ 回填驾车段。
        let ferry = sight("ferry", 31.3900, 121.5000)
        let island = sight("island", 31.3900, 121.5074)
        let source = CrossWaterSpySource()
        let stops = [PlannedStop(candidate: ferry, time: "09:00", stayMin: 60, note: nil),
                     PlannedStop(candidate: island, time: "10:30", stayMin: 90, note: nil)]

        let items = await ItineraryDayBuilder.buildItems(from: stops, source: source, city: "")
        let transit = items.first { $0.kind == .transit }
        XCTAssertEqual(transit?.transitMode, .drive)                     // 不再误判步行
        XCTAssertEqual(transit?.transitMeters, 3200)                     // 用回填段的真实数据
        XCTAssertEqual(source.requestedModes, [.walk, .drive])           // 先试步行、再回填
    }

    @MainActor
    func testWalkRouteFailureBackfillsToNonWalk() async {
        // 步行路线请求失败（水域不可达）→ 同样回填非步行，不丢交通段。
        let ferry = sight("ferry", 31.3900, 121.5000)
        let island = sight("island", 31.3900, 121.5074)
        let source = CrossWaterSpySource()
        source.walkFails = true
        let stops = [PlannedStop(candidate: ferry, time: "09:00", stayMin: 60, note: nil),
                     PlannedStop(candidate: island, time: "10:30", stayMin: 90, note: nil)]

        let items = await ItineraryDayBuilder.buildItems(from: stops, source: source, city: "")
        XCTAssertEqual(items.first { $0.kind == .transit }?.transitMode, .drive)
    }

    @MainActor
    func testNormalWalkSegmentStaysWalk() async {
        // 对照组：步行路网未超 3× 直线 → 保持步行（阈值语义不变，无过度回填）。
        let a = sight("a", 31.3900, 121.5000)
        let b = sight("b", 31.3900, 121.5074)
        let source = CrossWaterSpySource()
        source.walkMeters = 900                                           // ~1.3× 直线
        let stops = [PlannedStop(candidate: a, time: "09:00", stayMin: 60, note: nil),
                     PlannedStop(candidate: b, time: "10:30", stayMin: 90, note: nil)]

        let items = await ItineraryDayBuilder.buildItems(from: stops, source: source, city: "")
        XCTAssertEqual(items.first { $0.kind == .transit }?.transitMode, .walk)
        XCTAssertEqual(source.requestedModes, [.walk])                    // 未触发第二次请求
    }

    @MainActor
    func testConfiguredIslandCrossingUsesFerryDirectly() async {
        // 已配置离岛（鼓浪屿）：WaterGate 命中 → mode() 直接判轮渡，不走步行试探。
        let wharf = sight("wharf", 24.4460, 118.0820)                    // 本岛轮渡码头（圈外）
        let island = sight("gulangyu", 24.4470, 118.0670)                // 鼓浪屿岛心（圈内）
        let source = CrossWaterSpySource()
        let stops = [PlannedStop(candidate: wharf, time: "09:00", stayMin: 60, note: nil),
                     PlannedStop(candidate: island, time: "10:30", stayMin: 90, note: nil)]

        let items = await ItineraryDayBuilder.buildItems(from: stops, source: source, city: "")
        XCTAssertEqual(items.first { $0.kind == .transit }?.transitMode, .ferry)
        XCTAssertEqual(source.requestedModes, [.ferry])
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

    // MARK: - P8.2 v2：周一闭馆重插 / 确定性 golden diff

    func testMondayClosedMuseumReinsertedToTuesdayEndToEnd() async throws {
        // D2+D3 端到端：行程从周一（2026-07-06）出发，招牌博物馆「周一闭馆」落在周一簇 →
        // 被模拟器判不可行进 spill → SpillRepair 重插到周二，**不静默丢失**。
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 6
        let monday = Calendar.current.date(from: comps)!
        let museum = POICandidate(id: "museum", name: "博物馆", kind: .sight, subtype: "博物馆",
                                  lat: 24.4470, lng: 118.0810, rating: 5.0,
                                  openHours: "09:00-17:00，周一闭馆")
        let pool = [
            sight("s1", 24.4460, 118.0800), sight("s3", 24.4450, 118.0830), museum,   // 西南簇（周一）
            sight("s4", 24.4850, 118.1500), sight("s5", 24.4870, 118.1520),
            sight("s6", 24.4840, 118.1480),                                           // 东北簇（周二）
            food("f1", 24.4470, 118.0810, 4.6), food("f2", 24.4860, 118.1500, 4.7),
        ]

        let perDay = try await ItineraryDayBuilder.planStops(
            prefs: TripPrefs(pace: .relaxed), candidates: pool, days: 2,
            llm: StubLLMProvider(), startDate: monday)

        let allIDs = perDay.flatMap { $0 }.map(\.candidate.id)
        XCTAssertEqual(allIDs.filter { $0 == "museum" }.count, 1)          // 不丢失、不重复
        XCTAssertFalse(perDay[0].contains { $0.candidate.id == "museum" }) // 不在周一
        XCTAssertTrue(perDay[1].contains { $0.candidate.id == "museum" })  // 重插到周二

        // 周二到达在营业窗内（09:00–17:00）。
        guard let stop = perDay[1].first(where: { $0.candidate.id == "museum" }),
              let arrival = minutes(stop.time) else { return XCTFail("博物馆应有时刻") }
        XCTAssertTrue(arrival >= 9 * 60 && arrival <= 17 * 60)
    }

    func testPipelineDeterministicFieldByField() async throws {
        // D6 确定性门：同输入重跑整条流水线，输出逐字段一致（[[PlannedStop]] Equatable diff）。
        // 本文件的厦门候选集即离线 golden fixture（固化在代码中，回归可逐字段对比）。
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 6
        let monday = Calendar.current.date(from: comps)!
        let first = try await ItineraryDayBuilder.planStops(
            prefs: TripPrefs(pace: .relaxed), candidates: candidates, days: 2,
            llm: StubLLMProvider(), startDate: monday)
        let second = try await ItineraryDayBuilder.planStops(
            prefs: TripPrefs(pace: .relaxed), candidates: candidates, days: 2,
            llm: StubLLMProvider(), startDate: monday)
        XCTAssertEqual(first, second)
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
