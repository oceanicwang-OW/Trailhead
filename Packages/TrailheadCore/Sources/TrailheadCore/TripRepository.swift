//  TripRepository.swift
//  Trip 的增删改查 + 行程项重排封装（PDR T1.4 / T6.1）。视图用 @Query 直驱
//  读取；写操作收口到此处，便于落库与重排一致。

import Foundation
import SwiftData

public enum TripRepositoryError: Error, Equatable {
    case missingAdcode
}

public struct TripRepository {
    public let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    // MARK: - Create

    @discardableResult
    public func create(city: String, subtitle: String = "", adcode: String = "",
                       startDate: Date = .now, nights: Int = 3, prefs: TripPrefs = .init(),
                       status: TripStatus = .draft, accentSeed: Int = 0,
                       days: [DayPlan] = [], lodging: [LodgingOption] = []) throws -> Trip {
        let trip = Trip(city: city, subtitle: subtitle, adcode: adcode, startDate: startDate,
                        nights: nights, prefs: prefs, status: status, accentSeed: accentSeed,
                        days: days, lodging: lodging)
        context.insert(trip)
        try context.save()
        return trip
    }

    public func insert(_ trip: Trip) throws {
        context.insert(trip)
        try context.save()
    }

    // MARK: - Read

    /// 全部行程，按创建时间倒序（与侧栏 @Query 一致）。
    public func all() throws -> [Trip] {
        try context.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }

    public func trip(id: UUID) throws -> Trip? {
        try context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })).first
    }

    public func count() throws -> Int {
        try context.fetchCount(FetchDescriptor<Trip>())
    }

    // MARK: - Update / Delete

    public func save() throws { try context.save() }

    public func delete(_ trip: Trip) throws {
        context.delete(trip)
        try context.save()
    }

    /// 清空全部行程（设置页"清除全部数据"用，PDR T7.3）。
    public func deleteAll() throws {
        try context.delete(model: Trip.self)
        try context.save()
    }

    // MARK: - Reorder（PDR T1.4 重排封装 / T6.1）

    /// 按给定 id 顺序重写某天行程项的 `order`；未列出的项 order 不变。
    public func reorder(_ day: DayPlan, orderedItemIDs ids: [UUID]) throws {
        var indexByID: [UUID: Int] = [:]
        for (index, id) in ids.enumerated() { indexByID[id] = index }
        for item in day.items where indexByID[item.id] != nil {
            item.order = indexByID[item.id]!
        }
        try context.save()
    }

    /// Reorder only POI rows while keeping existing transit rows in their current slots.
    public func reorderPOIs(_ day: DayPlan, orderedPOIIDs ids: [UUID]) throws {
        let sortedItems = day.sortedItems
        let poiByID = Dictionary(uniqueKeysWithValues:
            sortedItems.filter { $0.kind != .transit }.map { ($0.id, $0) })
        var orderedPOIs = ids.compactMap { poiByID[$0] }
        let knownIDs = Set(ids)
        orderedPOIs.append(contentsOf: sortedItems.filter { $0.kind != .transit && !knownIDs.contains($0.id) })

        var poiIndex = 0
        var reordered: [PlanItem] = []
        for item in sortedItems {
            if item.kind == .transit {
                reordered.append(item)
            } else if poiIndex < orderedPOIs.count {
                reordered.append(orderedPOIs[poiIndex])
                poiIndex += 1
            }
        }

        for (index, item) in reordered.enumerated() {
            item.order = index
        }
        try context.save()
    }

    /// Delete one POI and rebuild transit rows between the remaining POIs.
    /// `adcode` 用于公交路线 city；缺省（"")时远途退化为驾车。
    /// @MainActor：ModelContext / @Model 操作须在主线程（route 网络经 await 仍在后台）。
    @MainActor
    public func deletePOI(_ item: PlanItem, from day: DayPlan,
                          routeUsing source: POIDataSource, adcode: String = "") async throws {
        guard item.kind != .transit else { return }
        let remainingPOIs = day.sortedItems.filter { $0.kind != .transit && $0.id != item.id }
        context.delete(item)
        try await rebuildDay(day, withPOIs: remainingPOIs, routeUsing: source, city: adcode)
    }

    /// Replace one POI and rebuild transit rows while preserving its schedule fields and position.
    @MainActor
    public func replacePOI(_ item: PlanItem, with candidate: POICandidate,
                           in day: DayPlan, routeUsing source: POIDataSource, adcode: String = "") async throws {
        guard item.kind != .transit else { return }
        item.poiId = candidate.id
        item.name = candidate.name
        item.kind = candidate.kind
        item.subtype = candidate.subtype
        item.lat = candidate.lat
        item.lng = candidate.lng
        let orderedPOIs = day.sortedItems.filter { $0.kind != .transit }
        try await rebuildDay(day, withPOIs: orderedPOIs, routeUsing: source, city: adcode)
    }

    /// Regenerate one existing day without changing the parent trip or other days.
    @MainActor
    public func regenerateDay(_ day: DayPlan, in trip: Trip,
                              source: POIDataSource, llm: LLMProvider) async throws {
        let adcode = trip.adcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adcode.isEmpty else { throw TripRepositoryError.missingAdcode }

        let recall = POIRecall(source: source, cache: POICache(context: context))
        let categories = AmapCategory.recallCategories(for: trip.prefs)
        let candidates = try await recall.recall(adcode: adcode, tags: categories, freeText: trip.prefs.freeText)
        // 住宿单独成清单；行程候选走确定性筛选（点评分 + 偏好加权 + 点名豁免，与整趟生成同规则）。
        let pinned = ItineraryEngine.pinnedIDs(in: candidates, freeText: trip.prefs.freeText)
        let itineraryCandidates = CandidateCuration.curate(candidates.filter { $0.kind != .lodging },
                                                           tags: trip.prefs.tags, pinned: pinned)
        guard !itineraryCandidates.isEmpty else { throw ItineraryEngine.EngineError.noCandidates }

        let perDay = try await ItineraryDayBuilder.planStops(prefs: trip.prefs,
                                                             candidates: itineraryCandidates,
                                                             days: 1,
                                                             llm: llm)
        guard let stops = perDay.first, !stops.isEmpty else {
            throw ItineraryEngine.EngineError.emptyPlan
        }
        // 几何定稿后补文案（note + 当天主题）；失败自动降级留空（P7.1）。
        let annotated = await NoteWriter.annotate(stops: [stops], prefs: trip.prefs, llm: llm)
        let annotatedStops = annotated.stops.first ?? stops
        day.theme = annotated.themes.first.flatMap { $0 } ?? day.theme
        let newItems = await ItineraryDayBuilder.buildItems(from: annotatedStops, source: source, city: adcode)

        for old in day.items {
            context.delete(old)
        }
        day.items = newItems
        for (index, item) in day.sortedItems.enumerated() {
            item.order = index
        }
        day.foodOptions = ItineraryEngine.nearbyFood(forItems: newItems,
                                                     foodPool: candidates.filter { $0.kind == .food })
        try context.save()
    }
}

