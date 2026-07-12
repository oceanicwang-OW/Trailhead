import Foundation
import TrailheadCore

struct NewTripDraft {
    static let rememberedDaysKey = "newTrip.lastDays"

    var destination: String
    var days: Int
    var startDate: Date
    var selectedTags: Set<String>
    var selectedCuisines: Set<String>
    var lodgingType: String
    var pace: Pace
    var budget: Double

    init(destination: String = "成都",
         days: Int = 3,
         startDate: Date = Calendar.current.startOfDay(for: .now),
         selectedTags: Set<String> = ["美食", "历史古迹", "自然风光"],
         selectedCuisines: Set<String> = [],
         lodgingType: String = "",
         pace: Pace = .relaxed,
         budget: Double = 600) {
        self.destination = destination
        self.days = Self.validDays(days)
        self.startDate = startDate
        self.selectedTags = selectedTags
        self.selectedCuisines = selectedCuisines
        self.lodgingType = lodgingType
        self.pace = pace
        self.budget = budget
    }

    var trimmedDestination: String {
        destination.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var preferences: TripPrefs {
        var preferences = TripPrefs()
        preferences.tags = Array(selectedTags).sorted()
        preferences.cuisines = Array(selectedCuisines).sorted()
        preferences.lodgingType = lodgingType
        preferences.pace = pace
        preferences.budgetPerDay = Int(budget)
        return preferences
    }

    var estimate: GenerationEstimate {
        GenerationEstimate(days: days)
    }

    static func rememberedDays(defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: rememberedDaysKey)
        return stored == 0 ? 3 : validDays(stored)
    }

    func rememberDays(defaults: UserDefaults = .standard) {
        defaults.set(Self.validDays(days), forKey: Self.rememberedDaysKey)
    }

    static func validDays(_ days: Int) -> Int {
        min(14, max(1, days))
    }
}

struct GenerationEstimate: Equatable {
    let minimumSeconds: Int
    let maximumSeconds: Int
    let minimumAmapCalls: Int
    let maximumAmapCalls: Int
    let deepSeekCalls: ClosedRange<Int>

    init(days: Int) {
        let safeDays = NewTripDraft.validDays(days)
        minimumSeconds = max(30, safeDays * 15)
        maximumSeconds = max(60, safeDays * 35)
        minimumAmapCalls = max(8, safeDays * 3)
        maximumAmapCalls = 10 + safeDays * 6
        deepSeekCalls = 2...3
    }

    var durationText: String {
        "约 \(Self.duration(minimumSeconds))–\(Self.duration(maximumSeconds))"
    }

    var callsText: String {
        "高德约 \(minimumAmapCalls)–\(maximumAmapCalls) 次 · DeepSeek 约 \(deepSeekCalls.lowerBound)–\(deepSeekCalls.upperBound) 次"
    }

    private static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = Int(ceil(Double(seconds) / 60))
        return "\(minutes) 分钟"
    }
}
