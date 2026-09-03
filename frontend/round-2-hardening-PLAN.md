# Frontend plan — Round 2 hardening (2026-08-31 independent review findings)

One finding from an independent code-quality review of the Slice H+D+F+hardening batch. See `docs/00-project/action-tracker.md` § 4b-16.

## Fix 1 — Log the swallowed `updateLastKnownLocation` failure (Low)

`matches_page.dart`'s `updateLastKnownLocation(...).catchError((_) {})` swallows failures with zero trace today — doesn't crash the screen (correct, this should stay fire-and-forget from the user's perspective), but leaves no record at all for debugging a real failure.

- Change the empty catch to at least `debugPrint('updateLastKnownLocation failed: $e')` (or this app's equivalent lightweight logging convention, if one exists beyond raw `debugPrint` — check what other fire-and-forget calls in this codebase do, if any, and match it). Do not surface this to the user (still correctly silent from their perspective) and do not add retry logic — this is strictly a debuggability fix, not a behavior change.

## Also verify while in this file

- The independent review flagged a small, unresolved discrepancy worth settling while this file is open anyway: the prior completion report claimed 248/248 tests passing; a mechanical count found 245 `test(`/`testWidgets(` declarations across `frontend/test/*.dart`. Run `flutter test` for real as part of this round's checklist and report the actual current total — this may just be a counting-methodology difference (e.g. `group()`-nested tests), but confirm rather than leave it unresolved.

## Tests

- No new test needed for Fix 1 itself (it's a logging-only change, not a behavior change) — but do add one if there's an existing pattern in this codebase for asserting a debug log line fires (only if that pattern already exists elsewhere; don't invent a new one just for this).
- Full checklist: `flutter analyze --fatal-infos`, `dart format --set-exit-if-changed`, `flutter test` — report the real total test count this time.
