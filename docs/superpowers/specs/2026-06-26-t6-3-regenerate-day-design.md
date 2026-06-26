# T6.3 Regenerate Single Day Design

## Scope

Implement PDR T6.3: regenerate only the currently selected day. The operation replaces that `DayPlan`'s items with a fresh one-day itinerary while leaving every other day and the parent `Trip` metadata unchanged.

This increment does not add per-day preference editing, candidate search controls, or whole-trip regeneration.

## User Flow

1. User opens an existing trip and selects a day.
2. The timeline exposes a regenerate-day action near the existing edit controls.
3. User taps the action.
4. The app disables timeline edit actions for that day and shows a loading state.
5. The selected day is regenerated from current trip preferences.
6. The timeline refreshes with new POI and transit rows.
7. The first non-transit item in the regenerated day becomes selected.

## Core Behavior

`TripRepository` gains a narrow API that regenerates a single existing `DayPlan`:

```swift
public func regenerateDay(_ day: DayPlan,
                          in trip: Trip,
                          source: POIDataSource,
                          llm: LLMProvider) async throws
```

The method uses:

- `trip.adcode` for POI recall.
- `trip.prefs.tags` for candidate categories.
- `trip.prefs` for LLM planning.
- `day.dayIndex`, `day.date`, and `day.cityLabel` as stable day metadata.

It calls the existing recall, LLM, parser, fact-checking, and route-building flow for exactly one day. It builds the new item list completely before mutating SwiftData. Only after that succeeds does it delete the old `day.items`, assign freshly built items, rewrite contiguous `order` values, and save once.

If no candidates are available or the LLM returns no valid stops after fact-checking, the method throws and leaves existing items unchanged.

## Architecture

The implementation should avoid creating a temporary `Trip`. Extract the reusable one-day building logic from `ItineraryEngine` into a Core helper that can be used by both whole-trip generation and day regeneration.

Preferred shape:

- `ItineraryEngine.generate(...)` continues to create full trips.
- A new Core service/helper handles "plan one day from candidates".
- `TripRepository` owns the final mutation of an existing `DayPlan`.

This keeps generation logic testable and keeps SwiftUI out of parsing, fact-checking, and route construction.

## SwiftUI Behavior

`RouteTimelineView` owns a small regeneration state:

- currently regenerating day id
- disabled state for edit, replace, delete, and save while regenerating
- error mapped into the existing edit alert

The action should be visible without requiring the user to enter edit mode, because regeneration is a day-level operation rather than a row-level operation.

If regeneration starts while edit mode has unsaved POI reorder changes, the view first persists the current draft order with `reorderPOIs` so the mutation starts from a consistent state.

## Error Handling

- Missing trip adcode: show an error and leave the day unchanged.
- No recalled candidates: show an error and leave the day unchanged.
- LLM parse failure after retry: show an error and leave the day unchanged.
- All LLM stops rejected by fact-checking: show an error and leave the day unchanged.
- Individual route segment failure: do not fail regeneration; omit only that transit row.

## Tests

Core tests drive the behavior:

- regenerating day 1 in a two-day trip changes only day 1 items.
- day index, date, and city label are preserved.
- old items from the regenerated day are deleted.
- new POI rows come only from fact-checked candidates.
- route rows are inserted between adjacent new POIs.
- no-candidate and empty-plan errors leave old items untouched.

UI verification stays compile/build based for this increment. Behavior should remain covered by Core tests, with the view only responsible for triggering the operation and rendering loading/error states.
