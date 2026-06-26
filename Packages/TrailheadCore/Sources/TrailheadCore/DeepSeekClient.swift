//  DeepSeekClient.swift
//  LLMProvider 的 DeepSeek 实现（PDR T2.6 / T3.1 / §5.2）。
//  POST /chat/completions，model=deepseek-chat，jsonMode 时 response_format=json_object。
//  超时 30s；可重试错误（网络/5xx/空响应）重试 1 次；鉴权/4xx 不重试。
//  引擎层依赖 LLMProvider 抽象，可热切通义/Kimi/Claude（同样实现本协议）。

import Foundation

// MARK: - 领域错误

public enum LLMError: Error, Equatable {
    case missingKey
    case http(status: Int)
    case apiError(String)
    case emptyResponse
    case decoding(String)
}

// MARK: - 对话消息

public struct ChatMessage: Equatable, Sendable {
    public enum Role: String, Sendable { case system, user, assistant }
    public let role: Role
    public let content: String
    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - DeepSeekClient

public struct DeepSeekClient: LLMProvider {
    private let base = URL(string: "https://api.deepseek.com")!
    private let model: String
    private let timeout: TimeInterval
    private let maxRetries: Int
    private let session: URLSession
    private let keyProvider: () -> String?
    private let onCall: (() -> Void)?

    public init(model: String = "deepseek-chat",
                timeout: TimeInterval = 30,
                maxRetries: Int = 1,
                session: URLSession = .shared,
                keyProvider: @escaping () -> String? = { KeychainStore.get(KeychainStore.Account.llm) },
                onCall: (() -> Void)? = nil) {
        self.model = model
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.session = session
        self.keyProvider = keyProvider
        self.onCall = onCall
    }

    /// 低层补全（PDR T2.6）：返回 choices[0].message.content 文本。
    public func complete(messages: [ChatMessage], jsonMode: Bool) async throws -> String {
        guard let key = keyProvider(), !key.isEmpty else { throw LLMError.missingKey }

        var attempt = 0
        while true {
            do {
                return try await send(messages: messages, jsonMode: jsonMode, key: key)
            } catch {
                if attempt >= maxRetries || !Self.isRetryable(error) { throw error }
                attempt += 1
            }
        }
    }

    /// LLMProvider：把候选 + 偏好交给 LLM，要求只引用候选 poi_id 输出 JSON 行程。
    /// 完整 prompt 构造见 PromptBuilder（PDR T3.2）；此处串联调用。
    public func planItinerary(prefs: TripPrefs, candidates: [POICandidate], days: Int) async throws -> Data {
        let messages = PromptBuilder.itineraryMessages(prefs: prefs, candidates: candidates, days: days)
        let content = try await complete(messages: messages, jsonMode: true)
        return Data(content.utf8)
    }

    // MARK: - 单次请求

    private func send(messages: [ChatMessage], jsonMode: Bool, key: String) async throws -> String {
        var request = URLRequest(url: base.appendingPathComponent("/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        onCall?()   // 计一次 LLM 调用（PDR T7.2）
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.http(status: http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decoding("响应非 JSON 对象")
        }
        if let error = json["error"] as? [String: Any] {
            throw LLMError.apiError(error["message"] as? String ?? "未知错误")
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String, !content.isEmpty else {
            throw LLMError.emptyResponse
        }
        return content
    }

    /// 可重试：网络错误 / 5xx / 空响应。鉴权与 4xx 不重试。
    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case is URLError: return true
        case LLMError.emptyResponse: return true
        case let LLMError.http(status): return status >= 500
        default: return false
        }
    }
}
