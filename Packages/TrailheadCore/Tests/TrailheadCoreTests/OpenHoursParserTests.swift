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

    // MARK: - D2 周闭馆 / 星期覆盖

    func testWeeklyClosedMonday() {
        // 国内博物馆第一大真实失败源：周一闭馆。
        let s = OpenHoursParser.schedule("09:00-17:00，周一闭馆")
        XCTAssertEqual(s.weeklyClosed, [1])
        XCTAssertEqual(s.windows(on: 1)?.isEmpty, true)            // 周一 → 当日闭馆
        XCTAssertEqual(s.windows(on: 2)?.first?.open, 540)        // 周二 → base 窗
        XCTAssertEqual(s.windows(on: nil)?.first?.open, 540)      // 无日期 → 退化 base
    }

    func testWeeklyClosedVariants() {
        XCTAssertEqual(OpenHoursParser.schedule("每周三休息").weeklyClosed, [3])
        XCTAssertEqual(OpenHoursParser.schedule("逢周日不开放").weeklyClosed, [7])
        XCTAssertEqual(OpenHoursParser.schedule("星期二闭馆").weeklyClosed, [2])
    }

    func testWeeklyClosedRange() {
        // 「周一至周二闭馆」区间闭馆。
        XCTAssertEqual(OpenHoursParser.schedule("周一至周二闭馆;09:00-18:00").weeklyClosed, [1, 2])
    }

    func testWeekdayRangeOverride() {
        // 「周二至周日 09:00-17:00」：命中日取覆盖窗；周一无覆盖退回 base（保守不误杀）。
        let s = OpenHoursParser.schedule("周二至周日 09:00-17:00")
        for d in 2...7 {
            XCTAssertEqual(s.windows(on: d)?.first?.open, 540, "weekday \(d)")
            XCTAssertEqual(s.windows(on: d)?.first?.close, 1020, "weekday \(d)")
        }
        XCTAssertEqual(s.windows(on: nil)?.first?.open, 540)      // 无日期 → base 语义
    }

    func testMuseumTypicalString() {
        // 典型博物馆串：覆盖 + 显式周闭馆同现。
        let s = OpenHoursParser.schedule("周二至周日09:00-17:00(16:00停止入馆)，周一闭馆")
        XCTAssertEqual(s.windows(on: 1)?.isEmpty, true)
        XCTAssertEqual(s.windows(on: 3)?.first?.close, 1020)
    }

    func testSingleWeekdayOverride() {
        let s = OpenHoursParser.schedule("09:00-17:00；周六 10:00-16:00")
        XCTAssertEqual(s.windows(on: 6)?.first?.open, 600)
        XCTAssertEqual(s.windows(on: 6)?.first?.close, 960)
        XCTAssertEqual(s.windows(on: 4)?.first?.open, 540)        // 非覆盖日走 base
    }

    func testWeekdayPatternFailureDegradesToBase() {
        // 周闭馆模式解析不了 → 静默降级为 base，绝不引入新的误杀面。
        let s = OpenHoursParser.schedule("每逢农历初一闭馆 09:00-17:00")
        XCTAssertTrue(s.weeklyClosed.isEmpty)
        XCTAssertEqual(s.windows(on: 1)?.first?.open, 540)
    }

    func testUnknownScheduleReturnsNilWindows() {
        let s = OpenHoursParser.schedule("营业中")
        XCTAssertNil(s.base)
        XCTAssertNil(s.windows(on: 1))                             // 未知 → 下游不过滤
    }
}
