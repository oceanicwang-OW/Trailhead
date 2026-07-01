//  DayClusterer.swift
//  聚类分天（PDR §4.4）。把「哪些点排在同一天」从大模型盲排收回为**确定性几何**：
//  投影到局部平面 → k-means 成团 → 容量约束均衡分配 → 天序按质心 NN 链接（相邻天地理相邻）。
//  纯函数、确定性（farthest-first 初始化，无随机），便于单测。sights<days 降级为轻量天，不抛错。

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

    /// 输出长度恒为 `days`：每天一组景点；点数<天数时尾部为轻量（空）天。
    public static func cluster(sights: [POICandidate], days: Int,
                               maxSightsPerDay: Int, iterations: Int = 10) -> [[POICandidate]] {
        guard days > 0 else { return [] }
        guard !sights.isEmpty else { return Array(repeating: [], count: days) }

        let n = sights.count
        let k = min(days, n)
        let pts = GeoProjection.project(sights)

        // k-means（确定性 farthest-first 初始化 → 迭代赋质心）。
        var centroids = initialCentroids(pts, k: k)
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

        // 容量约束分配：容量 = clamp(ceil(N/days), [2, maxSightsPerDay])；
        // 按 regret（次近−最近）降序逐点分配，满则退最近可用簇，全满则溢出到最近簇（保证不丢点）。
        let capacity = max(2, min(maxSightsPerDay, (n + days - 1) / days))
        var buckets = Array(repeating: [Int](), count: k)
        var counts = [Int](repeating: 0, count: k)
        for i in (0..<n).sorted(by: { regret($0, pts, centroids) > regret($1, pts, centroids) }) {
            let ranked = (0..<k).sorted { dist(pts[i], centroids[$0]) < dist(pts[i], centroids[$1]) }
            let target = ranked.first(where: { counts[$0] < capacity }) ?? ranked[0]
            buckets[target].append(i); counts[target] += 1
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

    /// farthest-first 确定性初始化：首簇取最西点（min x），其余每次取「到已选簇最小距离最大」的点。
    private static func initialCentroids(_ pts: [GeoProjection.Point], k: Int) -> [GeoProjection.Point] {
        var chosen = [(0..<pts.count).min(by: { pts[$0].x < pts[$1].x }) ?? 0]
        while chosen.count < k {
            let next = (0..<pts.count)
                .filter { !chosen.contains($0) }
                .max(by: { minDist($0, chosen, pts) < minDist($1, chosen, pts) }) ?? 0
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
