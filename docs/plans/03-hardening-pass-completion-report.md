# Hardening pass — completion report

All six sections (A–F) of `docs/plans/03-hardening-pass.md` are done,
including every item marked MINOR. Reported in the document's own A/B/C/D/E/F
grouping, with the deviations and findings called out rather than absorbed.

## Verification output (real, not claimed)

```
$ go build ./...
PASS

$ go vet ./...
PASS

$ golangci-lint run ./...          # v2.12.2
0 issues.

$ go test -race -coverprofile=coverage.out -covermode=atomic ./...
ok  	.../internal/eventbus                  coverage: 96.2%
ok  	.../internal/gateway/handlers          coverage: 52.8%
ok  	.../internal/gateway/middleware        coverage: 85.3%
ok  	.../internal/modules/auth              coverage: 75.2%
ok  	.../internal/modules/auth/email        coverage: 53.6%
ok  	.../internal/modules/auth/identity     coverage: 72.2%
ok  	.../internal/modules/auth/linkedin     coverage: 84.4%
ok  	.../internal/modules/auth/repository   coverage:  5.2%
ok  	.../internal/modules/auth/sms          coverage: 80.0%
ok  	.../internal/modules/meetup            coverage: 74.9%
ok  	.../internal/modules/notification      coverage: 66.5%
ok  	.../internal/platform/apperror         coverage: 96.2%
ok  	.../internal/platform/breaker          coverage: 100.0%
ok  	.../internal/platform/db               coverage: 24.3%
ok  	.../internal/platform/geo              coverage: 100.0%
ok  	.../internal/platform/geocoding        coverage: 97.5%
ok  	.../internal/platform/internalauth     coverage: 100.0%
ok  	.../internal/platform/jwt              coverage: 82.9%
ok  	.../internal/platform/logging          coverage: 84.3%
ok  	.../internal/platform/outbox           coverage: 75.6%
ok  	.../internal/platform/ratelimit        coverage: 96.2%
```

**679 test cases pass. 0 failures. 0 skips.** (Up from 514 at the end of
Phase 2. The count includes subtests; the skip count is 0 because Postgres
was reachable for every integration test — with the database down, the
integration tests skip rather than fail, by design.)

Concurrency-sensitive tests were additionally run `-count=5 -race`, and the
**full suite was run five times consecutively under `-race` with zero
failures** — the check that exposed, and then confirmed the fix for, the test
isolation problem described under "Findings not in the plan" below.

Integration tests run against their own database (`monolith_db_test`, created
automatically), never the one a live monolith is attached to. That is a
correctness requirement, not hygiene — see finding 3.

`auth/repository`'s 5.2% is a per-package artifact, not a coverage gap: that
package is exercised almost entirely by the `auth` package's integration
tests, and Go's default per-package coverage cannot attribute cross-package
execution. The same applies to `meetup/repository` and `grpcapi`.

---

## §A — Architecture-level

### A1. Event-bus panic recovery + failure observability — DONE

`Publish` now invokes each handler through `invoke`, which has its own
`recover()`, mirroring `logging.RecoveryUnaryServerInterceptor` and
`middleware.Recover` rather than inventing a pattern. Every swallowed failure
— returned error or recovered panic — is logged at ERROR with a fixed,
greppable `event=handler_failure` field plus a `kind` of `error` or `panic`,
and increments `event_handler_failure_total{topic,kind}`, exposed at
`/metrics`.

The accepted commit-then-crash data-loss window is now stated plainly in
`internal/eventbus/bus.go`'s package doc, in the terms someone debugging "why
didn't this user get notified" would actually need — including which topic is
deliberately *not* on the bus any more, and why.

**Proof** (`internal/eventbus/recovery_test.go`, 5 tests): a panicking handler
does not reach the publisher; a panic in one handler does not stop the
handlers registered after it; the panic is counted under `kind="panic"` and
distinguishable from `kind="error"`; the log line is valid JSON carrying the
fixed field and a stack trace pointing at the bus.

### A2. Rotatable gateway↔monolith shared secret — DONE

The server interceptor takes a *set* of accepted secrets;
`INTERNAL_GRPC_SHARED_SECRET` may now be a comma-separated list. The client
stays single-valued deliberately — the overlap belongs on the accepting side,
because a client holding two secrets would have to guess which one a given
server honours.

The comparison loop is constant-time **and non-short-circuiting**: it does not
`return` on first match, so the work done never depends on which secret
matched or how far through the list it was.

`ParseSecrets` refuses the configurations that would quietly weaken the check
— an empty value, an empty element from a stray or trailing comma (which
would make `""` a valid secret and authenticate every caller), and duplicates
(harmless, but always a rotation that did not actually happen).

