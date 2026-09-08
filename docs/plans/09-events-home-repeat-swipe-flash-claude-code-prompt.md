to# Claude Code prompt — reproduce and fix the grey flash on repeated Events↔Home swipes

You're working in `/Users/as/Documents/Professional Meetups/Professional-Meetups-Monolith`.

## Context — don't re-derive this

`docs/plans/08-tab-swipe-keepalive-fix.md` diagnosed and fixed a grey-flash bug
by adding `AutomaticKeepAliveClientMixin` to all four `AppShell` tab pages
(`HomePage`, `EventsPage`, `SafetyPage`, `ProfilePage`). That fix was verified
correct by a test that swipes Home → a distant tab → back to Home ONCE.

The user now reports the flash still happens, specifically on this exact
sequence: **Home → Events → Safety → Events → Home** (tapping the bottom nav
each step, landing on every tab in between — not jumping directly). They
separately confirmed Safety and Profile round-trips alone don't show it.

Don't read that as "Safety/Profile are fine, Events/Home are broken" — Safety
has no network fetch at all (`safety_page.dart`'s own doc comment: "it never
showed the grey skeleton") and Profile only has a tiny inline "Loading…" text
label, no full-body skeleton. Home and Events are the only two tabs with a
real `AsyncValue`-driven full-body skeleton to visibly flash. So this new
report doesn't necessarily mean a NEW bug distinct from the one already
"fixed" — it may mean the existing fix's test coverage (one swipe away, one
swipe back) never actually exercised the sequence the user is doing (Events
visited twice, four consecutive tab transitions).

## Step 1 — reproduce with a test that matches the actual report

Write a widget test that mounts the real `AppShell` and drives exactly this
sequence via the bottom nav taps (not `PageController.jumpToPage` —
tap `AppBottomBar`'s items the way a user would, so the PageView actually
builds every intermediate page):

1. Start on Home, let `activeMeetupsProvider`/`openMeetupsProvider` resolve.
2. Tap to Events, let `myMeetupsProvider` resolve.
3. Tap to Safety.
4. Tap back to Events.
5. Tap back to Home.

At steps 2, 4, and 5, assert:
- No skeleton widget is present (`_MyMeetupsSkeleton` on Events,
  `MeetupsSkeleton`/`SkeletonBox` on Home) immediately after landing — not
  after a `pumpAndSettle`, since the bug is about a *transient* frame, so
  pump only one or two frames after the tap before asserting.
- The mock service's fetch methods (`listMyMeetups` for Events,
  `listActiveMeetups`/`listOpenMeetups` for Home) were each called exactly
  once in total across the whole sequence — a second call at any point means
  something is re-fetching, which is the actual bug regardless of whether a
  skeleton frame is visible in the test.

## Step 2 — branch on what the test shows

**If the test fails (something re-fetches or a skeleton reappears):** find
the actual mechanism and fix it. Concretely check:

- Whether `EventsPage`'s nested `DefaultTabController` (`events_page.dart`)
  or `_MeetupList`'s own `TabController` (`SingleTickerProviderStateMixin`)
  is being recreated on the second visit to Events — a fresh `TabController`
  wouldn't itself cause a provider refetch, but rule it out.
  Do not just check `wantKeepAlive`/`super.build()` presence again — that was
  already confirmed correct in the prior round. Look for what's different
  about a *second* visit to the same tab versus a *first* visit.
- Whether anything invalidates `myMeetupsProvider`, `activeMeetupsProvider`,
  or `openMeetupsProvider` as a side effect of navigation itself, not just
  the already-known explicit invalidation sites (`home_page.dart`'s
  `onHostMeetup`/pull-to-refresh, `events_page.dart`'s post-push-route
  invalidation in `_MeetupList`'s `onTap` handlers). Grep for every
  `ref.invalidate`/`ref.refresh` call site touching these three providers
  and confirm none of them can fire from a plain tab switch.
- Whether `AppShell`'s `PageView` itself is rebuilding pages with new Widget
  identities on repeated navigation (e.g. because `pages` isn't actually
  `const` end-to-end, or a `ref.watch` inside `_AppShellState.build()`
  causes something upstream of `pages` to change), which would defeat
  `AutomaticKeepAliveClientMixin` regardless of it being correctly written,
  since keep-alive only helps if the same Element persists.

**If the test passes (no refetch, no skeleton, across the whole sequence):**
do not force a fix onto code that isn't reproducing the bug. Instead:

- State plainly that the state/data layer is not the cause — the previous
  fix holds even under this longer sequence.
- Note this points at a rendering/compositing artifact rather than a data
  bug (e.g., GPU shader compilation jank or image decode cost on the first
  real frame after a `PageView.animateToPage` completes, both classic causes
  of a debug-mode-only "flash" that widget tests can't see since they don't
  render real frames). Do not attempt a code fix for this — report it as the
  likely explanation and stop.

## Bar for "done"

Cite file:line for whatever you find. If you fixed something, prove it with
the exact-sequence test from Step 1, not by reasoning about the code. If the
test passed without any fix, say so explicitly — don't manufacture a change
just to have shipped something. Confirm `flutter analyze`/`dart format
--set-exit-if-changed`/`flutter test` all pass either way.
