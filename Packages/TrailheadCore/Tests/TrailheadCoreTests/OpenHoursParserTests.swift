//  OpenHoursParserTests.swift
//  营业时间解析（PDR §4.3）：脏数据容错，失败/缺失一律 nil（下游不过滤，绝不误杀招牌）。

import Foundation
@testable import TrailheadCore
import XCTest

final class OpenHoursParserTests: XCTestCase {

    func testNilInputReturnsNil() {
        XCTAssertNil(OpenHoursParser.parse(nil))
    }

    func testEmptyOrWhitespaceReturnsNil() {
        XCTAssertNil(OpenHoursParser.parse(""))
        XCTAssertNil(OpenHoursParser.parse("   "))
    }

    func testGarbageWithoutTimeReturnsNil() {
        XCTAssertNil(OpenHoursParser.parse("营业中"))
    }

    func testSingleWindow() {
        let out = OpenHoursParser.parse("09:00-17:00")
        XCTAssertEqual(out?.count, 1)
        XCTAssertEqual(out?.first?.open, 9 * 60)
        XCTAssertEqual(out?.first?.close, 17 * 60)
    }

    func testMultipleSegments() {
        // 午休闭馆：两段，分隔符任意。
        let out = OpenHoursParser.parse("09:00-12:00;14:00-17:30")
        XCTAssertEqual(out?.count, 2)
        XCTAssertEqual(out?[0].open, 540)
        XCTAssertEqual(out?[0].close, 720)
        XCTAssertEqual(out?[1].open, 840)
        XCTAssertEqual(out?[1].close, 1050)
    }

    func testAllDayKeyword() {
        XCTAssertEqual(OpenHoursParser.parse("全天")?.first.map { [$0.open, $0.close] }, [0, 1440])
    }

    func test24HourKeyword() {
        XCTAssertEqual(OpenHoursParser.parse("24小时营业")?.first.map { [$0.open, $0.close] }, [0, 1440])
    }

    func testCrossMidnightTreatedAsAllDay() {
        // 跨夜（close<open，如酒吧 22:00-02:00）→ 视为全天，不据此过滤。
        XCTAssertEqual(OpenHoursParser.parse("22:00-02:00")?.first.map { [$0.open, $0.close] }, [0, 1440])
    }

    func testCloseAt24() {
        let out = OpenHoursParser.parse("09:00-24:00")
        XCTAssertEqual(out?.first?.open, 540)
        XCTAssertEqual(out?.first?.close, 1440)
    }
}
