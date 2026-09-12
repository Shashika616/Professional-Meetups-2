# ADR-004 - Quantise Viewer Coordinates Before Using Them as a Cache Key

## Status

Accepted (2026-09-10).

## Context

`openMeetupsProvider` (`frontend/lib/core/providers/app_providers.dart`) is a
Riverpod `.family` keyed on `(intent, viewerLat, viewerLng, withinDays)`.
`happening_soon_section.dart` fed it the raw `position.latitude` /
`position.longitude` returned by the device.

Consumer GPS is accurate to roughly 3-10 metres, and it is *noisy*: asking a
stationary phone for its position twice returns two slightly different
numbers. Riverpod treats any distinct key as a distinct provider, so every
such reading minted a brand-new cache entry, missed the cache, and refetched
a list that was byte-for-byte identical to the one it had just discarded.

This was found in the deployed service's own request logs, not by reading
code. `/v1/meetups` was fetched at these latitudes within minutes, from a
phone sitting on a desk:

```
22:00:50  viewer_lat=6.8705648
22:02:48  viewer_lat=6.8705815
22:03:26  viewer_lat=6.8705842
22:07:26  viewer_lat=6.8705933
```

A spread of about three metres. The clearest single example: `intent=lunch`
was fetched at `22:07:54` and again at `22:08:15` - same filter, same
results, 21 seconds apart, purely because the coordinates had drifted.

`_loadLocation()` runs from `initState()`, not on a timer, so this was not
continuous polling: it cost one wasted round trip per mount of the Happening
Soon section (opening Home, returning to the Home tab after disposal, cold
start). Bounded, but entirely avoidable.

## Decision

Round the coordinate to three decimal places before it is used as a cache
key - `quantiseViewerCoordinate` in `happening_soon_section.dart`. Three
decimals is ~110m of latitude.

Quantisation happens **at the point of assignment** to `_viewerLat` /
`_viewerLng`, not at each provider call site. Those two fields feed the cache
key and nothing else, so doing it once at the source cannot be
half-applied - a second call site added later inherits it automatically.

`AuthService.updateLastKnownLocation` is deliberately **not** quantised. It
is passed the exact `position` from the device, because that value is the
user's stored location rather than a cache key. An existing test asserts
this, which is what keeps the two paths from being conflated.

### This changes what the server receives, and that was weighed

The family's key *is* what is passed to `listOpenMeetups`, so the API now
receives `6.927` rather than `6.9271`. Against ADR-021's 40km visibility
radius that is a 0.27% shift, and the server-side distance ordering can only
change for meetups within ~110m of each other, which is inside GPS noise
anyway. Accepted deliberately; it is not a purely client-side change and
should not be described as one.

### A grid, not a radius

Rounding snaps positions onto a fixed lattice ~110m apart. The guarantee is
"the same grid cell", not "within 110m of where I started". In the middle of
a cell the full ~110m of drift is absorbed; sitting almost exactly on a cell
boundary, a few metres of jitter can still flip between two adjacent keys.

So the honest claim is *usually* a cache hit while stationary, not *always*.
That is still the fix: before, a new key needed about one metre of noise, so
a refetch on every mount was guaranteed rather than occasional.

## Consequences

- The only continuous/repeated client-originated traffic left in the app is
  gone. (The other source, a retry loop against the not-yet-built
  `/v1/billing/subscription` 503, was fixed separately in the same pass.)
- Genuine movement past ~110m still crosses a cell boundary and refetches,
  which is the behaviour worth keeping.
- Frontend-only. No Go change, no `service.yaml` change, no Cloud Run
  redeploy - it ships in the app binary.
- Two existing tests asserted the raw coordinates reached `listOpenMeetups`.
  They now assert `quantiseViewerCoordinate(...)` rather than a hardcoded
  literal, so they document the contract instead of a magic number.

## What we did NOT do, and when to revisit

### `cos(latitude)` longitude correction

Rounding latitude and longitude by the same `0.001` is not a square grid. A
degree of longitude shrinks toward the poles, so cell shape depends on where
you are:

| latitude | cell size |
|---|---|
| Colombo 6.87°N | 111m × 110.5m |
| London 51.5°N | 111m × 69m |
| Reykjavík 64°N | 111m × 49m |

At Sri Lanka's latitude `cos(6.87°) = 0.9928`, so cells are within 0.7% of
square and the correction would change nothing measurable. Not applied.

**Revisit when:** the app is used meaningfully outside the tropics. At high
latitude the narrower cells have smaller area, so boundaries are crossed more
often and the wasted refetches partly return. Scaling longitude by
`cos(latitude)` before rounding fixes it in about two lines - but note it
needs a guard, since `cos` approaches zero at the poles, and the scale factor
itself shifts as the user moves north-south.

### H3 (hexagonal indexing)

Hexagons are geometrically better for this shape of problem. A square cell is
41% deeper toward its corners than its edges (`d√2/2` vs `d/2`); a regular
hexagon is only 15% (`R` vs `R√3/2`), and it has six equidistant neighbours
rather than four-plus-four. That uniformity is exactly why H3 exists.

Not adopted here. The deciding factor is not geometry but scale: cell size
(~110m) already dwarfs the error being absorbed (3-10m of jitter), a 10-30×
margin, so moving from a 1.41 ratio to 1.15 changes the boundary-crossing
probability without changing the outcome. Against that, H3 for Dart means a
package wrapping the C library - a native dependency to pin, keep building on
both platforms, and patch. This codebase already made that trade explicitly
elsewhere (`cmd/monolith/healthcheck.go`: a flag on its own binary rather
than "another third-party artifact to source, pin, verify and keep
patched"). A geospatial indexing library earning its keep as a rounding
function is a poor trade.

**Revisit when** the geo surface grows enough that one dependency serves
several call sites rather than one - at which point H3 is the right tool and
hand-rolled rounding is not:

- Bucketing meetups by cell server-side so `ListOpenMeetups` can hit an index
  instead of evaluating `ST_DWithin` per row
- Caching or sharding results per region
- Density/heatmap work ("how many meetups near here")
- Expanding-radius search via ring queries (`kRing`)

If that day comes, the client-side rounding here should be replaced by the
same cell id the server indexes on, so the two cannot disagree about which
cell a user is in.

## Related

ADR-021 in the vault (40km geo visibility - the radius this quantisation is
measured against) · `frontend/lib/features/home/widgets/happening_soon_section.dart`
(`quantiseViewerCoordinate` and its call site) ·
`frontend/test/happening_soon_section_test.dart` (the drift cases, using the
real latitudes from the logs above)
