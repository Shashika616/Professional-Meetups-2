# Plan 24 — Verify all functionality against the hosted Cloud Run + Supabase backend

## Context

Shashika asked to check that everything actually works against the real
deployed stack — Cloud Run service `meetups-backend` (revision `r31`,
`https://meetups-backend-k7eklebcwq-el.a.run.app`, `asia-south1`) backed by
Supabase Postgres (`monolith_db`, `ap-south-1`), per `docs/deploy/gcp-runbook.md`.
This is a live-environment verification task, not a code-review task.

I can't run this myself — my sandbox's network is allowlisted and doesn't
reach `*.run.app` — so this needs to run from your machine, where Claude Code
has normal network access.

**This is safe to run.** The deployed service already has two narrow,
documented test-only mechanisms enabled specifically for this
(`TESTING-NOTES.md`): `TEST_OTP_BYPASS_EMAILS` accepts the fixed code `123456`
for eight seeded `.test`-domain fixture accounts (`l0.a@meetups.test` through
`l3.b@meetups.test`, one pair per trust level 0–3, `backend/testdata/seed-test-users.sql`),
and `TEST_OTP_BYPASS_PHONES` does the same for two specific real device
numbers. Testing with the email fixtures touches no real user, no real
inbox, and no real SMS — stay on those and skip the phone numbers unless
Shashika is present with the physical devices to receive the SMS.

I already wrote and grounded a first-pass smoke-test script
(`smoke-test-hosted-backend.sh`, saved to the vault) against the actual
handler code in `backend/internal/gateway/handlers/handlers.go` and
`meetups.go` — request/response shapes are real, not guessed — but I have
never executed it, so treat its assumptions as unverified until this run
proves them right or wrong.

## What to do

### Part A — Run the existing script as-is

1. Copy the script Shashika has (`smoke-test-hosted-backend.sh`, in the
   vault folder) into `backend/scripts/smoke-test-hosted-backend.sh` in this
   repo (so it's versioned alongside `backend/scripts/backup-database.sh`).
2. Confirm `curl` and `jq` are available (`brew install jq` if not).
3. Run it: `bash backend/scripts/smoke-test-hosted-backend.sh`. Paste the
   full raw output in your report — don't summarize it away.
4. For every `FAIL` line: read the actual response body it printed and
   determine whether the script's *expectation* was wrong (e.g. I assumed a
   200 where the real handler correctly returns something else — fix the
   script, don't touch app code) or whether the *backend* is actually broken
   (a real defect — stop, do not attempt a fix, report it precisely: which
   endpoint, what was sent, what came back, what `handlers.go`/`meetups.go`
   says should happen instead).

### Part B — Extend to the two-party meetup lifecycle (the script only covers one account acting alone)

Using `l3.a@meetups.test` as host and `l3.b@meetups.test` as a second
participant (both code `123456`), chain through the parts of the meetup
lifecycle that need two accounts and which Part A's script cannot exercise
alone:

1. Host (`l3.a`) creates a meetup (reuse Part A's create-meetup call, or a
   fresh window if that one hit the one-meetup-at-a-time 409).
2. Participant (`l3.b`) calls `POST /v1/meetups/{id}/requests` (request to
   join).
3. Host calls `GET /v1/meetups/{id}/requests` (should show the pending
   request) then `POST /v1/meetups/requests/{id}/respond` to accept it.
4. Both accounts call `GET /v1/meetups/{id}/safety` and
   `POST /v1/meetups/{id}/safety/checklist` (Safety Gate, ADR-024).
5. `GET /v1/meetups/{id}/participants` — confirms both show up.
6. `POST /v1/meetups/{id}/safety/check-in` for both.
7. Close the loop: `POST /v1/meetups/{id}/close` (or wait/skip if it's
   time-gated — check `closeMeetup`'s actual precondition in the code rather
   than guessing), then `GET /v1/meetups/{id}/ratings/ratable` and
   `POST /v1/meetups/{id}/ratings` for both, and
   `POST /v1/meetups/{id}/review` / `GET /v1/meetups/{id}/review`.
8. **Clean up afterward**: cancel or close whatever test meetup this created
   (`POST /v1/meetups/{id}/cancel`) if it's still open at the end, so a stray
   test meetup doesn't sit in these two accounts' history indefinitely.

Read each handler's actual request/response shape from `meetups.go` before
calling it — don't assume the shape from the names alone; the create-meetup
shape in Part A's script is confirmed, the rest aren't.

### Part C — Guest signup (the one flow no fixture account represents)

`POST /v1/auth/guest/signup` creates a brand-new anonymous account — real
signup path, not a fixture. Call it once, confirm it returns a working
session (Level 0, `is_guest: true`), and confirm `GET /v1/users/me` reflects
that. This is throwaway data (a guest account with nothing identifying it) —
no cleanup needed.

### Part D — What this deliberately does not test, and why

- **Apple/Google/LinkedIn sign-in** — these need a real provider-issued
  `id_token`/OAuth code, which only the real mobile app (or a browser OAuth
  flow, for LinkedIn) can produce. Not testable via curl. If you want this
  covered, it needs the actual Flutter app pointed at the hosted backend
  (`frontend/build.sh`'s `PROD_URL`) run on a simulator/device — flag this
  back rather than trying to fake a token.
- **Real phone/SMS OTP and real email delivery (Twilio/Gmail)** — already
  proven working historically (that's *why* `TEST_OTP_BYPASS_PHONES` exists,
  per `TESTING-NOTES.md`'s own account of the Sri Lanka carrier issue); this
  smoke test is about the backend's logic and its connection to Supabase,
  not re-proving SMS/email deliverability.
- **Push notifications actually arriving on a device** — the notification
  outbox/dispatch logic can be checked via `GET /v1/notifications`, but
  confirming an FCM push actually lands needs a real device with the app
  installed and signed in.
- **Billing/IAP purchase verification** — confirmed as a clean 503 stub
  (Part A, checks 15–16); there is no real billing module yet to test beyond
  that (ADR-031/Slice B status — check `docs/00-project/action-tracker.md`
  if unsure whether this has since changed).

### Before you report done

Produce a clear pass/fail table covering every check in Parts A–C, in the
same style as this repo's other completion reports (see
`docs/plans/03-hardening-pass-completion-report.md` for the expected shape).
For anything that failed, state plainly whether it's a script bug (fixed) or
a real backend/Supabase defect (reported, not fixed) — do not blur the two
together, and do not attempt to fix a real backend defect without checking
back first, since a live-environment fix needs its own reviewed change and
redeploy, not a same-session patch.
