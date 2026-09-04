# Phase 1 fixes — post-review findings (paste into the Claude Code session)

An independent review compared this phase's code against the source
line-by-line. Most of it held up well (the nonce fix, the refresh-token
split, the rate limiter, JWT verification, route-level auth, SQL
parameterization all checked out clean — see
`docs/decisions/adr-001-modular-monolith-architecture.md`'s new
"Corrections" section for the full reasoning behind what follows). Four
concrete things need fixing before this phase is really done.

## Fix 1 — bring back the SOS-alert circuit breaker (was dropped too broadly)

Read ADR-001's new "Corrections" section first — the short version:
"no breaker" was meant to apply to the outbox/Pub/Sub-publish use case
only (correctly gone, per §4), not to the SOS-alert path's protection
against a slow/down Twilio or Resend, which is unrelated to events and still
exists in this design exactly as it did in the source.

- Add `internal/platform/breaker` — port `../Professional-Meetups/backend/shared/breaker`
  essentially unchanged (closed/open/half-open state machine, `Execute(fn) error`,
  `ErrOpen` sentinel).
- In `internal/modules/auth/sos/sos.go`, wrap the SMS and email sends each in
  their own breaker (`smsBreaker`, `emailBreaker` — one instance per channel,
  constructed once when the `sos` package's service/dependencies are built,
  not per-call, so it actually remembers consecutive failures across
  separate `TriggerSOS` calls from different users — that cross-call memory
  is the entire point). Same constants as the source:
  `sosBreakerFailureThreshold = 5`, `sosBreakerResetTimeout = 30 * time.Second`.
  Keep the existing bounded retry (`sendMaxAttempts = 2`,
  `sendRetryDelay = 500ms`) inside the breaker-wrapped call, same as the
  source's `sendSOSAlertWithResilience` shape — don't remove the retry, add
  the breaker around it.
- Update `sos_test.go`'s `TestTriggerSOS_SustainedChannelFailureStillAlertsEveryOtherChannel`
  (and add a new test if needed) to also assert the breaker actually trips:
  after 5 consecutive failures on one channel, a subsequent call to that
  channel fails fast (no retry delay incurred) while the other channel is
  unaffected — mirroring whatever test shape the source uses for its own
  breaker, if one exists there.

## Fix 2 — the Resend email sender has no explicit HTTP timeout

`internal/modules/auth/email/resend.go` constructs `resend.NewClient(apiKey)`
with no timeout override. The Twilio SMS sender already does this correctly
(`sms/twilio.go`'s `defaultTimeout = 5 * time.Second`, with a comment
explaining why every external HTTP call needs one) — the email sender
should match it exactly, both for the OTP-sending path and the SOS-alert
path. Check what `resend-go/v2` actually exposes for injecting a custom
`http.Client` (it likely takes one via an option or a client field) and set
an explicit timeout, same value and same reasoning as Twilio's, unless you
find a concrete reason this vendor's calls need a different number — say so
if you do.

## Fix 3 — add a shared-secret check on the gateway-to-monolith gRPC call

Read ADR-001's "Corrections" section for the full reasoning: today, nothing
in code stops any gRPC caller that can reach the monolith's port from acting
as any user, since every method trusts its caller's identity fields without
independently verifying them — safety currently rests entirely on Docker
network isolation between the two containers, not on anything enforced in
code.

- Generate a static shared secret (e.g. a random 32-byte value, base64), a
  new required config var on both sides: `INTERNAL_GRPC_SHARED_SECRET`
  (monolith) and the same value passed to the gateway as
  `MONOLITH_SHARED_SECRET` — add both to `backend/.env.example` with a
  comment explaining what it's for, and to `backend/docker-compose.yml`'s
  `monolith`/`gateway` environment blocks (reference the same `.env` value
  for both so they match).
- On the monolith side: a `grpc.UnaryServerInterceptor` that reads a
  specific metadata key (e.g. `x-internal-auth`) from the incoming context,
  compares it against the configured secret using
  `crypto/subtle.ConstantTimeCompare` (not `==` — same discipline as the
  nonce check), and rejects with `codes.Unauthenticated` if it doesn't
  match or is missing. Wire it into the gRPC server construction in
  `cmd/monolith/main.go`.
- On the gateway side: attach that metadata key/value to every outgoing
  call in `internal/gateway/monolithclient/monolithclient.go` (a
  `grpc.WithUnaryInterceptor` client-side, or attach it per-call via
  `metadata.AppendToOutgoingContext` — whichever fits this codebase's
  existing gRPC client-construction shape better).
- This is deliberately **not** mutual TLS — a static shared secret is
  enough for a two-process, single-tenant system to close "any network
  caller can impersonate any user," without the certificate-management
  overhead mTLS would add. Note this trade-off explicitly in your report if
  you think it's insufficient for some reason.
- Add a test proving a call with a missing/wrong secret is rejected before
  it ever reaches the auth module's business logic.

## Fix 4 — independently confirm the "385 tests, 0 skips" claim

Re-run the full suite yourself with Postgres actually up
(`docker compose up -d postgres` first, confirm healthy, then
`go test ./... -v 2>&1 | grep -E "SKIP|FAIL"` or equivalent) and paste the
real output showing zero `SKIP`/`FAIL` lines, rather than restating the
earlier number. `internal/modules/auth/integration_test.go`'s
`requirePostgres` helper silently skips every integration test if Postgres
isn't reachable within 500ms — worth confirming directly rather than
trusting a prior run's summary, since that's exactly the kind of claim that
can be accidentally satisfied by the skip path firing instead of the real
one.

## When done

Report per the usual shape: confirmation `go build`/`go vet`/`go test -race`
all still pass after these four changes, the new breaker's trip-and-recover
behavior demonstrated by a real test run (not just written), the shared-secret
rejection test's actual output, and the re-confirmed test-count/skip-count
from Fix 4. If any of these four turns up a reason it shouldn't be done
exactly as described here, say so explicitly rather than silently doing
something else.
