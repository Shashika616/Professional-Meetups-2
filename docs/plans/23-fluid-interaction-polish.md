# Plan 23 — Fluid interaction polish (apple-design principles on top of ADR-032's flat system)

## Context

Shashika asked to "polish my UI/UX using impeccable and apple-design skills to make the app look clean and professional." Before proposing anything, I re-checked the app's actual current state against ADR-032 (Accepted, 2026-09-03) rather than assuming — the flat-design migration is real and already landed:

- `Glass` → `FlatCard`, `GradientButton` → `PrimaryButton`, `GlassBottomBar` → `AppBottomBar` all exist today with no `BackdropFilter`/blur, solid fills, hairline borders — exactly as ADR-032 specified.
- `AppBackground` has moved even further than ADR-032 asked: the `suit.png` photo the ADR describes fading under a gradient has since been removed entirely (a later, undocumented TieHere-rebrand change — see "Doc drift" below), replaced by a single flat `AppPalette.onyx` fill.
- Typography, spacing, and per-widget letter-spacing/leading are already hand-tuned deliberately (e.g. `PrimaryButton`'s 13.5px/1.1 tracking comment explicitly reasons about competing with a 20px logo mark) — this is already doing what apple-design §15 asks for. Reduced-motion is already handled correctly: `Shimmer` checks `MediaQuery.maybeDisableAnimationsOf(context)` before animating.

So this is **not** a "rip out glassmorphism" plan — that work is done. What's left is narrower: apply apple-design's *interaction feel* principles (response, direct manipulation, spatial consistency) to close a few concrete, real gaps I found by reading the actual widget code, plus fix one doc-drift issue and one design-system consistency slip. Nothing here reintroduces translucency, blur, or gradients — ADR-032 stands.

**On "review the code" (the other half of the request):** nothing in the application code has changed since the fresh backend/frontend security+design review completed earlier in this engagement (Phase 12) — only plan docs and `.env`/config values have changed since. There's nothing new to re-review right now; this plan's own findings below are the current, up-to-date review of the UI layer specifically.

## Findings (all verified by reading the actual widget source, not assumed)

### 1. Tap targets give no press feedback — apple-design §1 violation

`MeetupCard` (`features/home/widgets/meetup_card.dart`), the card type shown on Home's "Happening Soon" list and Events, wraps its entire tappable card in a bare `GestureDetector(onTap: ...)` with **no visual response at all** on press — no opacity dip, no scale, nothing — until whatever `onTap` does (usually a page push) completes. Apple's own rule, and the first one in the apple-design skill: *"respond on pointer-down, not release... the moment lag appears, directness falls off a cliff."* Right now the only widget in this app that already gets this right is `PrimaryButton` (its `AnimatedScale` 1.0→1.02 on `onTapDown`).

This is worth fixing because it's the single highest-visibility "feels unfinished" gap in an otherwise well-crafted flat design — a card is the thing users tap most on Home/Events, and it currently feels inert.

### 2. `home_page.dart`'s CTA breaks the shared-button contract

The "HOST YOUR OWN MEETUP" button (`home_page.dart` line ~291) is a raw `FilledButton.icon` with a hand-rolled `FilledButton.styleFrom(...)`, not the shared `PrimaryButton`. Every other primary action in the app (sign-in, join, save, etc.) goes through `PrimaryButton`, which is where the tap-scale feedback, the loading spinner, and the label-shrink-instead-of-truncate behavior all live (see `PrimaryButton`'s own doc comment on why that shrink exists — a truncated label was "first reported on iOS"). This one button silently opts out of all three. `PrimaryButton` already supports a `fillColor`/`foregroundColor` override (exactly the pattern `SocialSignInSection` uses for its neutral-surface provider buttons), so this is a drop-in swap, not a redesign.

### 3. Doc drift: `CLAUDE.md`'s Design System section is stale

The repo's own `CLAUDE.md` (checked in, read by every future Claude Code session) still says: *"Dark, glassmorphism-style UI... `Glass` — the base frosted-glass container (`BackdropFilter` blur + tinted border)... `GradientButton`, `AppBackground`... "* None of that is true anymore — `Glass`/`GradientButton`/`GlassBottomBar` don't exist; `FlatCard`/`PrimaryButton`/`AppBottomBar` do; `AppBackground` paints a flat color, not a photo. This isn't cosmetic — it's the file Claude Code reads first on every future task in this repo, and it currently points at deleted widgets by name. Cheap, safe fix, in scope for this plan since it's a design-system doc.

### 4. Three residual `BackdropFilter` call sites — judgment calls, not required fixes

`signing_in_overlay.dart`, `ios_map_location_step.dart`, and `android_map_location_step.dart` still use `BackdropFilter`. I read `signing_in_overlay.dart` in full: it's a transient, full-screen, blocking loading veil shown only while a sign-in provider call is in flight (a few hundred milliseconds to a few seconds), not a persistent card or chrome element. Apple's own materials guidance (which ADR-032 otherwise excludes) explicitly calls out exactly this case — *"dim to focus: a modal task pairs the surface with a dimming scrim"* — as different in kind from the "AI-generated" persistent glass ADR-032 was reacting to. I'm recommending **leaving it as-is**; flattening it to a solid scrim would be a pure downgrade (worse "something is happening" affordance) for a problem ADR-032 was never actually complaining about. I have not read the two map-location-step files this pass — Claude Code should read them first and report what they're doing before touching anything there; if they're a native-map-SDK bottom-sheet material, the same reasoning likely applies and they should also be left alone.

### 5. Confirmed already correct — do not touch

- Reduced-motion handling (`Shimmer`, `ambient_animation.dart`'s `debugDisableAmbientAnimations`) — already respects `MediaQuery.maybeDisableAnimationsOf`. Any new motion this plan adds (the press-feedback in Finding 1) must follow the same pattern, not add a second one.
- Per-widget typography discipline (size-specific letter-spacing/leading) — already deliberate throughout `PrimaryButton`, `SecondaryButton`, `_DetailRow`, etc.
- Card/surface elevation logic in `FlatCard` (light-mode shadow vs. dark-mode lighter-surface) — already exactly matches apple-design's "materials convey hierarchy" intent without using any actual translucency.

## Decision

1. **New shared `Pressable` wrapper** in `core/widgets/` — a small `StatefulWidget` taking a `child` and `onTap`, applying the same `AnimatedScale` (1.0 → 0.98, 120ms, `Curves.easeOut`) press feedback `PrimaryButton` already uses, keyed off `onTapDown`/`onTapUp`/`onTapCancel` (not `onTap` alone) so feedback starts on press, not release. Must check `MediaQuery.maybeDisableAnimationsOf(context)` and skip the scale (snap instantly) when true, matching `Shimmer`'s existing pattern.
2. **Apply `Pressable`** to `MeetupCard`'s outer `GestureDetector` (Finding 1), and audit the rest of `frontend/lib/features/` for other bare `GestureDetector(onTap: ...)` wrapping a whole card/row-style tap target (not a button, not a text link) — grep for the pattern first, list what's found, and apply the same wrapper only to genuine card/list-row taps, not to every incidental `GestureDetector` in the codebase (e.g. drag handles, map controls) which may have their own reasons for the current behavior.
3. **Replace `home_page.dart`'s raw `FilledButton.icon`** with `PrimaryButton(label: 'HOST YOUR OWN MEETUP', icon: Icons.add_circle_outline, fillColor: AppPalette.verified, foregroundColor: Colors.black, onPressed: onHostMeetup)` (Finding 2). Verify visually (or via existing widget test, if `home_page_test.dart` exists) that the color/height match today's rendering — this must be a silent swap, not a visible redesign.
4. **Update `CLAUDE.md`'s "Design system" section** (Finding 3) to name `FlatCard`/`PrimaryButton`/`SecondaryButton`/`AppBottomBar`/`GlassTextField` (note: this class name itself is now stale too — flag it, but renaming it is a separate, larger mechanical change touching every call site; out of scope for this plan, just note it as a known follow-up in the doc) and describe `AppBackground` as a flat `AppPalette.onyx` fill, not a photo.
5. **Leave the three `BackdropFilter` sites alone**, except: have Claude Code read `ios_map_location_step.dart` and `android_map_location_step.dart` and report back what they're using blur for, so a future decision (not this plan) can be made with actual information instead of my not having read them.

## What this deliberately does not do

- Does not touch `AppPalette`, any color token, or any layout beyond the one button swap named above.
- Does not reintroduce `BackdropFilter`, gradients, or translucent fills anywhere — ADR-032 stands.
- Does not rewrite `PrimaryButton`'s press animation into a spring/physics-based system — the current fixed-duration `AnimatedScale` is short-lived enough (120ms, always completes) that upgrading it to a spring is a real but low-priority future option, not something this plan does.
- Does not do a screen-by-screen redesign pass. ADR-032's own "Consequences" section already recommended a full visual pass "before considering this done" — that's a larger, separate effort if Shashika wants it; this plan is the scoped, concrete gaps I could verify against actual source in this pass.
- Does not touch `signing_in_overlay.dart`'s blur (Finding 4) — a deliberate non-fix, explained above, not an oversight.

## Related

ADR-032 (flat design system). CLAUDE.md's Design System section (being updated as part of this plan).
