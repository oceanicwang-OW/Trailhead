//  QuotaState.swift
//  记录"高德配额今日已耗尽"（PDR T8.2）。命中 AmapError.quotaExceeded 时标记，
//  UI 据此显示降级横幅；次日自动失效。行程本地可读，不受影响（local-first）。

import Foundation

public struct QuotaState {
    private let defaults: UserDefaults
    private let key = "amap.quotaExhaustedDay"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func markExhausted(on date: Date = .now) {
        defaults.set(UsageStore.dayString(date), forKey: key)
    }

    public func isExhausted(on date: Date = .now) -> Bool {
        defaults.string(forKey: key) == UsageStore.dayString(date)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
