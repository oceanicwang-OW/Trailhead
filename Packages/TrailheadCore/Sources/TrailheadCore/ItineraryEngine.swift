//  ItineraryEngine.swift
//  生成流水线（PDR §3 七步 / T3.6 / T3.7）。串联：地理编码 → 缓存优先召回 →
//  LLM 编排（poi_id 锁定）→ JSON 解析(重试1次)→ FactChecker → 路线补全 → 落库。
//  @Published stage/progress 驱动 GeneratingView。

import Foundation
import SwiftData
#if canImport(Combine)
import Combine
#endif

@MainActor
public final class ItineraryEngine: ObservableObject {
    public enum Stage: String, Sendable { case analyzing, routing, dining, transit, budgeting, done }
    public enum EngineError: Error, Equatable { case noCandidates, emptyPlan }

    @Published public private(set) var stage: Stage = .analyzing
    @Published public private(set) var progress: Double = 0

    private let source: POIDataSource
    private let llm: LLMProvider
    private let recall: POIRecall
    private let repository: TripRepository

    public init(source: POIDataSource = StubPOISource(),
                llm: LLMProvider = StubLLMProvider(),
                context: ModelContext,
                cacheTTL: TimeInterval = POICache.defaultTTL) {
        self.source = source
        self.llm = llm
        self.recall = POIRecall(source: source, cache: POICache(context: context, ttl: cacheTTL))
        self.repository = TripRepository(context: context)
    }

    /// 端到端生成并落库；返回写入的 Trip。
    @discardableResult
    public func generate(destination: String, prefs: TripPrefs,
                         days: Int, startDate: Date = .now) async throws -> Trip {
        set(.analyzing, 0.1)
        let (adcode, _) = try await source.geocodeCity(destination)

        let candidates = try await recall.recall(adcode: adcode, tags: prefs.tags)
        guard !candidates.isEmpty else { throw EngineError.noCandidates }
        set(.routing, 0.4)

        let perDay = try await ItineraryDayBuilder.planStops(prefs: prefs, candidates: candidates,
                                                             days: days, llm: llm)

        set(.dining, 0.6)
        guard perDay.contains(where: { !$0.isEmpty }) else { throw EngineError.emptyPlan }

        set(.transit, 0.8)
        let dayPlans = await buildDays(perDay, destination: destination, startDate: startDate)

        set(.budgeting, 0.95)
        let trip = try repository.create(
            city: destination, subtitle: destination, adcode: adcode, startDate: startDate,
            nights: max(0, days - 1), prefs: prefs, status: .ready, days: dayPlans
        )
        set(.done, 1.0)
        return trip
    }

    // MARK: - 步骤

    /// 组装每天的 PlanItem，并在相邻 POI 间补交通段（PDR T3.5）。
    private func buildDays(_ perDay: [[PlannedStop]], destination: String, startDate: Date) async -> [DayPlan] {
        let cal = Calendar.current
        var result: [DayPlan] = []
        for (index, stops) in perDay.enumerated() {
            let date = cal.date(byAdding: .day, value: index, to: startDate) ?? startDate
            let items = await ItineraryDayBuilder.buildItems(from: stops, source: source)
            result.append(DayPlan(dayIndex: index, date: date, cityLabel: destination, items: items))
        }
        return result
    }

    private func set(_ s: Stage, _ p: Double) { stage = s; progress = p }

}
