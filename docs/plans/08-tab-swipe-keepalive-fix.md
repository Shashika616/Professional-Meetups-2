# Plan — stop tab pages losing state on swipe (the "grey flash")

Found from a direct user report ("sliding between pages... gets all grey and
then loads"), confirmed by reading the actual code, not reproduced on device.
Single, well-scoped fix — this is a known Flutter pattern, not a design
decision.

## Root cause

`app_shell.dart`'s `PageView(children: pages)` has no `cacheExtent`
override, and grepping the whole `lib/` tree for
`AutomaticKeepAliveClientMixin`/`wantKeepAlive` returns zero hits — none of
`HomePage`, `EventsPage`, `SafetyPage`, `ProfilePage` requests to stay alive.
Flutter's default page-view cache window is smaller than one screen width,
so a single full swipe puts the tab you left outside it, and its entire
Element/State subtree is disposed — not just scrolled off-screen. The class
comment above `_AppShellState` (lines 23-29) asserts pages are "kept alive by
`PageView`, not rebuilt per tab switch" — that was never actually enforced by
anything in the code.

Compounding it: `openMeetupsProvider` (Home's "Happening Soon"),
`activeMeetupsProvider` (Home's "Active Meetups"), and `myMeetupsProvider`
(Events) are all `.autoDispose`. The disposed page's `ref.watch()` was each
provider's only subscriber, so the cached data is thrown away at the same
moment. Swiping back remounts a fresh page, which watches a provider with no
cached value, renders the `AsyncLoading` branch — a flat, static
`SkeletonBox`-on-`AppPalette.card` block, no shimmer — then pops to real data
once the refetch resolves. That sequence is the reported grey flash.

## Fix

Add `AutomaticKeepAliveClientMixin` to each tab page's underlying State —
the standard Flutter fix for exactly this class of bug (a `PageView`/
`TabBarView` child losing state on scroll), not a workaround:

- `HomePage`'s `_HomePageState` already is a `ConsumerState` — add the mixin,
  `wantKeepAlive => true`, and call `super.build(context)` at the top of
  `build()`.
- `EventsPage`, `SafetyPage`, `ProfilePage` are currently plain
  `ConsumerWidget`s (stateless) — they need converting to
  `ConsumerStatefulWidget`/`ConsumerState` first, since only a `State` object
  can mix in `AutomaticKeepAliveClientMixin`. This is a structural change to
  each file, not just adding a line — do it carefully, moving each page's
  existing `build(context, ref)` body into the new State's `build(context)`
  (reading `ref` via `this.ref` / the State's own `WidgetRef`, whichever this
  codebase's Riverpod version idiom already uses elsewhere for a
  `ConsumerStatefulWidget` — check an existing one, like `HomePage` itself,
  and match its shape rather than inventing a new pattern).

Do **not** remove `.autoDispose` from the three providers as an alternative
fix. Keep-alive addresses the actual root cause (page disposal) without
changing provider semantics that are correct for their other job — freeing a
previous intent-filtered `openMeetupsProvider.family` instance when the
filter changes, which should still happen and has nothing to do with this
bug. If, after this fix, any residual flash is still observed on a real
device (it shouldn't be, per the causal chain above, but confirm), that
would point at something else entirely and should be reported back rather
than reflexively pulling `.autoDispose` off these providers as a second fix
attempt.

## Tests

- A widget test that mounts `AppShell` (or a minimal harness reproducing its
  `PageView` + 4 tabs + keep-alive), loads data on Home, swipes to a distant
  tab (Profile) and back to Home, and asserts the previously-loaded content
  is still present **immediately** (no loading skeleton re-appears, and the
  mock service's fetch method was not called a second time). This is the
  test that actually proves the fix — a test that only checks
  `wantKeepAlive == true` on the mixin would prove the code compiles, not
  that swiping preserves state.
- Repeat for `EventsPage` specifically, since it needed the bigger structural
  change (ConsumerWidget → ConsumerStatefulWidget) — confirm its existing
  tests still pass unchanged after that conversion, and add the same
  swipe-away-and-back assertion.

## When done

Cite file:line. Confirm by the test above (not by reading the code) that a
swipe away and back does not re-trigger a fetch or show a loading skeleton.
Confirm `EventsPage`/`SafetyPage`/`ProfilePage`'s conversion to
`ConsumerStatefulWidget` didn't change any existing behavior — run their
existing test suites and confirm they still pass unmodified, or note exactly
what had to change and why. `flutter analyze`/`dart format
--set-exit-if-changed`/`flutter test` all clean.
