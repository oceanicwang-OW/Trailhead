//  DayClusterer.swift
//  聚类分天（PDR §4.4，v2 含 D6/D7）。把「哪些点排在同一天」从大模型盲排收回为**确定性几何**：
//  投影到局部平面 → k-means 成团 → 容量约束均衡分配 → 天序按质心 NN 链接（相邻天地理相邻）。
//  D6 确定性播种：首质心取综合分最高点（平手按 poi_id 字典序），其后 farthest-point；
//  同输入必同输出，「重新生成的多样性」由显式 seedOffset 承担而非随机性副作用。
//  D7 时间预算容量：Σ停留 ≤ 预算，点数或时间任一超限即满簇（双博物馆吃满一天不再超编）。
//  纯函数。sights<days 降级为轻量天，不抛错。

import Foundation

public enum DayClusterer {
    /// 每天景点数上限（B2，可配的 pace 映射）：紧凑多、随性少。
    public static func maxSights(for pace: Pace) -> Int {
        switch pace {
        case .tight:   return 5
        case .relaxed: return 4
        case .casual:  return 3
        }
    }

    /// 时间预算比例 α（D7，可配）：Σ停留 ≤ α × (dayEnd − dayStart)，剩余留给通勤与餐饮。
    public static let defaultTimeBudgetRatio = 0.65

    /// 输出长度恒为 `days`：每天一组景点；点数<天数时尾部为轻量（空）天。
    /// `scores`：poi_id → 综合分（D6 播种用，缺省回退 rating ?? 中性分）。
    /// `stayMinutes` + `stayBudget`：D7 时间预算容量（stayBudget=nil 关闭）。
    /// `seedOffset`：显式轮换首质心（重新生成时的确定性多样性来源）。
    public static func cluster(sights: [POICandidate], days: Int,
                               maxSightsPerDay: Int, iterations: Int = 10,
                               scores: [String: Double] = [:],
                               stayMinutes: [String: Int] = [:],
                               stayBudget: Int? = nil,
                               seedOffset: Int = 0) -> [[POICandidate]] {
        guard days > 0 else { return [] }
        guard !sights.isEmpty else { return Array(repeating: [], count: days) }

        let n = sights.count
        let k = min(days, n)
        let pts = GeoProjection.project(sights)

        // k-means（D6 确定性播种 → 迭代赋质心）。
        var centroids = initialCentroids(pts, k: k, sights: sights, scores: scores, seedOffset: seedOffset)
        var labels = [Int](repeating: 0, count: n)
        for _ in 0..<max(1, iterations) {
            for i in 0..<n { labels[i] = nearest(pts[i], centroids) }
            var sumX = [Double](repeating: 0, count: k)
            var sumY = [Double](repeating: 0, count: k)
            var cnts = [Int](repeating: 0, count: k)
            for i in 0..<n {
                let l = labels[i]
                sumX[l] += pts[i].x; sumY[l] += pts[i].y; cnts[l] += 1
            }
            for c in 0..<k where cnts[c] > 0 {
                centroids[c] = GeoProjection.Point(x: sumX[c] / Double(cnts[c]), y: sumY[c] / Double(cnts[c]))
            }
        }

        // 容量约束分配：点数容量 = clamp(ceil(N/days), [2, maxSightsPerDay])；时间预算（D7）
        // 任一超限即满簇。按 regret（次近−最近）降序逐点分配（平手 poi_id），满则退最近可用簇，
        // 全满则溢出到最近簇（保证不丢点，超编交由模拟器按分牺牲）。
        let capacity = max(2, min(maxSightsPerDay, (n + days - 1) / days))
        var buckets = Array(repeating: [Int](), count: k)
        var counts = [Int](repeating: 0, count: k)
        var stayLoad = [Int](repeating: 0, count: k)
        func isFull(_ c: Int, adding stay: Int) -> Bool {
            if counts[c] >= capacity { return true }
            if let budget = stayBudget, stayLoad[c] + stay > budget { return true }
            return false
        }
        let order = (0..<n).sorted {
            let (ra, rb) = (regret($0, pts, centroids), regret($1, pts, centroids))
            return ra == rb ? sights[$0].id < sights[$1].id : ra > rb
        }
        for i in order {
            let stay = stayMinutes[sights[i].id] ?? 0
            let ranked = (0..<k).sorted { dist(pts[i], centroids[$0]) < dist(pts[i], centroids[$1]) }
            let target = ranked.first(where: { !isFull($0, adding: stay) }) ?? ranked[0]
            buckets[target].append(i)
            counts[target] += 1
            stayLoad[target] += stay
        }

        // 天序：对簇质心跑一次 NN 路径，使相邻两天地理相邻；不足天数尾部补轻量天。
        var result = nearestNeighborOrder(centroids).map { c in buckets[c].map { sights[$0] } }
        while result.count < days { result.append([]) }
        return result
    }

