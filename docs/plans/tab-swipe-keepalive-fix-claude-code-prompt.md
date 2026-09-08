# Claude Code prompt — fix the grey flash when swiping between tabs

You're working in `/Users/as/Documents/Professional Meetups/Professional-Meetups-Monolith`.
Direct user report: swiping between bottom-nav tabs isn't smooth and briefly
shows a grey/skeleton state before the real page content loads. Root cause
already diagnosed by reading the code — this is a known Flutter pattern
(`PageView`/`TabBarView` children losing state), not something to
re-investigate from scratch.

## Read first

`docs/plans/08-tab-swipe-keepalive-fix.md` in full.

## Root cause (confirmed, don't re-derive)

`app_shell.dart`'s `PageView` has no `cacheExtent` override, and none of its
four children (`HomePage`, `EventsPage`, `SafetyPage`, `ProfilePage`) use
`AutomaticKeepAliveClientMixin`. Flutter's default cache window is smaller
than one screen width, so a full swipe disposes the tab you left. Its main
content providers (`openMeetupsProvider`, `activeMeetupsProvider`,
`myMeetupsProvider`) are all `.autoDispose`, so the disposed page's
`ref.watch()` being the only subscriber means the cached data is thrown away
at the same moment — swiping back remounts from `AsyncLoading`, showing a
flat grey `SkeletonBox` skeleton before the refetch resolves.

## The fix

Add `AutomaticKeepAliveClientMixin` to each tab page:

- `HomePage`'s `_HomePageState` is already a `ConsumerState` — add the mixin,
  `wantKeepAlive => true`, call `super.build(context)` at the top of
  `build()`.
- `EventsPage`, `SafetyPage`, `ProfilePage` are currently `ConsumerWidget`
  (stateless) — convert each to `ConsumerStatefulWidget`/`ConsumerState`
  first (only a State can use the mixin). Move each page's existing
  `build(context, ref)` body into the new State's `build(context)`, matching
  whatever this codebase's existing `ConsumerStatefulWidget` idiom already
  looks like (check `HomePage` itself for the pattern, don't invent a new
  one).

Do **not** remove `.autoDispose` from the three providers as an alternative
or additional fix — keep-alive addresses the actual root cause without
touching provider semantics that correctly serve a different purpose
(freeing a previous intent-filtered `openMeetupsProvider.family` instance
when the filter changes). If a flash is somehow still observed after this
fix, report it back rather than reflexively pulling `.autoDispose`.

## Tests

The test that actually proves this (not just that it compiles): mount
`AppShell` (or a minimal equivalent harness), load data on Home, swipe to a
distant tab and back, and assert the previously-loaded content is still
present immediately with no re-fetch and no loading skeleton. Do the same
for `EventsPage`. Confirm `EventsPage`/`SafetyPage`/`ProfilePage`'s
`ConsumerWidget`→`ConsumerStatefulWidget` conversion didn't change existing
behavior — their current test suites should still pass, unmodified or with
a stated reason for any change.

## Bar for "done"

File:line, and prove the fix with the swipe-away-and-back test, not by
reading the code. Confirm `flutter analyze`/`dart format
--set-exit-if-changed`/`flutter test` all pass. Don't touch anything outside
the four page files and their tests.
