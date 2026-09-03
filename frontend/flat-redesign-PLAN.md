# Frontend plan — Flat design redesign (ADR-032)

See `docs/04-decisions/adr-032-flat-design-system-remove-glassmorphism-and-neon-effects.md` for the decision and the mockups it was approved against. This is a frontend-only visual change — no backend, no `AppPalette` value changes, no route/navigation changes beyond the one layout restructure in Step 4.

Verified before writing this plan: no call site anywhere in `frontend/lib` passes a custom `tint`/`border` override to `Glass` (`grep`-checked) — every call site uses the default styling, so the rename/restyle in Step 1 is mechanical everywhere except the two spots called out explicitly below (Step 3, Step 4). `GlassBottomBar` and `GlassTextField` both already delegate to `Glass` internally — they need no separate change beyond what Step 1 gives them for free (renaming them is optional polish, not required).

## Step 1 — `Glass` → `FlatCard`

`frontend/lib/core/widgets/glass.dart`: rename the class `Glass` → `FlatCard` (rename the file too: `glass.dart` → `flat_card.dart`). Keep the exact same constructor shape (`child`, `radius`, `padding`, `tint`, `border`, `blur` — `blur` becomes dead/ignored, or drop it from the constructor entirely and fix the ~2 call sites in `glass_bottom_bar.dart`/`intent_grid.dart`'s `_MoreTile` that pass it explicitly, whichever is less churn).

New implementation: no `BackdropFilter`, no `ImageFilter.blur`. A plain `Container` with:
- `color: tint ?? AppPalette.card` (solid, not `glassTint`'s translucent value)
- `border: Border.all(color: border ?? AppPalette.glassBorder.withValues(alpha: ...), width: 1)` — reuse `glassBorder`'s hue as a hairline border color if it still reads right at full/near-full opacity now that there's no blur behind it to soften it; if it reads too harsh, this is the moment to add a new `AppPalette.cardBorder` token instead (Claude Code's call — check visually against both themes, don't guess).
- `borderRadius: BorderRadius.circular(radius)`
- Light mode only: `boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 6, offset: Offset(0, 1))]` (gate on `AppPalette.isLight`). Dark mode: no shadow — the hairline border alone is the separation cue, matching the approved mockup.

Then a global rename of every `Glass(` call site to `FlatCard(` (import updates included). This is the change that mechanically flattens `GlassBottomBar`, `GlassTextField`, `HomeHeader`'s `_MyMeetupsEntryChip`, `ActiveMeetupsSection`'s cards, and every other screen built on `Glass` — do not hand-restyle those files individually, the point of this step is that they don't need it.

## Step 2 — `GradientButton` → `PrimaryButton`

`frontend/lib/core/widgets/gradient_button.dart` → rename file and class to `primary_button.dart`/`PrimaryButton`. Same constructor (`label`, `onPressed`, `height`, `isLoading`, `icon`). Replace the `LinearGradient` fill with a solid `AppPalette.candyBlue` background. Remove the `boxShadow` glow entirely (both the resting and pressed states). Press feedback: keep the existing `AnimatedScale` (1.0 → ~1.02, smaller than today's 1.03 reads calmer) or drop it for a simple opacity dip (`0.92` on press) — either is fine, pick whichever reads cleaner once it's on a flat background with no shadow doing visual work anymore. Disabled state: same `withValues(alpha: 0.4)` treatment on the solid color instead of the gradient stops.

Rename every call site `GradientButton(` → `PrimaryButton(`.

## Step 3 — `AppBackground`: drop the glow blobs

`frontend/lib/core/widgets/app_background.dart`: delete the two `Positioned(... child: _glow(...))` widgets and the `_glow()` method entirely. Keep everything else unchanged — the `suit.png` image, its `ColorFilter.mode(..., BlendMode.saturation)` desaturation, the `imageOpacity` param, and the existing three-stop gradient overlay fading into `AppPalette.onyx`. This is the one place in the whole change that's a pure deletion, not a rename — call it out in your own completion report as its own line item so it's easy to verify against the ADR.

## Step 4 — Home page: reposition the CTA buttons

`frontend/lib/features/home/home_page.dart` currently renders a single scrolling `ListView` as the page body (header, intent grid, `FIND MATCHES` button, `HOST YOUR OWN MEETUP` button, active meetups, network insights, safety tip — all scrolling together), inside `HomePage`'s own nested `Scaffold` (this page sits inside `AppShell`'s `IndexedStack`; `AppShell`'s own outer `Scaffold` owns the actual `bottomNavigationBar: GlassBottomBar(...)`, per `app_shell.dart`).

Change the body to:
```dart
body: SafeArea(
  child: Column(
    children: [
      Expanded(
        child: RefreshIndicator(
          onRefresh: () => ref.refresh(activeMeetupsProvider.future),
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              HomeHeader(...),
              const SizedBox(height: 8),
              IntentGrid(...),
              const ActiveMeetupsSection(),
              const NetworkInsightsRow(),
              const SafetyTipCard(),
              const SizedBox(height: 16), // clearance above the fixed CTA block, not the old 96 (that was clearance for the old floating nav bar position, which no longer applies the same way once CTAs sit above a solid, non-floating FlatCard-based bar)
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Column(
          children: [
            PrimaryButton(label: 'Find matches', onPressed: ...), // same onPressed body as today, unchanged
            const SizedBox(height: 8),
            OutlinedButton.icon(...), // same "Host your own meetup" button, unchanged onPressed body
          ],
        ),
      ),
    ],
  ),
),
```
The two buttons' `onPressed` bodies (the trust-gate check, the toast, the `Navigator.push`, the provider invalidations) move as-is — this step only relocates *where* they render, not what they do. Verify the fixed bottom block still reads correctly against `AppBackground`'s gradient-to-solid fade (it should, since the fade already terminates at a fully solid color well above where the fixed block sits).

## Step 5 — `IntentPickerSheet`'s own blur

`frontend/lib/features/home/widgets/intent_picker_sheet.dart` uses its own local `BackdropFilter`/`ImageFilter.blur` directly (not through `Glass`/`FlatCard`) — it won't be touched by Steps 1-2's rename. Remove the `BackdropFilter` wrapper, use a solid `AppPalette.surface` (or `.card`) background at full opacity instead of `.withValues(alpha: 0.88)` over a blur, keep the existing rounded-top-corners `ClipRRect`, keep `barrierColor` as-is (that's the modal scrim, not glass, out of scope). The grid of `IntentTile`s inside stays exactly as-is — only the sheet's own background container changes. This is the "More" intent picker — confirm after the change that tapping "More" on the (now-`FlatCard`-based) `_MoreTile` in `intent_grid.dart` still opens this sheet and every intent tile (locked and unlocked) still renders and behaves identically; nothing about *what* it does should change, only its background style.

## Verification

- `flutter analyze` / `dart format --set-exit-if-changed .` / `flutter test` clean, per CLAUDE.md's standard checklist.
- Manual/description-based check (screenshots if the runner supports capturing them) of: Home page (both themes), the bottom nav bar, a `GlassTextField`-based form screen (e.g. onboarding or profile edit), the "More" intent picker sheet, and one card-heavy screen (`ActiveMeetupsSection` or the open-meetups browse list) — confirm no `BackdropFilter`/blur remains anywhere (`grep -r "BackdropFilter" frontend/lib` should return zero matches after this change) and no `LinearGradient`/glow `boxShadow` remains on any button (`grep -r "GradientButton" frontend/lib` should also return zero matches once every call site is renamed).
- Confirm the "More" intent tile is still present and still opens `IntentPickerSheet` — this was explicitly flagged by Shashika as something that must not get lost in the redesign.

## Do not

- Do not change any `AppPalette` color value in either theme.
- Do not remove the `suit.png` background image or its gradient fade.
- Do not remove or restructure the "More" intent tile / `IntentPickerSheet` trigger — restyle only.
- Do not touch backend code, routes, or providers beyond the one CTA-button relocation in Step 4 (same handlers, new position).
