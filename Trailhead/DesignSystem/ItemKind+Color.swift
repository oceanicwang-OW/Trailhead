//  ItemKind+Color.swift
//  类型→色映射放在 App 的 DesignSystem 层（依赖 Palette），让 TrailheadCore
//  保持与 SwiftUI 解耦。时间线节点 / 标签按此着色。

import SwiftUI
import TrailheadCore

extension ItemKind {
    /// 路线时间线里节点 / 标签的颜色。
    var color: Color {
        switch self {
        case .sight:   return Palette.green
        case .food:    return Palette.orange
        case .lodging: return Palette.purple
        case .transit: return Palette.slate
        }
    }
}