**Proof** (`internalauth_test.go`, 3 new tests + 9 table cases): both old and
new secrets are accepted during the overlap; a secret removed from the set
stops working; an empty presented value never matches; every malformed
configuration is rejected.

The three-deploy rotation procedure is documented in
`backend/secrets/README.md`.

### A3. Rotatable JWT signing key — DONE

Access tokens now carry a `kid` header. The verifier holds the current public
key plus any number of previous ones and routes each token to the key that
signed it.

**Key ids are derived, never configured** — a truncated SHA-256 over the key's
PKIX DER (`internal/platform/jwt/kid.go`). An operator-assigned id would be a
name to keep in sync across two processes and a deploy pipeline, and a
mismatched name fails exactly like a wrong key while looking like a working
config. Deriving it from the key material means signer and verifier cannot
disagree, and adding a previous key is one file path and nothing else.

An unknown `kid` is an error, not a fallback to trying every key. A token with
*no* `kid` falls back to the current key — the documented upgrade path for
tokens minted before this shipped, valid for at most the 15-minute TTL.

**Proof** (`jwt/rotation_test.go`, 6 tests): a token signed by the previous key
verifies during the overlap; a fully retired key stops working and says why; a
token signed by an unknown key but *relabelled* with a trusted `kid` is
rejected (the obvious attack on any kid scheme); configuring the same key as
both current and previous fails startup; a pre-rotation token with no header
still verifies.

Refresh tokens are unaffected — they were never JWTs (ADR-001's §6
correction), so a signing-key rotation cannot end a session.

### A4. Rate limiter seam — DONE

`ratelimit.Limiter` is now a one-method interface; the concrete type is
`InMemory`. Both consumers (`handlers.WithRateLimiter`, `middleware.RateLimit`,
`middleware.UserKeyedRateLimit`) code against the interface. `Close` is
deliberately *not* on it — lifecycle belongs to whoever constructed the
concrete type, not to every middleware that calls `Allow`.

**Proof**: a test substitutes an alternative implementation and confirms it is
the one consulted, which is the actual property (that the seam admits a second
implementation), not merely that the current one compiles against it.

---

## §B — Auth module

### B1. Refresh-token reuse revokes the session family — DONE

The reuse-detected branch now calls `RevokeAllForUser` before rejecting, and
logs a deliberately loud `refresh_token_reuse` line with the user id and the
number of sessions ended — never the token or its hash.

A revocation failure is logged, not propagated: the caller must still be
rejected, and returning the revocation's error would turn a definite "no" into
an ambiguous 500 a client (or an attacker) would simply retry.

**Proof** (`refresh_reuse_test.go`, 3 tests). The assertion the item asked for
is the second one: after A is rotated to B and A is then replayed, **token B —
the legitimate, currently-valid token — is also revoked**, and is unusable end
to end afterwards. Also pinned: a legitimate rotation does *not* trigger
revocation; an unrelated user's session survives (so one stolen token cannot
become a denial of service against everyone).

**Control run** — with the fix removed, the test fails on exactly that
assertion:

```
--- FAIL: TestRefreshSession_ReuseRevokesTheWholeSessionFamily
    token B — the legitimately rotated, currently-valid token — was NOT
    revoked after a replay of token A was detected; only the replayed
    request was rejected, leaving the attacker's chain and the victim's
    session both live
```

### B2. Bounded DB and RPC execution — DONE (both, as recommended)

- **`statement_timeout = 10s`** on every pooled connection, set via
  `RuntimeParams` rather than string-appended to `DATABASE_URL` — an operator
  cannot remove it by editing the URL, and there is no `?`-vs-`&` bug to
  introduce.
- **`DeadlineUnaryServerInterceptor`** wraps every RPC at 10s, matching the
  gateway's `ReadTimeout`/`WriteTimeout` posture. It takes the *minimum* of
  the caller's deadline and its own: a caller asking for less gets less, and a
  caller asking for an hour does not get it. That is what makes it a
  server-side guarantee rather than a suggestion.

The two are complementary, not redundant: `statement_timeout` bounds one
statement and is enforced by Postgres itself (so it does not depend on this
process still being healthy enough to issue a cancel); the interceptor bounds
the whole handler, which is the only thing that catches a method running six
fast queries and a slow HTTP call.

**Proof**, including real evidence against Postgres:

```
statement_timeout_integration_test.go: pooled connections report
    statement_timeout = "10s" (configured: 10s)
statement_timeout_integration_test.go: Postgres aborted the runaway query
    after 256.13ms: ERROR: canceling statement due to statement timeout
    (SQLSTATE 57014)
```

