# T6.3 Regenerate Single Day Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Regenerate only the currently selected day of an existing trip, replacing that day's items while preserving every other day and trip metadata.

**Architecture:** Extract shared one-day itinerary item construction into `ItineraryDayBuilder` so whole-trip generation and single-day regeneration use the same parser, fact-checking, route, and PlanItem construction behavior. `TripRepository.regenerateDay(...)` owns the SwiftData mutation and builds all new items before deleting old day items.

**Tech Stack:** Swift 6, SwiftData, SwiftUI, TrailheadCore, XCTest, Xcode/macOS+iOS build verification.

---

## File Structure

- Create `Packages/TrailheadCore/Sources/TrailheadCore/ItineraryDayBuilder.swift`
  - Shared planning retry, fact-checking, stay label, route mode, and `PlanItem` construction.
- Modify `Packages/TrailheadCore/Sources/TrailheadCore/ItineraryEngine.swift`
  - Replace private duplicated build logic with `ItineraryDayBuilder`.
- Modify `Packages/TrailheadCore/Sources/TrailheadCore/TripRepository.swift`
  - Add `TripRepositoryError.missingAdcode`.
  - Add `regenerateDay(_:in:source:llm:)`.
- Modify `Packages/TrailheadCore/Tests/TrailheadCoreTests/TripRepositoryTests.swift`
  - Add one-day regeneration test doubles and Core tests.
- Modify `Trailhead/Features/Timeline/RouteTimelineView.swift`
  - Add day-level regenerate button and loading state.
- Modify `README.md` and `PDR-行迹.md`
  - Mark T6.3 complete after verification.

---

### Task 1: Core RED Test for Single-Day Regeneration

**Files:**
- Modify: `Packages/TrailheadCore/Tests/TrailheadCoreTests/TripRepositoryTests.swift`

- [ ] **Step 1: Add regeneration test doubles**

Add these helpers near the existing `RouteSpySource`:

```swift
private final class RegenerateSpySource: POIDataSource {
    var byTag: [String: [POICandidate]] = [:]
    private(set) var routePairs: [String] = []

    func geocodeCity(_ name: String) async throws -> (adcode: String, center: (Double, Double)) {
        ("110100", (0, 0))
    }

    func searchPOI(adcode: String, tags: [String]) async throws -> [POICandidate] {
        tags.flatMap { byTag[$0] ?? [] }
    }

    func route(from: POICandidate, to: POICandidate,
               mode: TransitMode) async throws -> (minutes: Int, meters: Int, cost: Int?) {
        routePairs.append("\(from.id)-\(to.id)")
        return (18, 1800, 8)
    }
}

private final class RegenerateLLM: LLMProvider {
    var responses: [String]
    private(set) var calls = 0

    init(_ responses: [String]) {
        self.responses = responses
    }

    func planItinerary(prefs: TripPrefs, candidates: [POICandidate], days: Int) async throws -> Data {
        defer { calls += 1 }
        return Data(responses[min(calls, responses.count - 1)].utf8)
    }
}

private func regenCandidate(_ id: String, kind: ItemKind = .sight,
                            lat: Double = 30.0, lng: Double = 104.0) -> POICandidate {
    POICandidate(id: id, name: id, kind: kind, subtype: kind.label, lat: lat, lng: lng)
}
```

- [ ] **Step 2: Write the failing behavior test**

Add this test to `TripRepositoryTests`:

