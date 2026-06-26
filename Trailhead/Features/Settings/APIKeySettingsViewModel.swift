//  APIKeySettingsViewModel.swift
//  Keychain-backed state for SettingsView API key rows.

import Combine
import Foundation
import TrailheadCore

@MainActor
final class APIKeySettingsViewModel: ObservableObject {
    @Published var amapKeyDraft = ""
    @Published var deepSeekKeyDraft = ""
    @Published private(set) var hasAmapKey = false
    @Published private(set) var hasDeepSeekKey = false

    var amapStatusText: String { hasAmapKey ? "已保存" : "未配置" }
    var deepSeekStatusText: String { hasDeepSeekKey ? "已保存" : "未配置" }

    init() {
        load()
    }

    func load() {
        hasAmapKey = hasValue(for: KeychainStore.Account.amap)
        hasDeepSeekKey = hasValue(for: KeychainStore.Account.llm)
    }

    func saveAmapKey() {
        save(amapKeyDraft, for: KeychainStore.Account.amap)
        amapKeyDraft = ""
        load()
    }

    func saveDeepSeekKey() {
        save(deepSeekKeyDraft, for: KeychainStore.Account.llm)
        deepSeekKeyDraft = ""
        load()
    }

    func deleteAmapKey() {
        KeychainStore.delete(KeychainStore.Account.amap)
        amapKeyDraft = ""
        load()
    }

    func deleteDeepSeekKey() {
        KeychainStore.delete(KeychainStore.Account.llm)
        deepSeekKeyDraft = ""
        load()
    }

    private func save(_ rawValue: String, for account: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        KeychainStore.set(value, for: account)
    }

    private func hasValue(for account: String) -> Bool {
        guard let value = KeychainStore.get(account) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
