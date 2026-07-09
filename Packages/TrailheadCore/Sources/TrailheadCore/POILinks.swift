//  POILinks.swift
//  美食/住宿卡片的外链构造（纯函数，便于单测）。高德本身没有用户点评正文，
//  真实点评/更多图片走外链：高德网页版 POI 详情页 + 小红书关键词搜索。

import Foundation

public enum POILinks {
    /// 高德网页版 POI 详情页（含图片与用户点评）。
    public static func amapDetail(poiId: String) -> URL? {
        guard !poiId.isEmpty else { return nil }
        return URL(string: "https://www.amap.com/detail/\(poiId)")
    }

    /// 小红书搜索「店名 城市」，看真实点评与图片。
    public static func xiaohongshuSearch(name: String, city: String = "") -> URL? {
        let keyword = city.isEmpty ? name : "\(name) \(city)"
        guard !keyword.isEmpty,
              let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://www.xiaohongshu.com/search_result?keyword=\(q)")
    }

    /// 高德图片 URL 多为 http，ATS 只放行 https —— 升级 scheme 后再交给 AsyncImage。
    public static func httpsPhotoURL(_ raw: String) -> URL? {
        guard var comps = URLComponents(string: raw), comps.host != nil else { return nil }
        if comps.scheme == "http" { comps.scheme = "https" }
        return comps.url
    }
}
