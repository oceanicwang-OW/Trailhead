//  POIKeywordExtractorTests.swift
//  从 freeText 抽取地点关键词：剥意向词、按分隔符切、去重去停用词、限量。

import Foundation
@testable import TrailheadCore
import XCTest

final class POIKeywordExtractorTests: XCTestCase {

    func testStripsLeadingIntentVerb() {
        XCTAssertEqual(POIKeywordExtractor.keywords(from: "我想去鼓浪屿"), ["鼓浪屿"])
        XCTAssertEqual(POIKeywordExtractor.keywords(from: "想去厦门大学"), ["厦门大学"])
    }

    func testSplitsOnSeparators() {
        XCTAssertEqual(POIKeywordExtractor.keywords(from: "鼓浪屿、厦门大学，南普陀寺"),
                       ["鼓浪屿", "厦门大学", "南普陀寺"])
    }

    func testDropsStopwordsAndTooShort() {
        // 「我」「去」是停用词，单字 token 也被滤掉。
        XCTAssertEqual(POIKeywordExtractor.keywords(from: "我 去 鼓浪屿"), ["鼓浪屿"])
    }

    func testDedupesAndCapsAtMax() {
        let many = (1...8).map { "地点\($0)" }.joined(separator: "、") + "、鼓浪屿、鼓浪屿"
        let result = POIKeywordExtractor.keywords(from: many)
        XCTAssertEqual(result.count, POIKeywordExtractor.maxKeywords)   // 限量
        XCTAssertEqual(Set(result).count, result.count)                // 去重
    }

    func testEmptyFreeTextYieldsNoKeywords() {
        XCTAssertTrue(POIKeywordExtractor.keywords(from: "").isEmpty)
        XCTAssertTrue(POIKeywordExtractor.keywords(from: "   ").isEmpty)
    }
}
