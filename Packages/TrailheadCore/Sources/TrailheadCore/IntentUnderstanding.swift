//  IntentUnderstanding.swift
//  对话请求/响应、提示词与 POI mention 契约（PDR CP-1.1 / CP-1.2）。

import Foundation

public struct IntentPOIMention: Codable, Hashable, Sendable {
    public var text: String
    public var requirement: POIRequirement
    public var assignedDay: Int?
    public var fixedArrivalMinute: Int?
    public var minimumStayMinutes: Int?

    public init(text: String, requirement: POIRequirement = .preferVisit,
                assignedDay: Int? = nil, fixedArrivalMinute: Int? = nil,
                minimumStayMinutes: Int? = nil) {
        self.text = text
        self.requirement = requirement
        self.assignedDay = assignedDay
        self.fixedArrivalMinute = fixedArrivalMinute
        self.minimumStayMinutes = minimumStayMinutes
    }
}
public struct IntentUncertainty: Codable, Hashable, Sendable {
    public var path: IntentPath?
    public var reason: String
    public var confidence: Double

    public init(path: IntentPath? = nil, reason: String, confidence: Double = 0.5) {
        self.path = path
        self.reason = reason
        self.confidence = confidence
    }
}

public struct IntentInterpretationRequest: Codable, Hashable, Sendable {
    public var intent: TripIntent
    public var recentMessages: [PlanningMessage]
    public var userMessage: String
    public var currentQuestion: ClarificationQuestion?

    public init(intent: TripIntent, recentMessages: [PlanningMessage], userMessage: String,
                currentQuestion: ClarificationQuestion? = nil) {
        self.intent = intent
        self.recentMessages = Array(recentMessages.suffix(6))
        self.userMessage = userMessage
        self.currentQuestion = currentQuestion
    }
}

public struct IntentInterpretationResponse: Codable, Hashable, Sendable {
    public var assistantText: String
    public var operations: [IntentPatch]
    public var poiMentions: [IntentPOIMention]
    public var uncertainties: [IntentUncertainty]
    public var suggestedQuestionIDs: [String]

    enum CodingKeys: String, CodingKey {
        case assistantText = "assistant_text"
        case operations
        case poiMentions = "poi_mentions"
        case uncertainties
        case suggestedQuestionIDs = "suggested_question_ids"
    }

    public init(assistantText: String, operations: [IntentPatch] = [],
                poiMentions: [IntentPOIMention] = [], uncertainties: [IntentUncertainty] = [],
                suggestedQuestionIDs: [String] = []) {
        self.assistantText = assistantText
        self.operations = operations
        self.poiMentions = poiMentions
        self.uncertainties = uncertainties
        self.suggestedQuestionIDs = suggestedQuestionIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assistantText = try container.decodeIfPresent(String.self, forKey: .assistantText) ?? ""
        operations = try container.decodeIfPresent([IntentPatch].self, forKey: .operations) ?? []
        poiMentions = try container.decodeIfPresent([IntentPOIMention].self, forKey: .poiMentions) ?? []
        uncertainties = try container.decodeIfPresent([IntentUncertainty].self, forKey: .uncertainties) ?? []
        suggestedQuestionIDs = try container.decodeIfPresent([String].self, forKey: .suggestedQuestionIDs) ?? []
    }
}

public enum IntentPromptBuilder {
    public static func messages(for request: IntentInterpretationRequest) -> [ChatMessage] {
        [ChatMessage(.system, systemPrompt), ChatMessage(.user, userPrompt(request))]
    }

    static let systemPrompt = """
    你是旅行需求理解器，不是路线规划器。只把用户最新表达转换为结构化 patch：
    - 禁止输出路线、poi_id、坐标、营业时间或虚构地点事实。
    - 只允许 operations.path 使用给定白名单；没有表达的字段不要猜。
    - 用户明确表达 source=userExplicit；合理但待确认的推断 source=modelInferred。
    - 必须去=mustVisit，最好/想去=preferVisit，不要去=avoidVisit。
    - assignedDay 使用 0-based；时间统一为当天分钟数。
    - 对否定、撤回和用户纠正优先按最新消息处理。
    - assistant_text 最多 60 字，先说理解结果，再提出至多一个主题的问题。
    严格输出 JSON：
    {
      "assistant_text":"",
      "operations":[{"op":"set|remove|append","path":"白名单","value":任意合法标量,"source":"userExplicit|modelInferred","confidence":0.0}],
      "poi_mentions":[{"text":"地点原话","requirement":"mustVisit|preferVisit|avoidVisit","assignedDay":0,"fixedArrivalMinute":840,"minimumStayMinutes":120}],
      "uncertainties":[{"path":"白名单或省略","reason":"","confidence":0.0}],
      "suggested_question_ids":[]
    }
    路径白名单：\(IntentPath.allCases.map(\.rawValue).joined(separator: ", "))
    Pace 枚举：tight, relaxed, casual。交通枚举：\(TransitMode.allCases.map(\.rawValue).joined(separator: ", "))。
    """

    static func userPrompt(_ request: IntentInterpretationRequest) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let intentJSON = (try? encoder.encode(request.intent)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let recent = request.recentMessages.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
        let question = request.currentQuestion?.prompt ?? "无"
        return """
        当前结构化意图：\(intentJSON)
        当前系统问题：\(question)
        最近消息：
        \(recent)
        用户最新消息：\(request.userMessage)
        """
    }
}
