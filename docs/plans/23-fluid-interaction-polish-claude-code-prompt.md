You are working in the Professional-Meetups-Monolith repo. Follow
`docs/plans/23-fluid-interaction-polish.md` in full before writing any code —
it explains why this is scoped narrowly (ADR-032's flat-design migration is
already done; this is about interaction *feel* on top of it, not another
visual redesign) and exactly which files were already read and confirmed
correct, so you don't need to re-litigate them.

## Part A — Shared `Pressable` wrapper

1. Create `frontend/lib/core/widgets/pressable.dart`: a `StatefulWidget`
   named `Pressable` with `required Widget child` and `required VoidCallback?
   onTap` (nullable, same convention as `PrimaryButton.onPressed` — null means
   disabled, no gesture recognizer fires).

2. Copy the exact press-feedback pattern already in
   `core/widgets/primary_button.dart`'s `_PrimaryButtonState`
   (`_onTapDown`/`_onTapUp`/`_onTapCancel` setting `_isPressed`, wrapped in
   `GestureDetector` + `AnimatedScale`), but scale to **1.0 → 0.98** (not
   1.02 — a card being pressed IN reads differently from a button growing;
   check this matches how `Pressable` will be used, i.e. wrapping a whole
   card, not a button) over the same 120ms/`Curves.easeOut`.

3. Before applying the scale, check `MediaQuery.maybeDisableAnimationsOf(context) ?? false`
   — if true, skip `AnimatedScale` entirely and just render `child` at scale
   1.0 always (mirror `Shimmer`'s existing early-return pattern in
   `core/widgets/skeleton_loader.dart`, don't invent a different shape).

4. `onTap` fires on tap-up inside the widget's bounds, same as
   `GestureDetector`'s default `onTap` semantics — don't change tap-commit
   behavior, only add press-down visual feedback.

5. Widget test: pressing down scales the child, releasing/cancelling returns
   it to 1.0, and with `MediaQuery.disableAnimations = true` the scale never
   changes at all (test via `tester.binding.platformDispatcher` or however
   the existing `Shimmer` test — if one exists, check for
   `skeleton_loader_test.dart` — asserts the same thing, follow that
   pattern).

## Part B — Apply `Pressable` to real card taps

1. Grep `frontend/lib/features/` for `GestureDetector(` where the enclosing
   widget represents a whole card, list row, or tile the user taps to
   navigate (NOT a drag handle, map control, or anything with its own
   gesture logic beyond a plain tap). Start with the confirmed case:
   `features/home/widgets/meetup_card.dart`'s `MeetupCard.build` — its outer
   `GestureDetector(onTap: locked ? ... : onTap, child: ClipRRect(...))`
   around the whole `FlatCard`. Replace that `GestureDetector` with
   `Pressable(onTap: locked ? () => _handleLockedTap(context) : onTap, child: ClipRRect(...))`.

2. List every other bare `GestureDetector(onTap: ...)` you find wrapping a
   card/row/tile elsewhere (check `features/home/`, `features/meetups/`,
   `features/profile/`, `features/notifications/` in particular) and apply
   the same swap — but only where it's a genuine "tap this whole card to
   navigate" pattern matching `MeetupCard`'s case. If you find one that's
   ambiguous (e.g. a `GestureDetector` doing something more than a plain
   tap), leave it and note it in your completion report rather than
   guessing.

3. Do not touch any `GestureDetector` inside `features/meetups/widgets/`
   related to the map/location pickers (`map_location_step.dart`,
   `ios_map_location_step.dart`, `android_map_location_step.dart`) as part of
   this step — see Part D below, that's a read-and-report task, not a change.

## Part C — Fix `home_page.dart`'s CTA to use the shared button

1. In `frontend/lib/features/home/home_page.dart`, find the
   `FilledButton.icon` with `key: const Key('hostYourOwnMeetup')` (around
   line 291). Replace it with `PrimaryButton`:
   ```dart
   PrimaryButton(
     key: const Key('hostYourOwnMeetup'),
     label: 'HOST YOUR OWN MEETUP',
     icon: Icons.add_circle_outline,
     height: 50,
     fillColor: AppPalette.verified,
     foregroundColor: Colors.black,
     onPressed: onHostMeetup,
   )
   ```
   Check `PrimaryButton`'s actual label `TextStyle` (fontWeight w800,
   letterSpacing 1.1, fontSize 13.5 — see `core/widgets/primary_button.dart`)
   against what `home_page.dart` currently renders (fontSize 12, letterSpacing
   1.0) and decide whether to accept `PrimaryButton`'s built-in label style
   as-is (recommended — consistency is the point) or whether that's a
   noticeable enough size/tracking change to flag back rather than silently
   ship. Err toward accepting `PrimaryButton`'s own style; note the exact
   before/after in your completion report either way.
