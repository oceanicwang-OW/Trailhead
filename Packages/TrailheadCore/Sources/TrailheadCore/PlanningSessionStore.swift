//  PlanningSessionStore.swift
//  对话草稿的轻量本地持久化；只保存会话结构，不涉及任何 API Key。

import Foundation

public struct PlanningSessionStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard,
                key: String = "trailhead.planning-session-draft.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func save(_ session: PlanningSession) throws {
        defaults.set(try JSONEncoder().encode(session), forKey: key)
    }

    public func load() -> PlanningSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PlanningSession.self, from: data)
    }

    public func delete() {
        defaults.removeObject(forKey: key)
    }
}
