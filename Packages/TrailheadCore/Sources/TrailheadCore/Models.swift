//  Models.swift
//  SwiftData 实体 + 枚举（PDR §4）。纯数据层，无 UI 依赖；类型→色映射放在
//  App 的 DesignSystem（ItemKind+Color）里，保持 Core 与 SwiftUI 解耦。

import Foundation
import SwiftData

// MARK: - Enums

public enum TripStatus: String, Codable, Sendable { case draft, generating, ready, failed, done }

public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case sight, food, lodging, transit

    public var label: String {
        switch self {
        case .sight:   return "景点"
        case .food:    return "餐饮"
        case .lodging: return "住宿"
        case .transit: return "交通"
        }
    }
}

public enum TransitMode: String, Codable, CaseIterable, Sendable {
    case walk, metro, bus, taxi, drive, train, ferry

    public var display: String {
        switch self {
        case .walk:  return "步行"
        case .metro: return "地铁"
        case .bus:   return "公交"
        case .taxi:  return "出租车"
        case .drive: return "驾车"
        case .train: return "列车"
        case .ferry: return "轮渡"
        }
    }
}

public enum TransitReliability: String, Codable, Sendable {
    case verified
    case estimated
}

public enum Pace: String, Codable, CaseIterable, Sendable {
    case tight, relaxed, casual
    public var display: String {
        switch self {
        case .tight:   return "紧凑高效"
        case .relaxed: return "轻松慢节奏"
        case .casual:  return "随性"
        }
    }
}

public enum VisitExecutionStatus: String, Codable, Sendable {
    case planned
    case visiting
    case completed
    case skipped
}

// MARK: - Preferences (Codable, embedded on Trip)

public struct TripPrefs: Codable, Hashable, Sendable {
    public var tags: [String]
    public var pace: Pace
    public var budgetPerDay: Int
    public var freeText: String
    public var cuisines: [String]      // 口味/菜系偏好（用作美食召回关键词）
    public var lodgingType: String     // 住宿类型（用作住宿召回关键词；""=不限）

    public init(tags: [String] = [], pace: Pace = .relaxed,
                budgetPerDay: Int = 600, freeText: String = "",
                cuisines: [String] = [], lodgingType: String = "") {
        self.tags = tags
        self.pace = pace
        self.budgetPerDay = budgetPerDay
        self.freeText = freeText
        self.cuisines = cuisines
        self.lodgingType = lodgingType
    }

    enum CodingKeys: String, CodingKey { case tags, pace, budgetPerDay, freeText, cuisines, lodgingType }

    /// 容错解码：老 Trip 的 prefsData 没有新字段，缺失即取默认，不丢失旧偏好。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        pace = try c.decodeIfPresent(Pace.self, forKey: .pace) ?? .relaxed
        budgetPerDay = try c.decodeIfPresent(Int.self, forKey: .budgetPerDay) ?? 600
        freeText = try c.decodeIfPresent(String.self, forKey: .freeText) ?? ""
        cuisines = try c.decodeIfPresent([String].self, forKey: .cuisines) ?? []
        lodgingType = try c.decodeIfPresent(String.self, forKey: .lodgingType) ?? ""
    }
}

// MARK: - Nearby food shortlist (Codable, embedded on DayPlan)

/// 当天行程附近的美食推荐（按就近 + 评分排序，供用户自选，不排进动线）。
public struct FoodOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String          // amap poi id
    public var name: String
    public var rating: Double?
    public var avgPrice: Int?
    public var subtype: String     // 菜系/类型，如「海鲜」「火锅」
    public var lat: Double
    public var lng: Double
    public var tags: [String]      // 推荐菜/特色标签（高德 business.tag/rectag）
    public var photos: [String]    // 图片 URL
    public var openHours: String?
    public var distanceMeters: Int?    // 距当天路线最近点
    public var estimatedMinutes: Int?  // 从路线最近点出发的粗略用时

    public init(id: String, name: String, rating: Double? = nil, avgPrice: Int? = nil,
                subtype: String = "", lat: Double, lng: Double,
                tags: [String] = [], photos: [String] = [], openHours: String? = nil,
                distanceMeters: Int? = nil, estimatedMinutes: Int? = nil) {
        self.id = id; self.name = name; self.rating = rating
        self.avgPrice = avgPrice; self.subtype = subtype; self.lat = lat; self.lng = lng
        self.tags = tags; self.photos = photos; self.openHours = openHours
        self.distanceMeters = distanceMeters; self.estimatedMinutes = estimatedMinutes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, rating, avgPrice, subtype, lat, lng, tags, photos, openHours
        case distanceMeters, estimatedMinutes
    }

    /// 容错解码：老数据没有新字段，缺失取默认，不丢整份清单（同 TripPrefs 先例）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        rating = try c.decodeIfPresent(Double.self, forKey: .rating)
        avgPrice = try c.decodeIfPresent(Int.self, forKey: .avgPrice)
        subtype = try c.decodeIfPresent(String.self, forKey: .subtype) ?? ""
        lat = try c.decode(Double.self, forKey: .lat)
        lng = try c.decode(Double.self, forKey: .lng)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        photos = try c.decodeIfPresent([String].self, forKey: .photos) ?? []
        openHours = try c.decodeIfPresent(String.self, forKey: .openHours)
        distanceMeters = try c.decodeIfPresent(Int.self, forKey: .distanceMeters)
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
    }
}

