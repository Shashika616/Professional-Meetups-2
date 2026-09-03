# Frontend plan — Passwordless auth + early company verification (ADR-019)

Companion to `backend/passwordless-and-company-verification-PLAN.md` — read both, and `docs/04-decisions/adr-019-passwordless-auth-and-early-company-verification.md`, before starting. Do not start this until the backend RPCs it depends on (`StartEmailLogin`/`CompleteEmailLogin`, `CompleteProfileSetup`, the updated `VerifyCorporateEmailCode` signature) exist — check with whoever ran the backend half first if working from a partial build.

**What exists today, concretely**: `frontend/lib/features/onboarding/onboarding_flow.dart` dispatches all four auth paths (Apple, Google, LinkedIn, email) to a shared `_goToAppShell()` method once auth succeeds — every path funnels through this one method, which is the single insertion point for anything that must happen "right after login, before the app shell," including this slice's new screen. `email_signup_step.dart` implements email signup as a 3-step local enum (`_Step { email, otp, password }`) — `password` is the step being removed. `age_confirmation_step.dart` is the existing pattern for a simple, single-purpose onboarding step widget — model the new profile-setup screen's structure on it rather than inventing a new shape. No login screen exists yet for the email path (`LoginWithPassword` is only referenced in `core/services/auth_service.dart`/`http_auth_service.dart`'s service-contract layer, never from a widget) — building it is genuinely new work here, not a modification.

## Step 1 — Remove the password step from signup

- `email_signup_step.dart`: collapse `_Step { email, otp, password }` to `_Step { email, otp }`. Remove `_passwordController` and everything gated on `_step == _Step.password` (`_submitPassword`, the 8-character-minimum check, the password `TextField`). The OTP step's "Continue"/submit action now calls `CompleteEmailSignup(email, code, ageConfirmedOver18)` directly (no password argument) once the backend's updated signature lands.
- `AuthService`/`HttpAuthService` (`core/services/`): update `completeEmailSignup`'s signature to drop the `password` parameter; remove `loginWithPassword` from the interface and its `Http`/`Mock` implementations entirely (mirrors the backend RPC removal — don't leave a dead method on the interface "just in case").

## Step 2 — Build the email login screen (new, not a modification)

- New widget, e.g. `features/onboarding/email_login_step.dart`, modeled directly on `email_signup_step.dart`'s email→otp shape (reuse its OTP-entry sub-widget if it's already factored out separately; factor it out now if it isn't, rather than copy-pasting the OTP UI a second time).
- Two-step: email → `StartEmailLogin` → otp entry → `CompleteEmailLogin` → session established → same post-auth path as every other method (see Step 3).
- Generic error copy on failure (wrong code *or* no such account) — don't let the UI distinguish these, matching the backend's enumeration-safety design (ADR-019 § 1).
- Wire this screen as the "log in" entry point wherever the landing page currently offers (or is expected to offer) a way back in for an existing email-path user — check `features/landing/` for the current button layout before deciding exact placement; this slice adds the screen and its entry point, it doesn't redesign the landing page.

## Step 3 — New mandatory profile-completion screen

- New widget, e.g. `features/onboarding/profile_setup_screen.dart`. Structure it like `age_confirmation_step.dart` (single-purpose, `ConsumerStatefulWidget`, calls one backend RPC on submit) rather than reusing `email_signup_step.dart`'s multi-step-enum shape — this screen isn't a multi-step wizard, it's one form with an inline optional sub-action.
- Fields:
  - Full name — `TextEditingController`, pre-filled from whatever the just-completed auth call's response already carries as a name (Apple/Google/LinkedIn responses should have one; email-OTP's won't — leave blank, required before "Continue" enables).
  - Company/organization name — plain `TextField`, optional.
  - Company/organization email — `TextField`, **disabled** (not just hidden) until the company-name field is non-empty; a "Verify" button next to/below it triggers the same OTP sub-flow already used for phone/personal-email verification elsewhere in the app (reuse that widget — check `features/verification/` or wherever Level 2/3's existing OTP entry UI lives before building a new one).
  - Required copy, placement matters (ADR-019 § 3, don't paraphrase loosely — use language consistent with the existing corporate-email badge-honesty copy already in `frontend/PLAN.md`'s Level 2/3 addendum): directly under the company email field, a line stating the raw address is never stored, only used to confirm the person controls an inbox at that domain; near the "Verify" button, a warning that verifying the same company mailbox across multiple accounts harms that company's/organization's standing on the platform.
- On a domain-mismatch or already-claimed-hash rejection from `VerifyCorporateEmailCode` (Step 3 of the backend plan), surface the specific message the backend returns — don't collapse it into a generic "verification failed" toast; the user needs to understand *why* (wrong domain for that company name, or already used elsewhere) to correct it.
- "Continue" enabled once full name is non-empty, regardless of whether company name/email were touched at all — verify this explicitly with a widget test, it's the easiest thing to accidentally over-gate.
- Insert into `onboarding_flow.dart`'s `_goToAppShell()`: route to this screen first, and only call the real `_goToAppShell()` navigation once this screen's "Continue" is pressed (whether or not company fields were filled).

## Step 4 — Theme/design consistency

- Use `Glass`/`GradientButton`/`SectionLabel`/`GlassTextField` (`core/widgets/`) — same chrome as every other onboarding step, not ad hoc styling. No new colors — pull from `AppPalette` only.

## Step 5 — Tests

- Widget test: profile-setup screen's "Continue" is enabled with only a full name entered.
- Widget test: company email field is disabled until company name has content.
- Widget test: a domain-mismatch error message from the backend renders as the specific returned message, not a generic fallback string.
- Update or remove any existing widget test that asserted against the now-removed password step/field in `email_signup_step.dart`.
- `flutter analyze --fatal-infos` and `flutter test` both clean; `dart format --set-exit-if-changed .` clean.
