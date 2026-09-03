# Frontend PLAN — Base Identity (Apple/Google/Email+Password), LinkedIn as Sole Trust-Granting Step, Age Eligibility

Implements ADR-014 (final shape, 2026-08-19). Pairs with `backend/level0-federated-identity-PLAN.md` — read both; several steps depend on the RPCs/routes that plan defines.

**Scope note (recommendation, flagged not silently decided)**: ship Sign in with Apple on iOS and Google Sign-In on Android only for this first cut, not both providers on both platforms — Apple has no native Android SDK (would mean a web-redirect flow), real extra engineering for uncertain v1 value. Add cross-platform secondary options later if wanted.

## Prerequisites

Apple Services ID + Google OAuth client ID (Action Tracker §1) — Steps 1-2 don't need real credentials; Step 3 onward does for on-device testing.

## Step 1 — Dependencies

```yaml
sign_in_with_apple: ^6.1.4   # confirm latest at implementation time
google_sign_in: ^6.2.2       # confirm latest at implementation time
```

**Manual platform config, flag explicitly**: iOS — enable "Sign in with Apple" capability in `Runner.xcworkspace` → Signing & Capabilities (Xcode, manual, cannot be done from code). Android — register the app's SHA-1 signing fingerprint against the Google Cloud OAuth Android client (`./gradlew signingReport` in `frontend/android`, both debug and release fingerprints), plus configure `google_sign_in`'s `serverClientId` to the separate **Web** OAuth client ID (not the Android one) — this is what makes the id_token's audience match what the backend verifies against; a common real gotcha, don't skip it.

## Step 2 — Models and `AuthService` contract

