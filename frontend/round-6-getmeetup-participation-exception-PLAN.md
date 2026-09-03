# Frontend plan — Round 6: fix the two remaining stale-comment force-unwraps, defense-in-depth

This is defense-in-depth, not a fix for a currently-reachable crash — the backend fix (participation exception, see the backend Round 6 plan) is what actually prevents a host/participant's own meetup from ever coming back redacted. But two frontend force-unwraps still assert a claim ("`GetMeetup` never redacts") that Round 5 made false, and should be corrected regardless, matching the treatment `meetup_detail_page.dart`'s other force-unwraps already got in Round 5. See `docs/00-project/action-tracker.md` § 4b-19.

## Fix 1 — `meetup_detail_page.dart`'s `_checkInWindowOpen`

Locate the getter (uses a force-unwrap on a time-window field, with a comment claiming `GetMeetup` never redacts, which is no longer true as of Round 5). Apply the same defensive pattern Round 5 already used for `hostFullName`/`locationLabel`/the time window elsewhere on this page: check `meetup.lockedForViewer` (or the specific field's nullness directly, whichever this getter's surrounding code already does) before force-unwrapping, and fall back to a safe default (check-in unavailable / false) rather than crashing. Update or remove the stale comment — don't leave it asserting something now false.

## Fix 2 — `host_meetup_controls.dart`'s `_canClose`

Same pattern. This getter is rendered unconditionally in `_buildContent` and isn't currently gated on `lockedForViewer` at all. Add the same defensive null-check the other force-unwraps in this codebase now use, with a safe default (can't close / false) if the relevant field is absent. Update the stale comment.

## Fix 3 — `meetup.dart`'s stale model doc comments

The `Meetup` model's doc comments still assert "only `listOpenMeetups` can produce a locked meetup" — false since Round 5 (`GetMeetup` can too) and will remain only-mostly-true even after the Round 6 backend fix (a genuinely locked non-participant reaching this model via some future feature is still possible in principle). Update the comment to describe the real current invariant: `lockedForViewer`/nulled fields can appear on any `Meetup` returned by any RPC, and callers should always check `lockedForViewer` before reading the nullable fields rather than assuming based on which RPC produced it.

## Tests

No new test scaffolding required specifically for this round — these are defensive null-handling changes on paths not currently reachable via any in-app navigation (confirmed in Round 5's verification). If a quick unit test on either getter's null-safe behavior is trivial given the existing test setup, add it; if it would require meaningfully new fixture/mocking work disproportionate to the fix's own size, it's fine to skip and say so in the report.

## Full checklist

`flutter analyze --fatal-infos`, `dart format --set-exit-if-changed`, `flutter test` — report the real total from the test runner's own summary line (not a grep), and flag plainly if it differs from the prior round's reported count.
