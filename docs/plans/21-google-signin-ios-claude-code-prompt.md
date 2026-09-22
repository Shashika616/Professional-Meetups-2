You are working in the Professional-Meetups-Monolith repo. Follow
`docs/plans/21-google-signin-ios.md` in full before writing any code —
it explains why the layout has to be built the way it's specified
(there's an existing test enforcing equal button sizes for App Store
Guideline 4.8 compliance, and this plan's whole design is built around
not breaking that).

Read the plan's "Grounding against the Apple Design skill" section
particularly carefully. Two things in it are load-bearing, not just
background reading: (1) `PrimaryButton`'s existing `Curves.easeOut`
press animation is the *correct* choice for a plain tap per that
skill's own reasoning (bounce/overshoot is reserved for momentum-driven
gestures — drags, flicks — not a button tap), so do not "improve" it
into a spring or bouncy curve; (2) do not add any blur/translucency to
these buttons — this app deliberately uses a flat design language
(ADR-032), and that section of the skill does not apply here. If you
find yourself wanting to touch `PrimaryButton` itself for any reason,
stop — it's a shared component used across the whole app, and nothing
in this plan requires changing it.

## What to do

1. Read `frontend/lib/features/auth/social_sign_in_section.dart` in
   full. Note that `provider(...)` inside `build()` is a local closure
   that constructs a button on call, not a stored widget — your edit
   needs to call it in the new order, not move existing widget
   instances around.

2. Make the `build()` method show, on iOS: Apple, then Google, then
   LinkedIn — all three as the exact same `PrimaryButton` treatment
   already used today (same height, radius, neutral fill, mark+label).
   On every other platform, behavior is unchanged: Google, then
   LinkedIn. Use a 12px gap between Apple and Google (matching today's
   existing spacing constant) and a 20px gap between Google and
   LinkedIn (wider on purpose — see the plan's "Design" section for
   why). Do not create a new button widget or variant — reuse the
   existing `provider()` builder and `PrimaryButton` exactly as the
   other two buttons already do, with the same `Key`s and `source`
   strings unchanged.

3. Update the two comments the plan calls out: the class doc comment
   describing which providers show on which platform, and the inline
   comment next to the `isIOS` check explaining the platform reasoning.

4. Do not touch `_run`, `_handleError`, `_setBusy`, or the `provider()`
   builder's internals — none of them need to change.

5. Extend the "Apple Guideline 4.8 — equal visual weight on iOS" test
   group in `frontend/test/onboarding_flow_test.dart`: assert Google's
   button is now present on iOS, fetch its size the same way Apple's
   and LinkedIn's are fetched, and assert all three are equal in size.

6. Add a new widget test confirming a tap on the iOS Google button
   calls `notifier.signInWithGoogle` — model it on whichever existing
   test covers the Android-path Google tap, run under
   `debugDefaultTargetPlatformOverride = TargetPlatform.iOS`, and reset
   the override to `null` before the test body returns (the existing
   Guideline-4.8 test in the same file shows the exact pattern and
   explains why the reset has to happen before the body ends, not in
   an `addTearDown`).

7. Grep `frontend/test/email_login_page_test.dart` and
   `frontend/test/onboarding_flow_test.dart` for any other test running
   under an iOS platform override that makes a count- or order-based
   assertion about this widget's buttons, and fix any that assumed only
   two buttons exist on iOS.

## Explicitly do not touch

- `frontend/ios/Runner/Info.plist` — blocked on a Google Cloud Console
  value that does not exist in this environment yet; someone else is
  wiring that by hand once it does. Touching this file risks a
  conflicting edit.
- `AppConfig.googleServerClientId`, any `.env` file, anything under
  `frontend/android/`, or `HttpAuthService.signInWithGoogle`/
  `_ensureGoogleSignInInitialized` — none of these need to change for
  this plan and are out of scope.

## Before you report done

Run `flutter analyze` and the full `flutter test` suite (not just the
two files you touched — confirm nothing else assumed iOS shows only two
provider buttons) and paste the real pass/fail output. Since a real iOS
simulator may not be available in your environment, describe (or
screenshot, if you do have one) what the resulting iOS screen looks
like — don't rely on "tests pass" alone to describe the visual result,
since the whole point of this change was that it should look
deliberate, not stacked on.
