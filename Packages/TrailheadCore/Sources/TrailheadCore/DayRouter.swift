//  DayRouter.swift
//  簇内排序（PDR §4.5）。把「当天先去哪后去哪」从大模型盲排收回为**确定性几何**：
//  贪心最近邻建初始序 → 2-opt 迭代消交叉至无改进。开放路径（无固定起终点），
//  距离复用既有 ItineraryDayBuilder.haversineMeters。每天 ≤6 点，复杂度可忽略。纯函数。

import Foundation

public enum DayRouter {
    /// 返回当天有序停留。`entryAnchor` 为上一天出口坐标（天间衔接），有则从最近点起。
    public static func route(_ stops: [POICandidate],
                             entryAnchor: (lat: Double, lng: Double)? = nil,
                             maxIterations: Int = 20) -> [POICandidate] {
        routeWithDiagnostics(stops, entryAnchor: entryAnchor, maxIterations: maxIterations).tour
    }

    /// 带诊断的排序（D8）：`converged` = 2-opt 在步数上限内正常收敛（未触顶退出），
    /// 供 ItineraryFeasibility 的软断言使用——「总长不增」是构造保证的恒真式，验不出问题。
    public static func routeWithDiagnostics(_ stops: [POICandidate],
                                            entryAnchor: (lat: Double, lng: Double)? = nil,
                                            maxIterations: Int = 20) -> (tour: [POICandidate], converged: Bool) {
        guard stops.count > 1 else { return (stops, true) }
        // 锚点仅用于距离计算，包成一个临时候选，复用同一 haversine。
        let anchor = entryAnchor.map {
            POICandidate(id: "__anchor__", name: "", kind: .sight, subtype: "", lat: $0.lat, lng: $0.lng)
        }

        // 起点：有锚点取离锚点最近的点；否则取最西点（min lng）。
        let startIdx: Int
        if let anchor {
            startIdx = (0..<stops.count).min(by: { d(anchor, stops[$0]) < d(anchor, stops[$1]) }) ?? 0
        } else {
            startIdx = (0..<stops.count).min(by: { stops[$0].lng < stops[$1].lng }) ?? 0
        }

        // 贪心最近邻建初始序。
        var remaining = stops
        var tour = [remaining.remove(at: startIdx)]
        while !remaining.isEmpty {
            let last = tour[tour.count - 1]
            let ni = (0..<remaining.count).min(by: { d(last, remaining[$0]) < d(last, remaining[$1]) }) ?? 0
            tour.append(remaining.remove(at: ni))
        }

        return twoOpt(tour, anchor: anchor, maxIterations: maxIterations)
    }

    /// 2-opt：反转任意子段 [i...j]，若开放路径总长变短则接受，迭代至无改进或达步数上限。
    /// 锚点为固定前缀（不进 tour 数组），其到首点的边在 pathLength 内计入，故锚点位置不被打乱。
    /// 返回 converged=false 表示触顶退出（最后一轮仍有改进）。
    private static func twoOpt(_ initial: [POICandidate], anchor: POICandidate?,
                               maxIterations: Int) -> (tour: [POICandidate], converged: Bool) {
        var tour = initial
        var improved = true
        var iter = 0
        while improved, iter < maxIterations {
            improved = false
            iter += 1
            for i in 0..<(tour.count - 1) {
                for j in (i + 1)..<tour.count {
                    var candidate = tour
                    candidate.replaceSubrange(i...j, with: tour[i...j].reversed())
                    if pathLength(candidate, anchor: anchor) + 1e-6 < pathLength(tour, anchor: anchor) {
                        tour = candidate
                        improved = true
                    }
                }
            }
        }
        return (tour, !improved)
    }

    /// 开放路径总长（含锚点→首点的衔接段，若有）。
    private static func pathLength(_ tour: [POICandidate], anchor: POICandidate?) -> Double {
        var total = 0.0
        if let anchor, let first = tour.first { total += d(anchor, first) }
        for i in 0..<max(0, tour.count - 1) { total += d(tour[i], tour[i + 1]) }
        return total
    }

    private static func d(_ a: POICandidate, _ b: POICandidate) -> Double {
        ItineraryDayBuilder.haversineMeters(a, b)
    }
}