```swift
func testRegenerateDayReplacesOnlySelectedDay() async throws {
    let ctx = try TestSupport.makeContext()
    let repo = TripRepository(context: ctx)
    let source = RegenerateSpySource()
    source.byTag = ["景点": [
        regenCandidate("X", kind: .sight, lat: 30.0, lng: 104.0),
        regenCandidate("Y", kind: .food, lat: 30.03, lng: 104.03),
    ]]
    let llm = RegenerateLLM([
        #"{"days":[{"day":1,"items":[{"poi_id":"X","time":"10:00","stay_min":90,"note":"new"},{"poi_id":"Y","time":"12:00","stay_min":60},{"poi_id":"GHOST"}]}]}"#,
    ])

    let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
    let oldA = PlanItem.poi(0, kind: .sight, time: "09:00", name: "Old A", subtype: "景点", note: "", stay: "")
    oldA.poiId = "OLD-A"; oldA.lat = 30.0; oldA.lng = 104.0
    let oldB = PlanItem.poi(1, kind: .food, time: "12:00", name: "Old B", subtype: "餐饮", note: "", stay: "")
    oldB.poiId = "OLD-B"; oldB.lat = 30.01; oldB.lng = 104.01
    let day0 = DayPlan(dayIndex: 0, date: originalDate, cityLabel: "成都", items: [oldA, oldB])
    let untouched = PlanItem.poi(0, kind: .sight, time: "09:00", name: "Keep", subtype: "景点", note: "", stay: "")
    untouched.poiId = "KEEP"; untouched.lat = 31.0; untouched.lng = 105.0
    let day1 = DayPlan(dayIndex: 1, date: originalDate.addingTimeInterval(86_400), cityLabel: "成都", items: [untouched])
    let trip = try repo.create(city: "成都", adcode: "510100", nights: 1,
                               prefs: TripPrefs(tags: ["景点"]), days: [day0, day1])
    let oldDay0IDs = Set(day0.items.map(\.id))

    try await repo.regenerateDay(day0, in: trip, source: source, llm: llm)

    XCTAssertEqual(trip.sortedDays.count, 2)
    XCTAssertEqual(day0.dayIndex, 0)
    XCTAssertEqual(day0.date, originalDate)
    XCTAssertEqual(day0.cityLabel, "成都")
    XCTAssertEqual(day1.sortedItems.compactMap(\.poiId), ["KEEP"])

    let regenerated = day0.sortedItems
    XCTAssertEqual(regenerated.map(\.kind), [.sight, .transit, .food])
    XCTAssertEqual(regenerated.compactMap(\.poiId), ["X", "Y"])
    XCTAssertEqual(regenerated.map(\.order), [0, 1, 2])
    XCTAssertEqual(regenerated[0].plannedTime, "10:00")
    XCTAssertEqual(regenerated[0].stayLabel, "约 1.5 小时")
    XCTAssertEqual(regenerated[0].note, "new")
    XCTAssertTrue(regenerated.allSatisfy { !oldDay0IDs.contains($0.id) })
    XCTAssertEqual(source.routePairs, ["X-Y"])
}
```

- [ ] **Step 3: Run the focused test and confirm RED**

Run:

```bash
xcodebuild test -scheme TrailheadCore -destination 'platform=macOS' -only-testing:TrailheadCoreTests/TripRepositoryTests/testRegenerateDayReplacesOnlySelectedDay
```

Expected: FAIL because `TripRepository` has no `regenerateDay`.

---

### Task 2: Shared One-Day Builder and Repository Implementation

**Files:**
- Create: `Packages/TrailheadCore/Sources/TrailheadCore/ItineraryDayBuilder.swift`
- Modify: `Packages/TrailheadCore/Sources/TrailheadCore/ItineraryEngine.swift`
- Modify: `Packages/TrailheadCore/Sources/TrailheadCore/TripRepository.swift`

- [ ] **Step 1: Create the shared builder**

Create `ItineraryDayBuilder.swift`:

