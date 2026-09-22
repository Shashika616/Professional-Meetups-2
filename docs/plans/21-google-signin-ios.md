# Plan 21 — Continue with Google on iOS

Adds Google as a second one-tap identity option on iOS, alongside Apple.
Backend and service-layer code already fully support this with zero
changes; this plan is a UI-only change to one shared widget, designed so
it reads as intentional rather than "one more button stacked on."

## Context

`SocialSignInSection` (`frontend/lib/features/auth/social_sign_in_section.dart`)
is the one widget both the sign-up flow (`onboarding_flow.dart`) and the
sign-in page (`email_login_page.dart`) use for one-tap provider buttons.
Today its `build()` method (lines 167-188) shows exactly one of
{Apple, Google} depending on platform — `if (isIOS) appleButton else
googleButton`, then LinkedIn unconditionally below. That was a deliberate
choice at the time (Apple has no native Android SDK; Google had "no
first-class iOS placement requirement the way Apple does" per the
existing inline comment) — but it's a choice, not a technical limit:
`HttpAuthService.signInWithGoogle` (`http_auth_service.dart:255-313`) has
no platform check anywhere in it. It calls `GoogleSignIn.instance
.authenticate()` and posts the resulting id_token to the same
`/v1/auth/federated/signup` endpoint every other provider uses,
identically regardless of caller platform.

**Not part of this plan, tracked separately:** making a real Google
sign-in attempt actually succeed on iOS also needs an iOS OAuth client
(Google Cloud Console) and two `Info.plist` entries (`GIDClientID`, a
URL-scheme for the reversed client ID) that depend on values from that
Console step. That is in progress outside this codebase change. Do not
touch `Info.plist` or `AppConfig.googleServerClientId` in this pass — the
UI change below is correct and testable on its own regardless of when
that configuration lands, and touching the same file from two directions
at once risks a conflicting edit.

## Design constraint that decides the layout

`onboarding_flow_test.dart` already has a test group named "Apple
Guideline 4.8 — equal visual weight on iOS" that asserts Apple's button
renders at the exact same size as LinkedIn's — codifying Apple's own App
Store rule that Sign in with Apple must not be visually diminished next
to other sign-in options. That test is the real constraint here, not a
style preference: Google's new button must be the same `PrimaryButton`
treatment (same 56pt height, same radius, same neutral surface, same
mark+label layout) as the other two, not a smaller "secondary" chip or a
half-width row. No new button component — reuse `PrimaryButton` exactly
as today's two buttons do.

(Consulted the `ui-ux-pro-max` design skill for the general checklist:
touch target ≥44×44pt — `PrimaryButton`'s fixed 56pt height already
clears this; ≥8pt spacing between touch targets; official brand marks
used unmodified; visual hierarchy expressed through spacing, not just
color. All of that is already true of this widget today and stays true
below — this plan doesn't introduce a new pattern, it extends the
existing one correctly.)

## Grounding against the Apple Design skill

Checked this plan's layout against the `apple-design` skill (Apple's WWDC
design-talk principles — written for the web, so treat every CSS/JS
snippet in it as illustrative, not literal; what's translated here is
the underlying design reasoning, applied to this Flutter codebase's own
idioms). This isn't a from-scratch redesign — the layout below was
already built around deliberate, defensible spacing before this check —
but naming which principle each choice satisfies, and which section of
that skill deliberately does *not* apply here, is worth doing explicitly
rather than leaving it implicit.

**Already satisfied, no change needed:**
- *§1 Response — feedback on pointer-down, not release.* `PrimaryButton`
  already does this: `onTapDown` sets `_isPressed` and triggers the
  scale animation immediately, not on `onTapUp`.
- *§4 Behavior over animation — reserve bounce/overshoot for
  momentum-driven gestures only, critically-damped (no overshoot) for
  everything else.* A tap is not a momentum-driven gesture (no flick, no
  drag, no release velocity to hand off) — `PrimaryButton`'s existing
  `Curves.easeOut` scale-down is already the *correct* choice for this
  interaction, not a shortcut to fix. **Explicitly decided not to** swap
  it for a bouncy/overshooting curve on the new Google button — that
  would contradict the skill's own guidance, not follow it.
- *§10 Gesture checklist — cancel by dragging away.* Flutter's
  `GestureDetector` tap recognizer already fires `onTapCancel` when the
  pointer leaves the hit-test region before release — this is built into
  the platform, not something to add.
- *§15 Typography — small text wants slightly positive tracking.*
  `PrimaryButton`'s label is `letterSpacing: 1.1` at `fontSize: 13.5` —
  already positive tracking at a small size, which is what the skill
  recommends (negative tracking is for large display text, not a
  13.5px button label).
- *§16 Craft — icon sizing as a deliberate, consistent token.* All three
  marks (`AppleMark`, `GoogleMark`, `LinkedInMark`) already render at the
  same `size: 20` — confirmed before writing this plan, not assumed.
- *§16 Familiarity — things that look the same must behave the same.*
  Reusing the exact same `PrimaryButton`/`provider()` builder for Google
  (rather than a new "secondary" compact variant) is this principle
  directly, not just convenient reuse.

**Considered and deliberately not applied:**
- *§12 Materials & depth — translucent surfaces.* This is the skill's
  most visually distinctive section, and it does not belong here: this
  app deliberately moved OFF glassmorphism to a flat design language
  (ADR-032, the flat-design redesign round) — the provider buttons sit
  on `AppPalette.card`, a solid flat surface, on purpose. Applying
  blur/translucency to this one button group would contradict that
  standing decision, not modernize it.
