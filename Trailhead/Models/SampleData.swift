//  SampleData.swift
//  Seeds the "关西环游" itinerary from the handoff mockup so the app renders
//  exactly like the design on first launch. Replaced by the real engine later
//  (PDR phase 3).

import Foundation
import SwiftData
import SwiftUI

enum SampleData {

    static func seedIfNeeded(_ context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<Trip>())) ?? 0
        guard count == 0 else { return }
        for trip in makeTrips() { context.insert(trip) }
        try? context.save()
    }

    static func makeTrips() -> [Trip] {
        [kansai(), hokkaido(), taipeiDraft(), tokyo(), seoul()]
    }

    // MARK: - 关西环游 (selected, fully detailed Day 1 — matches mockup)

    static func kansai() -> Trip {
        var prefs = TripPrefs()
        prefs.tags = ["美食", "历史古迹", "自然风光"]
        prefs.pace = .relaxed
        prefs.budgetPerDay = 600

        let cal = Calendar.current
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 12)) ?? .now

        // Day 1 — Kyoto (verbatim from the design)
        let d1 = DayPlan(dayIndex: 0, date: start, cityLabel: "京都", items: [
            .poi(0, kind: .sight, time: "09:00", name: "伏见稻荷大社",
                 subtype: "神社", note: "千本鸟居 · 建议早到", stay: "约 2.5 小时"),
            .transit(1, mode: .train, desc: "JR 奈良线 + 步行", minutes: 18, meters: 4200, cost: 150),
            .poi(2, kind: .food, time: "12:30", name: "锦市场",
                 subtype: "午餐", note: "京都厨房 · 街边小食", stay: "约 1 小时"),
            .transit(3, mode: .walk, desc: "步行", minutes: 12, meters: 900),
            .poi(4, kind: .sight, time: "14:30", name: "清水寺",
                 subtype: "寺院", note: "清水舞台 · 世界遗产", stay: "约 2 小时"),
            .transit(5, mode: .taxi, desc: "出租车", minutes: 10, meters: 2300, cost: 1020),
            .poi(6, kind: .food, time: "19:30", name: "祇园 · 怀石料理",
                 subtype: "晚餐", note: "花见小路 · 已预订", stay: ""),
            .poi(7, kind: .lodging, time: "21:30", name: "京都町家旅馆",
                 subtype: "过夜", note: "连住 2 晚 · 已确认", stay: ""),
        ])

        // Day 2 — Nara (lighter seed)
        let d2 = DayPlan(dayIndex: 1, date: cal.date(byAdding: .day, value: 1, to: start) ?? start,
                         cityLabel: "奈良", items: [
            .poi(0, kind: .sight, time: "09:30", name: "奈良公园 · 喂鹿",
                 subtype: "公园", note: "鞠躬鹿 · 鹿仙贝", stay: "约 1.5 小时"),
            .transit(1, mode: .walk, desc: "步行", minutes: 8, meters: 600),
            .poi(2, kind: .sight, time: "11:30", name: "东大寺",
                 subtype: "寺院", note: "大佛殿 · 世界遗产", stay: "约 1.5 小时"),
            .poi(3, kind: .food, time: "13:30", name: "中谷堂",
                 subtype: "午餐", note: "高速捣麻糬", stay: "约 40 分钟"),
        ])

        // Days 3–5 — placeholders so day tabs populate
        let d3 = DayPlan(dayIndex: 2, date: cal.date(byAdding: .day, value: 2, to: start) ?? start,
                         cityLabel: "大阪", items: [
            .poi(0, kind: .sight, time: "10:00", name: "大阪城",
                 subtype: "城郭", note: "天守阁 · 护城河", stay: "约 2 小时"),
            .poi(1, kind: .food, time: "13:00", name: "黑门市场",
                 subtype: "午餐", note: "海鲜 · 和牛串", stay: "约 1 小时"),
        ])
        let d4 = DayPlan(dayIndex: 3, date: cal.date(byAdding: .day, value: 3, to: start) ?? start,
                         cityLabel: "大阪", items: [
            .poi(0, kind: .sight, time: "10:00", name: "环球影城",
                 subtype: "乐园", note: "整日 · 建议买快速通", stay: "整日"),
        ])
        let d5 = DayPlan(dayIndex: 4, date: cal.date(byAdding: .day, value: 4, to: start) ?? start,
                         cityLabel: "大阪", items: [
            .poi(0, kind: .sight, time: "10:30", name: "道顿堀",
                 subtype: "街区", note: "格力高招牌 · 购物", stay: "约 2 小时"),
        ])

        return Trip(city: "关西环游", subtitle: "京都 / 大阪 / 奈良", adcode: "JP-KIX",
                    startDate: start, nights: 4, prefs: prefs, status: .ready,
                    accentSeed: 0, days: [d1, d2, d3, d4, d5])
    }

    // MARK: - Other sidebar entries (light)

    static func hokkaido() -> Trip {
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 20)) ?? .now
        return Trip(city: "北海道滑雪", subtitle: "札幌 / 二世古", startDate: start,
                    nights: 6, status: .ready, accentSeed: 1)
    }
    static func taipeiDraft() -> Trip {
        Trip(city: "台北周末", subtitle: "未排期 · 草稿", nights: 2, status: .draft, accentSeed: 2)
    }
    static func tokyo() -> Trip {
        let start = Calendar.current.date(from: DateComponents(year: 2024, month: 5, day: 3)) ?? .now
        return Trip(city: "东京漫步", subtitle: "2024 · 已完成", startDate: start,
                    nights: 4, status: .done, accentSeed: 3)
    }
    static func seoul() -> Trip {
        let start = Calendar.current.date(from: DateComponents(year: 2023, month: 9, day: 8)) ?? .now
        return Trip(city: "首尔美食", subtitle: "2023 · 已完成", startDate: start,
                    nights: 3, status: .done, accentSeed: 4)
    }

    /// Sidebar swatch gradients, indexed by Trip.accentSeed.
    static let swatches: [[Color]] = [
        [Palette.green, Palette.greenDeep],
        [Palette.slate, Color(hex: 0x3C4855)],
        [Palette.orange, Color(hex: 0xCF6E10)],
        [Palette.purple, Color(hex: 0x6D3FD4)],
        [Palette.blue, Color(hex: 0x0768CC)],
    ]
}
