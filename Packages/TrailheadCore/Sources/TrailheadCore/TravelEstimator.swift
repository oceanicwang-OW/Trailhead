//  TravelEstimator.swift
//  行段时间估算（PDR §4.7 / §5）。haversine × 模式速度 → 分钟，仅用于**排序与卡点**的时间估算，
//  非最终展示（展示仍走真实 source.route）。每段模式复用同一 ItineraryDayBuilder.mode()，
//  避免估时与展示两套逻辑各判各的（B4）；mode() 的水域兜底（P6.3）已落地，跨海段自动走轮渡档。纯函数。

import Foundation

public enum TravelEstimator {
    /// 各模式速度档（km/h，可配）：步行 5 / 公交·地铁 18 / 驾车·出租 30 / 列车 60 / 轮渡 12。
    /// 轮渡按航速粗估，未计候船与登离船耗时（P6.3 已知限制，短跨海整体偏乐观，后续可加固定卡点）。
    public static func speedKmh(for mode: TransitMode) -> Double {
        switch mode {
        case .walk:          return 5
        case .bus, .metro:   return 18
        case .drive, .taxi:  return 30
        case .train:         return 60
        case .ferry:         return 12
        }
    }

    /// 估算两点间行段用时（分钟，四舍五入）。`city` 为城市 adcode（决定远途走公交/驾车）。
    public static func minutes(from: POICandidate, to: POICandidate, city: String) -> Int {
        let mode = ItineraryDayBuilder.mode(from: from, to: to, city: city)
        let meters = ItineraryDayBuilder.haversineMeters(from, to)
        let metersPerMinute = speedKmh(for: mode) * 1000 / 60
        guard metersPerMinute > 0 else { return 0 }
        return Int((meters / metersPerMinute).rounded())
    }
}
