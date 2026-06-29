//  PromptBuilderTests.swift
//  PDR T3.2：prompt 含全部硬规则 + 候选 poi_id + 偏好。

import Foundation
@testable import TrailheadCore
import XCTest

final class PromptBuilderTests: XCTestCase {

    func testMessagesAreSystemThenUser() {
        let messages = PromptBuilder.itineraryMessages(
            prefs: TripPrefs(tags: ["美食"]), candidates: [TestSupport.candidate("A")], days: 3)
        XCTAssertEqual(messages.map(\.role), [.system, .user])
    }

    func testSystemPromptCarriesHardRules() {
        let system = PromptBuilder.systemPrompt(days: 4)
        XCTAssertTrue(system.contains("poi_id"))       // 只能引用候选 id
        XCTAssertTrue(system.contains("4"))            // 天数
        XCTAssertTrue(system.contains("JSON"))         // 严格 JSON
        XCTAssertTrue(system.contains("饭点"))          // 餐饮卡饭点
    }

    func testUserPromptListsCandidatesAndPrefs() {
        let prefs = TripPrefs(tags: ["美食", "历史古迹"], pace: .relaxed, budgetPerDay: 600)
        let user = PromptBuilder.userPrompt(
            prefs: prefs, candidates: [TestSupport.candidate("B0FFG", name: "故宫")], days: 2)
        XCTAssertTrue(user.contains("poi_id=B0FFG"))   // 候选 id 列出
        XCTAssertTrue(user.contains("故宫"))
        XCTAssertTrue(user.contains("美食"))            // 偏好标签
        XCTAssertTrue(user.contains("600"))            // 预算
    }

    func testUserPromptRanksHigherRatedFirst() {
        let low = POICandidate(id: "LOW", name: "无名小点", kind: .sight, subtype: "", lat: 24.4, lng: 118.0, rating: 3.2)
        let high = POICandidate(id: "HIGH", name: "鼓浪屿", kind: .sight, subtype: "", lat: 24.4, lng: 118.0, rating: 4.9)
        let user = PromptBuilder.userPrompt(prefs: TripPrefs(), candidates: [low, high], days: 2)
        let hiPos = try! XCTUnwrap(user.range(of: "poi_id=HIGH")).lowerBound
        let loPos = try! XCTUnwrap(user.range(of: "poi_id=LOW")).lowerBound
        XCTAssertTrue(hiPos < loPos)                   // 高评分排在前
    }
}
