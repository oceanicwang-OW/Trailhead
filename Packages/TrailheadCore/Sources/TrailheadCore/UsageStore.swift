//  UsageStore.swift
//  API 调用本地计数（PDR T7.2）。高德免费接口不在响应里给剩余配额，故按天本地
//  累计调用次数，设置页用进度条展示。按 provider + 日期 存 UserDefaults。

import Foundation

public struct UsageStore {
    public enum Provider: String, CaseIterable, Sendable { case amap, llm }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 记一次调用（默认 +1）。
    public func record(_ provider: Provider, count: Int = 1, on date: Date = .now) {
        let key = Self.key(provider, date)
        defaults.set(defaults.integer(forKey: key) + count, forKey: key)
    }

    /// 某天某 provider 的调用次数。
    public func count(_ provider: Provider, on date: Date = .now) -> Int {
        defaults.integer(forKey: Self.key(provider, date))
    }

    static func key(_ provider: Provider, _ date: Date) -> String {
        "usage.\(provider.rawValue).\(dayString(date))"
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}
