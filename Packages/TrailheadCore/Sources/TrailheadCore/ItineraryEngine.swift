//  ItineraryEngine.swift
//  生成流水线（PDR §3 七步 / T3.6 / T3.7）。串联：地理编码 → 缓存优先召回 →
//  LLM 编排（poi_id 锁定）→ JSON 解析(重试1次)→ FactChecker → 路线补全 → 落库。
//  @Published stage/progress 驱动 GeneratingView。

import Foundation
import SwiftData
#if canImport(Combine)
import Combine
#endif

public struct GenerationDiagnostics: Codable, Equatable, Sendable {
    public var recalledCandidates: Int = 0
    public var curatedCandidates: Int = 0
    public var cacheLookups: Int = 0
    public var cacheHits: Int = 0
    public var provisionalStops: Int = 0
    public var finalStops: Int = 0
    public var transitSegments: Int = 0
    public var verifiedTransitSegments: Int = 0
    public var estimatedTransitSegments: Int = 0
    public var droppedStops: Int = 0
    public var amapCalls: Int = 0
    public var llmCalls: Int = 0
    public var llmInputTokens: Int = 0
    public var llmOutputTokens: Int = 0
    public var stageDurationsMs: [String: Int] = [:]
    public var usedLodgingAnchor = false
    public var warnings: [String] = []

    public init() {}

    public var redactedSummary: String {
        var lines = [
            "候选：召回 \(recalledCandidates) / 筛选 \(curatedCandidates)",
            "缓存：命中 \(cacheHits) / 查询 \(cacheLookups)",
            "停留：初排 \(provisionalStops) / 最终 \(finalStops) / 移除 \(droppedStops)",
            "交通：真实 \(verifiedTransitSegments) / 估算 \(estimatedTransitSegments)",
            "调用：高德 \(amapCalls) / DeepSeek \(llmCalls)",
            "Token：输入 \(llmInputTokens) / 输出 \(llmOutputTokens)",
        ]
        if !stageDurationsMs.isEmpty {
            let stages = stageDurationsMs.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)ms" }.joined(separator: " · ")
            lines.append("阶段：\(stages)")
        }
        if !warnings.isEmpty { lines.append("提示：\(warnings.joined(separator: "；"))") }
        return lines.joined(separator: "\n")
    }
}

public struct GenerationDiagnosticsStore {
    private let defaults: UserDefaults
    private let key = "generation.diagnostics.last"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func save(_ diagnostics: GenerationDiagnostics) {
        defaults.set(try? JSONEncoder().encode(diagnostics), forKey: key)
    }

    public func load() -> GenerationDiagnostics? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(GenerationDiagnostics.self, from: data)
    }
}

@MainActor
public final class ItineraryEngine: ObservableObject {
    public enum Stage: String, Sendable { case analyzing, routing, dining, transit, budgeting, done }
    public enum EngineError: Error, Equatable { case noCandidates, emptyPlan }

    @Published public private(set) var stage: Stage = .analyzing
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var diagnostics = GenerationDiagnostics()

    private let source: POIDataSource
    private let llm: LLMProvider
    private let recall: POIRecall
    private let repository: TripRepository
    private var diagnosticStage: Stage?
    private var diagnosticStageStartedAt = Date()

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
        diagnostics = GenerationDiagnostics()
        diagnosticStage = nil
        let usage = UsageStore()
        let initialAmapCalls = usage.count(.amap)
        let initialLLMCalls = usage.count(.llm)
        let initialInputTokens = usage.llmInputTokens()
        let initialOutputTokens = usage.llmOutputTokens()
        set(.analyzing, 0.1)
        let (adcode, rawCenter) = try await source.geocodeCity(destination)
        let cityCenter = (lat: rawCenter.1, lng: rawCenter.0)

        // 吃住玩均衡：三支柱必含 + 兴趣；菜系/住宿类型替换对应召回词。
        let categories = AmapCategory.recallCategories(for: prefs)
        var cacheLookups = 0
        var cacheHits = 0
        let candidates = try await recall.recall(
            adcode: adcode, tags: categories, freeText: prefs.freeText,
            onCacheLookup: { hit in
                cacheLookups += 1
                if hit { cacheHits += 1 }
            }
        )
        guard !candidates.isEmpty else { throw EngineError.noCandidates }
        diagnostics.recalledCandidates = candidates.count
        diagnostics.cacheLookups = cacheLookups
        diagnostics.cacheHits = cacheHits
        set(.routing, 0.4)

