//  ItineraryDayBuilder.swift
//  单日/整趟行程的确定性编排（PDR 编排层改造 §3）。planStops 内部为 6 步纯几何流水线：
//  拆分 → 聚类分天 → 簇内排序 → 餐饮卡点 → 前向模拟赋时 → 装配 PlannedStop。
//  DeepSeek 已被移出几何步骤；time/stayMin 由模拟器确定性产出，不再由 LLM 拍脑袋。

import Foundation

public enum ItineraryDayBuilder {
    /// 签名保持不变（对外契约）。内部替换为确定性几何流水线；`days==1` 单日重生成走同一路径。
    public static func planStops(prefs: TripPrefs, candidates: [POICandidate],
                                 days: Int, llm: LLMProvider) async throws -> [[PlannedStop]] {
        _ = llm  // 几何步骤不使用 LLM；P7（NoteWriter）本期不做，保留参数维持对外契约不变（C3）。

        // 1. 按 kind 拆分：sights（含 other，即非食非住）/ food。住宿已在调用前剔除。
        let sights = candidates.filter { $0.kind != .food }
        let food = candidates.filter { $0.kind == .food }
        let pace = prefs.pace
        let maxPerDay = DayClusterer.maxSights(for: pace)

        // 2. 聚类分天（days==1 单日重生成跳过分天，全部候选进当天）。
        let dayClusters: [[POICandidate]] = days <= 1
            ? [sights]
            : DayClusterer.cluster(sights: sights, days: days, maxSightsPerDay: maxPerDay)

        var usedFood: Set<String> = []
        var previousExit: (lat: Double, lng: Double)?
        var result: [[PlannedStop]] = []

        for cluster in dayClusters {
            // 3. 簇内排序（贪心NN + 2-opt；天间用上一天出口锚点衔接）。
            let routed = DayRouter.route(cluster, entryAnchor: previousExit)
            // 4. 餐饮卡点（就近高分插午/晚餐；跨天去重）。
            let withMeals = MealSlotter.insertMeals(sights: routed, foodPool: food, usedIds: usedFood)
            for stop in withMeals where stop.kind == .food { usedFood.insert(stop.id) }
            // 5. 前向模拟赋 time/stayMin + 营业窗过滤（city 未入签名，估时按驾车/步行）。
            let scheduled = ScheduleSimulator.simulate(stops: withMeals, pace: pace, city: "")
            // 6. 装配 PlannedStop（Int 分钟 → "HH:mm"）；note 留空（P7 未做本期）。
            result.append(scheduled.map {
                PlannedStop(candidate: $0.candidate, time: clock($0.arrival),
                            stayMin: $0.stayMin, note: nil)
            })
            previousExit = scheduled.last.map { (lat: $0.candidate.lat, lng: $0.candidate.lng) }
        }
        return result
    }

    /// 当日分钟数 → "HH:mm"。仅在装配 PlannedStop 时用，内部一律 Int 运算（B5）。
    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// @MainActor：创建 PlanItem(@Model) 须与 mainContext 同处主线程；route 网络经 await 仍在后台。
    @MainActor
    public static func buildItems(from stops: [PlannedStop], source: POIDataSource, city: String = "") async -> [PlanItem] {
        var items: [PlanItem] = []
        var order = 0
        var previous: POICandidate?
        for stop in stops {
            if let previous {
                let mode = mode(from: previous, to: stop.candidate, city: city)
                if let segment = try? await source.route(from: previous, to: stop.candidate, mode: mode, city: city) {
                    let transit = PlanItem(order: order, kind: .transit)
                    transit.transitMode = mode
                    transit.transitDesc = mode.display
                    transit.transitMinutes = segment.minutes
                    transit.transitMeters = segment.meters
                    transit.transitCost = segment.cost
                    items.append(transit)
                    order += 1
                }
            }

            let poi = PlanItem(order: order, kind: stop.candidate.kind)
            poi.poiId = stop.candidate.id
            poi.name = stop.candidate.name
            poi.subtype = stop.candidate.subtype
            poi.lat = stop.candidate.lat
            poi.lng = stop.candidate.lng
            poi.plannedTime = stop.time
            poi.stayLabel = stop.stayMin.map(stayLabel)
            poi.note = stop.note
            items.append(poi)
            order += 1
            previous = stop.candidate
        }
        return items
    }

    static func stayLabel(_ minutes: Int) -> String {
        minutes >= 60 ? "约 \(String(format: "%g", (Double(minutes) / 60 * 10).rounded() / 10)) 小时" : "\(minutes) 分钟"
    }

    /// 短途步行；远途有 city 走公交、无 city 退化驾车（与 AmapClient.route 一致，标签不串）。
    static func mode(from: POICandidate, to: POICandidate, city: String) -> TransitMode {
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