/// 未占用主时间线的景点备选；用户有余力时再决定是否前往。
public struct OptionalVisitOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var subtype: String
    public var lat: Double
    public var lng: Double
    public var rating: Double?
    public var tags: [String]
    public var photos: [String]
    public var minimumMinutes: Int
    public var comfortableMinutes: Int
    public var extendedMinutes: Int
    public var distanceMeters: Int?
    public var estimatedMinutes: Int?

    public init(id: String, name: String, subtype: String, lat: Double, lng: Double,
                rating: Double?, tags: [String], photos: [String],
                minimumMinutes: Int, comfortableMinutes: Int, extendedMinutes: Int,
                distanceMeters: Int?, estimatedMinutes: Int?) {
        self.id = id; self.name = name; self.subtype = subtype
        self.lat = lat; self.lng = lng; self.rating = rating
        self.tags = tags; self.photos = photos
        self.minimumMinutes = minimumMinutes; self.comfortableMinutes = comfortableMinutes
        self.extendedMinutes = extendedMinutes; self.distanceMeters = distanceMeters
        self.estimatedMinutes = estimatedMinutes
    }
}

// MARK: - Lodging shortlist (Codable, embedded on Trip)

/// 住宿候选（不排进每日动线，单独成清单供用户自选）。
public struct LodgingOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String          // amap poi id
    public var name: String
    public var rating: Double?
    public var avgPrice: Int?
    public var lat: Double
    public var lng: Double
    public var tags: [String]      // 环境/服务标签，如「免费停车」「近地铁」
    public var photos: [String]    // 图片 URL
    public var distanceMeters: Int?    // 距整趟路线最近点
    public var estimatedMinutes: Int?  // 驾车粗略用时

    public init(id: String, name: String, rating: Double? = nil,
                avgPrice: Int? = nil, lat: Double, lng: Double,
                tags: [String] = [], photos: [String] = [],
                distanceMeters: Int? = nil, estimatedMinutes: Int? = nil) {
        self.id = id; self.name = name; self.rating = rating
        self.avgPrice = avgPrice; self.lat = lat; self.lng = lng
        self.tags = tags; self.photos = photos
        self.distanceMeters = distanceMeters; self.estimatedMinutes = estimatedMinutes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, rating, avgPrice, lat, lng, tags, photos, distanceMeters, estimatedMinutes
    }

    /// 容错解码：老数据没有新字段，缺失取默认（同 TripPrefs 先例）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        rating = try c.decodeIfPresent(Double.self, forKey: .rating)
        avgPrice = try c.decodeIfPresent(Int.self, forKey: .avgPrice)
        lat = try c.decode(Double.self, forKey: .lat)
        lng = try c.decode(Double.self, forKey: .lng)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        photos = try c.decodeIfPresent([String].self, forKey: .photos) ?? []
        distanceMeters = try c.decodeIfPresent(Int.self, forKey: .distanceMeters)
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
    }
}

// MARK: - Entities

@Model
public final class Trip {
    @Attribute(.unique) public var id: UUID
    public var city: String
    public var subtitle: String          // "京都 / 大阪 / 奈良"
    public var adcode: String
    public var startDate: Date
    public var nights: Int
    public var prefsData: Data           // encoded TripPrefs
    public var intentData: Data = Data() // encoded TripIntent（对话式规划确认快照；旧行程为空）
    public var lodgingData: Data = Data()  // encoded [LodgingOption]（住宿候选清单）
    public var statusRaw: String
    public var accentSeed: Int           // chooses the sidebar gradient swatch
    public var createdAt: Date
    @Relationship(deleteRule: .cascade) public var days: [DayPlan]

    public init(id: UUID = UUID(), city: String, subtitle: String = "", adcode: String = "",
                startDate: Date = .now, nights: Int = 3, prefs: TripPrefs = .init(),
                status: TripStatus = .draft, accentSeed: Int = 0, days: [DayPlan] = [],
                lodging: [LodgingOption] = [], intent: TripIntent? = nil) {
        self.id = id
        self.city = city
        self.subtitle = subtitle
        self.adcode = adcode
        self.startDate = startDate
        self.nights = nights
        self.prefsData = (try? JSONEncoder().encode(prefs)) ?? Data()
        self.intentData = intent.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        self.lodgingData = (try? JSONEncoder().encode(lodging)) ?? Data()
        self.statusRaw = status.rawValue
        self.accentSeed = accentSeed
        self.createdAt = .now
        self.days = days
    }

