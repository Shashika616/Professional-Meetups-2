# Frontend plan — 2026-08-31 review findings (bundled hardening, not their own slices)

Two real findings from the full-codebase review, small enough to bundle into this same change request.

## Fix 1 — Wire up the dead `Validators` class (Medium)

`core/validation/validators.dart` has zero call sites in `lib/` outside its own test (confirmed by grep) — contradicts `CLAUDE.md`'s documented "pure validators for instant feedback" pattern.

- `phone_verification_page.dart`: use `Validators.phone` (or the equivalent existing method) before submit, not just `.isEmpty`.
- `personal_email_verification_page.dart`: use `Validators.email`/personal-email equivalent before submit, not just `.isEmpty`.
- `corporate_email_verification_page.dart`: replace its own separately-maintained `_freeEmailDomains` list with `Validators`' existing free-provider/role-based-mailbox rejection logic — these two lists have been drifting independently, consolidate to one source of truth. Add real email-format validation here too (currently has none).
- `Validators.linkedin` can stay unused — the Level 1b paste-URL flow it validated is gone, replaced by real OAuth (ADR-011 correction). Don't resurrect a call site for it.
- The new trusted-contacts form (Slice H, Step 2 of `sos-trusted-contacts-PLAN.md`) should also use `Validators.phone`/`Validators.email` for its inputs rather than introducing a third ad hoc check.

## Fix 2 — Dead settings rows in `profile_page.dart` (Low)

Two rows use the plain `_Row` widget (no tap handler at all) despite showing a navigation chevron: "Notifications" and "Safety Center" (around `profile_page.dart:142-162`).

- "Safety Center": wire its tap to navigate to the same `SafetyPage` already reachable from the bottom nav (or remove the row entirely if a duplicate entry point isn't wanted — either is fine, just don't leave the chevron affordance lying).
- "Notifications": no push-preferences backend exists yet to back a real settings screen (out of scope here) — mark it visually as "Coming soon" (disabled state, no chevron) rather than leave a misleading live-looking affordance.

## Tests

- Widget test: phone/personal-email verification forms reject invalid input via `Validators` before any network call.
- Widget test: corporate-email screen's free-domain rejection now comes from `Validators`, confirmed via a shared test case that would have caught the old drift (a domain that's free-provider-listed in one list but not the other, if any existed).
- Widget test: "Safety Center" row navigates; "Notifications" row shows a disabled/coming-soon state and does nothing on tap.
- Full checklist: `flutter analyze`, `dart format --set-exit-if-changed`, `flutter test`.
