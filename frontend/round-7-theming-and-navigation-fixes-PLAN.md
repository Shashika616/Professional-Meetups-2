# Frontend plan — Round 7: VerificationChecklistPage theming, redirect-pattern consistency, auth-page black stripe

Three fixes, all frontend-only, all root-caused before this plan was written (see `docs/00-project/action-tracker.md` § 4b-20 for full context). Two are genuinely small (mirror an existing pattern); one (Fix 2's HOST YOUR OWN MEETUP item) closes a real pre-existing gate gap, not just a cosmetic fix.

## Fix 1 — `VerificationChecklistPage` doesn't theme at all

`lib/features/verification/verification_checklist_page.dart`: every color already correctly uses `AppPalette` tokens — the bug is that its `Scaffold.body` is bare `SafeArea(ListView(...))` with no `AppBackground` wrapper, so it never paints the theme-reactive background at all (falls through to plain black regardless of light/dark mode).

- Wrap the body in `AppBackground`, matching how every sibling page it navigates to/from already does it — check `verification_scaffold.dart` (the shared chrome for the four verification screens this page links out to) for the exact composition to mirror: `Scaffold(backgroundColor: Colors.transparent, body: AppBackground(child: ...))`.
- While touching this file's `Scaffold`, also add `extendBodyBehindAppBar: true` (it has an `AppBar`, and without this flag it would produce the same black-stripe-behind-the-appbar seam Fix 3 below fixes elsewhere) — same pattern as `profile_setup_screen.dart`.
- Verify: does adding `AppBackground` change any existing padding/spacing assumptions in the `ListView`'s children? Check against how `verification_scaffold.dart`'s own children are laid out (likely already inside a `SafeArea` + padding) to avoid double-padding or a layout shift.

## Fix 2 — extend the toast+redirect pattern to every locked-feature site, not just meetup cards

ADR-028 already built toast-then-redirect-to-`VerificationChecklistPage` for `matches_page.dart`'s locked meetup card/join button and `meetup_detail_page.dart`'s REQUEST TO JOIN button — leave both of those exactly as they are, they're the reference implementation.

Add the same redirect (not a new toast — just extend what already toasts to also navigate afterward) to:
- `home_page.dart`'s FIND MATCHES button (currently toasts and returns — add `Navigator.push` to `VerificationChecklistPage` after the toast, same as the reference sites).
- `intent_picker_sheet.dart`'s per-intent tiles (same treatment).
- `schedule_flow.dart`'s own intent-picker step (`_IntentStep`) (same treatment).
- `matches_page.dart`'s browse-screen intent tabs bar (`_IntentTabsBar.onSelect`) (same treatment).

And **add a gate that doesn't currently exist** to:
- `home_page.dart`'s HOST YOUR OWN MEETUP button — today this button has **no trust check at all**, unconditionally pushing `ScheduleFlowPage` regardless of trust level (the existing code comment explicitly defers gating to the flow's own nested intent step, which is toast-only with no redirect). Add a real gate here: check `selectedIntent.isUnlockedFor(trustLevel)` — the exact same check FIND MATCHES already does — before pushing the flow; on failure, toast + redirect exactly like the other sites; only push `ScheduleFlowPage` when unlocked. This is a genuine new gate, not just adding a redirect to an existing toast, since none exists on this button today. Leave the flow's own internal `_IntentStep` gate as a defense-in-depth backstop (a user can still change intent mid-flow), also getting the redirect per the bullet above — don't remove it.

Keep the actual redirect mechanism identical everywhere (same `Navigator.push(MaterialPageRoute(builder: (_) => const VerificationChecklistPage()))`-style call already used by the two reference sites) — this should read as "the same 2-line addition, copied to 5 more call sites, plus one new gate that reuses an existing check," not five different implementations.

## Fix 3 — black stripe on email sign-in/sign-up/OTP screens

`email_login_page.dart` and `email_signup_step.dart` (the OTP step lives inside each of these same files, swapped via `build()`'s `switch (_step)` — this is one shared root cause across both "screens," not three separate bugs) both have `Scaffold(appBar: AppBar(...), body: AppBackground(...))` missing `extendBodyBehindAppBar: true`. Without it, Flutter reserves the AppBar's height and `AppBackground` only paints below it, and since the global `AppBarTheme` and the `Scaffold`'s own background are both transparent, that reserved strip shows through to plain black.

- Add `extendBodyBehindAppBar: true` to both files' `Scaffold`s. This exact bug and fix already exist once in this codebase — `profile_setup_screen.dart` (lines ~170-199) has the identical shape with the fix applied and a code comment describing this precise symptom; copy that comment's reasoning (don't just add the flag silently) so the next person touching either file understands why it's there.
- Since the OTP step renders inside the same `Scaffold` (just a different `_step` in the same `switch`), fixing the `Scaffold` once per file fixes both the initial step and the OTP step in that file — confirm this by checking both `_step` branches render correctly once the flag is added, don't assume it without checking.

## Do not

- Do not touch `matches_page.dart`'s existing locked-card/join-button redirect or `meetup_detail_page.dart`'s REQUEST TO JOIN redirect — these are the reference implementation, already correct.
- Do not build a new toast/redirect helper — reuse the exact existing `showSnack(..., type: ToastType.locked)` + `Navigator.push(... VerificationChecklistPage())` shape already in the reference sites.
- Do not remove `schedule_flow.dart`'s nested `_IntentStep` gate when adding the outer gate to HOST YOUR OWN MEETUP — both should exist (outer gate for the common case, inner gate as a backstop for mid-flow intent changes).
- Do not change `onboarding_flow.dart`'s own `Scaffold` (it has no `AppBar` at all, so it isn't affected by Fix 3's bug and doesn't need the flag).

## Tests

- A widget test confirming `VerificationChecklistPage` builds without error and renders `AppBackground` in its tree (a simple `find.byType(AppBackground)` check is enough — this is a rendering-structure fix, not new logic).
- A widget test for the new HOST YOUR OWN MEETUP gate: a trust-level-0 user taps the button, confirm `ScheduleFlowPage` is NOT pushed, the locked toast shows, and `VerificationChecklistPage` IS pushed. A separate test confirming an unlocked user's tap DOES push `ScheduleFlowPage` as before (regression guard — don't break the working case while fixing the broken one).
- No new tests needed for Fix 3 (a rendering-only flag, no logic to unit test) beyond a sanity pump-and-settle confirming no exception on both `_step`s if that's cheap given existing fixtures; skip if it would need disproportionate new fixture work, same allowance as prior rounds.

## Full checklist

`flutter analyze --fatal-infos`, `dart format --set-exit-if-changed`, `flutter test` — report the real total from the test runner's own summary line.
