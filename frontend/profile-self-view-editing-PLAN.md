# Frontend plan — profile self-view editing, address out of trust level, Official badge fix (ADR-023)

Read `docs/04-decisions/adr-023-profile-self-view-editing-address-out-of-trust-level-official-badge-fix.md` first. Depends on the backend plan's Step 2 (four new `ProfileResponse` fields) being available — coordinate or sequence accordingly.

## Step 1 — `UserProfile` model

- `core/models/user_profile.dart`: add four fields — `phoneNumber`, `personalEmail`, `legalName`, `address` (all `String`, default `''`), parsed in `fromJson` from the new response fields, threaded through `copyWith`.
- Rewrite the class's doc comment — it currently says "never the raw phone number or email address... this model has no field capable of holding one." That's no longer true and the comment needs to say what's actually true now: these four are returned to the account's own owner only, still never sent anywhere else, still never shown to any other user. Don't just delete the claim; a wrong comment left behind is worse than an outdated one — replace it with the corrected scope (mirrors the backend plan's Step 2 note about `ProfileResponse`'s comment).

## Step 2 — Address out of Personal Details

- `features/verification/personal_details_page.dart`: remove the `_addressController` and its `GlassTextField` entirely. `_canSubmit` becomes legal-name-only. `submitPersonalDetails` call: check `AuthService.submitPersonalDetails`'s signature — if it still takes an address parameter, pass an empty string (don't remove the parameter from the shared interface unless the backend plan's Step 1 also drops it from the proto request, which it doesn't — `SubmitPersonalDetailsRequest.address` stays, just becomes optional).
- Update the screen's `trustBenefit` copy (currently mentions "legal name and address") to drop the address mention.

## Step 3 — Legal name pre-fill

- `PersonalDetailsPage`: on `initState`, if `profile.personalDetailsComplete` is `false`, pre-fill `_legalNameController` with `profile.fullName` (still fully editable, still a separate submission on CONTINUE). If `personalDetailsComplete` is already `true`, pre-fill instead from `profile.legalName` (Step 1's new field) — the actual current value, not a suggestion. This needs the current `profile` passed into the page (it's currently built with no constructor args, reading nothing from the caller) — thread it in from `ProfilePage`'s navigation call site, same way other data gets passed to pushed screens in this app.

## Step 4 — Official badge decoupled from full trust level

- `core/widgets/verification_badges.dart`: `VerificationBadges` gains an optional `bool? workEmailVerifiedOverride` parameter (default `null`). The "Official" condition becomes `workEmailVerifiedOverride ?? (trustLevel >= 3)`. Update the class doc comment to explain the override exists specifically for the self-view case, and that every other-user-facing call site (browse cards, request cards) must keep passing `null` (or simply not pass it) so their behavior is provably unchanged.
- `features/profile/profile_page.dart`: `_avatarBlock` passes `workEmailVerifiedOverride: profile?.workEmailVerified` when calling `VerificationBadges`.
- Grep the rest of the codebase for other `VerificationBadges(` call sites and confirm none of them pass this new parameter — if any other self-view-only surface exists (there shouldn't be one today), flag it rather than silently wiring it up.

## Step 5 — Edit-in-place, all five rows tappable

- `ProfilePage._verificationRow`: currently only renders the `_verifyChip` (tappable) when `!done && !locked` — when `done` is true, it shows a static checkmark with no tap target at all. Change this so the row is tappable regardless of `done` (still respecting `locked`), pushing the same `buildScreen` either way. Each destination screen needs to know it's being opened for "already verified, editing" vs. "first-time verifying" — thread the current profile (or just the specific current value) into each screen via its constructor:
  - **Phone / Personal Email** verification pages: accept an optional `currentValue` (from `profile.phoneNumber`/`profile.personalEmail`, Step 1) to display for context before the user enters a new value; the actual re-verification still runs the full OTP flow against whatever new value is entered (never silently resubmits the shown value as if already verified).
  - **Personal Details**: handled in Step 3.
  - **Work Email** (`CorporateEmailVerificationPage`): accept an optional current-domain hint (`profile.companyDomain`, already available today, no new field needed) to show something like "Currently verified: acme.com" above the form, and pre-fill the company-name field with a best-effort resolved display name if one is available (check whether the backend exposes a known-company display-name lookup by domain anywhere already reachable from this RPC surface — if not, just show the raw domain as the hint, don't invent a new backend call for this alone without checking the plan's backend side first). Frame the screen's copy as "Change work email" when a domain is already on file, vs. "Verify Your Work Email" for a first-time verification.
  - **Full name**: not part of `_verificationRow` today (there's no dedicated row for it in the VERIFICATION section) — add a lightweight inline edit affordance for full name near `_avatarBlock`'s displayed name (a pencil icon next to the name text is fine, doesn't need a full-screen page), calling `completeProfileSetup(fullName: ..., companyName: null, companyEmail: null)` so it never re-triggers a work-email verification-start as a side effect of a pure name edit.

## Step 6 — Tests

- `VerificationBadges` unit tests: override present and `true` shows Official regardless of trust level; override `null` falls back to existing `trustLevel >= 3` behavior unchanged (regression test for every other-user call site).
- `PersonalDetailsPage` widget tests: pre-fills from `fullName` when not yet complete; pre-fills from `legalName` when already complete; submits without an address field present at all.
- Full checklist: `flutter analyze`, `dart format --set-exit-if-changed`, `flutter test`.