Plus 4 interceptor tests: an unbounded handler is bounded; the handler's own
context carries the deadline (which is what lets pgx cancel an in-flight
query); a stricter caller deadline is preserved; a generous one is capped.

### B3. `auth.refresh_tokens` retention sweep — DONE

Hourly ctx-scoped goroutine, same shape as every other background loop.
Deletes rows that are revoked, or expired longer ago than a 7-day retention
window kept deliberately so a recent expiry is still inspectable while
debugging a "why was I signed out" report. Batched at 1000 rows and capped at
50 batches per tick, so no single statement holds a long lock — which matters
most on the first run, when the backlog is every dead row ever created.

**Proof** (3 integration tests): with all four states seeded, exactly the two
eligible rows are deleted and the recently-expired and live ones survive —
**and the live session still works end to end after the sweep**, which is the
assertion that actually protects users. Also: a 1200-row backlog is fully
drained by looping (not truncated at the batch size), a second run deletes
nothing, and a cancelled context ends the sweep cleanly.

---

## §C — Meetup module

### C1. `(0,0)` rejected — DONE

`geo.ValidateLatLng` now rejects exactly `(0,0)` with its own distinct error,
and also rejects infinities. The error deliberately does not say "out of
range", because 0 *is* in range and that message would send whoever reads it
looking in the wrong place — the real cause is upstream (a denied location
permission, a fix never acquired).

**Proof**: 17 table cases including the ones that must still pass — a meetup
on the equator, one on the prime meridian, and one a ten-thousandth of a
degree off null island. Plus a test that the message does not misreport it as
a range error.

### C2. Lifecycle poller safe under concurrency — DONE, and larger than asked

Adding `FOR UPDATE SKIP LOCKED` to the existing selection would not have been
enough. The gap that matters is between reading candidates and recording that
they were handled — the notifications go out inside it. Both sweeps are now a
single claiming `UPDATE ... RETURNING` that sets the de-dup guard in the same
statement that selects the rows (with `FOR UPDATE SKIP LOCKED` in the
subquery), and queues the notifications in that same transaction.

**Proof** (`lifecycle_concurrency_integration_test.go`, the two-concurrent-ticks
test the item asked for by name): two sweeps racing over 12 overlapping
candidates close exactly 12 meetups and queue exactly 12 notifications.

**And a control that proves the test is not vacuous** — the pre-fix
select-then-act algorithm, run under the same forced overlap:

```
CONTROL: the pre-fix select-then-act algorithm sent 24 notifications for
12 meetups — 12 duplicate pushes.
```

The control also confirms why this was invisible before: double-*closing* was
already prevented by the UPDATE's own WHERE clause, so the meetup state stayed
correct while every participant was told twice.

### C3. Backfill CLIs — DONE, with one substantive improvement over the source

`cmd/backfill-user-display-cache` and `cmd/backfill-user-location-cache`,
both with `--dry-run` and `--batch-size`.

**Deviation from the source, deliberate**: they take one `DATABASE_URL`, not
`SOURCE_DATABASE_URL`/`DEST_DATABASE_URL`. The source needed two because those
were genuinely separate databases, and its own comments flagged a "closing
window" where both had to stay mutually reachable. Here there is one database
with a schema per module, so that entire caveat is gone. The cross-schema read
exists only in these operator tools; the meetup module still never reads
`auth.users` at request time.

**A real bug in the source, not ported**: the source's *display*-cache backfill
wrote `updated_at = now()` with an unconditional `DO UPDATE`, so running it
against a live system could overwrite a cache row a newer profile-update event
had already applied — silently reverting a user's just-changed name. (Its
location-cache sibling did carry the guard; only that one lacked it.) This
port writes the row's own `auth.users.updated_at` and applies the same
ordering guard the live consumer uses.

**Proof** (3 integration tests, running the commands as real processes via
`go run`, because a backfill's likeliest failure is a wrong env var or a
drifted build, not a wrong predicate): gaps are filled, stale rows corrected,
and **a row a newer live event already updated is left untouched**; `--dry-run`
writes nothing; only users with a recorded location are seeded.

```
backfill-user-display-cache: read 3 users, applied 2, skipped 1 already-newer rows
```

### C4. Fast unit tests for DB-independent logic — DONE

`internal/modules/meetup/pure_logic_test.go` adds 9 tests / ~50 table cases
over `redactForViewer`, the validators (capacity, window ordering, free-text
length, lat/lng, intent) and `isPlaceholderLocationLabel`. Purely additive —
the integration tests are unchanged. `trustgate.go` and `cursor.go` already
had fast unit coverage from Phase 2 (8 tests), so they needed nothing.

