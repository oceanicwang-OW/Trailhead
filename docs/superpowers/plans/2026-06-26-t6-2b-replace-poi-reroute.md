# T6.2b Replace POI and Reroute Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users replace one POI from recalled candidates in timeline edit mode, then rebuild that day's transit rows.

**Architecture:** Keep mutation and route rebuilding in `TripRepository`; keep candidate loading and selection in `RouteTimelineView`. Refactor delete and replace to share one private day-rebuild helper so transit behavior stays identical.

**Tech Stack:** Swift 6, SwiftData, SwiftUI, TrailheadCore, XCTest, Xcode/macOS+iOS build verification.

---

## File Structure

- Modify `Packages/TrailheadCore/Sources/TrailheadCore/TripRepository.swift`
  - Add `replacePOI(_:with:in:routeUsing:)`.
  - Extract shared private `rebuildDay(_:withPOIs:routeUsing:)`.
  - Keep `mode(from:to:)`, `haversineMeters`, and `PlanItem.routeCandidate` private.
- Modify `Packages/TrailheadCore/Tests/TrailheadCoreTests/TripRepositoryTests.swift`
  - Add route spy support for route failures.
  - Add replacement tests before implementation.
- Modify `Trailhead/Features/Timeline/RouteTimelineView.swift`
  - Add replace button next to up/down/delete.
  - Add candidate sheet with loading, empty, error, and candidate rows.
  - Load candidates through `POIRecall(source: AmapClient(), cache: POICache(context: modelContext))`.
  - Filter duplicate `poiId`s from the current day.
- Modify `README.md` and `PDR-行迹.md`
  - Mark T6.2b complete after verification.

---

### Task 1: Core Replace API

**Files:**
- Modify: `Packages/TrailheadCore/Tests/TrailheadCoreTests/TripRepositoryTests.swift`
- Modify: `Packages/TrailheadCore/Sources/TrailheadCore/TripRepository.swift`

- [ ] **Step 1: Write the failing replacement test**

Add this test to `TripRepositoryTests` after `testDeletePOIRebuildsTransitBetweenRemainingPOIs`:

```swift
func testReplacePOIUpdatesTargetAndRebuildsTransit() async throws {
    let ctx = try TestSupport.makeContext()
    let repo = TripRepository(context: ctx)
    let source = RouteSpySource()
    let a = PlanItem.poi(0, kind: .sight, time: "09:00", name: "A", subtype: "景点", note: "", stay: "")
    a.poiId = "A"; a.lat = 30.0; a.lng = 104.0
    let transitAB = PlanItem.transit(1, mode: .walk, desc: "A 到 B", minutes: 12, meters: 900)
    let b = PlanItem.poi(2, kind: .food, time: "12:00", name: "B", subtype: "餐厅", note: "old note", stay: "约 1 小时")
    b.poiId = "B"; b.lat = 30.01; b.lng = 104.01
    let originalID = b.id
    let transitBC = PlanItem.transit(3, mode: .metro, desc: "B 到 C", minutes: 20, meters: 3500)
    let c = PlanItem.poi(4, kind: .sight, time: "15:00", name: "C", subtype: "景点", note: "", stay: "")
    c.poiId = "C"; c.lat = 30.04; c.lng = 104.04
    let day = DayPlan(dayIndex: 0, items: [a, transitAB, b, transitBC, c])
    try repo.create(city: "成都", days: [day])

    let replacement = POICandidate(id: "X", name: "X Cafe", kind: .food, subtype: "咖啡", lat: 30.02, lng: 104.02)
    try await repo.replacePOI(b, with: replacement, in: day, routeUsing: source)

    let sorted = day.sortedItems
    XCTAssertEqual(sorted.map(\.kind), [.sight, .transit, .food, .transit, .sight])
    XCTAssertEqual(sorted.map(\.name), ["A", nil, "X Cafe", nil, "C"])
    XCTAssertEqual(sorted.map(\.order), [0, 1, 2, 3, 4])
    XCTAssertEqual(sorted[2].id, originalID)
    XCTAssertEqual(sorted[2].poiId, "X")
    XCTAssertEqual(sorted[2].subtype, "咖啡")
    XCTAssertEqual(sorted[2].lat, 30.02)
    XCTAssertEqual(sorted[2].lng, 104.02)
    XCTAssertEqual(sorted[2].plannedTime, "12:00")
    XCTAssertEqual(sorted[2].stayLabel, "约 1 小时")
    XCTAssertEqual(sorted[2].note, "old note")
    XCTAssertEqual(source.routeCalls.map { "\($0.from)-\($0.to)" }, ["A-X", "X-C"])
}
```

