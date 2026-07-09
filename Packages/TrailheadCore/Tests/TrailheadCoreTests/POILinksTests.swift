//  POILinksTests.swift
//  外链构造：高德详情页 / 小红书搜索（中文需转义）/ 图片 URL http→https 升级。

import Foundation
@testable import TrailheadCore
import XCTest

final class POILinksTests: XCTestCase {

    func testAmapDetail() {
        XCTAssertEqual(POILinks.amapDetail(poiId: "B0FFG")?.absoluteString,
                       "https://www.amap.com/detail/B0FFG")
        XCTAssertNil(POILinks.amapDetail(poiId: ""))
    }

    func testXiaohongshuSearchEncodesChineseKeyword() throws {
        let url = try XCTUnwrap(POILinks.xiaohongshuSearch(name: "老店 大排档", city: "厦门"))
        XCTAssertEqual(url.host, "www.xiaohongshu.com")
        XCTAssertEqual(url.path, "/search_result")
        // 中文与空格已转义，无非法字符。
        XCTAssertFalse(url.absoluteString.contains(" "))
        XCTAssertTrue(url.absoluteString.contains("keyword="))

        XCTAssertNil(POILinks.xiaohongshuSearch(name: "", city: ""))
        // 无城市时只搜店名。
        XCTAssertNotNil(POILinks.xiaohongshuSearch(name: "老店"))
    }

    func testHttpsPhotoURLUpgradesScheme() {
        XCTAssertEqual(POILinks.httpsPhotoURL("http://store.is.autonavi.com/showpic/a.jpg")?.absoluteString,
                       "https://store.is.autonavi.com/showpic/a.jpg")
        XCTAssertEqual(POILinks.httpsPhotoURL("https://aos-comment.amap.com/b.jpg")?.absoluteString,
                       "https://aos-comment.amap.com/b.jpg")   // 已是 https 原样
        XCTAssertNil(POILinks.httpsPhotoURL("not a url"))
        XCTAssertNil(POILinks.httpsPhotoURL(""))
    }
}
