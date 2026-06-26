//  Theme.swift
//  Design tokens translated verbatim from the Claude Design handoff
//  (Trailhead.dc.html). Colors resolve automatically for light / dark,
//  matching the two mockup variants per frame.

import SwiftUI

// MARK: - Color helpers

extension Color {
    /// Hex initializer, e.g. Color(hex: 0x1FA67A)
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// Dynamic color that follows the system appearance.
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #elseif canImport(AppKit)
        self = Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor(dark) : NSColor(light)
        })
        #else
        self = light
        #endif
    }
}

// MARK: - Palette

enum Palette {
    // Brand / route accent (identical in both modes)
    static let green      = Color(hex: 0x1FA67A)   // 景点 + route spine + primary
    static let greenDeep  = Color(hex: 0x15805D)
    static let orange     = Color(hex: 0xF08A24)   // 餐饮
    static let purple     = Color(hex: 0x8B5CF6)   // 住宿
    static let slate      = Color(hex: 0x5B6B7B)   // 交通
    static let blue       = Color(hex: 0x0A84FF)   // 选中态
    static let red        = Color(hex: 0xFF3B30)   // 破坏性操作

    // Surfaces (light / dark from the two mockup variants)
    static let windowBG   = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x1C1C1E))
    static let canvasBG   = Color(light: Color(hex: 0xFBFBFA), dark: Color(hex: 0x1C1C1E))
    static let sidebarBG  = Color(light: Color(hex: 0xF4F3F1), dark: Color(hex: 0x252527))
    static let cardBG     = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x2C2C2E))
    static let groupedBG  = Color(light: Color(hex: 0xF2F2F7), dark: Color(hex: 0x1C1C1E))
    static let toolbarBG  = Color(light: Color(hex: 0xECECEB), dark: Color(hex: 0x2C2C2E))
    static let fieldBG    = Color(light: Color(hex: 0x000000, alpha: 0.05),
                                  dark:  Color(hex: 0xFFFFFF, alpha: 0.08))

    // Text
    static let textPrimary   = Color(light: Color(hex: 0x1D1D1F), dark: Color(hex: 0xF5F5F7))
    static let textSecondary = Color(hex: 0x8E8E93)
    static let textTertiary  = Color(hex: 0xA1A1A6)
    static let textMuted     = Color(hex: 0x86868B)

    // Hairlines
    static let separator = Color(light: Color(hex: 0x000000, alpha: 0.10),
                                 dark:  Color(hex: 0xFFFFFF, alpha: 0.12))
    static let cardStroke = Color(light: Color(hex: 0x000000, alpha: 0.08),
                                  dark:  Color(hex: 0xFFFFFF, alpha: 0.10))
}

// MARK: - Typography (SF Pro system face, sizes from the mockup)

enum Typo {
    static func display(_ size: CGFloat = 19, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static let titleBar   = Font.system(size: 13.5, weight: .semibold)
    static let cardTitle  = Font.system(size: 15, weight: .semibold)
    static let cardTitleL = Font.system(size: 16, weight: .semibold)
    static let body       = Font.system(size: 13.5)
    static let caption    = Font.system(size: 12)
    static let caption2   = Font.system(size: 11.5)
    static let tag        = Font.system(size: 10.5, weight: .semibold)
    static let sectionHdr = Font.system(size: 11, weight: .semibold)   // uppercase sidebar headers
    static let mono       = Font.system(size: 13.5, design: .monospaced)
}

// MARK: - Spacing & radii

enum Metric {
    static let cardRadius:   CGFloat = 12
    static let cardRadiusL:  CGFloat = 14
    static let windowRadius: CGFloat = 13
    static let fieldRadius:  CGFloat = 11
    static let chipRadius:   CGFloat = 20

    static let sidebarWidth:  CGFloat = 248
    static let timelineWidth: CGFloat = 448

    static let spineX:    CGFloat = 30   // x of the route spine inside the 64pt gutter (macOS)
    static let spineWidth: CGFloat = 3
    static let gutter:    CGFloat = 64
    static let gutterCompact: CGFloat = 50
}