    // MARK: - Geometry helpers（投影平面上的欧氏距离）

    private static func dist(_ a: GeoProjection.Point, _ b: GeoProjection.Point) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func nearest(_ p: GeoProjection.Point, _ centroids: [GeoProjection.Point]) -> Int {
        (0..<centroids.count).min(by: { dist(p, centroids[$0]) < dist(p, centroids[$1]) }) ?? 0
    }

    /// regret = 到次近质心距离 − 到最近质心距离；簇数<2 时为 0。高 regret 的点「非它不可」，优先安置。
    private static func regret(_ i: Int, _ pts: [GeoProjection.Point], _ centroids: [GeoProjection.Point]) -> Double {
        guard centroids.count >= 2 else { return 0 }
        let sorted = centroids.map { dist(pts[i], $0) }.sorted()
        return sorted[1] - sorted[0]
    }

    /// D6 确定性播种：首质心取综合分最高点（平手 poi_id 升序；seedOffset 显式轮换），
    /// 其后每个质心取「到已选质心集合最小距离最大」的点（平手同样按 poi_id 破平）。
    private static func initialCentroids(_ pts: [GeoProjection.Point], k: Int,
                                         sights: [POICandidate], scores: [String: Double],
                                         seedOffset: Int) -> [GeoProjection.Point] {
        let byScore = (0..<pts.count).sorted {
            let (sa, sb) = (ScheduleSimulator.score(sights[$0], scores),
                            ScheduleSimulator.score(sights[$1], scores))
            return sa == sb ? sights[$0].id < sights[$1].id : sa > sb
        }
        var chosen = [byScore[((seedOffset % pts.count) + pts.count) % pts.count]]
        while chosen.count < k {
            let next = (0..<pts.count)
                .filter { !chosen.contains($0) }
                .max { a, b in
                    let (da, db) = (minDist(a, chosen, pts), minDist(b, chosen, pts))
                    return da == db ? sights[a].id > sights[b].id : da < db
                } ?? 0
            chosen.append(next)
        }
        return chosen.map { pts[$0] }
    }

    private static func minDist(_ i: Int, _ chosen: [Int], _ pts: [GeoProjection.Point]) -> Double {
        chosen.map { dist(pts[i], pts[$0]) }.min() ?? 0
    }

    /// 质心 NN 路径：从最西质心出发，每步跳到最近的未访问质心，得到一条地理相邻的天序。
    private static func nearestNeighborOrder(_ centroids: [GeoProjection.Point]) -> [Int] {
        let k = centroids.count
        guard k > 1 else { return Array(0..<k) }
        var visited = [(0..<k).min(by: { centroids[$0].x < centroids[$1].x }) ?? 0]
        while visited.count < k {
            let last = visited.last!
            let next = (0..<k)
                .filter { !visited.contains($0) }
                .min(by: { dist(centroids[last], centroids[$0]) < dist(centroids[last], centroids[$1]) }) ?? 0
            visited.append(next)
        }
        return visited
    }
}
