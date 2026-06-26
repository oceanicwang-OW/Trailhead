//  QuotaStateTests.swift
//  PDR T8.2：配额耗尽标记当天有效、次日失效、可清除。

import Foundation
@testable import TrailheadCore
import XCTest

final class QuotaStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "quota-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testMarkAndCheckSameDay() {
        let state = QuotaState(defaults: defaults)
        XCTAssertFalse(state.isExhausted())
        state.markExhausted()
        XCTAssertTrue(state.isExhausted())
    }

    func testExpiresNextDay() {
        let state = QuotaState(defaults: defaults)
        let today = Date()
        state.markExhausted(on: today)
        XCTAssertFalse(state.isExhausted(on: today.addingTimeInterval(24 * 60 * 60)))
    }

    func testClear() {
        let state = QuotaState(defaults: defaults)
        state.markExhausted()
        state.clear()
        XCTAssertFalse(state.isExhausted())
    }
}