    public var status: TripStatus {
        get { TripStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }
    public var prefs: TripPrefs {
        get { (try? JSONDecoder().decode(TripPrefs.self, from: prefsData)) ?? .init() }
        set { prefsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    public var lodgingOptions: [LodgingOption] {
        get { (try? JSONDecoder().decode([LodgingOption].self, from: lodgingData)) ?? [] }
        set { lodgingData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    public var planningIntent: TripIntent? {
        get { try? JSONDecoder().decode(TripIntent.self, from: intentData) }
        set { intentData = newValue.flatMap { try? JSONEncoder().encode($0) } ?? Data() }
    }
    public var dayCount: Int { nights + 1 }
    public var sortedDays: [DayPlan] { days.sorted { $0.dayIndex < $1.dayIndex } }
}

@Model
public final class DayPlan {
    @Attribute(.unique) public var id: UUID
    public var dayIndex: Int             // 0-based
    public var date: Date
    public var cityLabel: String         // "京都"
    public var theme: String = ""        // 当天主题（P7 NoteWriter 生成，空=未生成；SwiftData 轻量迁移安全）
    public var foodData: Data = Data()   // encoded [FoodOption]（当天附近美食推荐）
    public var optionalVisitData: Data = Data() // encoded [OptionalVisitOption]（不占主时间线）
    @Relationship(deleteRule: .cascade) public var items: [PlanItem]

    public init(id: UUID = UUID(), dayIndex: Int, date: Date = .now,
                cityLabel: String = "", items: [PlanItem] = []) {
        self.id = id; self.dayIndex = dayIndex; self.date = date
        self.cityLabel = cityLabel; self.items = items
    }
    public var sortedItems: [PlanItem] { items.sorted { $0.order < $1.order } }
    public var foodOptions: [FoodOption] {
        get { (try? JSONDecoder().decode([FoodOption].self, from: foodData)) ?? [] }
        set { foodData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    public var optionalVisits: [OptionalVisitOption] {
        get { (try? JSONDecoder().decode([OptionalVisitOption].self, from: optionalVisitData)) ?? [] }
        set { optionalVisitData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

@Model
public final class PlanItem {
    @Attribute(.unique) public var id: UUID
    public var order: Int
    public var kindRaw: String

    // POI fields (kind != transit)
    public var poiId: String?
    public var name: String?
    public var subtype: String?          // "神社" / "寺院" / "午餐" …
    public var lat: Double?
    public var lng: Double?              // GCJ-02
    public var plannedTime: String?      // "09:00"
    public var stayLabel: String?        // "约 2.5 小时"
    public var plannedStayMinutes: Int?
    public var minimumStayMinutes: Int?
    public var comfortableStayMinutes: Int?
    public var extendedStayMinutes: Int?
    public var visitStatusRaw: String = VisitExecutionStatus.planned.rawValue
    public var actualStartAt: Date?
    public var actualEndAt: Date?
    public var note: String?             // "千本鸟居 · 建议早到"

    // Transit fields (kind == transit)
    public var transitModeRaw: String?
    public var transitDesc: String?      // "JR 奈良线 + 步行"
    public var transitMinutes: Int?
    public var transitMeters: Int?
    public var transitCost: Int?         // 本地货币最小单位的整数显示值
    public var transitReliabilityRaw: String?

    public init(id: UUID = UUID(), order: Int, kind: ItemKind) {
        self.id = id; self.order = order; self.kindRaw = kind.rawValue
    }

    public var kind: ItemKind {
        get { ItemKind(rawValue: kindRaw) ?? .sight }
        set { kindRaw = newValue.rawValue }
    }
    public var transitMode: TransitMode? {
        get { transitModeRaw.flatMap(TransitMode.init) }
        set { transitModeRaw = newValue?.rawValue }
    }
    public var transitReliability: TransitReliability {
        get { transitReliabilityRaw.flatMap(TransitReliability.init) ?? .verified }
        set { transitReliabilityRaw = newValue.rawValue }
    }
    public var visitStatus: VisitExecutionStatus {
        get { VisitExecutionStatus(rawValue: visitStatusRaw) ?? .planned }
        set { visitStatusRaw = newValue.rawValue }
    }

    /// "JR 奈良线 + 步行 · 18 分钟 · 4.2 km · ¥150"
    public var transitLine: String {
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
    public static func poi(_ order: Int, kind: ItemKind, time: String, name: String,
                           subtype: String, note: String, stay: String) -> PlanItem {
        let i = PlanItem(order: order, kind: kind)
        i.plannedTime = time; i.name = name; i.subtype = subtype
        i.note = note; i.stayLabel = stay
        return i
    }
    public static func transit(_ order: Int, mode: TransitMode, desc: String,
                               minutes: Int, meters: Int, cost: Int? = nil) -> PlanItem {
        let i = PlanItem(order: order, kind: .transit)
        i.transitMode = mode; i.transitDesc = desc
        i.transitMinutes = minutes; i.transitMeters = meters; i.transitCost = cost
        i.transitReliability = .verified
        return i
    }
}
