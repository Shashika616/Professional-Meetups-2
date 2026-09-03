# Frontend plan — Active meetups dashboard, persistent card, auto-close (ADR-025, Slice F)

Read `docs/04-decisions/adr-025-active-meetups-dashboard-persistent-card-auto-close.md` first. Depends on the backend plan's new `ListActiveMeetups` RPC.

## Step 1 — Service contract

- `MeetupService`: add `listActiveMeetups()`, mirrored in `MockMeetupService`/`HttpMeetupService`, returning the sorted (soonest-first) list with `windowStart`/`windowEnd` per entry.

## Step 2 — `HomePage` "Active Meetups" section

- New section rendering `listActiveMeetups()` results soonest-first, same visual language as the rest of `HomePage`'s existing cards — don't invent a new card style.

## Step 3 — Persistent swipeable card

- New widget: renders only for meetups where `now` falls within `[windowStart - 30min, windowEnd]` (computed client-side from the returned timestamps — this is a display decision, the *inclusion* in the active list is already server-decided). If more than one meetup qualifies concurrently, render as a swipeable `PageView`.
- Once a given card's `windowEnd` passes (computed client-side, no new backend call), it converts in place to the existing rate-the-experience prompt component already built for ADR-015/ADR-020's other rating triggers — reuse it, don't build a second prompt UI.
- Refresh via the same pull-to-refresh / re-fetch-on-focus pattern already used elsewhere in this app — no new realtime/polling infrastructure.

## Step 4 — Tests

- Widget test: card appears only within the eligible window, not before or after.
- Widget test: two concurrently-eligible meetups render as a swipeable set.
- Widget test: card converts to the rating prompt once `windowEnd` passes.
- Full checklist: `flutter analyze`, `dart format --set-exit-if-changed`, `flutter test`.
