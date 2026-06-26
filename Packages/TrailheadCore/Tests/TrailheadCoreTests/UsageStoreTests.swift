//  UsageStoreTests.swift
//  PDR T7.2：按 provider + 天 计数。

import Foundation
@testable import TrailheadCore
import XCTest

final class UsageStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "usage-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testRecordAccumulates() {
        let store = UsageStore(defaults: defaults)
        XCTAssertEqual(store.count(.amap), 0)
        store.record(.amap)
        store.record(.amap, count: 3)
        XCTAssertEqual(store.count(.amap), 4)
    }

    func testProvidersAreIsolated() {
        let store = UsageStore(defaults: defaults)
        store.record(.amap, count: 5)
        store.record(.llm, count: 2)
        XCTAssertEqual(store.count(.amap), 5)
        XCTAssertEqual(store.count(.llm), 2)
    }

    func testDaysAreIsolated() {
        let store = UsageStore(defaults: defaults)
        let today = Date()
        let yesterday = today.addingTimeInterval(-24 * 60 * 60)
        store.record(.amap, count: 7, on: today)
        XCTAssertEqual(store.count(.amap, on: today), 7)
        XCTAssertEqual(store.count(.amap, on: yesterday), 0)   // 次日清零
    }
}
