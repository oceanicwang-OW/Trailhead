//  OpenHoursParser.swift
//  营业时间解析（PDR §4.3，v2 含 D2 周闭馆/星期覆盖），容错优先。输入高德 opentime2 原始串
//  （脏且缺失率高），输出 OpenSchedule：默认窗 base + 每周固定闭馆日 + 按星期覆盖窗。
//  保守铁律：任何解析失败或缺失一律降级为「未知」——下游不过滤，宁可不筛绝不误杀招牌。

import Foundation

/// 一个 POI 的营业时刻表（D2）。weekday 一律用 1=周一 … 7=周日。
public struct OpenSchedule: Sendable {
    /// 默认时段（不区分星期）；nil = 未知（下游不得过滤）。
    public let base: [OpenHoursParser.Window]?
    /// 每周固定闭馆日，如「周一闭馆」。
    public let weeklyClosed: Set<Int>
    /// 按星期覆盖的时段（如「周二至周日 09:00-17:00」），命中则优先于 base。
    public let weekdayOverrides: [Int: [OpenHoursParser.Window]]

    public init(base: [OpenHoursParser.Window]? = nil,
                weeklyClosed: Set<Int> = [],
                weekdayOverrides: [Int: [OpenHoursParser.Window]] = [:]) {
        self.base = base
        self.weeklyClosed = weeklyClosed
        self.weekdayOverrides = weekdayOverrides
    }

    /// 当日营业窗。weekday 已知：闭馆日 → []（当日闭馆）；覆盖命中 → 该窗；否则 base。
    /// weekday == nil（行程无日期）：忽略周闭馆/覆盖，退化为 base 语义（与 v1 行为一致）。
    public func windows(on weekday: Int?) -> [OpenHoursParser.Window]? {
        guard let weekday else { return base }
        if weeklyClosed.contains(weekday) { return [] }
        if let override = weekdayOverrides[weekday] { return override }
        return base
    }
}

public enum OpenHoursParser {
    /// 单个营业窗，单位为「当日分钟数」（0...1440，close 可为 1440 表示当日 24:00）。
    public typealias Window = (open: Int, close: Int)

    static let allDay: Window = (0, 24 * 60)