The redaction tests are the security-relevant ones: they assert that *every*
identifying field is nulled below the trust floor (a partial redaction that
left raw coordinates readable would defeat the gate entirely), that nothing is
over-redacted at or above it, and — guarding the exact drift the code's own
comment warns about — that redaction uses the *same* floor as the join gate,
so a meetup can never be visible-but-unjoinable or hidden-but-joinable.

---

## §D — Operational readiness

### D1. Monolith health check + `service_healthy` gating — DONE

The standard `grpc_health_v1` service is registered on the monolith and marked
`SERVING` only once the listener is actually accepting — announcing readiness
before it is true is the exact failure this removes. On shutdown it is marked
down *before* `GracefulStop`, so watchers stop sending work while in-flight
calls drain.

The Compose healthcheck runs `/monolith -healthcheck`, a mode of the same
binary. The runtime image is distroless — no shell, no curl — and the usual
answer (COPY in `grpc-health-probe`) means another third-party artifact to
pin, verify and patch for something this binary already contains. The probe
authenticates like any other caller; the health service sits behind the same
interceptor chain deliberately, since an exemption list is a place for
mistakes.

`gateway` now depends on `condition: service_healthy`.

**Proof — real `docker compose up` ordering**:

```
Container ...-monolith-1  Starting
Container ...-monolith-1  Started
Container ...-monolith-1  Waiting
Container ...-monolith-1  Healthy
Container ...-gateway-1   Starting
```

### D2. Resource limits — DONE

`mem_limit`/`cpus` on all three services (postgres 2g/2.0, monolith 1g/2.0,
gateway 512m/1.0). Generous rather than tuned — the point is that a ceiling
exists, so a leak degrades one container instead of the host.

### D3. `/healthz`, `/readyz`, `/metrics` — DONE

Mounted outside the `/v1` surface and outside authentication (a probe that
needs a bearer token is a probe that cannot run).

`/healthz` is **liveness** and deliberately never consults the monolith: a
monolith outage answering it with a failure would get every gateway replica
restarted, turning a recoverable downstream problem into a full one.
`/readyz` is **readiness** and does check, via the monolith's gRPC health
service, because a gateway that cannot reach it can serve nothing but errors.
Its failure reason is generic on purpose — the endpoint is unauthenticated and
the underlying error names internal hostnames and ports.

**Proof — real endpoints against the running stack, including the negative
case**:

```
$ curl localhost:8080/healthz        {"status":"ok"}                     200
$ curl localhost:8080/readyz         {"status":"ok"}                     200

# with the monolith stopped:
$ curl localhost:8080/healthz        {"status":"ok"}                     200
$ curl localhost:8080/readyz  {"reason":"monolith is not reachable",...} 503

# after restarting it:
$ curl localhost:8080/readyz         {"status":"ok"}                     200
```

`/metrics` exposes per-route HTTP counts/latencies, per-method gRPC
counts/latencies, §A1's handler-failure counter, the outbox counters, and Go
runtime/process metrics:

```
http_requests_total{method="GET",route="GET /healthz",status="2xx"} 3
http_request_duration_seconds_count{method="GET",route="GET /readyz"} 1
notification_outbox_delivered_total 0
notification_outbox_pending 0
go_goroutines 16
```

Note the label is the **route pattern** (`GET /healthz`), never the raw path.
Labelling by `r.URL.Path` would create a series per meetup id and per cursor —
an unbounded label set fed directly by request traffic, which is both the
standard way to melt a Prometheus server and a way to publish object
identifiers into a metrics store. Unmatched requests bucket under a single
`unmatched` label for the same reason.

### D4. `.dockerignore` — DONE

Excludes `secrets/`, `.env*`, `.git/`, `*.md`, coverage output and editor
noise.

**Proof — verified rather than assumed.** A canary key was placed in
`secrets/` and the build stage inspected directly:

```
$ echo "FAKE-PRIVATE-KEY-CANARY" > secrets/canary.pem
$ docker build --target build -t context-check:local .
$ docker run --rm context-check:local ls /workspace/secrets
ls: /workspace/secrets: No such file or directory
```

CI now asserts the same thing on every run.

### D5. CI builds both images — DONE

A parallel `docker-build` job builds both Dockerfiles (no push), then
**smoke-tests both entrypoints** — a successful build does not prove the
`ENTRYPOINT` runs the binary. Both were verified locally:

