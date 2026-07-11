@testable import Trailhead
import TrailheadCore
import XCTest

@MainActor
final class APIKeySettingsViewModelTests: XCTestCase {
    private final class MemoryStore {
        var values: [String: String] = [:]
        var setError: Error?
        var deleteError: Error?

        var adapter: APIKeySettingsStore {
            APIKeySettingsStore(
                get: { [unowned self] in values[$0] },
                set: { [unowned self] value, account in
                    if let setError { throw setError }
                    values[account] = value
                },
                delete: { [unowned self] account in
                    if let deleteError { throw deleteError }
                    values.removeValue(forKey: account)
                }
            )
        }
    }

    private final class MemoryVerificationStore {
        var dates: [String: Date] = [:]
        var adapter: APIKeyVerificationStore {
            APIKeyVerificationStore(
                get: { [unowned self] in dates[$0] },
                set: { [unowned self] date, key in dates[key] = date }
            )
        }
    }

    func testSavingKeysPersistsValuesAndMarksBothAsConfigured() {
        let store = MemoryStore()
        let viewModel = APIKeySettingsViewModel(store: store.adapter)

        viewModel.amapKeyDraft = "amap-key"
        viewModel.deepSeekKeyDraft = "deepseek-key"
        viewModel.saveAmapKey()
        viewModel.saveDeepSeekKey()

        XCTAssertEqual(store.values[KeychainStore.Account.amap], "amap-key")
        XCTAssertEqual(store.values[KeychainStore.Account.llm], "deepseek-key")
        XCTAssertTrue(viewModel.hasAmapKey)
        XCTAssertTrue(viewModel.hasDeepSeekKey)
        XCTAssertEqual(viewModel.amapStatusText, "已保存 · 未验证")
        XCTAssertEqual(viewModel.deepSeekStatusText, "已保存 · 未验证")
        XCTAssertEqual(viewModel.amapKeyDraft, "")
        XCTAssertEqual(viewModel.deepSeekKeyDraft, "")
    }

    func testWhitespaceSaveDoesNotOverwriteExistingKey() {
        let store = MemoryStore()
        store.values[KeychainStore.Account.amap] = "existing-amap"
        let viewModel = APIKeySettingsViewModel(store: store.adapter)

        viewModel.amapKeyDraft = "   \n "
        viewModel.saveAmapKey()

        XCTAssertEqual(store.values[KeychainStore.Account.amap], "existing-amap")
        XCTAssertTrue(viewModel.hasAmapKey)
    }

    func testDeletingAKeyRemovesOnlyThatServiceKey() {
        let store = MemoryStore()
        store.values[KeychainStore.Account.amap] = "amap-key"
        store.values[KeychainStore.Account.llm] = "deepseek-key"
        let viewModel = APIKeySettingsViewModel(store: store.adapter)

        viewModel.deleteAmapKey()

        XCTAssertNil(store.values[KeychainStore.Account.amap])
        XCTAssertEqual(store.values[KeychainStore.Account.llm], "deepseek-key")
        XCTAssertFalse(viewModel.hasAmapKey)
        XCTAssertTrue(viewModel.hasDeepSeekKey)
    }

    func testKeychainWriteFailureKeepsDraftAndShowsRecoverableError() {
        let store = MemoryStore()
        store.setError = KeychainStoreError.operationFailed(operation: "保存", status: -1)
        let viewModel = APIKeySettingsViewModel(store: store.adapter)
        viewModel.amapKeyDraft = "secret-value"

        viewModel.saveAmapKey()

        XCTAssertEqual(viewModel.amapKeyDraft, "secret-value")
        XCTAssertFalse(viewModel.hasAmapKey)
        XCTAssertEqual(viewModel.operationError, "钥匙串保存失败（状态码 -1）")
        XCTAssertFalse(viewModel.operationError?.contains("secret-value") == true)
    }

    func testAmapValidationUsesDraftAndPersistsSuccessTime() async {
        let store = MemoryStore()
        let verified = MemoryVerificationStore()
        var receivedKey: String?
        let validator = APIKeyValidator(
            amap: { receivedKey = $0 },
            deepSeek: { _ in }
        )
        let viewModel = APIKeySettingsViewModel(
            store: store.adapter, validator: validator, verificationStore: verified.adapter)
        viewModel.amapKeyDraft = "draft-amap"

        await viewModel.testAmapConnection()

        XCTAssertEqual(receivedKey, "draft-amap")
        if case .verified = viewModel.amapVerification {} else { XCTFail("expected verified") }
        XCTAssertEqual(viewModel.amapStatusText, "连接有效 · 尚未保存")
        XCTAssertTrue(verified.dates.isEmpty)
    }

    func testSavedKeyValidationPersistsSuccessTime() async {
        let store = MemoryStore()
        store.values[KeychainStore.Account.amap] = "saved-amap"
        let verified = MemoryVerificationStore()
        let validator = APIKeyValidator(amap: { _ in }, deepSeek: { _ in })
        let viewModel = APIKeySettingsViewModel(
            store: store.adapter, validator: validator, verificationStore: verified.adapter)

        await viewModel.testAmapConnection()

        XCTAssertTrue(viewModel.amapStatusText.hasPrefix("已验证 · "))
        XCTAssertEqual(verified.dates.count, 1)
    }

    func testValidationErrorsAreSpecificAndDoNotLeakKey() async {
        let store = MemoryStore()
        store.values[KeychainStore.Account.amap] = "sensitive-amap-key"
        let validator = APIKeyValidator(
            amap: { _ in throw AmapError.apiError(code: "10001", message: "INVALID sensitive-amap-key") },
            deepSeek: { _ in throw URLError(.notConnectedToInternet) }
        )
        let viewModel = APIKeySettingsViewModel(store: store.adapter, validator: validator)

        await viewModel.testAmapConnection()

        XCTAssertEqual(viewModel.amapStatusText, "验证失败 · 密钥无效")
        XCTAssertFalse(viewModel.amapStatusText.contains("sensitive-amap-key"))
    }
}
