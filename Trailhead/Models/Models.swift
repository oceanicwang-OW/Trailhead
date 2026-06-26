//  Models.swift
//  SwiftData entities — PDR §4. Field set aligned with the handoff design
//  (stay duration label, transport description/distance/cost, lodging spine, …).

import Foundation
import SwiftData
import SwiftUI

// MARK: - Enums

enum TripStatus: String, Codable { case draft, generating, ready, failed, done }

enum ItemKind: String, Codable, CaseIterable {
    case sight, food, lodging, transit

    var label: String {
        switch self {
        case .sight:   return "景点"
        case .food:    return "餐饮"
        case .lodging: return "住宿"
        case .transit: return "交通"
        }
    }
    /// Node / tag color in the route timeline.
    var color: Color {
        switch self {
        case .sight:   return Palette.green
        case .food:    return Palette.orange
        case .lodging: return Palette.purple
        case .transit: return Palette.slate
        }
    }
}

enum TransitMode: String, Codable {
    case walk, metro, bus, taxi, drive, train

    var display: String {
        switch self {
        case .walk:  return "步行"
        case .metro: return "地铁"
        case .bus:   return "公交"
        case .taxi:  return "出租车"
        case .drive: return "驾车"
        case .train: return "列车"
        }
    }
}

enum Pace: String, Codable, CaseIterable {
    case tight, relaxed, casual
    var display: String {
        switch self {
        case .tight:   return "紧凑高效"
        case .relaxed: return "轻松慢节奏"
        case .casual:  return "随性"
        }
    }
}

// MARK: - Preferences (Codable, embedded on Trip)

struct TripPrefs: Codable, Hashable {
    var tags: [String] = []
    var pace: Pace = .relaxed
    var budgetPerDay: Int = 600
    var freeText: String = ""
}

// MARK: - Entities

@Model
final class Trip {
    @Attribute(.unique) var id: UUID
    var city: String
    var subtitle: String          // "京都 / 大阪 / 奈良"
    var adcode: String
    var startDate: Date
    var nights: Int
    var prefsData: Data           // encoded TripPrefs
    var statusRaw: String
    var accentSeed: Int           // chooses the sidebar gradient swatch
    var createdAt: Date
    @Relationship(deleteRule: .cascade) var days: [DayPlan]

    init(id: UUID = UUID(), city: String, subtitle: String = "", adcode: String = "",
         startDate: Date = .now, nights: Int = 3, prefs: TripPrefs = .init(),
         status: TripStatus = .draft, accentSeed: Int = 0, days: [DayPlan] = []) {
        self.id = id
        self.city = city
        self.subtitle = subtitle
        self.adcode = adcode
        self.startDate = startDate
        self.nights = nights
        self.prefsData = (try? JSONEncoder().encode(prefs)) ?? Data()
        self.statusRaw = status.rawValue
        self.accentSeed = accentSeed
        self.createdAt = .now
        self.days = days
    }

    var status: TripStatus {
        get { TripStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }
    var prefs: TripPrefs {
        get { (try? JSONDecoder().decode(TripPrefs.self, from: prefsData)) ?? .init() }
        set { prefsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    var dayCount: Int { nights + 1 }
    var sortedDays: [DayPlan] { days.sorted { $0.dayIndex < $1.dayIndex } }
}

@Model
final class DayPlan {
    @Attribute(.unique) var id: UUID
    var dayIndex: Int             // 0-based
    var date: Date
    var cityLabel: String         // "京都"
    @Relationship(deleteRule: .cascade) var items: [PlanItem]

    init(id: UUID = UUID(), dayIndex: Int, date: Date = .now,
         cityLabel: String = "", items: [PlanItem] = []) {
        self.id = id; self.dayIndex = dayIndex; self.date = date
        self.cityLabel = cityLabel; self.items = items
    }
    var sortedItems: [PlanItem] { items.sorted { $0.order < $1.order } }
}

@Model
final class PlanItem {
    @Attribute(.unique) var id: UUID
    var order: Int
    var kindRaw: String

    // POI fields (kind != transit)
    var poiId: String?
    var name: String?
    var subtype: String?          // "神社" / "寺院" / "午餐" …
    var lat: Double?
    var lng: Double?              // GCJ-02
    var plannedTime: String?      // "09:00"
    var stayLabel: String?        // "约 2.5 小时"
    var note: String?             // "千本鸟居 · 建议早到"

    // Transit fields (kind == transit)
    var transitModeRaw: String?
    var transitDesc: String?      // "JR 奈良线 + 步行"
    var transitMinutes: Int?
    var transitMeters: Int?
    var transitCost: Int?         // 本地货币最小单位的整数显示值

    init(id: UUID = UUID(), order: Int, kind: ItemKind) {
        self.id = id; self.order = order; self.kindRaw = kind.rawValue
    }

    var kind: ItemKind {
        get { ItemKind(rawValue: kindRaw) ?? .sight }
        set { kindRaw = newValue.rawValue }
    }
    var transitMode: TransitMode? {
        get { transitModeRaw.flatMap(TransitMode.init) }
        set { transitModeRaw = newValue?.rawValue }
    }

    /// "JR 奈良线 + 步行 · 18 分钟 · 4.2 km · ¥150"
    var transitLine: String {
        var parts: [String] = []
        if let d = transitDesc { parts.append(d) }
        if let m = transitMinutes { parts.append("\(m) 分钟") }
        if let meters = transitMeters {
            parts.append(meters >= 1000
                ? String(format: "%.1f km", Double(meters) / 1000)
                : "\(meters) m")
        }
        if let c = transitCost { parts.append("¥\(c)") }
        return parts.joined(separator: " · ")
    }
}

// Convenience builders for seeding -------------------------------------------

extension PlanItem {
    static func poi(_ order: Int, kind: ItemKind, time: String, name: String,
                    subtype: String, note: String, stay: String) -> PlanItem {
        let i = PlanItem(order: order, kind: kind)
        i.plannedTime = time; i.name = name; i.subtype = subtype
        i.note = note; i.stayLabel = stay
        return i
    }
    static func transit(_ order: Int, mode: TransitMode, desc: String,
                        minutes: Int, meters: Int, cost: Int? = nil) -> PlanItem {
        let i = PlanItem(order: order, kind: .transit)
        i.transitMode = mode; i.transitDesc = desc
        i.transitMinutes = minutes; i.transitMeters = meters; i.transitCost = cost
        return i
    }
}
