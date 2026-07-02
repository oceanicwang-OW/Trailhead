//  ItineraryDayBuilder.swift
//  单日/整趟行程的确定性编排（PDR 编排层改造 §3，v2 八步）。planStops 内部为纯几何流水线：
//  拆分 → 聚类分天 → 逐天(簇内排序 → 第一遍模拟 → 插餐 → 第二遍模拟) → spill 跨天重插 → 装配。
//  DeepSeek 已被移出几何步骤；time/stayMin 由模拟器确定性产出，不再由 LLM 拍脑袋。
//  确定性契约（D6）：同输入必同输出（无随机源；Set/Dictionary 遍历处一律先排序）。

import Foundation

public enum ItineraryDayBuilder {
    /// 每日活动窗（未决①：本期写死 09:00–20:00，做成常量待验证稳定后再开放 TripPrefs/UI）。
    public static let dayStart = 9 * 60
    public static let dayEnd = 20 * 60

    /// 对外契约不变（PDR §0）；`startDate` 为带默认值的新增参数——既有调用点零改动，
    /// 提供后可推导「天序号 → weekday」使 D2 周闭馆逐日生效；nil 则退化 base 语义。
    /// `days==1`（单日重生成）走同一路径：跳过分天，spill 无处可去直接进丢弃清单；
    /// 排除集（D9）由调用方在 candidates 里预先过滤（见 TripRepository.regenerateDay）。
    public static func planStops(prefs: TripPrefs, candidates: [POICandidate],
                                 days: Int, llm: LLMProvider,
                                 startDate: Date? = nil) async throws -> [[PlannedStop]] {
        _ = llm  // 几何步骤不使用 LLM（保持 100% 确定性）；文案由上层 NoteWriter 叠加（P7.1），参数保留维持对外契约（C3）。

        // 1. 按 kind 拆分：sights（含 other，即非食非住）/ food。住宿已在调用前剔除。
        let sights = candidates.filter { $0.kind != .food }
        let food = candidates.filter { $0.kind == .food }
        let pace = prefs.pace
        let maxPerDay = DayClusterer.maxSights(for: pace)

        // 综合分 + 停留先验的统一映射：D3 牺牲、D6 播种、D7 预算共用同一真源。
        let scores = Dictionary(candidates.map { ($0.id, CandidateCuration.score($0, tags: prefs.tags)) },
                                uniquingKeysWith: { a, _ in a })
        let stays = Dictionary(candidates.map { ($0.id, StayDuration.duration(for: $0, pace: pace)) },
                               uniquingKeysWith: { a, _ in a })
        let stayBudget = Int(DayClusterer.defaultTimeBudgetRatio * Double(dayEnd - dayStart))
        // 天序号 → weekday（1=周一…7=周日；无日期 → nil，D2 退化 base）。
        let weekdays: [Int?] = (0..<max(days, 1)).map { weekday(of: startDate, dayOffset: $0) }

        // 2. 聚类分天（days==1 单日重生成跳过分天，全部候选进当天）。
        let dayClusters: [[POICandidate]] = days <= 1
            ? [sights]
            : DayClusterer.cluster(sights: sights, days: days, maxSightsPerDay: maxPerDay,
                                   scores: scores, stayMinutes: stays, stayBudget: stayBudget)

        var usedFood: Set<String> = []
        var previousExit: (lat: Double, lng: Double)?
        var dayOrders: [[POICandidate]] = []
        var spillPool: [(day: Int, stop: SpilledStop)] = []
        var routerConverged: [Bool] = []

        for (dayIdx, cluster) in dayClusters.enumerated() {
            let wd = weekdays[min(dayIdx, weekdays.count - 1)]
            // 3. 簇内排序（贪心NN + 2-opt；天间用上一天出口锚点衔接；收敛标志供 D8 软断言）。
            let (routed, converged) = DayRouter.routeWithDiagnostics(cluster, entryAnchor: previousExit)
            routerConverged.append(converged)
            // 4. 第一遍模拟（仅景点）→ 临时时刻线；丢点按分牺牲进 spill 池（D1/D3）。
            let first = ScheduleSimulator.simulate(stops: routed, pace: pace, city: "", weekday: wd,
                                                   dayStart: dayStart, dayEnd: dayEnd, scores: scores)
            spillPool += first.spilled.map { (day: dayIdx, stop: $0) }
            // 5. 按临时时刻线插午/晚餐（餐窗中点定位 + 顺路绕行选店，跨天去重，D1）。
            let withMeals = MealSlotter.insertMeals(schedule: first.scheduled, foodPool: food,
                                                    usedIds: usedFood)
            for stop in withMeals where stop.kind == .food { usedFood.insert(stop.id) }
            // 6. 第二遍模拟（景点+餐饮）→ 终版顺序；被挤掉的景点同样进 spill（餐饮软约束不重插）。
            let second = ScheduleSimulator.simulate(stops: withMeals, pace: pace, city: "", weekday: wd,
                                                    dayStart: dayStart, dayEnd: dayEnd, scores: scores)
            spillPool += second.spilled.filter { $0.candidate.kind != .food }
                .map { (day: dayIdx, stop: $0) }
            dayOrders.append(second.scheduled.map(\.candidate))
            previousExit = second.scheduled.last.map { (lat: $0.candidate.lat, lng: $0.candidate.lng) }
        }

        // 7. SpillRepair：spill 按分数降序跨天重插；days==1 无处可去，直接进丢弃清单（D3）。
        var dropped: [SpilledStop] = []
        if days > 1, !spillPool.isEmpty {
            let ctx = SpillRepair.Context(pace: pace, city: "", weekdays: weekdays,
                                          dayStart: dayStart, dayEnd: dayEnd, scores: scores,
                                          maxSightsPerDay: maxPerDay, stayBudget: stayBudget)
            (dayOrders, dropped) = SpillRepair.repair(dayOrders: dayOrders, spill: spillPool, context: ctx)
        } else {
            dropped = spillPool.map(\.stop)
        }

        // 8. 终版模拟（纯函数重放，与第 6/7 步一致）并装配 PlannedStop（Int 分钟 → "HH:mm"）；
        //    note 留空（未决②：P7 NoteWriter 本期不做）。
        var result: [[PlannedStop]] = []
        for (dayIdx, order) in dayOrders.enumerated() {
            let wd = weekdays[min(dayIdx, weekdays.count - 1)]
            let sim = ScheduleSimulator.simulate(stops: order, pace: pace, city: "", weekday: wd,
                                                 dayStart: dayStart, dayEnd: dayEnd, scores: scores)
            result.append(sim.scheduled.map {
                PlannedStop(candidate: $0.candidate, time: clock($0.arrival),
                            stayMin: $0.stayMin, note: nil)
            })
        }

        // 出口自检（§7）：硬约束校验并返回最优可行子集，不抛错；软约束记 warning/info。
        return ItineraryFeasibility.check(result, days: days, maxSightsPerDay: maxPerDay,
                                          weekdays: weekdays, dropped: dropped,
                                          routerConverged: routerConverged).plan
    }

