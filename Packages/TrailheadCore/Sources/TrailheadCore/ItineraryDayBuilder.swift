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
                                 startDate: Date? = nil,
                                 city: String = "",
                                 baseAnchor: POICandidate? = nil,
                                 constraints: PlanningConstraints = .init()) async throws -> [[PlannedStop]] {
        _ = llm  // 几何步骤不使用 LLM（保持 100% 确定性）；文案由上层 NoteWriter 叠加（P7.1），参数保留维持对外契约（C3）。

        // 1. 严格拆分主景点 / food。高德购物、娱乐、交通等类目不再伪装成主景点；
        //    用户明确要求的非餐饮地点仍作为硬/软约束保留。
        let allowedCandidates = candidates.filter { !constraints.excludedPOIIDs.contains($0.id) }
        let availableIDs = Set(allowedCandidates.map(\.id))
        let missingRequired = constraints.requiredPOIIDs.subtracting(availableIDs)
        if !missingRequired.isEmpty {
            throw PlanningConflict(code: .requiredPOINotFound,
                                   message: "有必去地点不在可用候选中。",
                                   affectedPOIIDs: missingRequired.sorted())
        }
        let explicitlyRequested = constraints.requiredPOIIDs.union(constraints.preferredPOIIDs)
        let sights = allowedCandidates.filter {
            CandidateCuration.isPrimaryAttraction($0)
                || (explicitlyRequested.contains($0.id) && $0.kind != .food && $0.kind != .lodging)
        }
        let food = allowedCandidates.filter { $0.kind == .food }
        let pace = prefs.pace
        let maxPerDay = DayClusterer.maxSights(for: pace)
        let comfortPolicy = DayComfortPolicy.policy(for: pace)

        // 综合分 + 停留先验的统一映射：D3 牺牲、D6 播种、D7 预算共用同一真源。
        let scores = Dictionary(allowedCandidates.map {
            let base = CandidateCuration.score($0, tags: prefs.tags, cuisines: prefs.cuisines,
                                               budgetPerDay: prefs.budgetPerDay)
            let protected = constraints.requiredPOIIDs.contains($0.id) ? 1_000 : 0
            let preferred = constraints.preferredPOIIDs.contains($0.id) ? 1.25 : 0
            return ($0.id, base + Double(protected) + preferred)
        },
                                uniquingKeysWith: { a, _ in a })
        let profiles = Dictionary(allowedCandidates.map { ($0.id, StayDuration.profile(for: $0)) },
                                  uniquingKeysWith: { a, _ in a })
        let stays = Dictionary(allowedCandidates.map {
            let profile = profiles[$0.id]!
            return ($0.id, profile.accessBufferMin
                + VisitProfileResolver.selectedMinutes(in: profile.duration, pace: pace)
                + profile.exitBufferMin)
        },
                               uniquingKeysWith: { a, _ in a })
        let stayBudget = comfortPolicy.loadBudget(dayStart: dayStart, dayEnd: dayEnd)
        let profileAnchorIDs = Set(profiles.compactMap { $0.value.isDayAnchor ? $0.key : nil })
        // 每个完整游玩日优先分配一个经典核心景点，再围绕核心点聚类补充附近景点。
        let classicAnchorIDs = selectClassicAnchors(from: sights, days: days)
        let dayAnchorIDs = profileAnchorIDs.union(classicAnchorIDs)
        // 天序号 → weekday（1=周一…7=周日；无日期 → nil，D2 退化 base）。
        let weekdays: [Int?] = (0..<max(days, 1)).map { weekday(of: startDate, dayOffset: $0) }

        // 2. 聚类分天（days==1 单日重生成跳过分天，全部候选进当天）。
        let initialClusters: [[POICandidate]] = days <= 1
            ? [sights]
            : DayClusterer.cluster(sights: sights, days: days, maxSightsPerDay: maxPerDay,
                                   scores: scores, stayMinutes: stays, stayBudget: stayBudget,
                                   dayAnchorIDs: dayAnchorIDs)
        var dayClusters = days <= 1 ? initialClusters : GlobalItineraryOptimizer.optimize(
            clusters: initialClusters, prefs: prefs, weekdays: weekdays, city: city,
            baseAnchor: baseAnchor, maxSightsPerDay: maxPerDay,
            dailyAnchorIDs: classicAnchorIDs
        )
        // 以 TOPTW 的“只插入可执行高价值点”为独立参考解，与现有“聚类 + Beam Search”
        // 在同一排程器和质量函数下择优；固定预约仍由原有专用顺序逻辑处理。
        let referenceContext = TOPTWReferenceSolver.Context(
            prefs: prefs, weekdays: weekdays, city: city, baseAnchor: baseAnchor,
            scores: scores, maxSightsPerDay: maxPerDay,
            dailyAnchorIDs: classicAnchorIDs,
            requiredPOIIDs: constraints.requiredPOIIDs,
            dailyWindows: constraints.dailyWindows
        )
        if constraints.fixedVisits.isEmpty {
            let referenceClusters = TOPTWReferenceSolver.solve(candidates: sights, context: referenceContext)
            dayClusters = ItinerarySolutionPortfolio.choose(
                incumbent: dayClusters, reference: referenceClusters,
                context: referenceContext, hasFixedVisits: false
            )
        }
        dayClusters = applyFixedAssignments(dayClusters, fixedVisits: constraints.fixedVisits,
                                            candidates: allowedCandidates)

        var usedFood: Set<String> = []
        var previousExit: (lat: Double, lng: Double)?
        var dayOrders: [[POICandidate]] = []
        var spillPool: [(day: Int, stop: SpilledStop)] = []
        var routerConverged: [Bool] = []

        for (dayIdx, cluster) in dayClusters.enumerated() {
            let wd = weekdays[min(dayIdx, weekdays.count - 1)]
            let window = constraints.dailyWindows.first { $0.dayIndex == dayIdx }
            let currentDayStart = window?.startMinute ?? dayStart
            let currentDayEnd = window?.endMinute ?? dayEnd
            let fixedForDay = constraints.fixedVisits.filter { $0.dayIndex == dayIdx }
            let fixedArrivals = Dictionary(uniqueKeysWithValues: fixedForDay.map { ($0.poiID, $0.arrivalMinute) })
            let correctedMinimumStays = Dictionary(uniqueKeysWithValues: fixedForDay.compactMap { visit in
                visit.minimumStayMinutes.map { (visit.poiID, $0) }
            })
            let baseCoordinate = baseAnchor.map { (lat: $0.lat, lng: $0.lng) }
            // 3. 簇内排序（贪心NN + 2-opt；天间用上一天出口锚点衔接；收敛标志供 D8 软断言）。
            let (routed, converged) = routeRespectingFixedVisits(
                cluster, fixedVisits: fixedForDay,
                entryAnchor: baseCoordinate ?? previousExit, exitAnchor: baseCoordinate
            )
            routerConverged.append(converged)
            // 4. 第一遍模拟（仅景点）→ 临时时刻线；丢点按分牺牲进 spill 池（D1/D3）。
            let first = ScheduleSimulator.simulate(stops: routed, pace: pace, city: city, weekday: wd,
                                                   dayStart: currentDayStart, dayEnd: currentDayEnd, scores: scores,
                                                   entryAnchor: baseAnchor, exitAnchor: baseAnchor,
                                                   fixedArrivals: fixedArrivals,
                                                   minimumStays: correctedMinimumStays,
                                                   comfortPolicy: comfortPolicy)
            spillPool += first.spilled.map { (day: dayIdx, stop: $0) }
            // 5. 按临时时刻线插午/晚餐（餐窗中点定位 + 顺路绕行选店，跨天去重，D1）。
            let withMeals = MealSlotter.insertMeals(schedule: first.scheduled, foodPool: food,
                                                    usedIds: usedFood, cuisines: prefs.cuisines,
                                                    budgetPerDay: prefs.budgetPerDay,
                                                    weekday: wd)
            // 6. 第二遍模拟（景点+餐饮）→ 终版顺序；被挤掉的景点同样进 spill（餐饮软约束不重插）。
            let second = ScheduleSimulator.simulate(stops: withMeals, pace: pace, city: city, weekday: wd,
                                                    dayStart: currentDayStart, dayEnd: currentDayEnd, scores: scores,
                                                    entryAnchor: baseAnchor, exitAnchor: baseAnchor,
                                                    fixedArrivals: fixedArrivals,
                                                    minimumStays: correctedMinimumStays,
                                                    comfortPolicy: comfortPolicy)
            spillPool += second.spilled.filter { $0.candidate.kind != .food }
                .map { (day: dayIdx, stop: $0) }
            for stop in second.scheduled where stop.candidate.kind == .food {
                usedFood.insert(stop.candidate.id)
            }
            dayOrders.append(second.scheduled.map(\.candidate))
            if baseAnchor == nil {
                previousExit = second.scheduled.last.map { (lat: $0.candidate.lat, lng: $0.candidate.lng) }
            }
        }

        // 7. SpillRepair：spill 按分数降序跨天重插；days==1 无处可去，直接进丢弃清单（D3）。
        var dropped: [SpilledStop] = []
        if days > 1, !spillPool.isEmpty {
            let ctx = SpillRepair.Context(pace: pace, city: city, weekdays: weekdays,
                                          dayStart: dayStart, dayEnd: dayEnd, scores: scores,
                                          baseAnchor: baseAnchor, maxSightsPerDay: maxPerDay,
                                          stayBudget: stayBudget, comfortPolicy: comfortPolicy)
            (dayOrders, dropped) = SpillRepair.repair(dayOrders: dayOrders, spill: spillPool, context: ctx)
        } else {
            dropped = spillPool.map(\.stop)
        }

        // 8. 终版模拟（纯函数重放，与第 6/7 步一致）并装配 PlannedStop（Int 分钟 → "HH:mm"）；
        //    note 留空（未决②：P7 NoteWriter 本期不做）。
        var result: [[PlannedStop]] = []
        for (dayIdx, order) in dayOrders.enumerated() {
            let wd = weekdays[min(dayIdx, weekdays.count - 1)]
            let window = constraints.dailyWindows.first { $0.dayIndex == dayIdx }
            let fixedForDay = constraints.fixedVisits.filter { $0.dayIndex == dayIdx }
            let sim = ScheduleSimulator.simulate(stops: order, pace: pace, city: city, weekday: wd,
                                                 dayStart: window?.startMinute ?? dayStart,
                                                 dayEnd: window?.endMinute ?? dayEnd, scores: scores,
                                                 entryAnchor: baseAnchor, exitAnchor: baseAnchor,
                                                 fixedArrivals: Dictionary(uniqueKeysWithValues: fixedForDay.map {
                                                     ($0.poiID, $0.arrivalMinute)
                                                 }),
                                                 minimumStays: Dictionary(uniqueKeysWithValues: fixedForDay.compactMap { visit in
                                                     visit.minimumStayMinutes.map { (visit.poiID, $0) }
                                                 }),
                                                 comfortPolicy: comfortPolicy)
            result.append(sim.scheduled.map {
                PlannedStop(candidate: $0.candidate, time: clock($0.arrival),
                            stayMin: $0.stayMin, note: nil)
            })
        }

        // 出口自检（§7）：硬约束校验并返回最优可行子集，不抛错；软约束记 warning/info。
        let feasible = ItineraryFeasibility.check(result, days: days, maxSightsPerDay: maxPerDay,
                                                  weekdays: weekdays, dropped: dropped,
                                                  routerConverged: routerConverged).plan
        let finalIDs = Set(feasible.flatMap { $0.map(\.candidate.id) })
        let droppedRequired = constraints.requiredPOIIDs.subtracting(finalIDs)
        if !droppedRequired.isEmpty {
            throw PlanningConflict(
                code: .requiredPOIDropped,
                message: "当前日期、营业时间和行程负荷无法同时保留全部必去地点。",
                affectedPOIIDs: droppedRequired.sorted(),
                repairOptions: [
                    RepairOption(title: "延长到 21:00", detail: "为必去地点留出更多时间。",
                                 patches: [.init(path: .defaultDayEnd, value: .int(21 * 60),
                                                 source: .userExplicit)]),
                    RepairOption(title: "改为紧凑节奏", detail: "缩短普通地点停留，优先保留必去点。",
                                 patches: [.init(path: .preferencePace, value: .string(Pace.tight.rawValue),
                                                 source: .userExplicit)]),
                ]
            )
        }
        return feasible
    }

    /// 从高知名候选中挑每日核心景点：先保代表性，再兼顾地理分散。
    /// 没有任何知名度证据（旧测试桩/离线第三方数据）时不强造 anchor，沿用纯地理聚类。
    private static func selectClassicAnchors(from sights: [POICandidate], days: Int) -> Set<String> {
        let target = min(max(1, days), sights.count)
        guard target > 0, sights.contains(where: { CandidateCuration.fameScore($0) > 0 }) else { return [] }

        let ranked = sights.sorted {
            let left = CandidateCuration.classicPriorityScore($0)
            let right = CandidateCuration.classicPriorityScore($1)
            return left == right ? $0.id < $1.id : left > right
        }
        // 只在较高知名度候选中做地理分散，防止偏远冷门点仅凭距离成为每日核心。
        let poolCount = min(ranked.count, max(target, target * 4))
        let pool = Array(ranked.prefix(poolCount))
        var chosen = [pool[0]]

        while chosen.count < target {
            let remaining = pool.filter { candidate in !chosen.contains(where: { $0.id == candidate.id }) }
            guard !remaining.isEmpty else { break }
            let priorities = remaining.map(CandidateCuration.classicPriorityScore)
            let distances = remaining.map { candidate in
                chosen.map { haversineMeters(candidate, $0) }.min() ?? 0
            }
            let priorityMin = priorities.min() ?? 0
            let priorityRange = max(0.000_001, (priorities.max() ?? priorityMin) - priorityMin)
            let distanceMax = max(1, distances.max() ?? 1)
            let bestIndex = remaining.indices.max { left, right in
                let leftValue = 0.7 * ((priorities[left] - priorityMin) / priorityRange)
                    + 0.3 * (distances[left] / distanceMax)
                let rightValue = 0.7 * ((priorities[right] - priorityMin) / priorityRange)
                    + 0.3 * (distances[right] / distanceMax)
                return leftValue == rightValue ? remaining[left].id > remaining[right].id : leftValue < rightValue
            } ?? 0
            chosen.append(remaining[bestIndex])
        }
        return Set(chosen.map(\.id))
    }

    private static func applyFixedAssignments(_ clusters: [[POICandidate]],
                                              fixedVisits: [FixedVisit],
                                              candidates: [POICandidate]) -> [[POICandidate]] {
        guard !fixedVisits.isEmpty else { return clusters }
        let fixedIDs = Set(fixedVisits.map(\.poiID))
        let lookup = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var result = clusters.map { $0.filter { !fixedIDs.contains($0.id) } }
        for visit in fixedVisits.sorted(by: {
            $0.dayIndex == $1.dayIndex ? $0.arrivalMinute < $1.arrivalMinute : $0.dayIndex < $1.dayIndex
        }) where result.indices.contains(visit.dayIndex) {
            if let candidate = lookup[visit.poiID] { result[visit.dayIndex].append(candidate) }
        }
        return result
    }

    private static func routeRespectingFixedVisits(
        _ cluster: [POICandidate], fixedVisits: [FixedVisit],
        entryAnchor: (lat: Double, lng: Double)?, exitAnchor: (lat: Double, lng: Double)?
    ) -> (tour: [POICandidate], converged: Bool) {
        guard !fixedVisits.isEmpty else {
            return DayRouter.routeWithDiagnostics(cluster, entryAnchor: entryAnchor, exitAnchor: exitAnchor)
        }
        let fixedByID = Dictionary(uniqueKeysWithValues: fixedVisits.map { ($0.poiID, $0) })
        let fixed = cluster.filter { fixedByID[$0.id] != nil }.sorted {
            fixedByID[$0.id]!.arrivalMinute < fixedByID[$1.id]!.arrivalMinute
        }
        var flexible = cluster.filter { fixedByID[$0.id] == nil }
        var result: [POICandidate] = []
        var anchor = entryAnchor
        for stop in fixed {
            if !flexible.isEmpty {
                let nearest = flexible.indices.min { left, right in
                    guard let anchor else { return flexible[left].id < flexible[right].id }
                    let a = POICandidate(id: "__entry__", name: "", kind: .sight, subtype: "",
                                         lat: anchor.lat, lng: anchor.lng)
                    return haversineMeters(a, flexible[left]) < haversineMeters(a, flexible[right])
                } ?? 0
                result.append(flexible.remove(at: nearest))
            }
            result.append(stop)
            anchor = (stop.lat, stop.lng)
        }
        result.append(contentsOf: DayRouter.route(flexible, entryAnchor: anchor, exitAnchor: exitAnchor))
        return (result, true)
    }

    /// 用最终候选边的真实高德交通耗时重放排程。真实耗时导致溢出时，景点会再次尝试跨天重插；
    /// 新产生的相邻边在下一轮补取，直到顺序稳定或达到有限轮次。请求复用由 RouteMemoizingPOISource 承担。
    public static func reconcileWithRoutes(stops: [[PlannedStop]], prefs: TripPrefs,
                                           source: POIDataSource, city: String,
                                           startDate: Date? = nil,
                                           baseAnchor: POICandidate? = nil,
                                           constraints: PlanningConstraints = .init(),
                                           maxPasses: Int = 4) async -> [[PlannedStop]] {
        guard !stops.isEmpty else { return [] }

        var orders = stops.map { $0.map(\.candidate) }
        var travelTimes: RouteTimeMatrix = [:]
        let weekdays = stops.indices.map { weekday(of: startDate, dayOffset: $0) }
        let maxPerDay = DayClusterer.maxSights(for: prefs.pace)
        let comfortPolicy = DayComfortPolicy.policy(for: prefs.pace)
        let stayBudget = comfortPolicy.loadBudget(dayStart: dayStart, dayEnd: dayEnd)
        let scores = Dictionary(orders.flatMap { $0 }.map {
            ($0.id, CandidateCuration.score($0, tags: prefs.tags, cuisines: prefs.cuisines,
                                            budgetPerDay: prefs.budgetPerDay))
        }, uniquingKeysWith: { a, _ in a })

        for _ in 0..<max(1, maxPasses) {
            travelTimes = await loadRouteTimes(for: orders, baseAnchor: baseAnchor,
                                               source: source, city: city,
                                               existing: travelTimes,
                                               allowedModes: constraints.allowedModes,
                                               maxWalkingMinutes: constraints.maxWalkingMinutesPerSegment)
            var nextOrders: [[POICandidate]] = []
            var spill: [(day: Int, stop: SpilledStop)] = []
            var scheduledByDay: [[ScheduledStop]] = []

            for (dayIndex, order) in orders.enumerated() {
                let window = constraints.dailyWindows.first { $0.dayIndex == dayIndex }
                let fixed = constraints.fixedVisits.filter { $0.dayIndex == dayIndex }
                let simulation = ScheduleSimulator.simulate(
                    stops: order, pace: prefs.pace, city: city,
                    weekday: weekdays[dayIndex], dayStart: window?.startMinute ?? dayStart,
                    dayEnd: window?.endMinute ?? dayEnd,
                    scores: scores, travelTimes: travelTimes,
                    entryAnchor: baseAnchor, exitAnchor: baseAnchor,
                    fixedArrivals: Dictionary(uniqueKeysWithValues: fixed.map { ($0.poiID, $0.arrivalMinute) }),
                    minimumStays: Dictionary(uniqueKeysWithValues: fixed.compactMap { visit in
                        visit.minimumStayMinutes.map { (visit.poiID, $0) }
                    }),
                    comfortPolicy: comfortPolicy
                )
                scheduledByDay.append(simulation.scheduled)
                nextOrders.append(simulation.scheduled.map(\.candidate))
                spill += simulation.spilled.filter { $0.candidate.kind != .food }
                    .map { (day: dayIndex, stop: $0) }
            }

            if orders.count > 1, !spill.isEmpty {
                let context = SpillRepair.Context(
                    pace: prefs.pace, city: city, weekdays: weekdays,
                    dayStart: dayStart, dayEnd: dayEnd, scores: scores,
                    travelTimes: travelTimes, baseAnchor: baseAnchor,
                    maxSightsPerDay: maxPerDay,
                    stayBudget: stayBudget, comfortPolicy: comfortPolicy
                )
                nextOrders = SpillRepair.repair(dayOrders: nextOrders, spill: spill, context: context).dayOrders
            }

            let stable = spill.isEmpty && orderIDs(nextOrders) == orderIDs(orders)
            orders = nextOrders
            if stable {
                return scheduledByDay.map { day in
                    day.map {
                        PlannedStop(candidate: $0.candidate, time: clock($0.arrival),
                                    stayMin: $0.stayMin, note: nil)
                    }
                }
            }
        }

        travelTimes = await loadRouteTimes(for: orders, baseAnchor: baseAnchor,
                                           source: source, city: city,
                                           existing: travelTimes,
                                           allowedModes: constraints.allowedModes,
                                           maxWalkingMinutes: constraints.maxWalkingMinutesPerSegment)
        return orders.enumerated().map { dayIndex, order in
            let window = constraints.dailyWindows.first { $0.dayIndex == dayIndex }
            let fixed = constraints.fixedVisits.filter { $0.dayIndex == dayIndex }
            return ScheduleSimulator.simulate(
                stops: order, pace: prefs.pace, city: city,
                weekday: weekdays[dayIndex], dayStart: window?.startMinute ?? dayStart,
                dayEnd: window?.endMinute ?? dayEnd,
                scores: scores, travelTimes: travelTimes,
                entryAnchor: baseAnchor, exitAnchor: baseAnchor,
                fixedArrivals: Dictionary(uniqueKeysWithValues: fixed.map { ($0.poiID, $0.arrivalMinute) }),
                minimumStays: Dictionary(uniqueKeysWithValues: fixed.compactMap { visit in
                    visit.minimumStayMinutes.map { (visit.poiID, $0) }
                }),
                comfortPolicy: comfortPolicy
            ).scheduled.map {
                PlannedStop(candidate: $0.candidate, time: clock($0.arrival),
                            stayMin: $0.stayMin, note: nil)
            }
        }
    }

    private static func loadRouteTimes(for orders: [[POICandidate]], baseAnchor: POICandidate?,
                                       source: POIDataSource, city: String,
                                       existing: RouteTimeMatrix,
                                       allowedModes: Set<TransitMode>,
                                       maxWalkingMinutes: Int?) async -> RouteTimeMatrix {
        var matrix = existing
        for order in orders where order.count > 1 {
            for index in 1..<order.count {
                let from = order[index - 1]
                let to = order[index]
                let key = RouteTimeKey(fromID: from.id, toID: to.id)
                guard matrix[key] == nil else { continue }
                let segment = await routedSegment(from: from, to: to, source: source, city: city,
                                                  allowedModes: allowedModes,
                                                  maxWalkingMinutes: maxWalkingMinutes)
                matrix[key] = segment.minutes
            }
        }
        if let baseAnchor {
            for order in orders {
                if let first = order.first {
                    let key = RouteTimeKey(fromID: baseAnchor.id, toID: first.id)
                    if matrix[key] == nil {
                        let segment = await routedSegment(from: baseAnchor, to: first,
                                                          source: source, city: city,
                                                          allowedModes: allowedModes,
                                                          maxWalkingMinutes: maxWalkingMinutes)
                        matrix[key] = segment.minutes
                    }
                }
                if let last = order.last {
                    let key = RouteTimeKey(fromID: last.id, toID: baseAnchor.id)
                    if matrix[key] == nil {
                        let segment = await routedSegment(from: last, to: baseAnchor,
                                                          source: source, city: city,
                                                          allowedModes: allowedModes,
                                                          maxWalkingMinutes: maxWalkingMinutes)
                        matrix[key] = segment.minutes
                    }
                }
            }
        }
        return matrix
    }

    private static func orderIDs(_ orders: [[POICandidate]]) -> [[String]] {
        orders.map { $0.map(\.id) }
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
    public static func buildItems(from stops: [PlannedStop], source: POIDataSource, city: String = "",
                                  allowedModes: Set<TransitMode> = Set(TransitMode.allCases),
                                  maxWalkingMinutes: Int? = nil) async -> [PlanItem] {
        var items: [PlanItem] = []
        var order = 0
        var previous: POICandidate?
        for stop in stops {
            if let previous {
                let segment = await routedSegment(from: previous, to: stop.candidate,
                                                  source: source, city: city,
                                                  allowedModes: allowedModes,
                                                  maxWalkingMinutes: maxWalkingMinutes)
                let transit = PlanItem(order: order, kind: .transit)
                transit.transitMode = segment.mode
                transit.transitDesc = segment.mode.display
                transit.transitMinutes = segment.minutes
                transit.transitMeters = segment.meters
                transit.transitCost = segment.cost
                transit.transitReliability = segment.reliability
                items.append(transit)
                order += 1
            }

            let poi = PlanItem(order: order, kind: stop.candidate.kind)
            poi.poiId = stop.candidate.id
            poi.name = stop.candidate.name
            poi.subtype = stop.candidate.subtype
            poi.lat = stop.candidate.lat
            poi.lng = stop.candidate.lng
            poi.plannedTime = stop.time
            poi.stayLabel = stop.stayMin.map(stayLabel)
            poi.plannedStayMinutes = stop.stayMin
            let profile = StayDuration.profile(for: stop.candidate)
            poi.minimumStayMinutes = profile.duration.minimum
            poi.comfortableStayMinutes = profile.duration.comfortable
            poi.extendedStayMinutes = profile.duration.extended
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
        constrainedMode(from: from, to: to, city: city,
                        allowedModes: Set(TransitMode.allCases), maxWalkingMinutes: nil)
    }

    static func constrainedMode(from: POICandidate, to: POICandidate, city: String,
                                allowedModes: Set<TransitMode>,
                                maxWalkingMinutes: Int?) -> TransitMode {
        let distance = haversineMeters(from, to)
        let estimatedWalk = TravelEstimator.minutes(from: from, to: to, mode: .walk)
        let walkAllowed = allowedModes.contains(.walk)
            && maxWalkingMinutes.map { estimatedWalk <= $0 } != false
        if WaterGate.crossesWater(from, to), allowedModes.contains(.ferry) { return .ferry }
        if distance <= 1_500, walkAllowed { return .walk }

        let preferred: [TransitMode] = city.isEmpty
            ? [.drive, .taxi, .bus, .metro, .train, .ferry]
            : [.metro, .bus, .taxi, .drive, .train, .ferry]
        if let mode = preferred.first(where: allowedModes.contains) { return mode }
        // The compiler rejects an empty set. If walking is the only allowed mode,
        // return it here and let the real-route validator report an exact over-limit conflict.
        return allowedModes.sorted { $0.rawValue < $1.rawValue }.first ?? .walk
    }

    /// 步行路网距离 / 直线距离超过该倍数 → 疑似水域/障碍分隔（如轮渡场景），回填非步行（P6.3）。
    static let walkDetourCap = 3.0

    /// 请求一段真实交通（供 buildItems / rebuildDay 共用）：mode() 初判；步行段若
    /// 路网严重绕行或请求失败，改用非步行模式重请求（真实 route 回填，短距跨水不再误判步行）。
    public static func routedSegment(from: POICandidate, to: POICandidate,
                                     source: POIDataSource, city: String,
                                     allowedModes: Set<TransitMode> = Set(TransitMode.allCases),
                                     maxWalkingMinutes: Int? = nil)
        async -> (mode: TransitMode, minutes: Int, meters: Int, cost: Int?, reliability: TransitReliability) {
        let initial = constrainedMode(from: from, to: to, city: city,
                                      allowedModes: allowedModes,
                                      maxWalkingMinutes: maxWalkingMinutes)
        let fallback = (city.isEmpty
            ? [TransitMode.drive, .taxi, .bus, .metro, .train, .ferry]
            : [TransitMode.metro, .bus, .taxi, .drive, .train, .ferry])
            .first(where: allowedModes.contains)

        if let seg = try? await source.route(from: from, to: to, mode: initial, city: city) {
            // 步行路网远超直线（低于 200m 的近点不触发，避免噪声）→ 跨水特征，回填非步行。
            if initial == .walk,
               Double(seg.meters) > walkDetourCap * max(haversineMeters(from, to), 200),
               let fallback,
               let alt = try? await source.route(from: from, to: to, mode: fallback, city: city) {
                return (fallback, alt.minutes, alt.meters, alt.cost, .verified)
            }
            return (initial, seg.minutes, seg.meters, seg.cost, .verified)
        }
        // 步行请求失败（水域不可达等）→ 尝试非步行回填；其余模式失败按原语义跳过该段。
        if initial == .walk, let fallback,
           let alt = try? await source.route(from: from, to: to, mode: fallback, city: city) {
            return (fallback, alt.minutes, alt.meters, alt.cost, .verified)
        }
        let estimatedMode = initial == .walk ? (fallback ?? initial) : initial
        return (
            estimatedMode,
            TravelEstimator.minutes(from: from, to: to, mode: estimatedMode),
            TravelEstimator.meters(from: from, to: to, mode: estimatedMode),
            nil,
            .estimated
        )
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