`core/services/auth_service.dart` (interface) gains, alongside the existing `signInWithLinkedIn()` (**unchanged, keeps its name and behavior** — still a direct account-creating signup call, per ADR-014's final design):

```dart
Future<AuthSession> signInWithApple({required bool ageConfirmedOver18});
Future<AuthSession> signInWithGoogle({required bool ageConfirmedOver18});
Future<AuthSession> signUpWithEmail({required String email, required String code, required String password, required bool ageConfirmedOver18});
Future<AuthSession> loginWithEmail({required String email, required String password});
Future<AuthSession> linkLinkedIn(); // NEW — Profile-initiated linking to an already-authenticated Level-0 session, distinct from signInWithLinkedIn()
Future<void> startEmailSignupOtp(String email); // reuses the existing OTP-start pattern already built for personal-email verification
```

Update `MockAuthService` and `HttpAuthService` together — don't let the mock drift from the real contract.

`signInWithLinkedIn()` now also needs to pass `age_confirmed_over_18` (it didn't need to before — LinkedIn direct signup gets the age gate added too, per ADR-014).

## Step 3 — Age confirmation screen

New widget, `features/onboarding/age_confirmation_step.dart`. Shown **first**, before any of the four sign-up options are even visible — not after picking one, and not per-path. Once confirmed, the value is held for whichever path the user picks next (Apple/Google's native id_token call happens after this screen; LinkedIn and email signup also carry the confirmed flag into their respective calls).

Copy (starting point, from ADR-014 — needs the legal/PDPA pass already tracked in Action Tracker):

> **You must be 18 or older to use Professional Meetups.**
> ☐ I confirm I am 18 years of age or older.
>
> We verify professional identity and give you tools to plan safer in-person meetups — but only you can judge a situation in the moment. Please use your own judgment, meet in public places, and let someone know where you're going.

Checkbox unchecked by default; Continue disabled until checked.

## Step 4 — `OnboardingFlow` restructure

`features/onboarding/onboarding_flow.dart` currently: welcome step → "CONTINUE WITH LINKEDIN" button → `_continueWithLinkedIn()` → `_pendingVerificationSteps` sequence → `AppShell`.

New sequence:

1. `AgeConfirmationStep` (Step 3) — always first.
2. Entry screen with **co-equal buttons**, platform-appropriate: iOS shows "Continue with Apple" + "Continue with LinkedIn"; Android shows "Continue with Google" + "Continue with LinkedIn". Apple's button must be visually equal in size/weight to LinkedIn's (Guideline 4.8's placement requirement — this is a real App Review criterion, not a style preference). Add a third, visually secondary "Sign up with email" text link/button below the two primary ones, opening the email-signup form (Step 5).
3. Below the buttons, the ADR-014 microcopy: *"Signing in without LinkedIn keeps your account read-only. Connect LinkedIn anytime — during setup or later from your profile — to unlock matching, messaging, and meetups."*
4. Whichever path is chosen calls the matching `AuthService` method from Step 2. If it's LinkedIn (either directly, or the user picks email/Apple/Google first then this screen reappears with a "Connect LinkedIn" nudge — **decide which of these two UX shapes you want before building**, this plan doesn't prescribe it, both are consistent with ADR-014): `_pendingVerificationSteps` runs same as today. If it's Apple/Google/email without LinkedIn: straight to `AppShell` at Level 0.

Preserve the existing `pushAndRemoveUntil`-not-`pushReplacement` reasoning already documented in the file.

## Step 5 — Email signup and login screens

Two new widgets:

- `features/onboarding/email_signup_step.dart`: email field → `startEmailSignupOtp` → OTP entry (reuse the existing OTP-entry widget pattern from `phone_verification_page.dart`/`personal_email_verification_page.dart`, don't rebuild it) → password field (client-side strength hint, not a hard gate — real validation is server-side) → `signUpWithEmail`.
- `features/auth/email_login_page.dart`: email + password fields → `loginWithEmail`. This is the one screen that genuinely can't collapse into a single button the way Apple/Google/LinkedIn do — surface it from a "Sign in" link on the landing page for returning email+password users, distinct from the onboarding entry screen (Step 4) which is for new sign-ups.

## Step 6 — Level 0 read-only enforcement (client-side UX only — server is authoritative, same discipline as ADR-013)

Audit every screen currently gated by `IntentType.requiredTrustLevel` or anything else that implicitly assumed "logged in" meant "at least Level 1" (mirrors the backend audit in the paired plan's Step 5 — do both, they'll likely surface different spots).

- `matches_page.dart` (browse open Meetups): Level 0 still renders the list (read-only browse is the intended Level 0 capability), action buttons (request/schedule) disabled with an upsell prompt reusing whatever trust-gate pattern already exists elsewhere.
- `ProfilePage`: needs a "Connect LinkedIn" banner/CTA for Level 0 accounts (Step 7), and should show a "LinkedIn Verified" badge (per ADR-014, paired with the existing verified-badge caveat already used elsewhere in the app) once connected.
- Anywhere messaging/chat UI exists even as a stub: unreachable at Level 0.

## Step 7 — Profile page: deferred LinkedIn connection

`ProfilePage` gains a banner, visible only when `profile.trustLevel == 0`, calling the new `linkLinkedIn()` (Step 2) — not `signInWithLinkedIn()`, which is the account-creating call. On success: refresh the session (new `trust_level`), then run `_pendingVerificationSteps` the same way onboarding would have, so connecting from Profile doesn't skip the Level 2 steps a fresh-onboarding LinkedIn user would have seen.

## Step 8 — Tests

- Widget tests for `AgeConfirmationStep` (checkbox gating, copy present, shown before any signup button).
- Widget tests for the entry screen: Apple/LinkedIn buttons visually equal size on iOS (a real, testable layout assertion, not just "looks right").
- Widget tests for email signup (OTP step, password field) and email login.
- Update `MockAuthService` and any existing onboarding-flow tests currently assuming LinkedIn is the only/first auth step.
- A test confirming a Level-0 `UserProfile` renders `matches_page.dart` in read-only mode (list visible, actions disabled).

## Self-review checklist

- [ ] `MockAuthService` and `HttpAuthService` implement all six new/changed methods identically in shape.
- [ ] Age confirmation copy matches ADR-014 (or the final legal-reviewed version) exactly.
- [ ] Apple's button is genuinely equal in visual weight to LinkedIn's on the iOS entry screen — check this on an actual simulator, not just the widget tree.
- [ ] No screen reachable at Level 0 that should require Level 1+.
- [ ] `linkLinkedIn()` (Profile) and `signInWithLinkedIn()` (signup) are two distinct calls, not the same method reused — confirm they hit the two different backend routes from the paired plan.
- [ ] iOS: Sign in with Apple capability actually enabled in Xcode — needs an actual build check, can't be verified by grep.
- [ ] Android: `serverClientId` points at the Web OAuth client, not the Android one — verify by actually completing a sign-in on a test device/emulator, not just reading the config.

## Related

ADR-014 · `backend/level0-federated-identity-PLAN.md` · `frontend/PLAN.md` (original LinkedIn slice, `signInWithLinkedIn()` unchanged by this plan) · `frontend/meetup-scheduling-PLAN.md` (pattern this follows)
