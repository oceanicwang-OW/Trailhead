//  APIKeySettingsViewModel.swift
//  Keychain-backed state for SettingsView API key rows.

import Combine
import Foundation
import TrailheadCore

struct APIKeySettingsStore {
    let get: (String) -> String?
    let set: (String, String) throws -> Void
    let delete: (String) throws -> Void

    static let keychain = APIKeySettingsStore(
        get: KeychainStore.get,
        set: { value, account in try KeychainStore.set(value, for: account) },
        delete: KeychainStore.delete
    )
}

struct APIKeyValidator {
    let amap: (String) async throws -> Void
    let deepSeek: (String) async throws -> Void

    static let live = APIKeyValidator(
        amap: { key in
            _ = try await AmapClient(keyProvider: { key }, pagesPerCategory: 1,
                                     minRequestInterval: 0).geocodeCity("北京")
        },
        deepSeek: { key in
            _ = try await DeepSeekClient(maxRetries: 0, keyProvider: { key }).complete(
                messages: [ChatMessage(.user, "只回复 OK")], jsonMode: false)
        }
    )
}

struct APIKeyVerificationStore {
    let get: (String) -> Date?
    let set: (Date?, String) -> Void

    static let defaults = APIKeyVerificationStore(
        get: { UserDefaults.standard.object(forKey: $0) as? Date },
        set: { date, key in UserDefaults.standard.set(date, forKey: key) }
    )
}

@MainActor
final class APIKeySettingsViewModel: ObservableObject {
    enum VerificationState: Equatable {
        case unverified
        case testing
        case verified(Date)
        case failed(String)
    }

    @Published var amapKeyDraft = ""
    @Published var deepSeekKeyDraft = ""
    @Published private(set) var hasAmapKey = false
    @Published private(set) var hasDeepSeekKey = false
    @Published private(set) var amapVerification: VerificationState = .unverified
    @Published private(set) var deepSeekVerification: VerificationState = .unverified
    @Published private(set) var operationError: String?
    private let store: APIKeySettingsStore
    private let validator: APIKeyValidator
    private let verificationStore: APIKeyVerificationStore

    private static let amapVerifiedKey = "api.verification.amap.lastSuccess"
    private static let deepSeekVerifiedKey = "api.verification.deepseek.lastSuccess"

    var amapStatusText: String {
        statusText(saved: hasAmapKey, hasDraft: !amapKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   verification: amapVerification)
    }
    var deepSeekStatusText: String {
        statusText(saved: hasDeepSeekKey,
                   hasDraft: !deepSeekKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   verification: deepSeekVerification)
    }
    var amapIsTesting: Bool { amapVerification == .testing }
    var deepSeekIsTesting: Bool { deepSeekVerification == .testing }
    var amapValidationFailed: Bool { if case .failed = amapVerification { true } else { false } }
    var deepSeekValidationFailed: Bool { if case .failed = deepSeekVerification { true } else { false } }

    init(store: APIKeySettingsStore = .keychain,
         validator: APIKeyValidator = .live,
         verificationStore: APIKeyVerificationStore = .defaults) {
        self.store = store
        self.validator = validator
        self.verificationStore = verificationStore
        load()
    }

    func load() {
        hasAmapKey = hasValue(for: KeychainStore.Account.amap)
        hasDeepSeekKey = hasValue(for: KeychainStore.Account.llm)
        if hasAmapKey, let date = verificationStore.get(Self.amapVerifiedKey) {
            amapVerification = .verified(date)
        } else if !hasAmapKey { amapVerification = .unverified }
        if hasDeepSeekKey, let date = verificationStore.get(Self.deepSeekVerifiedKey) {
            deepSeekVerification = .verified(date)
        } else if !hasDeepSeekKey { deepSeekVerification = .unverified }
    }

    func saveAmapKey() {
        if save(amapKeyDraft, for: KeychainStore.Account.amap) {
            amapKeyDraft = ""
            verificationStore.set(nil, Self.amapVerifiedKey)
            amapVerification = .unverified
            load()
        }
    }

    func saveDeepSeekKey() {
        if save(deepSeekKeyDraft, for: KeychainStore.Account.llm) {
            deepSeekKeyDraft = ""
            verificationStore.set(nil, Self.deepSeekVerifiedKey)
            deepSeekVerification = .unverified
            load()
        }
    }

    func deleteAmapKey() {
        do {
            try store.delete(KeychainStore.Account.amap)
            amapKeyDraft = ""
            verificationStore.set(nil, Self.amapVerifiedKey)
            load()
        } catch { operationError = Self.storageMessage(error) }
    }

    func deleteDeepSeekKey() {
        do {
            try store.delete(KeychainStore.Account.llm)
            deepSeekKeyDraft = ""
            verificationStore.set(nil, Self.deepSeekVerifiedKey)
            load()
        } catch { operationError = Self.storageMessage(error) }
    }

    func testAmapConnection() async {
        let isDraft = !amapKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let key = candidateKey(draft: amapKeyDraft, account: KeychainStore.Account.amap) else { return }
        amapVerification = .testing
        do {
            try await validator.amap(key)
            let date = Date()
            if !isDraft { verificationStore.set(date, Self.amapVerifiedKey) }
            amapVerification = .verified(date)
        } catch { amapVerification = .failed(Self.validationMessage(error, provider: "高德")) }
    }

    func testDeepSeekConnection() async {
        let isDraft = !deepSeekKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let key = candidateKey(draft: deepSeekKeyDraft, account: KeychainStore.Account.llm) else { return }
        deepSeekVerification = .testing
        do {
            try await validator.deepSeek(key)
            let date = Date()
            if !isDraft { verificationStore.set(date, Self.deepSeekVerifiedKey) }
            deepSeekVerification = .verified(date)
        } catch { deepSeekVerification = .failed(Self.validationMessage(error, provider: "DeepSeek")) }
    }

    func clearOperationError() { operationError = nil }

    private func save(_ rawValue: String, for account: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        do {
            try store.set(value, account)
            operationError = nil
            return true
        } catch {
            operationError = Self.storageMessage(error)
            return false
        }
    }

    private func hasValue(for account: String) -> Bool {
        guard let value = store.get(account) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func candidateKey(draft: String, account: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return store.get(account)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func statusText(saved: Bool, hasDraft: Bool, verification: VerificationState) -> String {
        switch verification {
        case .testing: return "正在验证…"
        case let .verified(date):
            return hasDraft ? "连接有效 · 尚未保存" : "已验证 · \(Self.dateFormatter.string(from: date))"
        case let .failed(message): return "验证失败 · \(message)"
        case .unverified: return saved ? "已保存 · 未验证" : "未配置"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    private static func storageMessage(_ error: Error) -> String {
        (error as? KeychainStoreError)?.errorDescription ?? "钥匙串操作失败，请解锁设备后重试"
    }

    private static func validationMessage(_ error: Error, provider: String) -> String {
        if error is URLError { return "网络不可用，请检查连接后重试" }
        switch error {
        case AmapError.quotaExceeded: return "今日配额已用完"
        case AmapError.missingKey, LLMError.missingKey: return "密钥为空"
        case let AmapError.apiError(code, _):
            return code == "10001" ? "密钥无效" : "服务拒绝请求（\(code)）"
        case let LLMError.http(status):
            if status == 401 || status == 403 { return "密钥无效" }
            if status == 402 { return "账户余额不足" }
            if status == 429 { return "请求受限或额度已用完" }
            return "服务暂不可用（HTTP \(status)）"
        case LLMError.apiError: return "服务拒绝请求"
        default: return "\(provider)连接失败，请稍后重试"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
