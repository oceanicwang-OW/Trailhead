//  DayComfortPolicy.swift
//  把“轻松”落成可计算的每日负载、景点数、休息和自由余量约束。

import Foundation

public struct DayComfortPolicy: Equatable, Sendable {
    public let scheduledLoadRatio: Double
    public let maxPrimarySights: Int
    public let smallPointAllowance: Int
    public let continuousActivityLimitMin: Int
    public let restBufferMin: Int
    public let minimumFreeBufferMin: Int
    public let latestLargeAttractionStart: Int
    public let maxPreferredTransferMin: Int

    public static func policy(for pace: Pace) -> DayComfortPolicy {
        switch pace {
        case .tight:
            return DayComfortPolicy(scheduledLoadRatio: 0.85, maxPrimarySights: 4,
                                    smallPointAllowance: 4, continuousActivityLimitMin: 180,
                                    restBufferMin: 15, minimumFreeBufferMin: 45,
                                    latestLargeAttractionStart: 17 * 60,
                                    maxPreferredTransferMin: 60)
        case .relaxed:
            return DayComfortPolicy(scheduledLoadRatio: 0.72, maxPrimarySights: 2,
                                    smallPointAllowance: 3, continuousActivityLimitMin: 150,
                                    restBufferMin: 25, minimumFreeBufferMin: 90,
                                    latestLargeAttractionStart: 16 * 60,
                                    maxPreferredTransferMin: 45)
        case .casual:
            return DayComfortPolicy(scheduledLoadRatio: 0.62, maxPrimarySights: 2,
                                    smallPointAllowance: 2, continuousActivityLimitMin: 120,
                                    restBufferMin: 30, minimumFreeBufferMin: 120,
                                    latestLargeAttractionStart: 15 * 60 + 30,
                                    maxPreferredTransferMin: 35)
        }
    }

    public func loadBudget(dayStart: Int, dayEnd: Int) -> Int {
        Int(Double(max(0, dayEnd - dayStart)) * scheduledLoadRatio)
    }
}
