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

**Note: Fix 3 appears already applied** — `backend/docker-compose.yml` and
`backend/.env.example` already have `INTERNAL_GRPC_SHARED_SECRET`/
`MONOLITH_SHARED_SECRET` wired through with `:?` required-var syntax. If the
interceptor + client-side attachment + rejection test described above are
also already in place, just confirm and report that rather than redoing it.

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

## Fix 5 — frontend: Apple/Google sign-in never sends a nonce

The monolith's auth module now requires a `nonce` on `CompleteFederatedSignup`/
`LinkIdentity` (Fix from the original phase plan). The frontend has never
generated one: confirmed directly — `frontend/lib/core/services/http_auth_service.dart`'s
`signInWithApple` calls `SignInWithApple.getAppleIDCredential(scopes: [...])`
with no `nonce:` argument, and `signInWithGoogle` calls
`GoogleSignIn.instance.authenticate()` the same way. This is a real gap in
the shipped app too, not something this port introduced — but it means the
copied frontend will send an empty nonce and get rejected by the new backend
requirement unless this is fixed.

- **Apple** (`sign_in_with_apple: ^8.1.0`, confirmed in `pubspec.yaml` —
  this version supports it cleanly): generate a random value
  (`dart:math`'s `Random.secure()`, sufficient bytes — e.g. 32), SHA-256
  hash it (the `crypto` package is already a dependency, used elsewhere for
  PKCE), pass the **hash** as `nonce:` into `getAppleIDCredential(...)`,
  send the **raw** value to the backend alongside the `id_token`
  (`CompleteFederatedSignupRequest`/`LinkIdentityRequest`'s new `nonce`
  field). Apple embeds the hash in the token's `nonce` claim; the backend
  re-hashes the raw value it receives and compares.
- **Google** (`google_sign_in: ^7.2.0`) — **real package limitation, not a
  choice**: this version only accepts a nonce at
  `GoogleSignIn.instance.initialize(...)`, which its own docs require be
  called exactly once per app session (the existing
  `_ensureGoogleSignInInitialized()` memoization in this file already
  respects that). There is no supported way in this package version to set
  a fresh nonce per individual sign-in attempt (open upstream issue:
  flutter/flutter#175029). Generate the nonce once, at first
  initialization, pass it into `initialize(serverClientId: ..., nonce: ...)`,
  and send that same value to the backend on every Google sign-in for the
  life of that app session. This narrows the replay window to "within this
  one running app session" rather than eliminating it the way Apple's fix
  does — note this explicitly in your report as an accepted,
  package-imposed limitation, not silently treat it as equivalent to
  Apple's fix.
- Update `AuthService` (`auth_service.dart`), `HttpAuthService`, and any
  test fakes (`MockAuthService`, `_FakeAuthService` in test files) to
  thread a nonce through `signInWithApple`/`signInWithGoogle` and whatever
  calls `CompleteFederatedSignup`/`LinkIdentity` on the wire.
- Add a widget/unit test confirming a nonce is actually generated and sent
  on both providers' sign-in paths.

## When done

Report per the usual shape: confirmation `go build`/`go vet`/`go test -race`
(backend) and `flutter analyze`/`flutter test` (frontend, for Fix 5) all
pass after these five changes; the new breaker's trip-and-recover behavior
demonstrated by a real test run (not just written); the shared-secret
rejection test's actual output (or confirmation it was already in place);
the re-confirmed test-count/skip-count from Fix 4; and confirmation of
exactly what Fix 5 does differently for Apple vs. Google and why. If any of
these five turns up a reason it shouldn't be done exactly as described
here, say so explicitly rather than silently doing something else.
