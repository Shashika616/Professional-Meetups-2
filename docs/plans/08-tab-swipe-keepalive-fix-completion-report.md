# Completion report — tab-swipe keep-alive fix (the "grey flash")

Scope: `docs/plans/tab-swipe-keepalive-fix-claude-code-prompt.md`, working
from `docs/plans/08-tab-swipe-keepalive-fix.md`.

Only the four page files and one test file were touched. `app_shell.dart`
itself is unchanged, and `.autoDispose` was not removed from any provider.

---

## Root cause, confirmed before touching anything

Grepping `lib/` for `AutomaticKeepAliveClientMixin`, `wantKeepAlive` and
`cacheExtent` returned **zero hits**, while `app_shell.dart:23-29`'s class
comment asserted the pages are "built once into `pages` below and kept alive
by `PageView`, not rebuilt per tab switch". Nothing enforced that. A full
swipe put the tab you left outside `PageView`'s default cache window, which
disposes the whole Element/State subtree rather than scrolling it off; the
disposed page was the only subscriber to its `.autoDispose` providers, so the
cached data went with it and the return trip remounted from `AsyncLoading`
into a flat grey `SkeletonBox`.

## The fix

`AutomaticKeepAliveClientMixin` on each tab's State, with `super.build(context)`
first in `build` — omitting that call makes the mixin a silent no-op, so it is
commented at each site rather than left as folklore.

| Page | State | `wantKeepAlive` | `super.build` | Conversion needed |
|---|---|---|---|---|
| `home_page.dart` | :66 | :69 | :95 | none — already `ConsumerState` |
| `events_page.dart` | :100 | :103 | :109 | `ConsumerWidget` → `ConsumerStatefulWidget` |
| `safety_page.dart` | :41 | :44 | :49 | same |
| `profile_page.dart` | :38 | :41 | :46 | same |

The three conversions follow `HomePage`'s existing shape exactly — a
`ConsumerStatefulWidget` with `createState()`, a `ConsumerState` reading `ref`
as an inherited member — rather than introducing a second idiom. The only
behavioural edit inside any of them was `initialTab` → `widget.initialTab` in
`events_page.dart`, which the conversion requires.

`SafetyPage` and `ProfilePage` are documented at their States for why they are
kept alive even though Safety never showed the skeleton (it has no fetch of
its own): they still lose scroll position and, for Profile, flicker the
Premium row's subtitle while `subscriptionStatusProvider` re-resolves. One tab
behaving differently from its three siblings is worse than the cost of holding
a cheap page alive.

### The deliberate non-fix

`.autoDispose` stays on `openMeetupsProvider`, `activeMeetupsProvider` and
`myMeetupsProvider`, and `_HomePageState`'s doc comment records why: it is
doing a second, correct job — freeing the previous intent-filtered
`openMeetupsProvider.family` instance when Home's filter changes — that has
nothing to do with this bug. Removing it would mask page disposal while
leaking a provider instance per filter change.

---

## Proof, in both directions

Three tests in `frontend/test/app_shell_test.dart`, all asserting the
**outcome** rather than that `wantKeepAlive` returns true (which would prove
the code compiles and nothing else):

1. **Home survives the round trip** — mount `AppShell`, let Home load, assert
   `listActiveMeetupsCallCount == 1`, swipe to the furthest tab (Profile) and
   back, then assert the count is *still* 1 and no `MeetupsSkeleton` is
   rendered. The refetch and the skeleton are exactly what the user saw.
2. **Events survives it too** — asserted separately rather than assumed to
   follow Home, because it took the largest structural change. Visits Events,
   records `listMyMeetupsCallCount`, goes to Profile and back, asserts the
   count did not move.
3. **The tab you left is still mounted** — `find.byType(HomePage,
   skipOffstage: false)` after swiping to Profile. The direct statement of
   what keep-alive buys, and what makes the other two possible.

Tab changes are driven through `currentTabIndexProvider` — the same provider
the bottom bar and a real swipe both drive — then pumped past the 280ms
`animateToPage`. Deterministic where a fling is not, and it exercises the same
`PageView` scroll.

**Control run.** With `wantKeepAlive` flipped to `false` on all four pages,
**all three fail**:

```
test/app_shell_test.dart: … Home keeps its loaded data across a swipe to the far tab and back …
test/app_shell_test.dart: … Events keeps its loaded data across the same round trip …
test/app_shell_test.dart: … the tab you left is still MOUNTED after swiping away …
```

Restored to `true`: `+8: All tests passed!` for that file. The bug is real,
the tests detect it, and the fix is what closes them.

### One test-harness change the fix forced

`containerWith` now overrides `subscriptionStatusProvider` with a resolved
value. This is a direct consequence of the fix rather than incidental setup:
these tests visit Profile, which reads that provider, and it used to be
disposed the instant the swipe back completed — taking its in-flight read with
it. Now the page is deliberately kept alive, so an unresolved real read stays
pending and the framework fails the test for a leaked `Timer`. Resolving it
synchronously keeps these tests about keep-alive rather than about
subscription plumbing.

## Existing behaviour unchanged

The three converted pages' own suites pass **unmodified** — verified by mtime
that no test file except `app_shell_test.dart` was touched this round:

```
events_page_test    +28: All tests passed!
profile_page_test   +22: All tests passed!
safety_page_test     +4: All tests passed!
home_page_test      +11: All tests passed!
```

Nothing needed changing in any of them, which is the useful result: the
`ConsumerWidget` → `ConsumerStatefulWidget` conversion is invisible from
outside each page.

## Gates

```
flutter analyze                        No issues found!
dart format --set-exit-if-changed      139 files (0 changed), exit 0
flutter test                           +358: All tests passed!
```

Backend untouched.

## For the device check

The causal chain says this closes it. If any residual flash is still visible
on a real device after this, the plan is explicit that it points at something
else and should be reported back — not answered by pulling `.autoDispose` off
the providers as a second attempt.
