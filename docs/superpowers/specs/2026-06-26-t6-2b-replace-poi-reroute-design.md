# T6.2b Replace POI and Reroute Design

## Scope

Implement the replacement half of PDR T6.2. In timeline edit mode, users can replace one POI with a candidate recalled from the existing POI pipeline. After replacement, the day keeps the same POI order and rebuilds transit rows between adjacent POIs.

This increment does not add free-text POI search, manual category filters, or single-day regeneration. Those remain separate enhancements after T6.2b.

## User Flow

1. User enters timeline edit mode.
2. Each POI row exposes a replace action alongside move and delete.
3. Tapping replace opens a simple candidate sheet for that POI.
4. The sheet loads candidates through `POIRecall`, backed by `POICache` and `AmapClient`.
5. Existing POIs from the current day are filtered out by `poiId`.
6. User picks one candidate.
7. The app replaces the selected POI, rebuilds transit for the day, keeps editing mode active, and selects the replaced row.

## Candidate Rules

Candidate recall uses the trip adcode and tags derived from the original row:

- `sight` uses the original subtype when present, otherwise `景点`.
- `food` uses `美食`.
- `lodging` uses `住宿`.
- Other non-transit kinds fall back to `景点`.

If the trip has no usable adcode or the recall returns no non-duplicate candidates, the sheet shows an empty state and does not mutate the trip.

## Core Changes

`TripRepository` gains:

```swift
public func replacePOI(_ item: PlanItem,
                       with candidate: POICandidate,
                       in day: DayPlan,
                       routeUsing source: POIDataSource) async throws
```

The method rejects transit rows, updates the target POI's location fields, preserves user-facing schedule fields such as planned time, stay label, note, and order position, then rebuilds the day from all non-transit POIs in their existing order.

The existing delete implementation should share the same private rebuild helper so delete and replace cannot drift in route-row behavior. Rebuild deletes old transit rows, computes new adjacent route segments when both endpoints have coordinates, inserts successful transit rows, tolerates individual route failures by omitting that segment, rewrites contiguous `order` values, and saves once.

## SwiftUI Changes

`RouteTimelineView` owns replacement UI state:

- currently replacing item
- loading flag
- loaded candidates
- replacement error
- replacing item id for row-level disabled/loading state

The candidate sheet is intentionally simple: title, candidate name, subtype/kind, and optional metadata such as rating, open hours, or average price if present. It supports loading, empty, error, and disabled states.

Before replacing, the view persists the current draft POI order with `reorderPOIs`, matching the delete behavior. After a successful replacement, draft IDs remain stable because the existing `PlanItem` object is updated in place.

## Error Handling

- Missing or unusable adcode: show a candidate-sheet error.
- POI recall failure: show a candidate-sheet error.
- Replace persistence failure: show the existing edit alert.
- Route segment failure during rebuild: do not fail replacement; skip only that transit row.

## Tests

Core tests drive the behavior first:

- replacing B with X in `A -> B -> C` produces `A -> transit -> X -> transit -> C`
- old transit rows are deleted
- target row keeps its UUID and order position
- target row receives the candidate's `poiId`, name, kind, subtype, lat, and lng
- route calls are made for `A-X` and `X-C`
- route failure for one segment still saves the replacement

UI testing stays focused on compile/build verification for this increment. Candidate loading is kept in small view helpers so it can be extracted later if the flow grows.
