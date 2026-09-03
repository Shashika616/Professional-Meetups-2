# Frontend plan — Round 5: `meetup_detail_page.dart` null-safety + the two actually-missing tests

Two independent fixes bundled together — see `docs/00-project/action-tracker.md` § 4b-19.

## Fix 1 — Defensive null-handling in `meetup_detail_page.dart`

Depends on the backend plan's `GetMeetup` redaction fix. Once `GetMeetup` can genuinely return a response with `hostFullName`/`locationLabel`/the time-window fields absent (for a viewer below the required trust level), this page's current force-unwraps (`hostFullName!`, etc.) would crash rather than degrade gracefully.

- Read `_LockedCardHeader` (`matches_page.dart`) first — reuse its visual treatment (blur placeholders + lock icon + "Verify to see details") for this page's equivalent state, don't invent a third version of the same UI.
- If `lockedForViewer` is true on the loaded meetup, render the locked treatment instead of the normal content, and the join button should already correctly redirect via `_handleLockedTap`-equivalent logic (check what this page currently does for its trust-gated button and extend it to also apply when `lockedForViewer` is true from the server, not just the client-side `isUnlockedFor` check it currently relies on alone).
- This is a defensive fix — there's currently no in-app navigation path that reaches this page for a locked meetup (confirmed in Round 4's review), but don't leave a force-unwrap that would crash the moment that stops being true (e.g. a future notification deep link).

## Fix 2 — Add the two tests Round 4's plan asked for but never got

The prior completion report claimed these were "folded into ADR-028's regression tests" — verification found that's not accurate, they don't exist anywhere. Add them for real this time, in `matches_page_test.dart`'s existing `cursor pagination` test group:

- Intent-switch-while-a-second-page-is-loading: script `hasMore: true`, trigger the scroll-load, switch the intent filter before the fetch resolves, assert the new intent's list starts clean with no stale page-2 items from the previous intent leaking in.
- A `listOpenMeetups` failure occurring mid-pagination: confirm the current silent-fail/clear-loading-flag behavior with a real test (this is a deliberate "best-effort" choice already accepted, not something to change — just add the missing coverage for it).

## Tests

- The two tests described in Fix 2 above are the tests for this round — no additional test scaffolding needed beyond what's already in `matches_page_test.dart`'s existing groups.
- Full checklist: `flutter analyze --fatal-infos`, `dart format --set-exit-if-changed`, `flutter test` — report the real total test count, and if it doesn't match a prior claim, say so plainly rather than restating the old number.