- *§14 Reduced motion.* `PrimaryButton`'s press animation is a 2% scale
  bump (`1.0 → 1.02`) over 120ms — well below the scale of motion this
  guidance targets (parallax, slides, large transforms that can trigger
  vestibular discomfort). Gating a micro-interaction this small behind
  `MediaQuery.disableAnimations` is a reasonable future improvement to
  `PrimaryButton` broadly, but it's a shared component used across the
  entire app — that's a separate, deliberately-scoped change, not
  something to fold into a two-button layout tweak.

## The actual design

Three co-equal, full-width buttons on iOS, in this order: Apple, Google,
LinkedIn (Android/other platforms unchanged: Google, LinkedIn). To avoid
three identical-looking rows reading as an afterthought, group them by
what they actually mean to someone using this app rather than by
uniform spacing: Apple and Google are both generic one-tap identity
providers, LinkedIn is this app's own professional-identity anchor — a
different kind of thing, not just a third option. Express that
difference the same way the rest of this design system already
expresses hierarchy: with spacing, not new copy or an extra divider.

Concretely: keep the existing 12px gap between Apple and Google (today's
already-established constant, unchanged), then a wider 20px gap before
LinkedIn — still an intentional value on the 4pt grid, just visibly more
than the gap within the identity-provider pair. That's the entire visual
change beyond adding the button itself: no new widget, no new color, no
new text.

## Implementation

### `frontend/lib/features/auth/social_sign_in_section.dart`

Read the current `build()` method in full before editing — `provider(...)`
at the top of `build()` is a local builder function (closure), not a
prebuilt widget, so each button is constructed by calling it at the point
it's needed, not by reordering existing widget instances.

Replace the current structure:
```dart
if (isIOS)
  provider(... apple ...)
else
  provider(... google ...),
const SizedBox(height: 12),
provider(... linkedin ...),
```
with:
```dart
if (isIOS) ...[
  provider(... apple ...),
  const SizedBox(height: 12),
],
provider(... google ...),   // now unconditional: shown on iOS too
const SizedBox(height: 20), // wider than the 12px above LinkedIn on purpose — see class doc comment
provider(... linkedin ...),
```
Keep every existing `Key`, `source` string, and `onPressed` callback
exactly as they are today — this is a structural/ordering change only,
not a behavior change to any individual button.

Update two comments so they describe what's actually true afterward:
- The class doc comment (currently: "Apple + LinkedIn on iOS, Google +
  LinkedIn elsewhere") → "Apple + Google + LinkedIn on iOS, Google +
  LinkedIn elsewhere."
- The inline comment next to `final isIOS = ...` (currently explains
  Apple has no Android SDK and Google has no first-class iOS placement
  requirement) → keep that reasoning (it's still why Apple is iOS-only)
  but make clear Google is offered on both because nothing platform-side
  prevents it — only Apple's own store requirement is what's
  platform-specific here, not a technical constraint on Google.

Do not change `_run`, `_handleError`, `_setBusy`, or the `provider()`
builder itself — none of that is platform-aware and none of it needs to
be.

### Tests

1. **Extend** `onboarding_flow_test.dart`'s "Apple Guideline 4.8 — equal
   visual weight on iOS" test: add `expect(find.text('CONTINUE WITH
   GOOGLE'), findsOneWidget);` (it's currently absent by construction on
   iOS — confirm this assertion would have failed before this change,
   as a sanity check that the test is actually exercising the new
   behavior), fetch Google's button size the same way Apple's and
   LinkedIn's are fetched, and assert all three sizes are equal. Rename
   the test description if "same size" now covers three buttons instead
   of two.

2. **Add** a new test confirming a tap on the iOS Google button actually
   calls `notifier.signInWithGoogle` — mirror whatever existing test
   covers the Android-path Google tap, just wrapped in
   `debugDefaultTargetPlatformOverride = TargetPlatform.iOS` /
   `= null` the same way the Guideline-4.8 test already does (including
   resetting it before the test body returns, per that test's own
   comment about the framework's teardown assertion).

3. **Grep both** `email_login_page_test.dart` and `onboarding_flow_test.dart`
   for any other test that runs under an iOS platform override and
   makes a count- or order-based assertion about the buttons in this
   widget (e.g. asserting exactly two children, or a specific `Column`
   length) — none were found in this plan's own research, but confirm
   before and after, since a stale assertion elsewhere would otherwise
   fail confusingly rather than obviously.

## Explicitly out of scope — do not touch

- `frontend/ios/Runner/Info.plist` — blocked on a Google Cloud Console
  value that doesn't exist yet outside this codebase.
- `AppConfig.googleServerClientId` / any `.env` file — unrelated to this
  UI change.
- Anything under `frontend/android/` — the Android layout is unchanged
  and already correct.
- `HttpAuthService.signInWithGoogle` / `_ensureGoogleSignInInitialized` —
  already fully platform-agnostic, needs no change for this plan.

## Verification checklist

- [ ] `flutter analyze` clean.
- [ ] `flutter test` — full run, not just the two touched files, to
      catch any other iOS-platform-conditional assertion this change
      might affect.
- [ ] The extended Guideline-4.8 test passes and genuinely covers three
      buttons, not two.
- [ ] The new iOS-Google-tap test passes.
- [ ] Since a real iOS build/simulator isn't available in every
      environment, the completion report should describe (or, if a
      simulator is available, screenshot) the resulting iOS screen —
      "tests pass" alone doesn't confirm the spacing reads the way this
      plan intends.

## Related

`docs/gap-tracker.md` #37 (the Apple Guideline 4.8 finding that produced
the equal-size test this plan extends) · this app's Google Sign-In OAuth
Console setup, in progress outside this repo change · the `apple-design`
skill (Apple's WWDC design-talk principles), consulted for the
"Grounding" section above — written for the web, translated here for
Flutter, and explicitly not applied where it would contradict ADR-032's
flat-design decision.
