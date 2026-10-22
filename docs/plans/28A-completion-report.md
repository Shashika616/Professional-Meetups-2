# Plan 28A, completion report

Date: 2026-10-22. Working tree only; nothing committed, deployed, or run
against production or Supabase. Replaces `28A-progress-report.md`, whose
content is carried forward below.

**Every Phase A item is closed with a test that failed before the change
and passes after.** The failing-before output is quoted per item.

## Preconditions and deviations

| Thing | State |
|---|---|
| `CLAUDE.md` | Does not exist in this repository (Plan 25 covers creating it). Everything else on the prompt's read list was read. |
| `docs/plans/28-decisions.md` | Does not exist, so the bracketed defaults stand. **D1 was needed and applied**: one live request per user per meetup; a rejected user cannot re-request; a withdrawn user can. D2–D6 are not reached by Phase A. |
| Migration numbering | The prompt said "next number is 0019". Phase A needed **three**: 0019 (#79), 0020 (#82), 0021 (#78, the SOS audit columns). |
| `.git/index.lock` | 0 bytes, dated 2026-10-08, no git process running. **Not deleted, and no index-writing git command was run** — every before/after capture used file copies. Shashika should clear it before the next commit. |
| Test database | `go test` against local Docker Postgres via `DATABASE_URL`; migrations applied to `monolith_db` and `monolith_db_test` only. |
| Test fixtures | Unchanged. `TEST_OTP_BYPASS_EMAILS` reserved-TLD enforcement and `TEST_OTP_BYPASS_PHONES` allowlisting both still work on Cloud Run, asserted by `TestRefuseGlobalOTPBypassOnCloudRun/leaves_the_scoped_email_allowlist_alone_on_Cloud_Run`. |

## Release notes (required before deploying this branch)

- **Access tokens minted before the `aud` change are rejected after
  deploy.** The blast radius is one access-token TTL (15 minutes); refresh
  tokens are unaffected, so clients recover without a sign-in. Expect a
  burst of refreshes at rollout.
- **`minScale: "1"` and `cpu-throttling: "false"`** change the bill. See
  runbook §7.
- **The release build now fails without `android/key.properties`.** That
  is deliberate; runbook §8 has the keystore steps.
- **Migrations 0019, 0020 and 0021 must be applied before the new image
  serves**, in that order. 0019 and 0020 build the new index before
  dropping the old one, so there is no unprotected window.

## Items

### #77 — background work gets CPU (N-C1, High)

`minScale: "1"` plus `run.googleapis.com/cpu-throttling: "false"` in
`backend/service.yaml` and `docs/deploy/service.yaml.template`, cost
reasoning rewritten in both and in runbook §6/§7. Guarded by
`cmd/monolith/deploy_manifest_test.go`.

Failing before (it caught that `backend/service.yaml` had been missed
while the template was already edited):

```
--- FAIL: TestDeployManifestsKeepBackgroundWorkRunning
    ../../../backend/service.yaml is missing "autoscaling.knative.dev/minScale: \"1\""
    ../../../backend/service.yaml is missing "run.googleapis.com/cpu-throttling: \"false\""
    ../../../backend/service.yaml still sets minScale to 0
```

### #79 — one live request per user per meetup (N-B1, High)

**Migration 0019.** Partial unique index
`(meetup_id, requester_id) WHERE status IN ('pending','accepted')` built
**before** the old `UNIQUE (meetup_id, requester_id, status)` is dropped.
The old key put the STATUS inside the uniqueness, which permits two live
rows in different states and forbids two dead rows in the same one —
both wrong, both reachable.

The down migration **refuses** when duplicate `(meetup, requester,
status)` groups exist, naming the count and an example, because those
rows are legal under 0019 and the old constraint cannot hold them. A
plain `ADD CONSTRAINT` there fails with a bare 23505 that tells whoever
is mid-rollback nothing. Verified both ways on the local database:

```
ERROR: cannot restore UNIQUE (meetup_id, requester_id, status): 1 duplicate
(meetup, requester, status) group(s) exist, e.g. 1111…/3333…/rejected. These
rows are legal under migration 0019 … Resolve the duplicates deliberately
before rolling back, or stay on 0019.
```

**D1 in the service, not the index.** "A rejected user may not re-request"
is a conditional `INSERT … WHERE NOT EXISTS (… status = 'rejected')`.
It cannot be an index: expressing it would mean including `'rejected'`
in the uniqueness, which is precisely the collision 0019 removes. Zero
rows back is reported separately from 23505 because the two want
different words — "the host already said no" versus "you have already
asked".

**23505 → `ErrConflict`** in accept, auto-reject, reject and withdraw via
`conflictIfUniqueViolation`. Unreachable after 0019, kept because "should
be unreachable" is a belief about the schema and the cost of being wrong
is a 500 on the host's accept button.

Tests (`request_uniqueness_integration_test.go`), the four named
sequences plus a concurrency case:

```
--- FAIL: TestRequestUniqueness_RejectAfterReRequest
    re-request after a rejection: error = <nil>, want ErrConflict
--- FAIL: TestRequestUniqueness_WithdrawASecondAcceptance
    second withdraw: … request state changed under us: conflict
--- FAIL: TestRequestUniqueness_AcceptedUserCannotOpenASecondRequest
    second request while accepted: error = <nil>, want ErrConflict
```

`TestRequestUniqueness_FinalSeatAcceptWithARejectedRequesterPresent`
passes under both schemas, because with D1 enforced the rejected user can
no longer hold the second pending row that used to set the trap; it is
kept as the regression guard for the accept path.
`TestRequestUniqueness_ConcurrentFirstRequestsSerialize` runs two real
goroutines under `-race` and fails with "2 of 2 concurrent first requests
succeeded" without the index.

### #82 — one target, one budget (N-A1, Medium)

**Migration 0020.** `target_normalized`, `GENERATED ALWAYS … STORED`, so
it cannot drift from `target` and needs no backfill statement. The
expression is purpose-aware because one rule would break the other:
email lowercases and trims (stripping punctuation would mangle
`foo-bar@x.com`), phone strips spaces, hyphens, brackets and dots. The
new unique index is built before the old one is dropped; expired rows are
deleted first, as the plan allows.

`UpsertVerificationCodeForSignup` now infers `target_normalized`, so a
call site that forgets to normalise lands on the same row rather than
opening a second budget.

**Service layer** normalises at every public entry point — eight methods
— not deeper down, so the value that gets PERSISTED (`users.phone_number`,
`users.personal_email`) is the one that was verified.

**Limiter keys** normalise too, via `normalizeLimiterTarget`, keyed off
the field name the route reads since that is all the middleware knows.

New `identity.NormalizePhone`: strips spaces (including non-breaking),
hyphens, brackets and dots, and **nothing else** — no country-code
guessing, no leading-zero stripping, no rejection. It is a canonicaliser,
not a validator.

```
--- FAIL: TestTargetNormalization_CasingSharesOneCooldown
    resend as "Victim@example.com": error = <nil>, want ErrRateLimited —
    a second spelling bought a second cooldown and a second email
--- FAIL: TestTargetNormalization_CasingSharesOneAttemptBudget
    verification_codes rows after five guesses across three spellings = 1,
    want 0 — each spelling kept its own attempt budget
--- FAIL: TestTargetNormalization_PhoneSpacingSharesOneTarget
    stored target = "+94 77 123 4567", want the normalised "+94771234567"
```

The budget test spends five guesses across three spellings on purpose:
the cap is five per target, so if each spelling kept its own counter
none would reach it (two, two and one) and the row would survive.

### #83 — atomic refresh rotation (N-A2, Medium, confirming #57)

`MarkRefreshTokenReplaced` becomes a conditional `UPDATE … WHERE
replaced_by IS NULL AND revoked_at IS NULL AND expires_at > now()
RETURNING`, `:one`, in the same transaction as the child insert. The
child is inserted first and the parent claimed second, so a concurrent
rotation blocks on the parent's row lock and then matches nothing — its
child insert rolls back with it.

Zero rows returns `ErrRefreshTokenAlreadyRotated`, which the service
treats as reuse and revokes the family, through a
`handleRefreshTokenReuse` helper now called from both the pre-check and
the rotation. **There is no session-revoked event on the bus in this
codebase**, so the plan's "publish the existing signal if one exists"
has nothing to publish; the structured `event: refresh_token_reuse` warn
log is the signal, and the comment says so.

`-race`, five rounds, two real goroutines:

```
--- FAIL: TestRefreshRotation_ConcurrentRefreshesOfOneTokenForkNothing
    round 1: 2 of 2 concurrent refreshes of ONE token succeeded, want
    exactly 1 — the session chain forked
```

The test also asserts the winner's **new** token is dead afterwards,
which is what distinguishes "we rejected the loser" from "we handled the
reuse".

### #78 — SOS cannot hang, and works without a location (N-D1/D2/D3, High)

**End to end optional coordinates.** `optional double` in the proto
(wire-compatible: same field numbers and types, presence bit added),
pointers through the gateway JSON, the gRPC layer, the service and the
audit record. Only a COMPLETE pair counts — half a location is not a
location. Migration 0021 drops `NOT NULL` on `sos_events.latitude/
longitude`, and its down migration refuses rather than back-filling 0,0
into a safety audit trail.

`AlertMessage` says "Location unavailable." rather than omitting the
line: a contact told someone may need help will look for a location, and
silence reads as a truncated message.

**Deadlines.** `DeadlineHttpClient` wraps the auth service's HTTP client
— one override of `BaseClient.send`, which every convenience method
funnels through, rather than seventeen call sites and an eighteenth
written next month without one. 15 s default; `SocketException`,
`http.ClientException` and `TimeoutException` all map to
`AuthNetworkException`, because they are three types from three layers
describing one situation the UI has one thing to say about.

SOS gets 10 s per attempt and **exactly one** retry — the alert is not
idempotent, so this is the smallest number that survives a single lost
packet, not a retry loop.

**The sheet always lands somewhere actionable.** A failed location read
now costs the coordinates and nothing else; a bare `catch` covers
anything that is not an `AuthException` (previously it escaped `_confirm`
and left the sheet spinning on "Getting your location…" during an
emergency); the failure state offers **Retry** first, then **Call
emergency services**, then Close. Success says so when the alert went out
without a location, because the contact was told that too.

```
--- FAIL: no location fix: the alert is still sent, without coordinates
--- FAIL: an unexpected error does not strand the sheet on "sending"
```

Six widget tests cover the plan's five cases plus Retry actually
retrying. Backend: `TestTriggerSOS_SendsWithoutALocationFix` and
`TestAlertMessage` (including "half a location is no location").

### #84 — withdraw guarded on meetup status and window (N-B2, Med-High)

`WithdrawMeetupRequest` joins the meetup and requires
`status IN ('open','full') AND window_end > now()`. The abuse it closes:
rating eligibility is keyed on being an accepted participant, so someone
could attend, behave badly, withdraw afterwards and delete every
co-attendee's ability to say so — while the host kept it through the
separate withdrawal-rating path.

Withdrawing an **accepted** request also enqueues a
`meetups_completed_outbox` row in the same transaction.

### #85 — a full meetup reopens when a seat is freed (N-B3, Medium)

`ReopenMeetupIfSeatFreed`, one conditional `UPDATE` re-checking `'full'`
and recounting, in the withdrawal's transaction under a meetup lock that
transaction now takes in the same order the accept path uses.

Two things had to change, one of them a bug I introduced and caught:
`RETURNING r.*` hands back the row **as written** — status `'withdrawn'`
— so it cannot answer "was this seat occupied?". The first version read
that value and the reopen never fired. It now re-reads the request
`FOR UPDATE` under the meetup lock, which is what the accept path does
and for the same reason.

```
--- FAIL: TestWithdraw_FullMeetupReopens
    status after the seat was freed = "full", want "open"
    request to join the reopened meetup: meetup … is not open: conflict
--- FAIL: TestWithdraw_RefusedOnceTheMeetupIsOver/the_window_has_passed
    withdraw after the meetup ended: error = <nil>, want ErrConflict
--- FAIL: TestWithdraw_RefusedOnceTheMeetupIsOver/the_host_cancelled_it
    withdraw from a cancelled meetup: error = <nil>, want ErrConflict
--- FAIL: TestWithdraw_SchedulesCompletedRecompute
    withdrawing an accepted request scheduled no meetups_completed recompute
```

### #86 — concurrent raters of one person (N-B4, Medium)

`pg_advisory_xact_lock(2, hashtext(rated_user_id))` first in both rating
transactions. The two-argument form puts it in a different lock space
from `LockUserSchedule`'s single-argument form, so being rated and
scheduling cannot block each other.

The review path locks **every** rated participant up front **in sorted
order** — load-bearing, because two reviewers of one meetup rate the same
people, the lists arrive in client order, and locking in list order lets
each hold what the other wants.

```
--- FAIL: TestSubmitRating_ConcurrentRatersOfOnePersonAgreeOnTheCount
    round 1: highest published count = 1, want 2 — the second rater
    computed an aggregate that did not include the first
```

### #92 — test-bypass and sender guard-rails (N-A6, N-A9, Low)

- **Global bypass refused on Cloud Run.** `ALLOW_TEST_OTP_BYPASS=true`
  with `K_SERVICE` set is a startup failure. Only the global flag; the
  scoped allowlists are untouched and a test asserts they keep working.
- **No real senders, no startup.** On Cloud Run, missing email or SMS
  credentials refuse startup, naming the variables. The logging fallback
  is a silent outage with a security twist: every send "succeeds",
  nobody receives anything, and the codes go to the logs.

  **The email half is an OR, and the deployed service passes it on Gmail
  alone.** `backend/service.yaml` declares `GMAIL_ADDRESS`,
  `GMAIL_APP_PASSWORD` and all three `TWILIO_*`, and sets no `RESEND_*`
  at all — a supported combination, not a gap.
  `TestRequireRealSendersInProduction_AcceptsTheDeployedManifest` reads
  the real manifest, mirrors exactly the variables it declares into a
  config and asserts the guard accepts it, so a guard meant to catch a
  misconfigured deploy can never become the reason a correct one will
  not start. If someone tightens it to require Resend, or drops
  `GMAIL_APP_PASSWORD` from the manifest, that fails in CI rather than
  on the next deploy.
  `TestRefuseGlobalOTPBypassOnCloudRun_AcceptsTheDeployedManifest` does
  the same for the bypass guard, reading the `ALLOW_TEST_OTP_BYPASS`
  value the manifest actually sets (`"false"`) rather than assuming it.
- **Twilio bodies redacted.** Twilio's error payloads echo the request —
  destination number, often the message body (an OTP, or an SOS naming a
  real person and their location). The error now carries the HTTP status
  and Twilio's numeric error code only. `twilioErrorCode` reads it from a
  bounded reader and returns 0 on anything unparseable.
- **Phone bypass list validated and normalised.** Now normalised with
  `identity.NormalizePhone` — a real bug after #82, since the entry and
  the lookup key would otherwise be normalised differently and the bypass
  would silently stop matching. `ValidateTestOTPBypassPhones` reports
  non-E.164 entries, logged at startup. It reports rather than refuses: a
  typo in a test convenience should not take the service down.

### #93 — `aud` on access tokens (N-A7, Low)

Signer stamps `aud: professional-connections-api`; verifier requires it.
One existing rotation test hand-built a token without it and was updated
— it tests `kid` fallback, and the audience rejection it would otherwise
have asserted by accident is now asserted deliberately.

```
--- FAIL: TestSign_StampsTheAudience
    Audience = [], want [professional-connections-api]
--- FAIL: TestVerify_RejectsTokenWithoutAudience
    a token with no audience verified as an access token
--- FAIL: TestVerify_RejectsTokenForAnotherAudience
    a token minted for another audience verified as an access token
```

### #55 — Android release signing (V-5, High)

`key.properties` drives a real `release` signing config; the release
build **fails** without it instead of falling back to the debug keystore.
Gated on the requested Gradle tasks: `buildTypes { release { } }` is
configured on every invocation, so an unconditional throw would have
broken `flutter run` on every machine without a keystore.

Verified by invocation — Gradle configuration is not reachable from
`flutter test`:

```
$ flutter build apk --debug    → ✓ Built build/app/outputs/flutter-apk/app-debug.apk
$ flutter build apk --release  → FAILURE: Release build needs android/key.properties …
```

Runbook §8 covers creating the keystore, why it cannot be recovered, and
how to verify the signer.

### #94 — client hardening (N-D4, N-D6, N-D7, N-D10)

- `allowBackup="false"`, `fullBackupContent="false"` and
  `res/xml/data_extraction_rules.xml` refusing both cloud backup and
  device-to-device transfer (allowBackup alone no longer covers D2D on
  API 31+).
- `INTERNET` declared in the **main** manifest. It was arriving through a
  plugin's merged manifest — an accident of the dependency list that
  would have silently broken release networking the day that plugin was
  dropped.
- `--obfuscate --split-debug-info` on both prod targets in `build.sh`,
  with the symbol directory called out: a stack trace from an obfuscated
  binary is unreadable without the matching symbols, and "matching" means
  that exact build. Debug and emulator targets deliberately get neither.
- `debugLog` gates every `debugPrint` behind `kDebugMode`. `debugPrint`
  reads as debug-only and is not — it survives release builds and writes
  to the platform log, where on Android any app with `READ_LOGS` can
  read it. Every call site already knew, which is the problem: that
  discipline works until the sixth call site is added without reading the
  other five. No raw `debugPrint` call sites remain in `lib/`.

## Gates

```
backend:  go vet ./...                      clean
          gofmt -l ./cmd ./internal         clean
          go test -race ./...               all packages pass
frontend: flutter analyze                   No issues found
          dart format --set-exit-if-changed clean
          flutter test                      760 passed
```

Backend test count grew by the integration and race tests above; Flutter
by 760 − 753 = 7 (six SOS failure-path tests and `debug_log_test.dart`).

## Only Shashika can do

- Create the Android upload keystore and `frontend/android/key.properties`
  (runbook §8). Until then `flutter build apk --release` fails by design.
- Clear the stale `.git/index.lock`.
- Apply migrations 0019, 0020, 0021 in order, before the new image serves.
- Deploy the manifest to put `minScale: "1"` and `cpu-throttling: "false"`
  into effect.
- Nothing to change for senders: the deployed service already has Gmail
  and Twilio, which is what the new startup guard requires. Resend stays
  unconfigured and that is fine (the email check is Gmail **or** Resend).
  Two tests pin the real manifest against both new startup guards.
- Decide release-note wording for the `aud` cutover.