```
$ docker run --rm pm-monolith:local
{"severity":"ERROR","error":"config: required environment variable MONOLITH_PORT is not set"}
$ docker run --rm pm-gateway:local
{"severity":"ERROR","error":"load config: config: required environment variable PORT is not set"}
```

Reaching config validation is what confirms the image is wired correctly.

### D6. Coverage in CI — DONE

`go test -race -coverprofile=coverage.out -covermode=atomic ./...`, with the
profile and an HTML report uploaded as artifacts (14-day retention) and a
`go tool cover -func` summary line in the log.

`-race` was added alongside, and is not optional here: this backend now runs
four concurrent background loops beside request handling, and several tests
deliberately exercise concurrent claimers.

No threshold gate yet — deliberately, since there is now a baseline to set one
from and picking a number before having one is arbitrary.

### D7. Bounded `GracefulStop` — DONE

`GracefulStop` runs in a goroutine raced against a 10s timer, falling back to
`Stop()` and logging a WARN. Matches the gateway's existing posture. Unbounded
`GracefulStop` waits for *every* in-flight RPC, so one stuck call held
shutdown open until the orchestrator's patience ran out and SIGKILLed the
process mid-write instead.

---

## §E — Notification module

### E1/E2/E3. Sender ported and wired — DONE

`internal/modules/notification` holds `Sender`, `FCMPushSender` and
`LoggingPushSender`, ported from
`services/notification-dispatch/internal/notifications`. No schema, no
repository — same as the source's service. `cloud.google.com/go/auth v0.20.0`
(the version already proven in the source) added to `go.mod`.

Env-var-gated selection at startup, logged at INFO (`FIREBASE_SERVICE_ACCOUNT_JSON`
empty is a normal local-dev state, not a bypass). One deliberate difference
from the source's pattern: a credential that is *present but unusable* fails
the process at startup rather than falling back — an environment configured to
send notifications that silently logs them instead is a failure nobody notices
until users report missing notifications.

`docker-compose.yml` and `.env.example` carry the real entry.

**Two improvements over the source, both security-relevant:**

1. **The source leaks device tokens into errors.** Its `send` returns FCM's raw
   response body on a non-200, and FCM echoes the offending registration token
   back inside `INVALID_ARGUMENT` messages. This port surfaces only the status
   code and FCM's own PII-free classification. A device token is a bearer
   credential for pushing to someone's phone, and logs are shipped and indexed
   far more widely than the database is.
2. **Bounded concurrency** replaces the sequential per-token loop (§E2b).

### E2b. Circuit breaker + bounded concurrency — DONE, inside §F4's `process`

**Breaker**: `internal/platform/breaker` wraps the batch send, using the SOS
breaker's own constants (5 failures / 30s reset) — same class of dependency,
values already reasoned about here, so keeping them identical was deliberate.
It wraps the *batch*, not each token: the thing being protected is "FCM as a
dependency", and its state should track whether FCM works, not how many
devices happened to be in one row.

**Proof** (4 tests): the breaker trips after exactly the threshold and then
**stops calling the sender entirely** (the cross-call memory that makes it a
breaker rather than a retry policy); a row skipped because the breaker was open
is classified retryable, never dead-lettered (an FCM outage must not discard
notifications); and a batch with *any* success does not trip it, because the
dependency is evidently up.

**Bounded concurrency**: a worker pool of 10, with a 30s batch deadline.

**Proof** — a 500-recipient batch (the nearby-notify cap) against a 20ms fake:

```
500 recipients delivered in 1.16s with peak concurrency 10
(sequential would be ~10s)
```

Both halves asserted: bounded *time* (not 500 × latency) and bounded
*concurrency* (peak ≤ 10, so a fan-out is not 500 simultaneous outbound
requests to one third party).

The "business-call latency must not depend on FCM" property is now true by
construction — the poller is not in that call stack at all — and is asserted
anyway as a regression guard.

### E2c. Dead device tokens cleaned up — DONE

`classifyFCMError` parses the FCM error body and returns a distinguishable
`ErrTokenUnregistered` for the two explicit permanent signals: `UNREGISTERED`
(HTTP 404) and `INVALID_ARGUMENT` (HTTP 400) **narrowed to responses that name
the registration token** — because FCM returns `INVALID_ARGUMENT` for a
malformed *message* too, and deleting every recipient's token because the
notification body was wrong would unsubscribe the whole user base at once.

Everything else, including anything unrecognised, is transient by default.
That default direction is the safe one: a transient failure misread as
permanent silently and irreversibly stops notifying a real user, while the
reverse merely wastes a few retries.