        // 确定性规则：点评分 + 偏好加权筛出每类高分点；freeText 点名的点豁免必留。
        let pinned = Self.pinnedIDs(in: candidates, freeText: prefs.freeText)
        let itineraryCandidates = CandidateCuration.curate(candidates.filter { $0.kind != .lodging },
                                                           tags: prefs.tags, cuisines: prefs.cuisines,
                                                           budgetPerDay: prefs.budgetPerDay, pinned: pinned)
        guard !itineraryCandidates.isEmpty else { throw EngineError.noCandidates }
        // 住宿先以已筛出的路线候选中位点做保守锚定；距候选路线过远的住宿不参与每天首尾卡点。
        let provisionalRouteCoords = itineraryCandidates.map { (lat: $0.lat, lng: $0.lng) }
        let initialLodging = Self.lodgingShortlist(from: candidates, prefs: prefs, anchor: cityCenter,
                                                   routeCoords: provisionalRouteCoords,
                                                   maxDistanceMeters: 15_000)
        let baseAnchor = initialLodging.first.flatMap { option in
            candidates.first { $0.id == option.id }
        }
        diagnostics.curatedCandidates = itineraryCandidates.count
        diagnostics.usedLodgingAnchor = baseAnchor != nil

        // startDate 使 D2 周闭馆逐日生效（天序号 → weekday 由 planStops 推导）。
        let perDay = try await ItineraryDayBuilder.planStops(prefs: prefs, candidates: itineraryCandidates,
                                                             days: days, llm: llm, startDate: startDate,
                                                             city: adcode, baseAnchor: baseAnchor)
        diagnostics.provisionalStops = perDay.reduce(0) { $0 + $1.count }

        let routedSource = RouteMemoizingPOISource(base: source)
        let reconciled = await ItineraryDayBuilder.reconcileWithRoutes(
            stops: perDay, prefs: prefs, source: routedSource,
            city: adcode, startDate: startDate, baseAnchor: baseAnchor
        )
        diagnostics.finalStops = reconciled.reduce(0) { $0 + $1.count }
        let droppedByRealRoutes = diagnostics.provisionalStops - diagnostics.finalStops
        diagnostics.droppedStops = max(0, droppedByRealRoutes)
        if droppedByRealRoutes > 0 {
            diagnostics.warnings.append("真实路线校准后移除 \(droppedByRealRoutes) 个不可行停留")
        }
        let routeCoords = reconciled.flatMap { day in
            day.map { (lat: $0.candidate.lat, lng: $0.candidate.lng) }
        }
        let lodging = Self.lodgingShortlist(from: candidates, prefs: prefs,
                                            anchor: cityCenter, routeCoords: routeCoords)

        set(.dining, 0.6)
        guard reconciled.contains(where: { !$0.isEmpty }) else { throw EngineError.emptyPlan }

        // 几何定稿后，LLM 只补文案（note + 每日主题）；失败自动降级留空，不阻断生成（P7.1）。
        let annotated = await NoteWriter.annotate(stops: reconciled, prefs: prefs, llm: llm)

        set(.transit, 0.8)
        let foodPool = candidates.filter { $0.kind == .food }
        let dayPlans = await buildDays(annotated.stops, themes: annotated.themes,
                                       destination: destination, adcode: adcode,
                                       startDate: startDate, foodPool: foodPool,
                                       routeSource: routedSource)
        let transitItems = dayPlans.flatMap(\.items).filter { $0.kind == .transit }
        diagnostics.transitSegments = transitItems.count
        diagnostics.estimatedTransitSegments = transitItems.filter { $0.transitReliability == .estimated }.count
        diagnostics.verifiedTransitSegments = transitItems.count - diagnostics.estimatedTransitSegments
        if diagnostics.estimatedTransitSegments > 0 {
            diagnostics.warnings.append("有 \(diagnostics.estimatedTransitSegments) 段交通使用估算时间，待联网校准")
        }