    /// 天序号 → weekday（1=周一…7=周日）。无日期返回 nil（D2 退化 base 语义）。
    static func weekday(of startDate: Date?, dayOffset: Int) -> Int? {
        guard let startDate else { return nil }
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: dayOffset, to: startDate) ?? startDate
        let w = cal.component(.weekday, from: date)   // Apple: 1=周日…7=周六
        return w == 1 ? 7 : w - 1
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
                if let segment = await routedSegment(from: previous, to: stop.candidate,
                                                     source: source, city: city) {
                    let transit = PlanItem(order: order, kind: .transit)
                    transit.transitMode = segment.mode
                    transit.transitDesc = segment.mode.display
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

    /// 跨水域强制轮渡（P6.3 WaterGate 水域兜底，先于阈值判定，已配置离岛不再误判步行）；
    /// 否则短途步行；远途有 city 走公交、无 city 退化驾车（与 AmapClient.route 一致，标签不串）。
    /// 未配置进 WaterGate 的跨水段由 routedSegment 的真实路线回填兜底（A1：不抬 1500m 阈值）。
    static func mode(from: POICandidate, to: POICandidate, city: String) -> TransitMode {
        if WaterGate.crossesWater(from, to) { return .ferry }
        guard haversineMeters(from, to) > 1500 else { return .walk }
        return city.isEmpty ? .drive : .metro
    }

    /// 步行路网距离 / 直线距离超过该倍数 → 疑似水域/障碍分隔（如轮渡场景），回填非步行（P6.3）。
    static let walkDetourCap = 3.0

    /// 请求一段真实交通（供 buildItems / rebuildDay 共用）：mode() 初判；步行段若
    /// 路网严重绕行或请求失败，改用非步行模式重请求（真实 route 回填，短距跨水不再误判步行）。
    public static func routedSegment(from: POICandidate, to: POICandidate,
                                     source: POIDataSource, city: String)
        async -> (mode: TransitMode, minutes: Int, meters: Int, cost: Int?)? {
        let initial = mode(from: from, to: to, city: city)
        let fallback: TransitMode = city.isEmpty ? .drive : .metro

        if let seg = try? await source.route(from: from, to: to, mode: initial, city: city) {
            // 步行路网远超直线（低于 200m 的近点不触发，避免噪声）→ 跨水特征，回填非步行。
            if initial == .walk,
               Double(seg.meters) > walkDetourCap * max(haversineMeters(from, to), 200),
               let alt = try? await source.route(from: from, to: to, mode: fallback, city: city) {
                return (fallback, alt.minutes, alt.meters, alt.cost)
            }
            return (initial, seg.minutes, seg.meters, seg.cost)
        }
        // 步行请求失败（水域不可达等）→ 尝试非步行回填；其余模式失败按原语义跳过该段。
        if initial == .walk,
           let alt = try? await source.route(from: from, to: to, mode: fallback, city: city) {
            return (fallback, alt.minutes, alt.meters, alt.cost)
        }
        return nil
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
