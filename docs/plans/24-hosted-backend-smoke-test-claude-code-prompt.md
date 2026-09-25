You are working in the Professional-Meetups-Monolith repo, on Shashika's own
machine (this needs real network access to `*.run.app`, which is why it's
running here rather than in a sandboxed session). Follow
`docs/plans/24-hosted-backend-smoke-test.md` in full before running anything —
it explains exactly what's safe to touch on the live hosted backend and why
(the deployed `TEST_OTP_BYPASS_EMAILS`/`.test` fixture mechanism), what NOT to
touch (the two real phone numbers in `TEST_OTP_BYPASS_PHONES`, unless Shashika
is present with the devices), and what's out of scope entirely (Apple/Google/
LinkedIn sign-in, real SMS/email delivery, push-to-device, billing beyond the
stub check).

Target: `https://meetups-backend-k7eklebcwq-el.a.run.app` (Cloud Run,
`meetups-backend`, revision `r31`) → Supabase Postgres (`monolith_db`,
`ap-south-1`). This is the real, live, currently-deployed backend and
database — not local docker-compose. Treat every request as hitting
production.

## Part A — Run the existing smoke-test script, fix only the script if it's wrong

1. The script `smoke-test-hosted-backend.sh` is in Shashika's vault folder —
   ask for its path if it's not already visible to you, or find it under the
   "Professional Meetups Vault" folder. Copy it into
   `backend/scripts/smoke-test-hosted-backend.sh`.
2. `brew install jq` if needed. Run
   `bash backend/scripts/smoke-test-hosted-backend.sh` and capture the full
   output.
3. For every `FAIL`: open `backend/internal/gateway/handlers/handlers.go`
   and `meetups.go`, find the actual handler, and determine whether the
   script's expected status/shape was simply wrong (fix the script's
   `check` call, rerun) or whether the live response genuinely contradicts
   what the handler code says it should do (a real defect — do not patch
   app code for this; report it in full: endpoint, request body sent, exact
   response received, and the specific line(s) of handler code it
   contradicts).
4. Commit the corrected script once it accurately reflects the real API
   (even the fixed version is worth keeping in `backend/scripts/` for future
   deploys).

## Part B — Two-party meetup lifecycle

Using `l3.a@meetups.test` (host) and `l3.b@meetups.test` (participant), both
via `POST /v1/auth/email/login/start` then `/login` with code `123456`, walk
through: create meetup → participant requests to join → host accepts →
both acknowledge the safety checklist → both check in → close/cancel →
ratings/review. Read each endpoint's real request/response shape from
`meetups.go` before calling it (Plan 24 lists the exact endpoint sequence and
the ADRs behind each step — ADR-024 for the safety gate, in particular).
**Clean up**: cancel or close the test meetup at the end so it doesn't sit in
either account's history.

## Part C — Guest signup

`POST /v1/auth/guest/signup` once, confirm a working Level 0 session and that
`GET /v1/users/me` agrees. No cleanup needed — a nameless guest account with
no identifying data is harmless to leave.

## Explicitly do not do

- Do not touch `TEST_OTP_BYPASS_PHONES`'s two real numbers.
- Do not attempt to fake or fabricate an Apple/Google/LinkedIn token to test
  federated sign-in — it's out of scope here (Plan 24 §D explains why and
  what would actually be needed to cover it).
- Do not modify any application code to "fix" a discovered backend defect —
  report it and stop; a production fix needs its own review and redeploy.
- Do not run personal-email or corporate-email *verification* flows against
  the seeded fixture accounts (as opposed to *login*, which Part A already
  covers) — that would overwrite real seed data (`legal_name`,
  `company_name`, etc.) that other testing may depend on staying intact.

## Before you report done

A clear pass/fail table for every check across Parts A–C, in the style of
`docs/plans/03-hardening-pass-completion-report.md`. Separate "script was
wrong, now fixed" from "backend defect found, not fixed, here's exactly
what's wrong" — don't blur the two.
