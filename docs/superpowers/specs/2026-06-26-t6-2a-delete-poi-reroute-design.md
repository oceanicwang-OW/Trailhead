# T6.2a Delete POI and Reroute Design

## Scope

Implement the delete half of PDR T6.2. Users can remove a POI from a day timeline. After deletion, the day is rebuilt from the remaining POIs and any old transit rows are discarded. New transit rows are inserted between adjacent remaining POIs when both POIs have coordinates and the route provider returns a segment.

Replacement from candidate sets is intentionally out of scope for this increment and will be handled by T6.2b.

## Behavior

- Deleting a transit row is not supported.
- Deleting a POI keeps the remaining POI order.
- Remaining POIs are re-numbered from `order = 0`.
- Transit rows are rebuilt between adjacent remaining POIs.
- If a POI lacks `poiId`, name, or coordinates, it is still retained as a POI, but route generation involving that POI is skipped.
- If route generation fails for a pair, that pair has no transit row; the edit still saves.
- The Timeline edit UI shows a trash control for each POI next to the existing move controls.

## Architecture

Core owns the mutation. `TripRepository` gets an async delete helper that converts existing POI `PlanItem`s into routeable `POICandidate`s where possible, deletes old day items from the `ModelContext`, rebuilds POI and transit rows, then saves. `RouteTimelineView` only gathers the selected POI and calls the repository with `AmapClient`.

## Testing

Add a Core test that starts with `A, transitAB, B, transitBC, C`, deletes `B`, and asserts the day becomes `A, transitAC, C` with fresh orders and exactly one route call from A to C.