**Proof**: an 8-case table over real FCM response shapes; a simulated
`UNREGISTERED` deletes **exactly one** token; a simulated 500 deletes
**none**; a cleanup failure does not cause redelivery (which would produce a
duplicate push to fix a bookkeeping problem).

### E4. Every trigger verified

The plan asked for a manual walkthrough with two accounts. That exercises the
code once and proves nothing about the next change, so all ten rows of the
§E4 table were turned into integration tests
(`notification_triggers_integration_test.go`), each asserting **who** is
notified and **with what title**, and — equally important — that no
unintended recipient is:

| Trigger | Notifies | Test |
|---|---|---|
| `RequestToJoin` | host | PASS |
| `WithdrawRequest` | host | PASS |
| `RespondToRequest` accept | requester ×2 (accepted + checklist) | PASS |
| `RespondToRequest` reject | requester | PASS |
| Auto-reject on capacity | each auto-rejected requester | PASS |
| `CancelMeetup` | every accepted requester | PASS |
| `CloseMeetup` (manual) | host + accepted requesters | PASS |
| **Auto-close poller** | host + accepted requesters | PASS |
| Starting-soon reminder | host + accepted requesters | PASS |
| Safety Gate decline | host | PASS |
| Nearby-notify fan-out | ≤40km, 24h-fresh, host excluded | PASS (Phase 2 test, updated) |

The auto-close row was verified through the **poller path specifically**, as
the plan asked, not only the manual close.

### Real FCM delivery — what was and was not verified

**Verified against the live FCM API.** With the real
`FIREBASE_SERVICE_ACCOUNT_JSON` from `backend/.env`, the stack was brought up
and a notification driven end to end:

```
{"severity":"INFO","message":"push notification delivery: FCM",
 "project_id":"professional-meetups-976d2"}
{"severity":"INFO","message":"notification: deleted permanently unregistered device token"}

outbox row:      processed=true attempts=1 dead=false last_error=(none)
device_tokens:   0 rows   (was 1)
```

That single line is the whole chain working against real infrastructure: the
service account authenticated against Google's OAuth endpoint, a real HTTPS
request reached
`fcm.googleapis.com/v1/projects/professional-meetups-976d2/messages:send`,
real FCM returned its permanent-failure verdict for the (deliberately fake)
token, `classifyFCMError` recognised it, §E2c deleted exactly that token, and
the row was marked processed rather than retried. The log line contains no raw
token.

**Not verified: a push physically arriving on a handset.** I have no device or
emulator with a registered FCM token, so the final hop is the one thing here
not confirmed first-hand. Everything up to and including FCM's own response to
a real authenticated request is verified above. To close it, register a real
device token via `POST /v1/device-tokens` from the app and run any trigger
from the §E4 table; the code path is identical to the one exercised, differing
only in the token being live.

**Fallback path verified too**, deliberately, with the credential unset —
because CI and every credential-free environment depend on it:

```
{"severity":"INFO","message":"push notification delivery: LoggingPushSender (FIREBASE_SERVICE_ACCOUNT_JSON not set)"}
{"severity":"INFO","message":"push notification (LoggingPushSender — not actually sent)",
 "token_count":2,"title":"Fallback clean probe","body":"Only the logging sender can deliver this",
 "data":{"probe":"fallback"}}
```

Note `token_count:2` and **no raw token** — the never-log-a-token discipline
holding in a real running process, not only in a unit test.

### E5. Tests — DONE

19 tests in `internal/modules/notification`: request shape against a mocked
transport, one failing token not stopping the others, the returned error never
containing a raw token, the `LoggingPushSender` logging usefully without one,
plus everything under E2b/E2c above.

---

## §F — Durable delivery via a Postgres outbox

`meetup.notification_outbox` (migration `0003`) + `internal/platform/outbox`
(generic poller) + the delivery logic in `internal/modules/notification`.
`push-notification-requested` is gone from the event bus entirely — the
constant and payload were **deleted**, not left defined-but-unused, so a
future publish to it fails at compile time rather than being silently lost.

### F1. Schema — as specified

Partial claim index `(next_attempt_at) WHERE processed_at IS NULL AND
dead_lettered_at IS NULL`, exactly as written; `ClaimBatch` orders by
`next_attempt_at` to match it; explicit column list. Two further partial
indexes support the retention job's predicates.

### F2/F3. Two deviations from the spec, both necessary — see ADR-001

Recorded in full in ADR-001's new "Correction (2026-09-05)" section:

