//  DeepSeekClientTests.swift
//  PDR T2.6 验收：返回可解析 JSON 字符串。mock 拦截，离线测请求形状/解析/重试。

import Foundation
@testable import TrailheadCore
import XCTest

final class DeepSeekClientTests: XCTestCase {

    override func setUp() { super.setUp(); MockURLProtocol.reset() }

    private func makeClient(key: String? = "TESTKEY", maxRetries: Int = 1) -> DeepSeekClient {
        DeepSeekClient(maxRetries: maxRetries, session: TestSupport.mockSession(), keyProvider: { key })
    }

    private func completion(_ content: String) -> String {
        #"{"choices":[{"message":{"role":"assistant","content":"\#(content)"}}]}"#
    }

    private func lastBodyJSON() throws -> [String: Any] {
        let data = try XCTUnwrap(MockURLProtocol.requestBodies.last)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // T2.6 ---------------------------------------------------------------

    func testCompleteParsesContent() async throws {
        MockURLProtocol.stub(completion("{\\\"days\\\":[]}"))
        let out = try await makeClient().complete(messages: [ChatMessage(.user, "hi")], jsonMode: true)
        XCTAssertEqual(out, "{\"days\":[]}")
    }

    func testRequestShapeAndJSONMode() async throws {
        MockURLProtocol.stub(completion("ok"))
        _ = try await makeClient().complete(
            messages: [ChatMessage(.system, "S"), ChatMessage(.user, "U")], jsonMode: true)

        let req = try XCTUnwrap(MockURLProtocol.requests.last)
        XCTAssertEqual(req.url?.path, "/chat/completions")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer TESTKEY")

        let body = try lastBodyJSON()
        XCTAssertEqual(body["model"] as? String, "deepseek-chat")
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_object")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages.first?["content"], "S")
    }

    func testJsonModeOmittedWhenFalse() async throws {
        MockURLProtocol.stub(completion("ok"))
        _ = try await makeClient().complete(messages: [ChatMessage(.user, "U")], jsonMode: false)
        XCTAssertNil(try lastBodyJSON()["response_format"])
    }

    func testMissingKeyThrowsBeforeRequest() async throws {
        await assertThrows(.missingKey) {
            _ = try await self.makeClient(key: nil).complete(messages: [ChatMessage(.user, "U")], jsonMode: true)
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    // 重试（PDR：失败重试 1 次）-------------------------------------------

    func testRetriesOnceThenSucceeds() async throws {
        MockURLProtocol.stubSequence([(500, "{}"), (200, completion("ok"))])
        let out = try await makeClient().complete(messages: [ChatMessage(.user, "U")], jsonMode: true)
        XCTAssertEqual(out, "ok")
        XCTAssertEqual(MockURLProtocol.requests.count, 2)   // 1 次重试
    }

    func testRetryExhaustedThrowsHTTP() async throws {
        MockURLProtocol.stubSequence([(500, "{}"), (500, "{}")])
        await assertThrows(.http(status: 500)) {
            _ = try await self.makeClient().complete(messages: [ChatMessage(.user, "U")], jsonMode: true)
        }
        XCTAssertEqual(MockURLProtocol.requests.count, 2)   // 原始 + 1 重试后放弃
    }

    func testNoRetryOnAuthError() async throws {
        MockURLProtocol.stubSequence([(401, "{}"), (200, completion("ok"))])
        await assertThrows(.http(status: 401)) {
            _ = try await self.makeClient().complete(messages: [ChatMessage(.user, "U")], jsonMode: true)
        }
        XCTAssertEqual(MockURLProtocol.requests.count, 1)   // 4xx 不重试
    }

    func testApiErrorBody() async throws {
        MockURLProtocol.stub(#"{"error":{"message":"Insufficient Balance"}}"#)
        await assertThrows(.apiError("Insufficient Balance")) {
            _ = try await self.makeClient(maxRetries: 0).complete(messages: [ChatMessage(.user, "U")], jsonMode: true)
        }
    }

    // helper -------------------------------------------------------------

    private func assertThrows(_ expected: LLMError, _ body: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected to throw \(expected)", file: file, line: line) }
        catch let e as LLMError { XCTAssertEqual(e, expected, file: file, line: line) }
        catch { XCTFail("wrong error: \(error)", file: file, line: line) }
    }
}