- [ ] **Step 2: Run the focused Core test and confirm RED**

Run:

```bash
xcodebuild test -scheme TrailheadCore -destination 'platform=macOS' -only-testing:TrailheadCoreTests/TripRepositoryTests/testReplacePOIUpdatesTargetAndRebuildsTransit
```

Expected: FAIL because `TripRepository` has no `replacePOI`.

- [ ] **Step 3: Implement shared rebuild and replace**

In `TripRepository.swift`:

- Replace the body of `deletePOI` so it calls a private rebuild helper.
- Add `replacePOI(_:with:in:routeUsing:)`.
- Add a private `rebuildDay(_:withPOIs:routeUsing:)`.

Implementation shape:

```swift
public func deletePOI(_ item: PlanItem, from day: DayPlan, routeUsing source: POIDataSource) async throws {
    guard item.kind != .transit else { return }
    let remainingPOIs = day.sortedItems.filter { $0.kind != .transit && $0.id != item.id }
    context.delete(item)
    try await rebuildDay(day, withPOIs: remainingPOIs, routeUsing: source)
}

public func replacePOI(_ item: PlanItem, with candidate: POICandidate,
                       in day: DayPlan, routeUsing source: POIDataSource) async throws {
    guard item.kind != .transit else { return }
    item.poiId = candidate.id
    item.name = candidate.name
    item.kind = candidate.kind
    item.subtype = candidate.subtype
    item.lat = candidate.lat
    item.lng = candidate.lng
    let orderedPOIs = day.sortedItems.filter { $0.kind != .transit }
    try await rebuildDay(day, withPOIs: orderedPOIs, routeUsing: source)
}

private func rebuildDay(_ day: DayPlan, withPOIs orderedPOIs: [PlanItem],
                        routeUsing source: POIDataSource) async throws {
    var transitBeforePOI: [UUID: PlanItem] = [:]
    var previousCandidate: POICandidate?
    for poi in orderedPOIs {
        guard let candidate = poi.routeCandidate else {
            previousCandidate = nil
            continue
        }
        if let previousCandidate {
            let mode = Self.mode(from: previousCandidate, to: candidate)
            if let segment = try? await source.route(from: previousCandidate, to: candidate, mode: mode) {
                let transit = PlanItem(order: 0, kind: .transit)
                transit.transitMode = mode
                transit.transitDesc = mode.display
                transit.transitMinutes = segment.minutes
                transit.transitMeters = segment.meters
                transit.transitCost = segment.cost
                transitBeforePOI[poi.id] = transit
            }
        }
        previousCandidate = candidate
    }

    for removed in day.items where removed.kind == .transit {
        context.delete(removed)
    }

    var rebuilt: [PlanItem] = []
    var order = 0
    for poi in orderedPOIs {
        if let transit = transitBeforePOI[poi.id] {
            transit.order = order
            rebuilt.append(transit)
            order += 1
        }
        poi.order = order
        rebuilt.append(poi)
        order += 1
    }
    day.items = rebuilt
    try context.save()
}
```

- [ ] **Step 4: Run the focused test and confirm GREEN**

Run:

```bash
xcodebuild test -scheme TrailheadCore -destination 'platform=macOS' -only-testing:TrailheadCoreTests/TripRepositoryTests/testReplacePOIUpdatesTargetAndRebuildsTransit
```

Expected: PASS.

- [ ] **Step 5: Run the existing delete test**

Run:

```bash
xcodebuild test -scheme TrailheadCore -destination 'platform=macOS' -only-testing:TrailheadCoreTests/TripRepositoryTests/testDeletePOIRebuildsTransitBetweenRemainingPOIs
```

Expected: PASS. This guards the rebuild refactor.

---

### Task 2: Route Failure Tolerance

**Files:**
- Modify: `Packages/TrailheadCore/Tests/TrailheadCoreTests/TripRepositoryTests.swift`
- Modify: `Packages/TrailheadCore/Sources/TrailheadCore/TripRepository.swift`

- [ ] **Step 1: Extend `RouteSpySource` to simulate one failed route**

Change the spy to:

```swift
private final class RouteSpySource: POIDataSource {
    var failingPairs: Set<String> = []
    private(set) var routeCalls: [(from: String, to: String, mode: TransitMode)] = []

    func geocodeCity(_ name: String) async throws -> (adcode: String, center: (Double, Double)) {
        ("000000", (0, 0))
    }

    func searchPOI(adcode: String, tags: [String]) async throws -> [POICandidate] {
        []
    }

    func route(from: POICandidate, to: POICandidate,
               mode: TransitMode) async throws -> (minutes: Int, meters: Int, cost: Int?) {
        routeCalls.append((from.id, to.id, mode))
        if failingPairs.contains("\(from.id)-\(to.id)") {
            throw URLError(.cannotConnectToHost)
        }
        return (22, 2600, 12)
    }
}
```

- [ ] **Step 2: Add the failure-tolerance test**

Add:

```swift
func testReplacePOISkipsFailedRouteSegmentAndStillSaves() async throws {
    let ctx = try TestSupport.makeContext()
    let repo = TripRepository(context: ctx)
    let source = RouteSpySource()
    source.failingPairs = ["A-X"]
    let a = PlanItem.poi(0, kind: .sight, time: "09:00", name: "A", subtype: "景点", note: "", stay: "")
    a.poiId = "A"; a.lat = 30.0; a.lng = 104.0
    let b = PlanItem.poi(1, kind: .food, time: "12:00", name: "B", subtype: "餐厅", note: "", stay: "")
    b.poiId = "B"; b.lat = 30.01; b.lng = 104.01
    let c = PlanItem.poi(2, kind: .sight, time: "15:00", name: "C", subtype: "景点", note: "", stay: "")
    c.poiId = "C"; c.lat = 30.04; c.lng = 104.04
    let day = DayPlan(dayIndex: 0, items: [a, b, c])
    try repo.create(city: "成都", days: [day])

    let replacement = POICandidate(id: "X", name: "X Cafe", kind: .food, subtype: "咖啡", lat: 30.02, lng: 104.02)
    try await repo.replacePOI(b, with: replacement, in: day, routeUsing: source)

    let sorted = day.sortedItems
    XCTAssertEqual(sorted.map(\.kind), [.sight, .food, .transit, .sight])
    XCTAssertEqual(sorted.map(\.name), ["A", "X Cafe", nil, "C"])
    XCTAssertEqual(source.routeCalls.map { "\($0.from)-\($0.to)" }, ["A-X", "X-C"])
}
```

- [ ] **Step 3: Run the focused failure test**

Run:

```bash
xcodebuild test -scheme TrailheadCore -destination 'platform=macOS' -only-testing:TrailheadCoreTests/TripRepositoryTests/testReplacePOISkipsFailedRouteSegmentAndStillSaves
```

Expected: PASS. The implementation from Task 1 already uses `try?` around individual route calls, so no new production code should be needed unless the refactor regressed.

---

### Task 3: Timeline Replacement UI

**Files:**
- Modify: `Trailhead/Features/Timeline/RouteTimelineView.swift`

- [ ] **Step 1: Add UI state**

Add state near the existing edit state:

```swift
@State private var replacingItem: PlanItem?
@State private var replacementCandidates: [POICandidate] = []
@State private var replacementLoading = false
@State private var replacementError: String?
@State private var applyingReplacementItemID: UUID?
```

- [ ] **Step 2: Present the candidate sheet**

Attach to the root `ScrollView` chain:

```swift
.sheet(item: $replacingItem) { item in
    replacementSheet(for: item)
}
```

- [ ] **Step 3: Add the replace button to row controls**

In `moveControls(for:day:)`, insert before the trash button:

```swift
moveButton(systemName: applyingReplacementItemID == item.id ? "hourglass" : "arrow.triangle.2.circlepath",
           tint: Palette.green,
           disabled: deletingItemID != nil || applyingReplacementItemID != nil) {
    openReplacement(for: item, day: day)
}
.help("替换")
```

- [ ] **Step 4: Add candidate sheet helpers**

Add private helpers inside `RouteTimelineView`:

```swift
private func replacementSheet(for item: PlanItem) -> some View {
    VStack(alignment: .leading, spacing: 14) {
        HStack {
            Text("替换地点")
                .font(Typo.display(18, .bold))
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Button("关闭") {
                replacingItem = nil
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textMuted)
        }

        if replacementLoading {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if let replacementError {
            VStack(alignment: .leading, spacing: 8) {
                Text(replacementError)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                Button("重试") {
                    if let day { loadReplacementCandidates(for: item, day: day) }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if replacementCandidates.isEmpty {
            Text("没有可替换的候选")
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            List(replacementCandidates) { candidate in
                Button {
                    if let day { applyReplacement(candidate, for: item, day: day) }
                } label: {
                    replacementCandidateRow(candidate)
                }
                .buttonStyle(.plain)
                .disabled(applyingReplacementItemID != nil)
            }
            .listStyle(.plain)
            .frame(minHeight: 240)
        }
    }
    .padding(18)
    .frame(minWidth: 360, idealWidth: 420, minHeight: 300)
}

private func replacementCandidateRow(_ candidate: POICandidate) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(candidate.name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Palette.textPrimary)
        Text(candidateMetadata(candidate))
            .font(.system(size: 12))
            .foregroundStyle(Palette.textSecondary)
    }
    .padding(.vertical, 6)
}

private func candidateMetadata(_ candidate: POICandidate) -> String {
    var parts = [candidate.subtype.isEmpty ? candidate.kind.label : candidate.subtype]
    if let rating = candidate.rating { parts.append(String(format: "%.1f 分", rating)) }
    if let avgPrice = candidate.avgPrice { parts.append("¥\(avgPrice)") }
    if let openHours = candidate.openHours, !openHours.isEmpty { parts.append(openHours) }
    return parts.joined(separator: " · ")
}
```

- [ ] **Step 5: Add candidate loading and apply helpers**

Add:

```swift
private func openReplacement(for item: PlanItem, day: DayPlan) {
    replacingItem = item
    loadReplacementCandidates(for: item, day: day)
}

private func loadReplacementCandidates(for item: PlanItem, day: DayPlan) {
    replacementLoading = true
    replacementError = nil
    replacementCandidates = []
    Task { @MainActor in
        do {
            guard !trip.adcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                replacementError = "当前行程缺少城市编码，无法召回候选"
                replacementLoading = false
                return
            }
            let recall = POIRecall(source: AmapClient(), cache: POICache(context: modelContext))
            let existingPOIIDs = Set(day.sortedItems.compactMap(\.poiId))
            let tags = replacementTags(for: item)
            replacementCandidates = try await recall.recall(adcode: trip.adcode, tags: tags)
                .filter { !existingPOIIDs.contains($0.id) }
            replacementLoading = false
        } catch {
            replacementError = error.localizedDescription
            replacementLoading = false
        }
    }
}

private func replacementTags(for item: PlanItem) -> [String] {
    switch item.kind {
    case .sight:
        if let subtype = item.subtype, !subtype.isEmpty { return [subtype] }
        return ["景点"]
    case .food:
        return ["美食"]
    case .lodging:
        return ["住宿"]
    case .transit:
        return ["景点"]
    }
}

private func applyReplacement(_ candidate: POICandidate, for item: PlanItem, day: DayPlan) {
    guard applyingReplacementItemID == nil else { return }
    let currentIDs = poiIDs(for: day)
    applyingReplacementItemID = item.id
    Task { @MainActor in
        do {
            let repo = TripRepository(context: modelContext)
            try repo.reorderPOIs(day, orderedPOIIDs: currentIDs)
            try await repo.replacePOI(item, with: candidate, in: day, routeUsing: AmapClient())
            draftPOIIDs = currentIDs
            selectedItemID = item.id
            replacingItem = nil
            applyingReplacementItemID = nil
        } catch {
            editError = error.localizedDescription
            applyingReplacementItemID = nil
        }
    }
}
```

- [ ] **Step 6: Build macOS app**

Run:

```bash
xcodebuild test -project Trailhead.xcodeproj -scheme Trailhead -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

---

### Task 4: Progress Docs and Full Verification

**Files:**
- Modify: `README.md`
- Modify: `PDR-行迹.md`

- [ ] **Step 1: Update progress text**

Update README milestone row and next-step text so T6.2b is marked complete and T6.3 is next.

Update PDR T6.2 rows/status notes so deletion and replacement are complete.

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
git add README.md PDR-行迹.md Packages/TrailheadCore/Sources/TrailheadCore/TripRepository.swift Packages/TrailheadCore/Tests/TrailheadCoreTests/TripRepositoryTests.swift Trailhead/Features/Timeline/RouteTimelineView.swift docs/superpowers/plans/2026-06-26-t6-2b-replace-poi-reroute.md
git commit -m "feat: replace poi and reroute day"
```

Expected: commit succeeds.