1. **§F3's "no call-site changes" is not achievable alongside atomicity**, and
   the two were mutually exclusive. A `Sender` is invoked *after* the business
   write's repository method has returned and committed its own transaction —
   there is nothing left to join. What was built instead: each
   notification-triggering repository method takes a callback that runs inside
   its transaction, receiving a `NotifyTx` (transaction-scoped reads for
   participants and device tokens, plus the enqueue). Notification content is
   still composed entirely in the service layer; only *when* moved.
2. **`ClaimBatch` writes its claim rather than holding the lock across
   processing**, because processing is an FCM round trip and holding a
   transaction open across a third-party HTTP call lets a degraded FCM exhaust
   the connection pool. Each claimed row gets a 60s visibility timeout;
   `FOR UPDATE SKIP LOCKED` stays in the claiming subquery.

**The second was not theoretical.** The first implementation released the lock
without the stamp, and the concurrency test caught it immediately:

```
row 18805d6a… was claimed 3 times by concurrent claimers
row 1673e7de… was claimed 3 times by concurrent claimers
   … (16 more)
--- FAIL: TestClaimBatch_ConcurrentClaimersNeverOverlap_Integration
```

In production that is the same user receiving the same push three times. After
the rewrite the test passes, and passes `-count=5 -race`.

### F4/F5. Poller and wake signal — DONE

`process` does breaker-wrapped send → dead-token cleanup → mark
processed/failed/dead-lettered. **Partial success is success**: if any device
received it, or the only failures were permanently-dead tokens now deleted,
the row is done — retrying would re-deliver to devices that already got it in
exchange for nothing.

Terminal writes use a context detached from the poller's own, so a delivery
that *succeeded* during shutdown is still recorded — losing that bookkeeping
is the one avoidable source of duplicates in an at-least-once system.

`Wake()` is a non-blocking single-slot nudge, called after each committing
write.

**This caught a real omission.** Four of the notifying call sites in
`requests.go` — join, withdraw, accept, reject — were not calling `Wake` at
all, so every join-request notification would have waited for the safety-net
tick. Found by the test, fixed, and pinned by
`TestService_WakesThePollerAfterEveryNotifyingWrite`, which names the call
site on failure. **Control run** with `Wake` removed from `RequestToJoin`:

```
--- FAIL: TestService_WakesThePollerAfterEveryNotifyingWrite_Integration
    RequestToJoin did not wake the notification poller — its notifications
    would sit queued until the next safety-net tick instead of going out
    immediately
```

The wake mechanism itself (a `Wake` causes a drain with the tick set an hour
out) is pinned deterministically in `internal/platform/outbox`'s own unit
tests, with no database and no possible competing claimer.

### F6. At-least-once documented — DONE

Stated explicitly in three package docs (`internal/platform/outbox`,
`internal/modules/notification`, `internal/eventbus`) as a deliberate choice
with its reasoning, including the note that a future caller whose side effect
is *not* safely repeatable must not use the package as-is.

### F7. Tests — all required cases present

| Required | Result |
|---|---|
| Outbox insert rolls back **with** the business write | PASS — a failure after the insert leaves neither the request row nor the outbox row |
| Commits together on the success path | PASS |
| `FOR UPDATE SKIP LOCKED`: concurrent claimers never overlap | PASS — 4 claimers, 60 rows, no row twice, nothing dropped |
| Locked rows skipped, not waited on | PASS — asserts promptness **and** disjointness |
| Backoff: failed row not reclaimable until due | PASS |
| Dead-letter past the ceiling, never claimed again, retained | PASS |
| Wake delivers ahead of the tick | PASS (see F5) |
| Crash recovery without an explicit step | PASS — an abandoned claim becomes claimable again on its own |
| Breaker / bounded concurrency / dead-token | PASS (see E2b/E2c) |
| Retention windows | PASS (see F8) |

Plus 11 unit tests on the generic poller covering the exponential-backoff
curve against a substituted clock, the dead-letter ceiling, `ErrPermanent`
skipping the retry budget, `Wake` never blocking under 10,000 calls, and
clean shutdown.

### F8. Retention — DONE

Hourly, batched at 1000 with a 50-batch per-tick ceiling. Processed rows
deleted after 7 days; dead-lettered after 30 — kept four times longer on
purpose, since a permanent delivery failure is the one outcome worth
investigating.

**Proof**: with six rows seeded across every state, exactly the two past their
windows are deleted. Including the case a single shared retention period would
get wrong — a dead-lettered row older than the *processed* window but inside
its own — and confirming a still-pending row is never touched. Plus a 1200-row
backlog fully drained by looping, and an idempotent second run.

---

## Findings not in the plan

