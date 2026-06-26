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

        let plan = try await planWithRetry(prefs: prefs, candidates: candidates, days: days)

        set(.dining, 0.6)
        let perDay = FactChecker.reconcile(plan, candidates: candidates)
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

    /// 解析失败重试一次（PDR T3.3）。
    private func planWithRetry(prefs: TripPrefs, candidates: [POICandidate], days: Int) async throws -> ItineraryPlan {
        let first = try await llm.planItinerary(prefs: prefs, candidates: candidates, days: days)
        if let plan = try? ItineraryParser.parse(first) { return plan }
        let retry = try await llm.planItinerary(prefs: prefs, candidates: candidates, days: days)
        return try ItineraryParser.parse(retry)   // 二次仍失败则抛出
    }

    /// 组装每天的 PlanItem，并在相邻 POI 间补交通段（PDR T3.5）。
    private func buildDays(_ perDay: [[PlannedStop]], destination: String, startDate: Date) async -> [DayPlan] {
        let cal = Calendar.current
        var result: [DayPlan] = []
        for (index, stops) in perDay.enumerated() {
            let date = cal.date(byAdding: .day, value: index, to: startDate) ?? startDate
            var items: [PlanItem] = []
            var order = 0
            var prev: POICandidate?
            for stop in stops {
                if let prev {
                    let mode = Self.mode(from: prev, to: stop.candidate)
                    if let seg = try? await source.route(from: prev, to: stop.candidate, mode: mode) {
                        let transit = PlanItem(order: order, kind: .transit)
                        transit.transitMode = mode
                        transit.transitDesc = mode.display
                        transit.transitMinutes = seg.minutes
                        transit.transitMeters = seg.meters
                        transit.transitCost = seg.cost
                        items.append(transit); order += 1
                    }
                }
                let poi = PlanItem(order: order, kind: stop.candidate.kind)
                poi.poiId = stop.candidate.id
                poi.name = stop.candidate.name
                poi.subtype = stop.candidate.subtype
                poi.lat = stop.candidate.lat
                poi.lng = stop.candidate.lng
                poi.plannedTime = stop.time
                poi.stayLabel = stop.stayMin.map(Self.stayLabel)
                poi.note = stop.note
                items.append(poi); order += 1
                prev = stop.candidate
            }
            result.append(DayPlan(dayIndex: index, date: date, cityLabel: destination, items: items))
        }
        return result
    }

    private func set(_ s: Stage, _ p: Double) { stage = s; progress = p }

    // MARK: - 工具

    static func stayLabel(_ minutes: Int) -> String {
        minutes >= 60 ? "约 \(String(format: "%g", (Double(minutes) / 60 * 10).rounded() / 10)) 小时" : "\(minutes) 分钟"
    }

    /// 直线距离 >1.5km 走公交，否则步行（粗略选路，真实时长由 route 给）。
    static func mode(from: POICandidate, to: POICandidate) -> TransitMode {
        haversineMeters(from, to) > 1500 ? .metro : .walk
    }

    static func haversineMeters(_ a: POICandidate, _ b: POICandidate) -> Double {
        let radius = 6_371_000.0
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLng = (b.lng - a.lng) * .pi / 180
        let lat1 = a.lat * .pi / 180, lat2 = b.lat * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * radius * asin(min(1, sqrt(h)))
    }
}
