@testable import Trailhead
import TrailheadCore
import XCTest

@MainActor
final class APIKeySettingsViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeychainStore.delete(KeychainStore.Account.amap)
        KeychainStore.delete(KeychainStore.Account.llm)
    }

    override func tearDown() {
        KeychainStore.delete(KeychainStore.Account.amap)
        KeychainStore.delete(KeychainStore.Account.llm)
        super.tearDown()
    }

    func testSavingKeysPersistsValuesAndMarksBothAsConfigured() {
        let viewModel = APIKeySettingsViewModel()

        viewModel.amapKeyDraft = "amap-key"
        viewModel.deepSeekKeyDraft = "deepseek-key"
        viewModel.saveAmapKey()
        viewModel.saveDeepSeekKey()

        XCTAssertEqual(KeychainStore.get(KeychainStore.Account.amap), "amap-key")
        XCTAssertEqual(KeychainStore.get(KeychainStore.Account.llm), "deepseek-key")
        XCTAssertTrue(viewModel.hasAmapKey)
        XCTAssertTrue(viewModel.hasDeepSeekKey)
        XCTAssertEqual(viewModel.amapStatusText, "已保存")
        XCTAssertEqual(viewModel.deepSeekStatusText, "已保存")
        XCTAssertEqual(viewModel.amapKeyDraft, "")
        XCTAssertEqual(viewModel.deepSeekKeyDraft, "")
    }

    func testWhitespaceSaveDoesNotOverwriteExistingKey() {
        KeychainStore.set("existing-amap", for: KeychainStore.Account.amap)
        let viewModel = APIKeySettingsViewModel()

        viewModel.amapKeyDraft = "   \n "
        viewModel.saveAmapKey()

        XCTAssertEqual(KeychainStore.get(KeychainStore.Account.amap), "existing-amap")
        XCTAssertTrue(viewModel.hasAmapKey)
    }

    func testDeletingAKeyRemovesOnlyThatServiceKey() {
        KeychainStore.set("amap-key", for: KeychainStore.Account.amap)
        KeychainStore.set("deepseek-key", for: KeychainStore.Account.llm)
        let viewModel = APIKeySettingsViewModel()

        viewModel.deleteAmapKey()

        XCTAssertNil(KeychainStore.get(KeychainStore.Account.amap))
        XCTAssertEqual(KeychainStore.get(KeychainStore.Account.llm), "deepseek-key")
        XCTAssertFalse(viewModel.hasAmapKey)
        XCTAssertTrue(viewModel.hasDeepSeekKey)
    }
}
