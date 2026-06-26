# T6.2a Delete POI and Reroute Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete a POI from a day and rebuild that day's transit rows from the remaining POIs.

**Architecture:** Add the mutation to `TripRepository` so SwiftData writes and route rebuilds stay centralized. Reuse `POIDataSource.route` for fresh transit rows. Keep Timeline UI thin: show a trash button in edit mode and call the repository.

**Tech Stack:** Swift, SwiftData, SwiftUI, XCTest, existing `POIDataSource` abstraction.

---

### Task 1: Core Delete Helper

**Files:**
- Modify: `Packages/TrailheadCore/Tests/TrailheadCoreTests/TripRepositoryTests.swift`
- Modify: `Packages/TrailheadCore/Sources/TrailheadCore/TripRepository.swift`

- [ ] Add a failing async XCTest `testDeletePOIRebuildsTransitBetweenRemainingPOIs`.
- [ ] Run `cd Packages/TrailheadCore && xcodebuild test -scheme TrailheadCore -destination 'platform=macOS'` and confirm it fails because `deletePOI` is missing.
- [ ] Implement `TripRepository.deletePOI(_:from:routeUsing:)`.
- [ ] Re-run the Core test and then the full Core suite.

### Task 2: Timeline UI

**Files:**
- Modify: `Trailhead/Features/Timeline/RouteTimelineView.swift`

- [ ] Add a trash icon button to edit-mode POI controls.
- [ ] Call `TripRepository(context: modelContext).deletePOI(item, from: day, routeUsing: AmapClient())` in a `Task`.
- [ ] Disable the button while a delete is saving and show the existing save error alert on failure.

### Task 3: Docs and Verification

**Files:**
- Modify: `README.md`
- Modify: `PDR-行迹.md`

- [ ] Mark T6.2 delete as complete and replacement as pending.
- [ ] Run `make test`.
- [ ] Run `xcodebuild -project Trailhead.xcodeproj -scheme Trailhead -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
- [ ] Run `swiftformat . --lint`, `make lint`, and `git diff --check`.