Three things turned up that the document did not anticipate. All are fixed.

1. **Four missing `Wake` calls** (§F5 above) — would have made every
   join/withdraw/accept/reject notification wait for the tick.

2. **The outbox claim double-claimed rows** (§F2 above) — my own first
   implementation; caught by the concurrency test, not by review.

3. **The integration test suite was latently flaky, and had been since Phase
   2.** Two independent causes, both found by chasing intermittent failures
   rather than by review, and neither of them a product defect.

   **Cause one: packages truncating each other's tables.** The `auth` and
   `meetup` integration packages both `TRUNCATE auth.users`, and
   `go test ./...` runs packages in parallel — so they wiped each other's
   fixtures mid-test. It passed almost always; a slower `-coverpkg` run made
   it reliable, failing five tests across two packages at once, none of them
   actually broken.

   Fixed with a Postgres advisory lock taken by every integration harness
   (`db.AcquireIntegrationTestLock`). Chosen over `go test -p 1`, which would
   serialise every package to solve a problem in two, and which has to be
   *remembered* — a developer running `go test ./...` by hand silently loses
   it. An advisory lock is enforced by the code and released automatically
   when the connection dies, including on a panic.

   **Cause two, and the more interesting one: the running application was
   eating the tests' fixtures.** With this pass's work in place, a live
   monolith attached to the same database does two things that are entirely
   correct and completely hostile to a test suite sharing it:

   - Its outbox poller claims rows the tests just queued — exactly what
     ClaimBatch's concurrency guarantee says should happen, and precisely
     what §F7's own concurrency test *proves* works. A test asserting "I
     claimed this row" then fails through no fault of the code.
   - With a real `FIREBASE_SERVICE_ACCOUNT_JSON` configured it actually
     **sends** them. Real FCM rejects the tests' fake device tokens as
     permanently invalid, and §E2c's dead-token cleanup deletes those rows —
     so the application garbage-collects the tests' own fixtures out from
     under them, mid-test. Measured on the live stack while diagnosing this:
     **61 fixture deletions in five minutes.**

   Fixed by giving integration tests their own database
   (`db.EnsureTestDatabase`, `monolith_db_test`, created on first use and
   migrated normally). That is the standard answer and it removes the whole
   class of problem — the competing poller, the fixture deletion, and any
   future interaction of the same shape — rather than papering over the two
   symptoms that happened to surface first.

   Verified both ways afterwards: the application's own database is untouched
   by a full test run, and the container stopped deleting anything.

   Two outbox tests were additionally made property-based rather than
   count-based. That change stands on its own merits regardless of the
   isolation fix: "no row was claimed twice" and "the claim returned
   promptly" are the guarantees, while "this particular goroutine got exactly
   N rows" is an implementation detail that a legitimate second claimer
   invalidates.

   **Stability after the fix**: five consecutive full-suite `-race` runs, zero
   failures. Before it, the suite failed on two of four consecutive runs.

## Explicitly not changed

Everything in the plan's own "Explicitly not changing" list: items rated FINE
by the audits, and the Phase-3 boundary topics (`subscription-*` with no
publisher yet, `meetup-request-created/-accepted/-rejected` with no consumers
— a gap ported as-is from the source). These remain intentional phase
boundaries.

## Design review against ADR-001

- **No cross-schema foreign keys** — migration `0003` adds none.
- **No module reaches into another's SQL** — the notification module reads
  `meetup.notification_outbox` only through a repository the meetup module
  owns and exposes, and declares its own narrow `DeviceTokenCleaner` interface
  rather than importing meetup's repository surface. The one cross-schema read
  in the codebase is in the backfill operator tools, deliberately and
  documented.
- **Event-bus publishes still happen after their transaction commits**,
  unchanged — the in-process handler would otherwise read uncommitted rows.
- **The outbox is a scoped exception to §4, not a reversal** — one topic,
  reasoned in ADR-001, with every other topic still synchronous on the
  in-memory bus.
- **Every SQL query is parameterized.** The only interpolated identifier in
  the repository is none; one exists in a test helper, from a compile-time
  constant in that test file, noted in place.
- **Every authorization decision still comes from the verified caller
  context.** Nothing in this pass added a code path that reads identity from a
  client-supplied field.
- **Secrets and tokens are never logged.** Asserted by test for device tokens
  (both senders), FCM errors, and the reuse-detection log line; the
  service-account JSON is never logged even on a startup failure.

## Next

Phase 3 (billing) resumes as originally planned. Nothing in this pass changed
the billing surface; `subscription-activated`/`-deactivated` still have their
subscriber wired and waiting for a publisher.
