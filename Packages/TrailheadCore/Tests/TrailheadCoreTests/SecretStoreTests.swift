//  SecretStoreTests.swift
//  解析优先级：环境变量 → 本地文件 → Keychain（缺省回退）。

import Foundation
@testable import TrailheadCore
import XCTest

final class SecretStoreTests: XCTestCase {

    private func tempFile(_ json: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("secrets-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        return url
    }

    func testEnvTakesPrecedence() throws {
        let file = try tempFile(#"{"amap":"FROM_FILE"}"#)
        let value = SecretStore.resolve(
            envVar: "X", fileKey: "amap", keychainAccount: "nope_amap_test",
            fileURL: file, environment: ["X": "FROM_ENV"])
        XCTAssertEqual(value, "FROM_ENV")
    }

    func testFileUsedWhenNoEnv() throws {
        let file = try tempFile(#"{"amap":"FROM_FILE","deepseek":"DS"}"#)
        let value = SecretStore.resolve(
            envVar: "X", fileKey: "amap", keychainAccount: "nope_amap_test",
            fileURL: file, environment: [:])
        XCTAssertEqual(value, "FROM_FILE")
    }

    func testFallsBackToNilWhenAllMissing() throws {
        let value = SecretStore.resolve(
            envVar: "X", fileKey: "amap",
            keychainAccount: "definitely_absent_account_\(UUID().uuidString)",
            fileURL: URL(fileURLWithPath: "/no/such/secrets.json"), environment: [:])
        XCTAssertNil(value)   // 无环境变量、无文件、Keychain 也无 → nil
    }

    func testEmptyFileValueIgnored() throws {
        let file = try tempFile(#"{"amap":""}"#)
        let value = SecretStore.resolve(
            envVar: "X", fileKey: "amap",
            keychainAccount: "definitely_absent_account_\(UUID().uuidString)",
            fileURL: file, environment: [:])
        XCTAssertNil(value)   // 空串视为未设
    }
}