    /// 匹配 `H:mm-H:mm` / `HH:mm-HH:mm`，全局查找自动跨 `;,、` 等分隔符切段。
    private static let timeRegex = try! NSRegularExpression(pattern: #"(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})"#)

    /// 周字头（每周/周/星期/礼拜/逢周）+ 单个星期字。
    private static let weekdayChars = "一二三四五六日天"
    /// 「周X闭馆」「每周X休息」等闭馆词；支持「周X至周Y闭馆」区间。
    private static let closedRegex = try! NSRegularExpression(
        pattern: #"(?:每周|逢周|周|星期|礼拜)([一二三四五六日天])(?:\s*(?:至|到|-|—|~)\s*(?:每周|周|星期|礼拜)?([一二三四五六日天]))?\s*(?:闭馆|休馆|闭园|休园|休息|公休|不开放|停业|不营业|停止开放)"#)
    /// 「周X至周Y HH:mm-HH:mm[; HH:mm-HH:mm…]」按星期覆盖（区间形）。
    private static let rangeOverrideRegex = try! NSRegularExpression(
        pattern: #"(?:每周|周|星期|礼拜)([一二三四五六日天])\s*(?:至|到|-|—|~)\s*(?:每周|周|星期|礼拜)?([一二三四五六日天])\s*((?:\d{1,2}:\d{2}\s*-\s*\d{1,2}:\d{2}[;,、\s]*)+)"#)
    /// 「周X HH:mm-HH:mm」按星期覆盖（单日形）；与区间形重叠时以区间形为准（见 schedule）。
    private static let singleOverrideRegex = try! NSRegularExpression(
        pattern: #"(?:每周|周|星期|礼拜)([一二三四五六日天])\s*((?:\d{1,2}:\d{2}\s*-\s*\d{1,2}:\d{2}[;,、\s]*)+)"#)

    /// v1 兼容入口：只取默认窗（不区分星期）。等价 `schedule(raw).base`。
    public static func parse(_ raw: String?) -> [Window]? {
        schedule(raw).base
    }

    /// D2 入口：解析出完整时刻表。任何子模式解析失败都静默降级（不引入新的误杀面）。
    public static func schedule(_ raw: String?) -> OpenSchedule {
        guard let raw else { return OpenSchedule() }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return OpenSchedule() }
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)

        // 周闭馆（含区间「周一至周二闭馆」）。
        var weeklyClosed: Set<Int> = []
        for m in closedRegex.matches(in: s, range: full) {
            guard let start = weekday(ns, m, at: 1) else { continue }
            let end = weekday(ns, m, at: 2) ?? start
            weeklyClosed.formUnion(expand(from: start, to: end))
        }

        // 星期覆盖：先区间形，记录命中范围；单日形只在不与区间重叠时生效
        // （避免「周二至周日 9:00-17:00」的尾部「周日9:00-17:00」被单日形重复命中）。
        var overrides: [Int: [Window]] = [:]
        var claimed: [NSRange] = []
        for m in rangeOverrideRegex.matches(in: s, range: full) {
            guard let start = weekday(ns, m, at: 1), let end = weekday(ns, m, at: 2),
                  let wins = windowList(ns.substring(with: m.range(at: 3))), !wins.isEmpty else { continue }
            for d in expand(from: start, to: end) { overrides[d, default: []].append(contentsOf: wins) }
            claimed.append(m.range)
        }
        for m in singleOverrideRegex.matches(in: s, range: full)
        where !claimed.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            guard let d = weekday(ns, m, at: 1),
                  let wins = windowList(ns.substring(with: m.range(at: 2))), !wins.isEmpty else { continue }
            overrides[d, default: []].append(contentsOf: wins)
        }

        // 默认窗：全天关键词优先；否则收集串中全部时间段（含覆盖段——windows(on:) 时覆盖优先）。
        let base: [Window]?
        if s.contains("全天") || s.contains("24小时") || s.contains("24 小时") {
            base = [allDay]
        } else {
            base = windowList(s)
        }
        return OpenSchedule(base: base, weeklyClosed: weeklyClosed, weekdayOverrides: overrides)
    }

    // MARK: - 内部

    /// 星期字捕获组 → 1...7；组缺失或非星期字返回 nil。
    private static func weekday(_ s: NSString, _ m: NSTextCheckingResult, at group: Int) -> Int? {
        guard group < m.numberOfRanges, m.range(at: group).location != NSNotFound else { return nil }
        let ch = s.substring(with: m.range(at: group))
        guard let idx = weekdayChars.firstIndex(of: Character(ch)) else { return nil }
        let n = weekdayChars.distance(from: weekdayChars.startIndex, to: idx) + 1
        return min(n, 7)   // 「天」与「日」同为 7
    }

    /// 星期区间展开（1=周一…7=周日），支持跨周回绕（周六至周二 → 6,7,1,2）。
    private static func expand(from start: Int, to end: Int) -> [Int] {
        var result = [start]
        var d = start
        while d != end, result.count < 7 {
            d = d % 7 + 1
            result.append(d)
        }
        return result
    }

    /// 从任意子串收集全部 `HH:mm-HH:mm` 窗；空串/无命中返回 nil。跨夜（close<=open）视为全天。
    private static func windowList(_ raw: String) -> [Window]? {
        let ns = raw as NSString
        var windows: [Window] = []
        for m in timeRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            guard let open = minutes(ns, m, hourGroup: 1, minGroup: 2),
                  let close = minutes(ns, m, hourGroup: 3, minGroup: 4) else { continue }
            windows.append(close <= open ? allDay : (open, close))
        }
        return windows.isEmpty ? nil : windows
    }

    /// 取一个 HH / mm 捕获组转分钟；小时 0...24、分钟 0...59，越界视为无效段。
    private static func minutes(_ s: NSString, _ m: NSTextCheckingResult, hourGroup: Int, minGroup: Int) -> Int? {
        guard let h = Int(s.substring(with: m.range(at: hourGroup))),
              let min = Int(s.substring(with: m.range(at: minGroup))),
              (0...24).contains(h), (0...59).contains(min) else { return nil }
        return h * 60 + min
    }
}
