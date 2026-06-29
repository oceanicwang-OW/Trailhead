//  TripPrefsTests.swift
//  新增 cuisines/lodgingType 后，老 prefsData（无这些键）仍能解码、不丢旧偏好。

import Foundation
@testable import TrailheadCore
import XCTest

final class TripPrefsTests: XCTestCase {

    func testDecodesLegacyPayloadWithoutNewFields() throws {
        // 模拟旧版本写入的 JSON（没有 cuisines / lodgingType）。
        let legacy = #"{"tags":["美食"],"pace":"relaxed","budgetPerDay":800,"freeText":"想去鼓浪屿"}"#
        let prefs = try JSONDecoder().decode(TripPrefs.self, from: Data(legacy.utf8))

        XCTAssertEqual(prefs.tags, ["美食"])           // 旧字段不丢
        XCTAssertEqual(prefs.budgetPerDay, 800)
        XCTAssertEqual(prefs.freeText, "想去鼓浪屿")
        XCTAssertEqual(prefs.cuisines, [])             // 新字段取默认
        XCTAssertEqual(prefs.lodgingType, "")
    }

    func testRoundTripsNewFields() throws {
        var prefs = TripPrefs(tags: ["美食"])
        prefs.cuisines = ["海鲜", "火锅"]
        prefs.lodgingType = "民宿"
        let data = try JSONEncoder().encode(prefs)
        let back = try JSONDecoder().decode(TripPrefs.self, from: data)
        XCTAssertEqual(back.cuisines, ["海鲜", "火锅"])
        XCTAssertEqual(back.lodgingType, "民宿")
    }
}
