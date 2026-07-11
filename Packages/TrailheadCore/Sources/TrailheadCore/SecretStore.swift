//  SecretStore.swift
//  API key 解析：正式版本仅使用 Keychain。
//  DEBUG 构建保留环境变量与 ~/.config/trailhead/secrets.json，方便本地开发和自动化测试；
//  它们不会成为 Release 构建的密钥来源。

import Foundation

public enum SecretStore {
    /// 仅 DEBUG 使用的本地开发配置文件。正式版本统一由设置页写入 Keychain。
    public static let defaultFileURL: URL = {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/trailhead/secrets.json")
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("trailhead/secrets.json")
        #endif
    }()

    /// Release 必须为 false，防止正式版本从明文文件或进程环境读取 API key。
    static let developmentSourcesAllowed: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    public static func amapKey() -> String? {
        resolve(envVar: "TRAILHEAD_AMAP_KEY", fileKey: "amap", keychainAccount: KeychainStore.Account.amap)
    }

    public static func deepseekKey() -> String? {
        resolve(envVar: "TRAILHEAD_DEEPSEEK_KEY", fileKey: "deepseek", keychainAccount: KeychainStore.Account.llm)
    }

    static func resolve(envVar: String, fileKey: String, keychainAccount: String,
                        fileURL: URL = defaultFileURL,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        allowDevelopmentSources: Bool = developmentSourcesAllowed) -> String? {
        if allowDevelopmentSources {
            if let value = environment[envVar], !value.isEmpty { return value }
            if let value = readFile(at: fileURL)?[fileKey], !value.isEmpty { return value }
        }
        return KeychainStore.get(keychainAccount)
    }

    static func readFile(at url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return json
    }
}

// MARK: - 生产用 client 工厂（统一走 SecretStore，避免各处重复注入）

public extension AmapClient {
    static func live() -> AmapClient {
        AmapClient(keyProvider: { SecretStore.amapKey() },
                   onCall: { UsageStore().record(.amap) })
    }
}

public extension DeepSeekClient {
    /// 默认模型 deepseek-v4-pro、超时 180s（v4-pro 推理较慢）。
    static func live(model: String = "deepseek-v4-pro", timeout: TimeInterval = 180) -> DeepSeekClient {
        DeepSeekClient(model: model, timeout: timeout,
                       keyProvider: { SecretStore.deepseekKey() },
                       onCall: { UsageStore().record(.llm) },
                       onUsage: { input, output in UsageStore().recordLLMTokens(input: input, output: output) })
    }
}
