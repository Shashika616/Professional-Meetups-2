# Completion report — repeated Events↔Home swipe flash

Scope: `docs/plans/09-events-home-repeat-swipe-flash-claude-code-prompt.md`.

**Headline: the data layer is NOT the cause.** The round-08 keep-alive fix
holds under the longer sequence — proven, not reasoned. But the investigation
turned up one concrete, code-level cause of a grey panel that is real,
asymmetric to exactly the tab the user named, and now fixed.

---

## Step 1 — reproduced the exact reported sequence

`frontend/test/app_shell_test.dart`, group *"repeated Home <-> Events <->
Safety navigation"*. Mounts the real `AppShell` and taps the bottom bar the
way a user does — `HOME` → `EVENTS` → `SAFETY` → `EVENTS` → `HOME`, landing on
every tab, never `jumpToPage` — asserting after **one frame**, not
`pumpAndSettle`, since the bug is a transient frame.

Instrumented output at each step (fetch counts and skeleton counts, per page):

```
first-events@350ms    home=0  events=15  my=1  active=1  open=1
first-events@+1frame  home=0  events=0   my=1  active=1  open=1
after-safety          home=0  events=0   my=1  active=1  open=1
second-events@1frame  home=0  events=0   my=1  active=1  open=1
home@1frame           home=0  events=0   my=1  active=1  open=1
```

Reading it:

- **No refetch anywhere.** `listMyMeetups`, `listActiveMeetups` and
  `listOpenMeetups` each stay at **1** across the entire five-step sequence,
  and across three further laps of it (second test in the group).
- **No skeleton on any repeat visit**, even at single-frame granularity —
  where a transient flash is the only place it could hide.
- The one skeleton is Events' **genuine first load**, gone on the next frame.
  That is a real fetch resolving, not the reported bug; the test asserts it
  is present and then that it clears, rather than papering over it.

Both tests are now permanent regression coverage.

### The three checks the plan asked for, before concluding

1. **Every `invalidate`/`refresh` of the three providers** — 11 sites, all
   user- or event-driven, none reachable from a plain tab switch:
   `app_shell.dart:85` (`AppLifecycleState.resumed`), `:98-99`
   (`meetup_closed` push), `home_page.dart:170-172` (after the schedule flow
   returns), `:186,191` (pull-to-refresh), `events_page.dart:160` (RETRY),
   `:183,199` (after a pushed detail route pops), `:335` (pull-to-refresh),
   `happening_soon_section.dart:198,254,271` (retry / detail pop /
   requestToJoin). The fetch counts above confirm it empirically.
2. **`AppShell` page identity** — `build` watches only
   `currentTabIndexProvider`, and `pages` is a `const` list held as a State
   field, so a rebuild reuses the identical Widget instances and the Elements
   persist. Round 08's "the tab you left is still MOUNTED" test already pins
   this.
3. **`EventsPage`'s `TabController`s** — ruled out as a refetch source by the
   counts; a fresh controller cannot cause one.

**Conclusion for Step 2's branch: the test passes.** No fix was forced onto
the state layer, and `.autoDispose` was not touched.

---

## What the investigation did find

Chasing "what is actually grey", not "what refetches":

`frontend/lib/core/widgets/app_background.dart` paints a solid
`AppPalette.onyx` `Container` **first**, then an `Image.asset` over it at 28%
opacity. `Image` renders *nothing* until its stream resolves — so an
unresolved background is, literally, a flat grey panel.

And there is one asymmetry across the four tabs:

| Tab | Paints its own `AppBackground`? |
|---|---|
| `home_page.dart` | no |
| **`events_page.dart`** | **yes — 2 sites** |
| `safety_page.dart` | no |
| `profile_page.dart` | no |

`EventsPage` wrapped itself while already inside `AppShell`'s
(`app_shell.dart:160`). Its own comment called this *"Harmless when nested —
it paints the same background twice."* That claim was wrong on both counts
that matter:

- each instance is a full-screen `Image.asset` under an `Opacity` **and** a
  `ColorFiltered`, both of which force an off-screen full-screen `saveLayer`
  — so the Events tab composited **two** of them on every frame of a page
  transition;
- two instances are **two independent image streams** for the same asset, so
  two chances to show the bare grey fill.

Events is the only tab that did this, and the user's reported sequence goes
through Events twice.

### The fix

`AppBackground` now detects that an ancestor has already painted and returns
its child untouched (`app_background.dart:53-55`), via a data-free
`_AppBackgroundScope` `InheritedWidget` (`:116`). The painted layer carries a
`layerKey` (`:45,62`) so a test can count instances that actually rendered —
a widget count cannot distinguish a painting instance from a pass-through.

`getInheritedWidgetOfExactType`, not `dependOnInheritedWidgetOfExactType`:
this never changes for a given position, so registering a dependency would
add rebuild bookkeeping for a notification that can never fire.

**The pushed-route path still works.** `meetup_detail_page.dart` pushes
`EventsPage` as a route, and a pushed route is built under the `Navigator`,
which sits *above* `AppShell` — so it genuinely has no background ancestor and
still paints its own. `events_page.dart:127` is unchanged except its comment,
which now states what is true.

### Proof

`frontend/test/app_background_test.dart` (4 tests): one instance paints one
layer; nested paints one; three-deep paints one; **a pushed route paints its
own** (2 total), which is the case a naive fix would have broken.

Plus an `AppShell`-level test: the Events tab paints exactly one layer, and
stays at one across the whole reported sequence.

**Control run** — with the pass-through disabled, **3 tests fail**:

```
test/app_background_test.dart: a NESTED AppBackground paints nothing extra …
test/app_background_test.dart: nesting three deep still paints exactly one
test/app_shell_test.dart:      the Events tab paints ONE background layer, not two …
```

Restored: `+15: All tests passed!` for those two files.

---

## Honest limits

What is **proven**: no refetch and no skeleton on any repeat visit; the Events
tab no longer double-paints a full-screen image with two `saveLayer`s.

What is **not proven**: that this removes the flash the user sees. Widget
tests do not render real frames, so they cannot observe compositing cost or
image-decode timing. This removes a real, measurable redundancy sitting
directly on the reported path, and it is the only structural difference
between the tab that flashes and the three that do not — but it needs a device
check to confirm.

If it still flashes after this, the remaining candidates are the ones the plan
named and that no code change addresses: shader compilation jank on the first
real frame after `animateToPage` completes (debug-mode only, fixed by
`--profile`/`--release` or SkSL warm-up), or first-frame image decode. Those
should be confirmed on device rather than guessed at in code.

## Gates

```
flutter analyze                        No issues found!
dart format --set-exit-if-changed      140 files (0 changed), exit 0
flutter test                           +365: All tests passed!
```

Backend untouched.