private extension TripRepository {
    @MainActor
    func rebuildDay(_ day: DayPlan, withPOIs orderedPOIs: [PlanItem],
                    routeUsing source: POIDataSource, city: String = "") async throws {
        var transitBeforePOI: [UUID: PlanItem] = [:]
        var previousCandidate: POICandidate?
        for poi in orderedPOIs {
            guard let candidate = poi.routeCandidate else {
                previousCandidate = nil
                continue
            }
            if let previousCandidate {
                let mode = Self.mode(from: previousCandidate, to: candidate, city: city)
                if let segment = try? await source.route(from: previousCandidate, to: candidate, mode: mode, city: city) {
                    let transit = PlanItem(order: 0, kind: .transit)
                    transit.transitMode = mode
                    transit.transitDesc = mode.display
                    transit.transitMinutes = segment.minutes
                    transit.transitMeters = segment.meters
                    transit.transitCost = segment.cost
                    transitBeforePOI[poi.id] = transit
                }
            }
            previousCandidate = candidate
        }

        for removed in day.items where removed.kind == .transit {
            context.delete(removed)
        }

        var rebuilt: [PlanItem] = []
        var order = 0
        for poi in orderedPOIs {
            if let transit = transitBeforePOI[poi.id] {
                transit.order = order
                rebuilt.append(transit)
                order += 1
            }
            poi.order = order
            rebuilt.append(poi)
            order += 1
        }
        day.items = rebuilt
        try context.save()
    }

    static func mode(from: POICandidate, to: POICandidate, city: String) -> TransitMode {
        if WaterGate.crossesWater(from, to) { return .ferry }  // 水域兜底（P6.3），与 ItineraryDayBuilder.mode() 同源
        guard haversineMeters(from, to) > 1500 else { return .walk }
        return city.isEmpty ? .drive : .metro
    }

    static func haversineMeters(_ a: POICandidate, _ b: POICandidate) -> Double {
        let radius = 6_371_000.0
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLng = (b.lng - a.lng) * .pi / 180
        let lat1 = a.lat * .pi / 180
        let lat2 = b.lat * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * radius * asin(min(1, sqrt(h)))
    }
}

private extension PlanItem {
    var routeCandidate: POICandidate? {
        guard kind != .transit,
              let poiId,
              let name,
              let lat,
              let lng else { return nil }
        return POICandidate(id: poiId, name: name, kind: kind, subtype: subtype ?? "", lat: lat, lng: lng)
    }
}
