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

        // 吃住玩均衡：三支柱必含 + 兴趣；菜系/住宿类型替换对应召回词。
        let categories = AmapCategory.recallCategories(for: prefs)
        let candidates = try await recall.recall(adcode: adcode, tags: categories, freeText: prefs.freeText)
        guard !candidates.isEmpty else { throw EngineError.noCandidates }
        set(.routing, 0.4)

        // 住宿拆成单独清单（不排进每日动线）；行程编排只用非住宿候选。
        let lodging = Self.lodgingShortlist(from: candidates)
        // 确定性规则：点评分 + 偏好加权筛出每类高分点；freeText 点名的点豁免必留。
        let pinned = Self.pinnedIDs(in: candidates, freeText: prefs.freeText)
        let itineraryCandidates = CandidateCuration.curate(candidates.filter { $0.kind != .lodging },
                                                           tags: prefs.tags, pinned: pinned)
        guard !itineraryCandidates.isEmpty else { throw EngineError.noCandidates }

        let perDay = try await ItineraryDayBuilder.planStops(prefs: prefs, candidates: itineraryCandidates,
                                                             days: days, llm: llm)

        set(.dining, 0.6)
        guard perDay.contains(where: { !$0.isEmpty }) else { throw EngineError.emptyPlan }

        // 几何定稿后，LLM 只补文案（note + 每日主题）；失败自动降级留空，不阻断生成（P7.1）。
        let annotated = await NoteWriter.annotate(stops: perDay, prefs: prefs, llm: llm)

        set(.transit, 0.8)
        let foodPool = candidates.filter { $0.kind == .food }
        let dayPlans = await buildDays(annotated.stops, themes: annotated.themes,
                                       destination: destination, adcode: adcode,
                                       startDate: startDate, foodPool: foodPool)

        set(.budgeting, 0.95)
        let trip = try repository.create(
            city: destination, subtitle: destination, adcode: adcode, startDate: startDate,
            nights: max(0, days - 1), prefs: prefs, status: .ready, days: dayPlans, lodging: lodging
        )
        set(.done, 1.0)
        return trip
    }

    /// freeText 点名命中的候选 id（名称含任一关键词）——这些点豁免筛选、必定保留。
    static func pinnedIDs(in candidates: [POICandidate], freeText: String) -> Set<String> {
        let keywords = POIKeywordExtractor.keywords(from: freeText)
        guard !keywords.isEmpty else { return [] }
        return Set(candidates.filter { c in keywords.contains { c.name.contains($0) } }.map(\.id))
    }

    /// 取评分最高的若干住宿作为候选清单（PDR：住宿不排进动线，单独成清单）。
    static func lodgingShortlist(from candidates: [POICandidate], limit: Int = 6) -> [LodgingOption] {
        candidates
            .filter { $0.kind == .lodging }
            .sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
            .prefix(limit)
            .map { LodgingOption(id: $0.id, name: $0.name, rating: $0.rating,
                                 avgPrice: $0.avgPrice, lat: $0.lat, lng: $0.lng) }
    }

    // MARK: - 步骤

    /// 组装每天的 PlanItem，并在相邻 POI 间补交通段（PDR T3.5）。themes 与 perDay 天序对齐（P7）。
    private func buildDays(_ perDay: [[PlannedStop]], themes: [String?], destination: String,
                           adcode: String, startDate: Date, foodPool: [POICandidate]) async -> [DayPlan] {
        let cal = Calendar.current
        var result: [DayPlan] = []
        for (index, stops) in perDay.enumerated() {
            let date = cal.date(byAdding: .day, value: index, to: startDate) ?? startDate
            let items = await ItineraryDayBuilder.buildItems(from: stops, source: source, city: adcode)
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

    private func set(_ s: Stage, _ p: Double) { stage = s; progress = p }

}