        set(.budgeting, 0.95)
        let trip = try repository.create(
            city: destination, subtitle: destination, adcode: adcode, startDate: startDate,
            nights: max(0, days - 1), prefs: prefs, status: .ready, days: dayPlans, lodging: lodging
        )
        set(.done, 1.0)
        diagnostics.amapCalls = max(0, usage.count(.amap) - initialAmapCalls)
        diagnostics.llmCalls = max(0, usage.count(.llm) - initialLLMCalls)
        diagnostics.llmInputTokens = max(0, usage.llmInputTokens() - initialInputTokens)
        diagnostics.llmOutputTokens = max(0, usage.llmOutputTokens() - initialOutputTokens)
        GenerationDiagnosticsStore().save(diagnostics)
        return trip
    }

    /// freeText 点名命中的候选 id（名称含任一关键词）——这些点豁免筛选、必定保留。
    static func pinnedIDs(in candidates: [POICandidate], freeText: String) -> Set<String> {
        let keywords = POIKeywordExtractor.keywords(from: freeText)
        guard !keywords.isEmpty else { return [] }
        return Set(candidates.filter { c in keywords.contains { c.name.contains($0) } }.map(\.id))
    }

    /// 取评分最高的若干住宿作为候选清单（PDR：住宿不排进动线，单独成清单）。
    static func lodgingShortlist(from candidates: [POICandidate], prefs: TripPrefs? = nil,
                                 anchor: (lat: Double, lng: Double)? = nil,
                                 routeCoords: [(lat: Double, lng: Double)] = [],
                                 maxDistanceMeters: Double = 30_000,
                                 limit: Int = 6) -> [LodgingOption] {
        let lodging = candidates.filter { $0.kind == .lodging }
        let routeAnchor = routeMedian(routeCoords) ?? anchor
        let named = Set(lodging.filter { candidate in
            guard let prefs else { return false }
            return prefs.freeText.contains(candidate.name)
                || pinnedIDs(in: [candidate], freeText: prefs.freeText).contains(candidate.id)
        }.map(\.id))
        let filtered = lodging.filter { candidate in
            guard let routeAnchor else { return true }
            return distance(from: candidate, to: routeAnchor) <= maxDistanceMeters || named.contains(candidate.id)
        }
        let ranked = filtered.sorted { lhs, rhs in
            let leftDistance = routeAnchor.map { distance(from: lhs, to: $0) }
            let rightDistance = routeAnchor.map { distance(from: rhs, to: $0) }
            let left = lodgingScore(lhs, prefs: prefs, distanceMeters: leftDistance)
            let right = lodgingScore(rhs, prefs: prefs, distanceMeters: rightDistance)
            return left == right ? lhs.id < rhs.id : left > right
        }
        let diverse = priceDiversePrefix(ranked, prefs: prefs, limit: limit)
        return diverse.map { candidate in
            let nearest = routeCoords.map {
                NearbyFood.meters(candidate.lat, candidate.lng, $0.lat, $0.lng)
            }.min() ?? routeAnchor.map { distance(from: candidate, to: $0) }
            let rounded = nearest.map { Int($0.rounded()) }
            return LodgingOption(id: candidate.id, name: candidate.name, rating: candidate.rating,
                                 avgPrice: candidate.avgPrice, lat: candidate.lat, lng: candidate.lng,
                                 tags: candidate.tags, photos: candidate.photos,
                                 distanceMeters: rounded,
                                 estimatedMinutes: rounded.map(lodgingMinutes))
        }
    }

    private static func lodgingScore(_ candidate: POICandidate, prefs: TripPrefs?,
                                     distanceMeters: Double? = nil) -> Double {
        var score = candidate.rating ?? CandidateCuration.neutralRating
        if let distanceMeters {
            score -= min(4, distanceMeters / 8_000)
        }
        guard let prefs else { return score }
        if !prefs.lodgingType.isEmpty,
           CandidateCuration.matchesAny(candidate, terms: [prefs.lodgingType]) {
            score += 0.75
        }
        if let price = candidate.avgPrice {
            let target = max(1, Double(prefs.budgetPerDay) * 0.5)
            let ratio = Double(price) / target
            score += ratio <= 1 ? 0.25 : -min(2, (ratio - 1) * 0.75)
        }
        return score
    }

    private static func routeMedian(_ coords: [(lat: Double, lng: Double)]) -> (lat: Double, lng: Double)? {
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.lat).sorted(), lngs = coords.map(\.lng).sorted()
        let middle = coords.count / 2
        if coords.count.isMultiple(of: 2) {
            return ((lats[middle - 1] + lats[middle]) / 2,
                    (lngs[middle - 1] + lngs[middle]) / 2)
        }
        return (lats[middle], lngs[middle])
    }

    private static func distance(from candidate: POICandidate,
                                 to anchor: (lat: Double, lng: Double)) -> Double {
        NearbyFood.meters(candidate.lat, candidate.lng, anchor.lat, anchor.lng)
    }

    private enum PriceBand: Hashable { case low, middle, high, unknown }

    private static func priceBand(_ candidate: POICandidate, prefs: TripPrefs?) -> PriceBand {
        guard let price = candidate.avgPrice, let prefs else { return .unknown }
        let target = max(1, Double(prefs.budgetPerDay) * 0.5)
        if Double(price) < target * 0.65 { return .low }
        if Double(price) <= target * 1.25 { return .middle }
        return .high
    }

    private static func priceDiversePrefix(_ ranked: [POICandidate], prefs: TripPrefs?,
                                           limit: Int) -> [POICandidate] {
        guard limit > 0, let first = ranked.first else { return [] }
        var selected = [first]
        var bands = Set([priceBand(first, prefs: prefs)])
        for candidate in ranked.dropFirst() where selected.count < min(3, limit) {
            let band = priceBand(candidate, prefs: prefs)
            if band != .unknown, bands.insert(band).inserted { selected.append(candidate) }
        }
        let selectedIDs = Set(selected.map(\.id))
        selected.append(contentsOf: ranked.filter { !selectedIDs.contains($0.id) }
            .prefix(max(0, limit - selected.count)))
        return Array(selected.prefix(limit))
    }

    private static func lodgingMinutes(_ meters: Int) -> Int {
        let routedMeters = Double(meters) * TravelEstimator.circuity(for: .drive)
        return max(1, Int((routedMeters / (TravelEstimator.speedKmh(for: .drive) * 1_000 / 60)).rounded()))
    }

    // MARK: - 步骤

    /// 组装每天的 PlanItem，并在相邻 POI 间补交通段（PDR T3.5）。themes 与 perDay 天序对齐（P7）。
    private func buildDays(_ perDay: [[PlannedStop]], themes: [String?], destination: String,
                           adcode: String, startDate: Date, foodPool: [POICandidate],
                           routeSource: POIDataSource) async -> [DayPlan] {
        let cal = Calendar.current
        var result: [DayPlan] = []
        for (index, stops) in perDay.enumerated() {
            let date = cal.date(byAdding: .day, value: index, to: startDate) ?? startDate
            let items = await ItineraryDayBuilder.buildItems(from: stops, source: routeSource, city: adcode)
            let day = DayPlan(dayIndex: index, date: date, cityLabel: destination, items: items)
            day.theme = (themes.indices.contains(index) ? themes[index] : nil) ?? ""
            day.foodOptions = Self.nearbyFood(forItems: items, foodPool: foodPool)
            result.append(day)
        }
        return result
    }

    /// 当天附近高分美食：以当天景点坐标为参照，排除已排进动线的餐饮。
    static func nearbyFood(forItems items: [PlanItem], foodPool: [POICandidate]) -> [FoodOption] {
        let coords: [(lat: Double, lng: Double)] = items
            .filter { $0.kind != .transit }
            .compactMap { item in item.lat.flatMap { lat in item.lng.map { (lat, $0) } } }
        let used = Set(items.compactMap(\.poiId))
        return NearbyFood.pick(foodPool, nearCoords: coords, excluding: used)
    }

    private func set(_ s: Stage, _ p: Double) {
        let now = Date()
        if let diagnosticStage, diagnosticStage != s {
            let elapsed = max(0, Int(now.timeIntervalSince(diagnosticStageStartedAt) * 1_000))
            diagnostics.stageDurationsMs[diagnosticStage.rawValue, default: 0] += elapsed
        }
        diagnosticStage = s
        diagnosticStageStartedAt = now
        stage = s
        progress = p
    }

}
