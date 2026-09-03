# Frontend plan — Round 4: `ListMyMeetups` pagination + Round 3 cleanup

Two parts: wiring the backend's newly-completed `ListMyMeetups` pagination into `my_meetups_page.dart`, plus three small correctness/coverage items the Round 3 verification pass found (a misleading comment, two missing tests) — bundled here since they're quick and touch related files.

## Part A — Wire `ListMyMeetups` pagination into `my_meetups_page.dart`

Depends on the backend plan's new `hosted_cursor`/`requested_cursor`/`hosted_next_cursor`/`hosted_has_more`/`requested_next_cursor`/`requested_has_more` fields.

- `MeetupService.listMyMeetups` gains optional `hostedCursor`/`requestedCursor` params, returns the four new pagination fields alongside the existing `hosted`/`requested` lists. Mock + Http implementations.
- `my_meetups_page.dart`'s HOSTING and REQUESTED tabs each get the same "load more near the bottom of the list" mechanism `matches_page.dart`'s `_MeetupList` already has (Round 3 Fix 1) — reuse that exact pattern (scroll-threshold listener, loading-guard flag, disposed `ScrollController`), don't invent a second one. The two tabs paginate independently, matching the two independent cursors.

## Part B — Round 3 cleanup (found during verification, not fixed then)

- **Fix the misleading comment in `matches_page.dart`.** The current comment claims pull-to-refresh and intent-switching reset pagination state "via `didUpdateWidget`" — traced during review, both are actually a full unmount/remount through `initState` (a different widget briefly renders in between — `_MeetupsSkeleton()` — so `_MeetupList` itself gets torn down and recreated, not updated in place). End-user behavior is correct either way; just correct the comment to describe what actually happens, so the next person reading it isn't misled about the mechanism.
- **Add the missing intent-switch-during-pagination test.** Confirm that switching the intent filter while a second page is mid-load doesn't leak stale page-2 items from the previous intent into the new list — script a `hasMore: true` response, trigger the scroll-load, switch intent before it resolves, and assert the new intent's list starts clean.
- **Add the missing mid-pagination-failure test.** Confirm the current behavior (a `listOpenMeetups` failure during scroll-triggered pagination is caught, `_loadingMore` is cleared, no error UI shown — a deliberate "best-effort" choice, not an oversight) is actually covered by a test, so a future change can't silently alter this without a test noticing.

## Tests

- `TestMyMeetupsPage_HostingTab_LoadsNextPageOnScroll`, `TestMyMeetupsPage_RequestedTab_LoadsNextPageOnScroll` (independent pagination per tab).
- The two Round 3 cleanup tests described in Part B above.
- Full checklist: `flutter analyze --fatal-infos`, `dart format --set-exit-if-changed`, `flutter test` — report the real total test count.
