//  SecretStore.swift
//  API key 解析（按优先级）：环境变量 → 本地文件 ~/.config/trailhead/secrets.json
//  → Keychain。本地文件方式不弹钥匙串授权框；文件仅本人可读、永不入库。
//  文件格式：{ "amap": "...", "deepseek": "..." }

import Foundation

public enum SecretStore {
    /// 本地机密文件（家目录下，不在仓库内）。
    public static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/trailhead/secrets.json")

    public static func amapKey() -> String? {
        resolve(envVar: "TRAILHEAD_AMAP_KEY", fileKey: "amap", keychainAccount: KeychainStore.Account.amap)
    }

    public static func deepseekKey() -> String? {
        resolve(envVar: "TRAILHEAD_DEEPSEEK_KEY", fileKey: "deepseek", keychainAccount: KeychainStore.Account.llm)
    }

    static func resolve(envVar: String, fileKey: String, keychainAccount: String,
                        fileURL: URL = defaultFileURL,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let value = environment[envVar], !value.isEmpty { return value }
        if let value = readFile(at: fileURL)?[fileKey], !value.isEmpty { return value }
        return KeychainStore.get(keychainAccount)
    }

    static func readFile(at url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return json
    }
}