```swift
//  ItineraryDayBuilder.swift
//  Shared one-day itinerary construction used by full-trip generation and T6.3 day regeneration.

import Foundation

public enum ItineraryDayBuilder {
    public static func planStops(prefs: TripPrefs, candidates: [POICandidate],
                                 days: Int, llm: LLMProvider) async throws -> [[PlannedStop]] {
        let plan = try await planWithRetry(prefs: prefs, candidates: candidates, days: days, llm: llm)
        return FactChecker.reconcile(plan, candidates: candidates)
    }

    public static func buildItems(from stops: [PlannedStop], source: POIDataSource) async -> [PlanItem] {
        var items: [PlanItem] = []
        var order = 0
        var previous: POICandidate?
        for stop in stops {
            if let previous {
                let mode = mode(from: previous, to: stop.candidate)
                if let segment = try? await source.route(from: previous, to: stop.candidate, mode: mode) {
                    let transit = PlanItem(order: order, kind: .transit)
                    transit.transitMode = mode
                    transit.transitDesc = mode.display
                    transit.transitMinutes = segment.minutes
                    transit.transitMeters = segment.meters
                    transit.transitCost = segment.cost
                    items.append(transit)
                    order += 1
                }
            }

            let poi = PlanItem(order: order, kind: stop.candidate.kind)
            poi.poiId = stop.candidate.id
            poi.name = stop.candidate.name
            poi.subtype = stop.candidate.subtype
            poi.lat = stop.candidate.lat
            poi.lng = stop.candidate.lng
            poi.plannedTime = stop.time
            poi.stayLabel = stop.stayMin.map(stayLabel)
            poi.note = stop.note
            items.append(poi)
            order += 1
            previous = stop.candidate
        }
        return items
    }

    private static func planWithRetry(prefs: TripPrefs, candidates: [POICandidate],
                                      days: Int, llm: LLMProvider) async throws -> ItineraryPlan {
        let first = try await llm.planItinerary(prefs: prefs, candidates: candidates, days: days)
        if let plan = try? ItineraryParser.parse(first) { return plan }
        let retry = try await llm.planItinerary(prefs: prefs, candidates: candidates, days: days)
        return try ItineraryParser.parse(retry)
    }

    static func stayLabel(_ minutes: Int) -> String {
        minutes >= 60 ? "约 \(String(format: "%g", (Double(minutes) / 60 * 10).rounded() / 10)) 小时" : "\(minutes) 分钟"
    }

    static func mode(from: POICandidate, to: POICandidate) -> TransitMode {
        haversineMeters(from, to) > 1500 ? .metro : .walk
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
```

- [ ] **Step 2: Refactor `ItineraryEngine` onto the helper**

In `ItineraryEngine.generate`, replace:

```swift
let plan = try await planWithRetry(prefs: prefs, candidates: candidates, days: days)

set(.dining, 0.6)
let perDay = FactChecker.reconcile(plan, candidates: candidates)
```

with:

```swift
let perDay = try await ItineraryDayBuilder.planStops(prefs: prefs, candidates: candidates,
                                                     days: days, llm: llm)
set(.dining, 0.6)
```

In `buildDays`, replace the inner stop loop with:

```swift
let items = await ItineraryDayBuilder.buildItems(from: stops, source: source)
result.append(DayPlan(dayIndex: index, date: date, cityLabel: destination, items: items))
```

Delete the now-unused private `planWithRetry`, `stayLabel`, `mode`, and `haversineMeters` methods from `ItineraryEngine`.

- [ ] **Step 3: Add repository error and regenerate method**

In `TripRepository.swift`, add near imports:

```swift
public enum TripRepositoryError: Error, Equatable {
    case missingAdcode
}
```

Add this method to `TripRepository`:

```swift
public func regenerateDay(_ day: DayPlan, in trip: Trip,
                          source: POIDataSource, llm: LLMProvider) async throws {
    let adcode = trip.adcode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !adcode.isEmpty else { throw TripRepositoryError.missingAdcode }

    let recall = POIRecall(source: source, cache: POICache(context: context))
    let candidates = try await recall.recall(adcode: adcode, tags: trip.prefs.tags)
    guard !candidates.isEmpty else { throw ItineraryEngine.EngineError.noCandidates }

    let perDay = try await ItineraryDayBuilder.planStops(prefs: trip.prefs,
                                                         candidates: candidates,
                                                         days: 1,
                                                         llm: llm)
    guard let stops = perDay.first, !stops.isEmpty else {
        throw ItineraryEngine.EngineError.emptyPlan
    }
    let newItems = await ItineraryDayBuilder.buildItems(from: stops, source: source)

    for old in day.items {
        context.delete(old)
    }
    day.items = newItems
    for (index, item) in day.sortedItems.enumerated() {
        item.order = index
    }
    try context.save()
}
```

- [ ] **Step 4: Run the focused regeneration test and confirm GREEN**

Run:

```bash
xcodebuild test -scheme TrailheadCore -destination 'platform=macOS' -only-testing:TrailheadCoreTests/TripRepositoryTests/testRegenerateDayReplacesOnlySelectedDay
```

Expected: PASS.

- [ ] **Step 5: Run existing full-trip generation tests**

Run:

```bash
xcodebuild test -scheme TrailheadCore -destination 'platform=macOS' -only-testing:TrailheadCoreTests/ItineraryEngineTests
```

Expected: PASS. This guards the helper refactor.

---

### Task 3: Failure Atomicity Tests

**Files:**
- Modify: `Packages/TrailheadCore/Tests/TrailheadCoreTests/TripRepositoryTests.swift`

- [ ] **Step 1: Add no-candidates test**

Add:

```swift
func testRegenerateDayNoCandidatesLeavesExistingItems() async throws {
    let ctx = try TestSupport.makeContext()
    let repo = TripRepository(context: ctx)
    let source = RegenerateSpySource()
    let llm = RegenerateLLM([#"{"days":[{"day":1,"items":[{"poi_id":"X"}]}]}"#])
    let old = PlanItem.poi(0, kind: .sight, time: "09:00", name: "Old", subtype: "景点", note: "", stay: "")
    old.poiId = "OLD"; old.lat = 30.0; old.lng = 104.0
    let day = DayPlan(dayIndex: 0, items: [old])
    let trip = try repo.create(city: "成都", adcode: "510100", prefs: TripPrefs(tags: ["景点"]), days: [day])

    do {
        try await repo.regenerateDay(day, in: trip, source: source, llm: llm)
        XCTFail("expected noCandidates")
    } catch {
        XCTAssertEqual(error as? ItineraryEngine.EngineError, .noCandidates)
    }

    XCTAssertEqual(day.sortedItems.compactMap(\.poiId), ["OLD"])
    XCTAssertEqual(day.sortedItems.map(\.name), ["Old"])
}
```

- [ ] **Step 2: Add empty fact-checked plan test**

Add:

```swift
func testRegenerateDayEmptyPlanLeavesExistingItems() async throws {
    let ctx = try TestSupport.makeContext()
    let repo = TripRepository(context: ctx)
    let source = RegenerateSpySource()
    source.byTag = ["景点": [regenCandidate("X")]]
    let llm = RegenerateLLM([#"{"days":[{"day":1,"items":[{"poi_id":"GHOST"}]}]}"#])
    let old = PlanItem.poi(0, kind: .sight, time: "09:00", name: "Old", subtype: "景点", note: "", stay: "")
    old.poiId = "OLD"; old.lat = 30.0; old.lng = 104.0
    let day = DayPlan(dayIndex: 0, items: [old])
    let trip = try repo.create(city: "成都", adcode: "510100", prefs: TripPrefs(tags: ["景点"]), days: [day])

    do {
        try await repo.regenerateDay(day, in: trip, source: source, llm: llm)
        XCTFail("expected emptyPlan")
    } catch {
        XCTAssertEqual(error as? ItineraryEngine.EngineError, .emptyPlan)
    }

    XCTAssertEqual(day.sortedItems.compactMap(\.poiId), ["OLD"])
    XCTAssertEqual(day.sortedItems.map(\.name), ["Old"])
}
```

- [ ] **Step 3: Run focused failure tests**

Run:

```bash
xcodebuild test -scheme TrailheadCore -destination 'platform=macOS' -only-testing:TrailheadCoreTests/TripRepositoryTests/testRegenerateDayNoCandidatesLeavesExistingItems -only-testing:TrailheadCoreTests/TripRepositoryTests/testRegenerateDayEmptyPlanLeavesExistingItems
```

Expected: PASS.

---

### Task 4: Timeline Regenerate UI

**Files:**
- Modify: `Trailhead/Features/Timeline/RouteTimelineView.swift`

- [ ] **Step 1: Add regeneration state**

Add near other `@State` values:

```swift
@State private var regeneratingDayID: UUID?
```

- [ ] **Step 2: Add regenerate action to header**

Change the header HStack to include a spacer and button:

