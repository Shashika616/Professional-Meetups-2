# Frontend plan — Round 3 performance hardening (2026-08-31 audit)

Three frontend findings from a performance/memory-lens audit — see `docs/00-project/action-tracker.md` § 4b-17.

## Fix 1 — Wire real pagination into the browse-meetups list (Medium — the main item this round)

The backend's `listOpenMeetups` already returns `PagedResult` with `nextCursor`/`hasMore` (`core/models/paged_result.dart`, `http_meetup_service.dart`) — `matches_page.dart`'s `_MeetupList` never reads either field. The list silently caps at page 1 forever with no way to reach page 2.

- Add a scroll listener (or `ListView.builder`'s existing lazy-build mechanism combined with a "load more when near the end" check) that, when `hasMore` is true and the user scrolls near the bottom, calls `listOpenMeetups` again with `nextCursor` and appends results.
- Show a loading indicator at the list's end while the next page is in flight; handle the last-page case (`hasMore == false`) by simply not triggering another fetch — no "you've reached the end" banner needed unless that's already this app's convention elsewhere (check before adding one).
- This is purely a frontend change — no backend API change needed, the capability already exists and is unused.

## Fix 2 — `active_meetups_section.dart`'s list construction (Low)

Currently `...active.map(...)` inside a `Column` — eager, builds every item regardless of visibility. Low severity given the list is naturally small (server-scoped to open/full, unexpired), but inconsistent with `ListView.builder` used everywhere else in this app.

- Switch to `ListView.builder` (or `Column` is fine to keep if this section is never expected to scroll independently — check the actual layout context before changing; if it's already inside a scrollable parent and this section itself doesn't scroll, `ListView.builder` may not even be the right widget — use judgment, the point is consistency with intent, not mechanically swapping widgets).

## Fix 3 — `ProfessionalAvatar` image cache dimensions (Low)

`Image.network` doesn't set `cacheWidth`/`cacheHeight` — a high-resolution photo decodes and caches at full source resolution despite rendering at ~44-48px, wasteful memory per unique avatar URL, compounding with Fix 1's now-longer scrollable lists.

- Set `cacheWidth`/`cacheHeight` (or the equivalent `memCacheWidth`/`memCacheHeight` if this ends up using a caching image package instead — check what's already available in `pubspec.yaml` before adding a new dependency) sized to the widget's actual maximum rendered size (account for device pixel ratio — don't just use the logical pixel size, multiply by a reasonable max `devicePixelRatio` like 3).

## Tests

- Widget test: browse list requests a second page when scrolled near the bottom and `hasMore` is true; does not request again once `hasMore` is false.
- Full checklist: `flutter analyze --fatal-infos`, `dart format --set-exit-if-changed`, `flutter test`.

## Optional cleanup, not required this round

`schedule_flow.dart` has a ~40-line dead commented-out `_LocationStep` block predating the real map-picker widgets — fine to delete opportunistically while in this file for Fix 1/2, not worth its own pass.
