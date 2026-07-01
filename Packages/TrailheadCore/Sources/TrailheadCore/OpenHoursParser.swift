//  OpenHoursParser.swift
//  营业时间解析（PDR §4.3），容错优先。输入高德 opentime2 原始串（脏且缺失率高），
//  输出「当日分钟数」窗口；解析失败或缺失一律返回 nil —— 下游对 nil 不过滤，宁可不筛绝不误杀招牌。

import Foundation

public enum OpenHoursParser {
    /// 单个营业窗，单位为「当日分钟数」（0...1440，close 可为 1440 表示当日 24:00）。
    public typealias Window = (open: Int, close: Int)

    static let allDay: Window = (0, 24 * 60)

    /// 匹配 `H:mm-H:mm` / `HH:mm-HH:mm`，全局查找自动跨 `;,、` 等分隔符切段。
    private static let regex = try! NSRegularExpression(pattern: #"(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})"#)

    public static func parse(_ raw: String?) -> [Window]? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // 全天/24 小时关键词优先，直接判全天（跨夜、免闭馆等都归此类）。
        if s.contains("全天") || s.contains("24小时") || s.contains("24 小时") {
            return [allDay]
        }

        let ns = s as NSString
        var windows: [Window] = []
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let open = minutes(ns, m, hourGroup: 1, minGroup: 2),
                  let close = minutes(ns, m, hourGroup: 3, minGroup: 4) else { continue }
            // 跨夜（close<=open，如 22:00-02:00）→ 视为全天，不据此误杀。
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