```swift
HStack(alignment: .firstTextBaseline, spacing: 9) {
    Text("Day \(selectedDayIndex + 1)")
        .font(Typo.display(19, .bold))
        .foregroundStyle(Palette.textPrimary)
    Text(daySubtitle)
        .font(.system(size: 13))
        .foregroundStyle(Palette.textSecondary)
    Spacer()
    if let day {
        regenerateDayButton(day)
    }
}
```

Add:

```swift
private func regenerateDayButton(_ day: DayPlan) -> some View {
    Button {
        regenerateDay(day)
    } label: {
        Image(systemName: regeneratingDayID == day.id ? "hourglass" : "arrow.clockwise")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(regeneratingDayID == nil ? Palette.green : Palette.textMuted.opacity(0.45))
            .frame(width: 30, height: 28)
            .background(Palette.fieldBG, in: RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .disabled(regeneratingDayID != nil)
    .help("重新生成当天")
}
```

- [ ] **Step 3: Disable edit operations while regenerating**

Update edit/save/move/replace/delete controls so they are disabled when `regeneratingDayID != nil`.

For `editButton`, add:

```swift
.disabled(regeneratingDayID != nil)
```

For the save control:

```swift
editControlButton(systemName: "checkmark", tint: .white, background: Palette.green) {
    if let day { saveEditing(day) }
}
.disabled(regeneratingDayID != nil)
.help("保存")
```

For move buttons, include `regeneratingDayID != nil` in each `disabled:` expression.

For replace/delete buttons, include `regeneratingDayID != nil` in each `disabled:` expression.

- [ ] **Step 4: Implement UI trigger**

Add:

```swift
private func regenerateDay(_ day: DayPlan) {
    guard regeneratingDayID == nil else { return }
    let currentIDs = poiIDs(for: day)
    regeneratingDayID = day.id
    Task { @MainActor in
        do {
            let repo = TripRepository(context: modelContext)
            if isEditing {
                try repo.reorderPOIs(day, orderedPOIIDs: currentIDs)
            }
            try await repo.regenerateDay(day, in: trip, source: AmapClient(), llm: DeepSeekClient())
            draftPOIIDs = day.sortedItems.filter { $0.kind != .transit }.map(\.id)
            selectedItemID = draftPOIIDs.first
            regeneratingDayID = nil
        } catch {
            editError = error.localizedDescription
            regeneratingDayID = nil
        }
    }
}
```

- [ ] **Step 5: Build macOS app**

Run:

```bash
xcodebuild test -project Trailhead.xcodeproj -scheme Trailhead -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

---

### Task 5: Progress Docs and Full Verification

**Files:**
- Modify: `README.md`
- Modify: `PDR-行迹.md`
- Modify: `docs/superpowers/plans/2026-06-26-t6-3-regenerate-day.md`

- [ ] **Step 1: Update progress text**

Update README milestone row and next-step text so T6.3 is complete and T7.2 is next.

Update PDR T6.3 row/status notes so single-day regeneration is complete.

- [ ] **Step 2: Run full verification**

Run:

```bash
make test
```

Expected: PASS.

Run:

```bash
xcodebuild -project Trailhead.xcodeproj -scheme Trailhead -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Expected: PASS.

Run:

```bash
swiftformat . --lint
```

Expected: exit 0. Cache permission warnings are acceptable if the process exits 0.

Run:

```bash
git diff --check
```

Expected: no output.

Run:

```bash
make lint
```

Expected: PASS with 0 violations.

- [ ] **Step 3: Commit implementation**

Run:

```bash
git add README.md PDR-行迹.md Packages/TrailheadCore/Sources/TrailheadCore/ItineraryDayBuilder.swift Packages/TrailheadCore/Sources/TrailheadCore/ItineraryEngine.swift Packages/TrailheadCore/Sources/TrailheadCore/TripRepository.swift Packages/TrailheadCore/Tests/TrailheadCoreTests/TripRepositoryTests.swift Trailhead/Features/Timeline/RouteTimelineView.swift docs/superpowers/plans/2026-06-26-t6-3-regenerate-day.md
git commit -m "feat: regenerate single day itinerary"
```

Expected: commit succeeds.