2. Remove the now-unused `Padding`/`SizedBox(width: double.infinity)`
   wrapper only if `PrimaryButton` already renders full-width on its own
   (check its `build` method — it does, via the `Container` inside `Ink`
   with `width: double.infinity`); if so simplify the surrounding code, don't
   leave a redundant double wrapper.
3. If a `home_page_test.dart` or similar widget test exists and asserts on
   the old `FilledButton` type/style, update it to assert on `PrimaryButton`
   instead — don't leave a test silently checking for a deleted widget type.

## Part D — Read and report on the two map-location `BackdropFilter` sites

Read `frontend/lib/features/meetups/widgets/ios_map_location_step.dart` and
`.../android_map_location_step.dart` in full. In your completion report,
state plainly: what the `BackdropFilter` in each is for (a bottom sheet over
the map? a native SDK overlay requirement? something else?), and whether it
reads as a persistent card-style glass effect (the kind ADR-032 targeted) or
a transient/functional overlay (like `signing_in_overlay.dart`, which this
plan explicitly leaves alone). **Do not change either file.** This is
information-gathering only, so a real decision can be made next with actual
facts instead of a guess.

## Part E — Fix the stale `CLAUDE.md` Design System section

In the repo-root `CLAUDE.md`, under `### Design system` (inside the
`## Architecture` section), replace the current text — which describes
`Glass`/`GradientButton`/`AppBackground` as a photo-backed glassmorphism
system — with an accurate description:

- `AppPalette` still holds every color token, unchanged (keep this line).
- `FlatCard` (`core/widgets/flat_card.dart`) is the shared solid-fill card
  surface with a hairline border — no blur, no translucency (ADR-032).
- `PrimaryButton`/`SecondaryButton` are the shared button styles — solid
  fill / hairline-outlined respectively, both with tap-scale press feedback
  and label-shrink-not-truncate behavior.
- `AppBottomBar` is the shared bottom nav bar — flush, solid, single top
  hairline border.
- `AppBackground` paints a single flat `AppPalette.onyx` fill — note
  explicitly that it is **not** a background photo (an earlier version was;
  it was removed in a later rebrand pass — check `core/widgets/app_background.dart`'s
  own doc comment, "THIS USED TO BE A PHOTOGRAPH", for the full reasoning
  and cite it briefly).
- Note `GlassTextField` (`core/widgets/glass_text_field.dart`) still carries
  its old glass-era name despite internally rendering via `FlatCard` now —
  flag this as a known stale name, out of scope to rename in this pass since
  it would touch every call site, not something to fix here.

Keep the rest of the Design System section's structure (the "Shared chrome
lives in `frontend/lib/core/widgets/`" framing) — this is a content fix, not
a rewrite of the section's shape.

## Explicitly do not touch

- `AppPalette`, any color/token value.
- `ADR-032` itself, or any decision it made — this plan builds on it, not
  around it.
- `signing_in_overlay.dart` — leave its `BackdropFilter` exactly as-is (see
  the plan doc's Finding 4 for why).
- Any map/location picker file beyond the read-and-report in Part D.
- `PrimaryButton`'s own animation implementation — `Pressable` is a new,
  separate widget; do not refactor `PrimaryButton` to use it or vice versa.

## Before you report done

Run `flutter analyze` and `flutter test` from `frontend/` and paste the real
pass/fail output. In your completion report, explicitly list: every file
where you applied `Pressable` (Part B) and why each qualified, the exact
before/after label style for the Home CTA (Part C), and the Part D findings
on the two map-location files in full — that last one is the part of this
task that feeds a future decision, so don't compress it to one line.
