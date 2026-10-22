# Claude Code prompt: continue Plan 28 (Phase A remainder, then B and C)

Read first: `docs/plans/28-full-review-remediation.md`, `docs/plans/28-full-review-remediation-claude-code-prompt.md` (all hard rules still apply), `docs/plans/28A-progress-report.md`, `docs/security-review-2026-10-21.md`, `TESTING-NOTES.md`. `CLAUDE.md` does not exist in this repo; do not stop for it (plan 25 covers creating it separately).

State: Phase A items #77, #84, #85, #86, #93 (aud), #92 (global-bypass refusal), #55 and #94 (signing, backups, INTERNET) are done with tests. Do not redo them.

## Remaining Phase A, in this order

1. **#79 (migration 0019), D1 default:** one live request per user per meetup; a rejected user cannot re-request; a withdrawn user can. Build the partial unique index `(meetup_id, requester_id) WHERE status IN ('pending','accepted')` before dropping the old constraint; guarded down migration. Tests for the four sequences: reject after a re-request, final-seat accept with a previously rejected pending user, withdraw of a second acceptance, an accepted user creating a second pending row. Map 23505 to `ErrConflict` in accept, reject, withdraw.
2. **#82:** normalise email and phone at the top of every target-keyed start and complete path and in the limiter key; migration with normalised target column, backfill, then unique index. Test that `Victim@x.com` and `victim@x.com` share one attempt budget, one cooldown and one limiter bucket.
3. **#83:** atomic refresh rotation (single conditional `UPDATE ... RETURNING` in the same transaction as the child insert, zero rows means reuse and revoke the family). `-race` test with concurrent refreshes of one token: exactly one succeeds.
4. **#78:** SOS and auth HTTP: 15 s wrapper (SOS 10 s plus one retry) mapping network errors to `AuthNetworkException`; location optional end to end (proto regeneration, gateway, service, SMS and email text "location unavailable"); every error in `_confirm()` ends in a failure state with Retry and Call emergency services. Flutter tests: offline, timeout, no location, 5xx, session expired.
5. **Rest of #92:** refuse startup in production without real SMS and email senders; redact targets and Twilio response bodies in logs; validate the phone bypass list format. **Rest of #94:** `kDebugMode` gate on `debugPrint`; obfuscation flags in `build.sh` and CI prod targets.

Keep the bypass guarantees: `TEST_OTP_BYPASS_EMAILS` and `_PHONES` keep working on Cloud Run (the existing test must stay green).

## Then

Write `28A-completion-report.md` only when every Phase A item has a passing test (replace the progress report; keep its content). Include a release-notes section: tokens minted before the `aud` change are rejected after deploy (one 15-minute TTL, refresh still works). Then proceed to Phase B and Phase C exactly as in the Plan 28 prompt, stopping after each with its report.

## Housekeeping to report, not to do

`.git/index.lock` (0 bytes, 2026-10-08) is stale; do not delete it and do not run index-writing git commands. Say so in the report so Shashika can clear it.
