# Phase 1 completion report — scaffold, gateway, auth module

Implements `01-phase1-scaffold-gateway-auth.md` against
`../decisions/adr-001-modular-monolith-architecture.md`, at the quality bar
in `00-overview.md` and the security checklist in
`../security-review-framework.md`.

**Updated 2026-09-04** after the post-review fix pass
(`phase1-fixes-breaker-timeout-grpc-auth.md`): the SOS circuit breaker is
restored, the Resend client has an explicit timeout, the gateway→monolith
gRPC hop is authenticated, the test-count claim was independently
re-confirmed, and the frontend nonce plumbing is built — which surfaced a
real weakness in the original nonce design, now fixed. See §9.

Everything below was actually run in this environment (Go 1.26.6, Docker,
`sqlc` v1.31.1, `buf` 1.72.0, `golangci-lint` v2.12.2). Where something was
*not* exercised, it says so and why.

---

## 1. Toolchain verification (real output)

```
$ go build ./...
(no output = success)

$ go vet ./...
(no output = success)

$ golangci-lint run ./...
0 issues.

$ gofmt -l .    # excluding generated internal/proto + sqlcgen
(no output = success)
```

`go test ./...`, with `DATABASE_URL` pointed at a real Postgres so the
integration tests run rather than skip:

```
?   .../cmd/gateway                        [no test files]
?   .../cmd/monolith                       [no test files]
ok  .../internal/eventbus                  0.718s
?   .../internal/gateway/config            [no test files]
ok  .../internal/gateway/handlers          2.581s
ok  .../internal/gateway/middleware        1.222s
?   .../internal/gateway/monolithclient    [no test files]
?   .../internal/grpcapi                   [no test files]
ok  .../internal/modules/auth              6.425s
?   .../internal/modules/auth/config       [no test files]
ok  .../internal/modules/auth/email        2.383s
ok  .../internal/modules/auth/identity     2.247s
ok  .../internal/modules/auth/linkedin     2.723s
ok  .../internal/modules/auth/repository   2.991s
?   .../internal/modules/auth/repository/sqlcgen [no test files]
ok  .../internal/modules/auth/sms          3.163s
?   .../internal/modules/auth/sos          [no test files]
ok  .../internal/platform/apperror         2.644s
?   .../internal/platform/db               [no test files]
?   .../internal/platform/geo              [no test files]
ok  .../internal/platform/jwt              2.386s
ok  .../internal/platform/logging          2.197s
ok  .../internal/platform/ratelimit        2.327s
?   .../internal/proto/auth/v1             [no test files]
```

`go test -race ./...` — same result, every package `ok`, no data races.

**407 test cases pass (including subtests); 0 failures, 0 skips** — see §9
Fix 4 for the independently re-confirmed counts and the control run proving
the skip path was not what fired.

Two packages listed as `[no test files]` are covered indirectly and
deliberately: `internal/grpcapi` and `internal/gateway/monolithclient` are
mechanical proto↔struct adapters, exercised end to end by the live-stack run
in §4 (a field dropped in either one fails that run). `cmd/*` are wiring
files, also covered by §4. `internal/platform/db` is exercised by every
integration test (it runs the migrations and opens the pool).

---

## 2. Completeness checklist against the inventory

### 2a. Gateway routes (auth subset) — method, path, middleware chain

Global chain, applied to the whole mux in `cmd/gateway/main.go`, in the
source's exact order: `Recover` → `logging.HTTPMiddleware` (request ID) →
`RequestLogging` → `RateLimit` (in-memory IP+path 20/min) → `MaxBytes`
(1 MiB). Server timeouts: `ReadHeaderTimeout=10s`, `ReadTimeout=30s`,
`WriteTimeout=30s`, `IdleTimeout=120s`.

| # | Method | Path | Per-route middleware | Extra limit |
|---|---|---|---|---|
| 1 | POST | `/v1/auth/federated/signup` | — (unauthenticated) | — |
| 2 | POST | `/v1/auth/linkedin/callback` | — | — |
| 3 | POST | `/v1/auth/email/signup/start` | — | — |
| 4 | POST | `/v1/auth/email/signup` | — | email-keyed 20/min |
| 5 | POST | `/v1/auth/email/login/start` | — | — |
| 6 | POST | `/v1/auth/email/login` | — | email-keyed 20/min |
| 7 | POST | `/v1/auth/refresh` | — | — |
| 8 | POST | `/v1/auth/logout` | — | — |
| 9 | POST | `/v1/auth/identities/link` | `requireAuth` | — |
| 10 | POST | `/v1/auth/profile-setup` | `requireAuth` | — |
| 11 | POST | `/v1/verification/phone/start` | `requireAuth` | target-keyed 5/hour (`phone_number`) |
| 12 | POST | `/v1/verification/phone/verify` | `requireAuth` | — |
| 13 | POST | `/v1/verification/personal-email/start` | `requireAuth` | target-keyed 5/hour (`email`) |
| 14 | POST | `/v1/verification/personal-email/verify` | `requireAuth` | — |
| 15 | POST | `/v1/verification/personal-details` | `requireAuth` | — |
| 16 | POST | `/v1/verification/corporate-email/start` | `requireAuth` | target-keyed 5/hour (`email`) |
| 17 | POST | `/v1/verification/corporate-email/verify` | `requireAuth` | — |
| 18 | GET | `/v1/users/me` | `requireAuth` | — |
| 19 | POST | `/v1/sos/contacts` | `requireAuth` | — |
| 20 | GET | `/v1/sos/contacts` | `requireAuth` | — |
| 21 | DELETE | `/v1/sos/contacts/{id}` | `requireAuth` | — |
| 22 | POST | `/v1/sos/trigger` | `requireAuth` → `UserKeyedRateLimit` | user-keyed 5/hour |
| 23 | POST | `/v1/users/me/location` | `requireAuth` | — |

Mechanically diffed against the source gateway's own `Register`: the
extracted `(method, path)` lists are **byte-for-byte identical**, in the same
order.

Rate-limit key strings are copied verbatim, not re-derived:
`ratelimit:<ip>:<path>` · `ratelimit:email:<path>:<email>` ·
`ratelimit:target:<path>:<target>` · `ratelimit:user:<path>:<userID>`. The
429 shape is unchanged (`Retry-After: 60`, `{"error":"rate limited"}`).

### 2b. Module methods — 23 of 23

The plan says "22 methods"; the proto contract actually declares 23 RPCs
(`CompleteFederatedSignup` … `TriggerSOS`). All 23 are implemented,
registered on the gRPC server, and reachable through a gateway route:
CompleteFederatedSignup, CompleteLinkedInOnboarding, LinkIdentity,
StartEmailSignup, CompleteEmailSignup, StartEmailLogin, CompleteEmailLogin,
RefreshSession, RevokeSession, StartPhoneVerification, VerifyPhoneCode,
StartPersonalEmailVerification, VerifyPersonalEmailCode,
SubmitPersonalDetails, StartCorporateEmailVerification,
VerifyCorporateEmailCode, GetProfile, CompleteProfileSetup,
UpdateLastKnownLocation, AddTrustedContact, ListTrustedContacts,
RemoveTrustedContact, TriggerSOS.

### 2c. Schema — 8 tables

`auth.users`, `auth.refresh_tokens`, `auth.verification_codes`,
`auth.user_identities`, `auth.known_companies`,
`auth.unverified_company_claims`, `auth.trusted_contacts`,
`auth.sos_events` — the squashed final state of the source's ten auth
migrations, minus `outbox_events` (ADR-001 §4) and minus `password_hash`
(added then dropped in the source's own history). The plan's prose says "10
tables" but enumerates these 8; 8 + the dropped outbox table + the never-added
`password_hash` column accounts for the difference.

Same enums (`account_status`, `verification_purpose` with all 5 values,
`identity_provider`), same partial unique indexes
(`idx_users_linkedin_sub`, `idx_users_phone_number`,
`idx_users_personal_email`, `idx_verification_codes_signup_target`), same
`UNIQUE(user_id, purpose)`, `UNIQUE(provider, subject)`,
`UNIQUE(user_id, provider)`, same `work_email_hash` UNIQUE, same
`known_companies` lowercase-domains CHECK and its 16 seeded rows, same
`CHECK (phone_number IS NOT NULL OR email IS NOT NULL)` on trusted contacts,
same two `set_updated_at` triggers.

### 2d. Business rules — verified, not assumed

Each of these was read out of the source's service code and is covered by a
test (unit, integration, or both):

- OTP: 6 digits from `crypto/rand`, SHA-256 stored (never the raw code), 10
  min expiry, **5-attempt cap** (row deleted on the 5th), 1-minute resend
  cooldown, row deleted on success so the raw target doesn't linger.
- Trust levels: LinkedIn is a hard prerequisite for Level 2+; Level 2 is the
  bundle (phone + personal email + legal name), no partial credit; Level 3
  additionally needs work email; address is deliberately *not* in the Level 2
  bundle.
- Corporate email: free-provider and role-based rejection before any code is
  sent; company name↔domain cross-check against `known_companies`
  (normalized name, lowercased domain); unknown company → accept + flag into
  the review queue; same mailbox cannot verify a second account (keyed HMAC);
  the raw address is never persisted.
- Age gate: enforced server-side on all four signup paths; no account is
  created without it.
- Enumeration safety: `StartEmailLogin` never reveals whether the account
  exists; `CompleteEmailLogin` returns one generic error and runs the OTP
  check unconditionally.
- Refresh tokens: rotation invalidates the presented token; replay of an
  already-rotated token is rejected as a theft signal; revoke is idempotent.
- Trusted contacts: cap of 3; at least one of phone/email; delete scoped to
  `(contact_id, user_id)` in one statement.
- SOS: 500-char context cap, lat/lng validation, per-contact send tolerance,
  audit row written even when sends fail.
- Length caps: full name 200, legal name 200, address 500, company name 200,
  contact name 200.

---

## 3. Security review — all six properties

### Confidentiality — clean, with two improvements

- The JWT private key exists only in the gateway process; `cmd/monolith` does
  not import `internal/platform/jwt` at all. The work-email HMAC key exists
  only in the monolith. Neither is logged.
- `GetProfile`/`CompleteProfileSetup` return the four raw PII fields only for
  the caller's own account — the user id is always the gateway's
  verified-JWT value, never a body field (tested per-route).
- No raw work email anywhere: `TestGetProfile_*` asserts the response type's
  field set by reflection, and an integration test greps **every text column
  of every `auth.*` table** for the raw address after a successful
  verification.
- No password field exists anywhere in the schema or the response types —
  structurally, not by omission.
- LinkedIn/Apple/Google tokens are verified then discarded; only SHA-256
  hashes of refresh tokens and OTPs are stored.
- **Improvement over the source**: the rate limiter's body peek is now bounded
  (see Availability).

### Integrity — clean

- Trust level is computed server-side by `computeTrustLevel` on every
  mutation and written in the same statement as the field it depends on; it
  is never read from a request.
- Refresh-token rotation detects reuse (`replaced_by`/`revoked_at` checked
  before issuing).
- DB constraints, not application logic, resolve the races: the partial
  UNIQUE indexes are what reject a phone/personal-email/work-email-hash
  already claimed elsewhere, and the repository maps `23505` to
  `ErrConflict`. An integration test proves this against real Postgres.
- Every JWT is verified before any claim is trusted; three forgery attempts
  against the live gateway (tampered signature, escalated `trust_level` with
  the original signature, `alg=none`) all returned 401.

### Availability — one accepted regression, reported

- Every external HTTP client has an explicit 5s timeout (LinkedIn, Twilio,
  JWKS); the HTTP server has all four timeouts set; the gRPC client fails
  fast at startup rather than accepting traffic it can't serve.
- The in-memory limiter has no external dependency, so there is no
  "fails open" case to preserve — every check either succeeds or 429s. Its
  sweeper bounds memory (an attacker-controlled key space would otherwise
  grow forever).
- **Bounded the one unbounded read**: the source's `peekRequestField` calls
  `io.ReadAll(r.Body)` in the rate limiter, which runs *before* `MaxBytes` in
  the chain — an arbitrarily large body was fully buffered at any of the 5
  keyed paths. Now capped at the same 1 MiB, with the peeked prefix stitched
  back in front of the unread remainder so downstream behavior is identical.
- **SOS circuit breaker: restored** (§9 Fix 1). One breaker per channel, on
  the long-lived service, so failure memory persists across `TriggerSOS`
  calls from different users — a sustained Twilio/Resend outage fails fast
  after 5 consecutive failures instead of every emergency paying the full
  retry-and-timeout cost. The bounded retry sits inside it, same shape as the
  source.
- **Resend now has an explicit 5s timeout** (§9 Fix 2), matching Twilio.
  resend-go's own default is 1 minute — not unbounded, but far too long for
  an OTP send and much too long for the SOS path.
- **Accepted trade-off (ADR-001 §5)**: the in-memory limiter is correct for a
  single gateway instance only. Behind a load balancer each replica enforces
  its own limit.

### Authenticity — the source's known gap is fixed

- RS256 is pinned via `WithValidMethods` on both our own tokens and
  Apple/Google id_tokens; issuer and audience are checked, not just the
  signature; an unconfigured audience fails **closed**.
- **Fixed the nonce-replay gap** (`security-review-framework.md`'s named
  Phase-1 item) — details in §5.
- LinkedIn's flow keeps its `state`-based CSRF protection (client-side,
  unchanged) and its confidential-client exchange.

### Non-repudiation — clean

Every security-relevant change carries its own timestamp attributable to a
`user_id` and durable in Postgres: `refresh_tokens.issued_at`/`revoked_at`/
`replaced_by` (the rotation chain), `users.age_confirmed_at`,
`work_email_verified_at`, `sos_events.triggered_at` + `contacts_notified`,
`unverified_company_claims.flagged_at`. No tamper-evident admin audit log
exists — the same explicitly-named gap as the source, and there is still no
admin surface for it to cover; not built speculatively.

### Authorization & accountability — clean

- Every authenticated route takes its caller identity from
  `middleware.UserIDFromContext` (the verified JWT) and nothing else. A
  dedicated table test posts a **different** `user_id` in the body of nine
  authenticated routes and asserts the monolith is still called with the
  token's user.
- `RemoveTrustedContact` deletes scoped to `(contact_id, user_id)` in one
  statement — no check-then-delete TOCTOU window — and maps "no row" to
  Forbidden without revealing whether the id exists. Proven against real
  Postgres with a second account.
- `ListTrustedContacts` is self-scoped (a second account sees zero rows).
- Cross-account identity-linking collisions hard-reject (`ErrConflict`);
  no silent merge.
- Trust level in the token can only be stale *low* (it only ever increases),
  which is the safe direction.
- **The gateway→monolith hop is now authenticated** (§9 Fix 3). Every monolith
  RPC trusts its caller's `user_id`; that is only sound if the gateway is the
  sole caller, and until this fix nothing in code enforced it — it rested on
  Docker network isolation alone. A shared secret in gRPC metadata, verified
  constant-time by a unary interceptor that runs before any handler, closes
  "anything that can reach the port can act as any user". Verified against the
  running stack, not just in unit tests.

### Cross-cutting

- **Every SQL query is parameterized.** All queries are sqlc-generated from
  `queries/*.sql`. A grep for string-built SQL across all non-test code
  returns nothing. (The only `fmt.Sprintf`-built SQL in the repo is in an
  integration test, over `information_schema` identifiers, with the value
  still bound as `$1`.)
- **Secrets are never logged.** The only lines that log an OTP are
  `LoggingSmsSender`/`LoggingEmailSender`, which exist precisely to stand in
  for a real provider in dev and never log the target address. Nothing logs a
  token, key, or password.
- **Rate limits match the inventory exactly** — same routes, same numbers,
  same key shapes (§2a), verified at the boundary both in unit tests and
  against the live gateway (§4).

---

## 4. End-to-end verification (actually run)

Run twice: once against the two binaries directly, once through
`docker compose up --build` (gateway container → monolith container →
Postgres container). Both produced identical results.

1. `POST /v1/auth/email/signup/start` → `200 {"resend_after_seconds":60}`.
2. OTP read from the monolith's `LoggingEmailSender` log line (this port does
   **not** carry the source's hardcoded-`123456` bypass — see §6).
3. Wrong code → `400 {"error":"invalid code: invalid input"}`.
4. `age_confirmed_over_18: false` → `400` (server-side age gate).
5. Correct code → `200` with a real session.
6. **The access token is signed by the gateway** and decodes to
   `{"user_id":"38e5ae6c-…","trust_level":0,"iss":"professional-connections-auth","sub":…,"exp":…,"iat":…}`
   — the monolith never returned one.
7. `GET /v1/users/me` with no token → `401`. With a tampered signature → `401`.
   With `trust_level` escalated to 3 and the original signature → `401`. With
   `alg=none` → `401`.
8. `POST /v1/auth/profile-setup` (Bearer) → `200`, name persisted.
9. `GET /v1/users/me` (Bearer) → `200`, the persisted profile.
10. SOS: add contact → `200`; `"not-a-phone"` → `400` (server-side format
    check, see §6); list → `200`; trigger → `200 {"contacts_notified":1}`;
    latitude 91 → `400`.
11. `POST /v1/users/me/location` → `204`.
12. Refresh → new token pair; replaying the old refresh token → `401
    {"error":"refresh token already used: unauthorized"}`.
13. Phase 2/3 routes → `503` with `{"error":"meetups are not configured"}` /
    `{"error":"billing is not configured"}`; unauthenticated → `401` first
    (auth precedence, same as the source); webhooks → `503` unauthenticated.
14. Rate limits at the boundary: 20 allowed then `429 Retry-After: 60` on
    `POST /v1/auth/logout`; a different path unaffected; 5 allowed then `429`
    on `POST /v1/verification/personal-email/start` (target-keyed).

**What proves the JWT relocation works**: step 6 plus step 9 — the token that
authenticates `/v1/users/me` was minted by the gateway from identity facts
the monolith returned, and verified by the gateway's own verifier.

---

## 5. The nonce fix (required security change)

The source verifies Apple/Google `id_token`s for signature, issuer, audience
and expiry, but never checks the `nonce` claim — a valid token intercepted
inside its validity window can be replayed. Fixed here, not carried forward:

- `identity.Provider.Verify(ctx, idToken, expectedNonce)` now takes the
  client-generated per-attempt nonce and compares it (constant-time) against
  the token's own `nonce` claim, after the signature/audience/issuer checks.
- **An empty expected nonce is rejected outright** — a check you can bypass by
  omitting a field is not a check.
- The nonce is threaded through: REST body → `CompleteFederatedSignupRequest`/
  `LinkIdentityRequest` (new `nonce` field 4 / field 6 in the proto) →
  `monolithclient` → `grpcapi` → module → verifier.

**Tests proving it** (`internal/modules/auth/identity/identity_test.go`, all
passing): each case below is a token that is otherwise completely valid.

- `replayed token: nonce belongs to a different sign-in attempt` → rejected
- `token carries no nonce claim at all` → rejected
- `caller supplies no expected nonce (check must not be skippable)` → rejected
- `neither side has a nonce (both empty must still fail closed)` → rejected

Plus `TestFederatedSignup_RequiresNonce_Integration` (module level, real
Postgres: signup with no nonce fails, with a nonce succeeds and writes the
identity row) and `TestFederatedSignup_ForwardsNonce` (gateway level: the
body's nonce actually reaches the client call).

**Contract consequence, called out as instructed**: this changes the REST
request shape for `POST /v1/auth/federated/signup` and
`POST /v1/auth/identities/link` (Apple/Google branch). The copied
`frontend/` does not generate a nonce anywhere today (`grep -rin nonce lib/`
returns nothing), so **Apple/Google sign-in needs a frontend change** — see
§7, gap 2. Every other route in this phase needs zero frontend changes.

---

## 6. Deviations from a 1:1 port (all deliberate)

1. **JWT signing moved to the gateway** (ADR-001 §6). `SessionResponse` drops
   `access_token` and `access_token_expires_in_seconds` (field numbers 2 and
   4 reserved, not reused) and gains `trust_level`, which the auth service
   used to consume internally and so never had to send. It **keeps**
   `refresh_token`: ADR §6 reads "drops those two fields", but Step 3 of the
   phase plan specifies the monolith returns "the new refresh-token row's raw
   value", and the gateway has no database in which to create that row. I
   followed the more specific instruction; flagging the tension in the ADR's
   wording for review.
2. **Nonce added to two request shapes** (§5).
3. **The OTP testing bypass is not ported.** The source's `otpMatches`
   returns `code == "123456"` unconditionally, with the real comparison
   commented out and marked "DO NOT SHIP TO PRODUCTION". Porting an
   authentication bypass is not what "port the validation rules faithfully"
   means. The real constant-time comparison is restored; local testing reads
   the code from the logging sender instead (which is what it is for).
4. **Server-side format validation added** for phone numbers and email
   addresses. These rules existed **only** in the Flutter client, whose own
   header says "the server must re-validate every single input"; the source
   accepted any non-empty string. Applied at `StartPhoneVerification`,
   `StartPersonalEmailVerification`, `StartCorporateEmailVerification` and
   `AddTrustedContact`, using the frontend's *exact* regexes so nothing the
   shipped UI accepts is now rejected.
5. ~~**SOS circuit breaker not ported**~~ — reversed after review; the
   breaker is now ported (§9 Fix 1). ADR-001 §7's "no breaker" turned out to
   be scoped to the outbox use case only.
6. **Rate-limiter body peek bounded** (Availability above).
7. **Module returns sentinel errors, not gRPC statuses.** The source's service
   *was* the gRPC server, so it called `apperror.ToGRPCStatus` inline; here
   that translation belongs at the boundary (`internal/grpcapi`). Same
   sentinels, same messages — the wire behavior a client sees is unchanged.
8. **`auth.Deps` struct instead of 15 positional parameters** to `New`.
9. **docker-compose host ports parameterized** (`POSTGRES_HOST_PORT`,
   `GATEWAY_HOST_PORT`, `MONOLITH_HOST_PORT`), defaults unchanged. The
   sibling repo's stack is running on 5432/8080/9090 and Phase 5 needs both
   stacks up simultaneously. Container ports are untouched.

### Observations about source behavior, preserved as-is (not changed)

- `GET /v1/users/me` does **not** return `rating_average`/`rating_count`: the
  proto and the module carry them, the source's REST response drops them, and
  the frontend defaults them to 0. Ported exactly; flagging because it looks
  like an omission and isn't mine.
- A failed age-gate check on `CompleteEmailSignup` **consumes the OTP**
  (verify-and-consume runs before the age check), so the user must request a
  new code. Observed during the live run; faithful to the source.
- The blanket and target-keyed rate limits run *before* per-route auth, so an
  unauthenticated caller can spend a victim's target-keyed budget. That is
  the intended shape (the limit exists to protect the target's phone/inbox),
  and it is the source's behavior.
- The frontend's free-provider list (10 domains) is broader than the server's
  (7). Server behavior ported exactly; a `@aol.com` address is blocked
  client-side and accepted server-side, in both backends. Reported rather
  than unilaterally "fixed".

---

## 7. Known gaps for Phase 2+ (named, not implicit)

1. ~~**SOS alert resilience regressed**~~ — **resolved**. ADR-001's
   2026-09-04 correction confirmed the reading I flagged: "no breaker" was
   scoped to the outbox/Pub/Sub publish, not the SOS vendor calls. The
   per-channel breaker is restored (§9 Fix 1).
2. ~~**Apple/Google sign-in needs a frontend change for the nonce**~~ —
   **resolved** (§9 Fix 5). The client now generates the pair, hands the
   provider the hash and sends the raw pre-image. One residual, documented at
   the call site: Google's nonce is per-app-run rather than per-attempt,
   because `google_sign_in` 7.x takes it on `initialize` (callable exactly
   once) rather than on `authenticate`.
3. **`rating-updated` has no subscriber yet** — the auth module consumes it in
   the source, but only the meetup module publishes it. Wiring a handler now
   would be a dangling subscription, so the `Subscribe` call belongs in Phase
   2 next to its publisher. `UpsertRatingCache` (repository + ordering guard)
   is already ported and tested.
4. **Phase 2's Safety Gate authorization gap** — `security-review-framework.md`
   names it as Phase 2 scope; untouched here, restated so it isn't lost.
5. **No meetup/billing/notification modules** — their routes 503 (registered,
   auth-wrapped, never faking success).
6. **Frontend not exercised against a running app.** Route/field compatibility
   was verified by reading the frontend's actual HTTP calls and JSON parsing:
   all 23 routes it calls in this phase's subset match by method and path, and
   every key it parses (`access_token`, `expires_in`, `user_id`,
   `refresh_token`, `is_new_user`, `full_name`, `profile_photo_url`, and the
   15 profile keys) matches this gateway's responses. What was **not** done is
   pointing a real `flutter run` at this gateway and tapping through
   LinkedIn/Apple/Google sign-in: LinkedIn needs real OAuth credentials and
   the deployed auth-bridge redirect, and Apple/Google need real
   `APPLE_SERVICES_ID`/`GOOGLE_CLIENT_ID` audiences — none of which exist in
   this environment (the same "Action Tracker §1" gap the source has). The
   email-OTP path, which needs no external credential, was exercised for real
   end to end.
7. **No tamper-evident admin audit log** — same explicitly-accepted gap as the
   source; no admin surface exists yet.

---

## 8. Design review against ADR-001

- **§1 two deployables** — `cmd/gateway` and `cmd/monolith`, separate
  binaries, separate containers, talking gRPC. One target (`MONOLITH_ADDR`),
  not three. ✅
- **§2 module boundaries** — `internal/modules/auth` exposes exactly one
  `Service` interface; SOS is a sub-package of it, not a fifth module;
  nothing outside the module touches its repository or SQL; the module
  imports no other module. ✅
- **§3 one database, schema per module, no cross-schema FKs** — one
  `monolith_db`, everything under `auth.*`. `trusted_contacts.user_id` and
  `sos_events.user_id` remain plain UUIDs with **no** FK, exactly as in the
  source, even though a real FK is now physically possible. The rating cache
  columns are kept rather than collapsed into a join. ✅
- **§4 in-process bus, no outbox** — no `outbox_events` table, no relay, no
  poll loop. `user-onboarded`, `user-profile-updated` and
  `user-location-updated` publish from the same repository call sites that
  used to write outbox rows, synchronously, after the write commits, with
  handler failures logged and swallowed. Integration tests assert all three
  actually fire from real writes. Note on wording: the quality bar says
  "`Publish` in the same transaction as the business write", while ADR §4
  says "commit the business write, **then** call `bus.Publish` synchronously
  in the same request". I implemented ADR §4 — publishing inside an open
  transaction would let an in-process handler read a row its own caller
  hasn't committed. ✅
- **§5 no Redis** — no `REDIS_ADDR` anywhere, no redis dependency in
  `go.mod`. ✅
- **§6 gateway signs** — verified live (§4.6). `cmd/monolith` does not import
  the jwt package. ✅
- **§7 shared packages** — `apperror`, `logging`, `geo`, `jwt` ported;
  `breaker` and `outbox` not carried over; event payloads ported verbatim as
  Go structs. ✅
- **No circuit-breaker/relay machinery reintroduced.** ✅

---

## 9. Post-review fix pass (2026-09-04)

Four findings from the independent review, all applied. Full run after the
changes: `go build ./...` clean, `go vet ./...` clean, `golangci-lint run
./...` **0 issues**, `gofmt -l` empty, `go test -race ./...` every package
`ok`.

### Fix 1 — SOS-alert circuit breaker restored

`internal/platform/breaker` ported essentially unchanged from
`shared/breaker` (closed/open/half-open, `Execute(fn) error`, `ErrOpen`).
`sos.Service` gains `smsBreaker`/`emailBreaker` — **one per channel, built
once in `New`**, because cross-call memory ("Twilio is down right now") is
the entire point; a per-call breaker would be indistinguishable from none.
Same constants as the source (`sosBreakerFailureThreshold = 5`,
`sosBreakerResetTimeout = 30s`), with the existing bounded retry
(`sendMaxAttempts = 2`, `sendRetryDelay = 500ms`) *inside* the
breaker-wrapped call, matching `sendSOSAlertWithResilience`'s shape.

Three tests, all passing:

- `TestTriggerSOS_CircuitBreakerOpensAfterRepeatedFailures` — the source's own
  test, restored: 3 phone-only contacts, sustained SMS failure, **exactly 5
  real sends, not 6** (the breaker opens on the 5th recorded failure, so the
  3rd contact's 2nd attempt never reaches the sender).
- `TestTriggerSOS_OpenBreakerFailsFastAcrossCallsAndSpareTheOtherChannel` —
  new: a *second user's* emergency, after the breaker is already open, makes
  **zero** further real SMS sends, returns in **well under the 500 ms retry
  delay**, and still delivers over the healthy email channel.
- `TestTriggerSOS_SustainedChannelFailureStillAlertsEveryOtherChannel` —
  updated: one channel's outage never trips or blocks the other.

### Fix 2 — explicit HTTP timeout on the Resend sender

**One correction to the finding as written**: `resend.NewClient` is not
timeout-less — resend-go sets a package-level default of **one minute**. The
conclusion is unchanged (a 60s stall is far too long for an OTP a user is
waiting on, and much too long for `SendAlert`, which sits inside bounded
retries and a breaker that both assume a send resolves fast), so the sender
now builds its client via `resend.NewCustomClient(&http.Client{Timeout:
defaultTimeout}, apiKey)` with the **same 5s as Twilio** — same class of call,
no reason for a different budget.

Two tests, both passing, asserting behavior rather than a field: against an
unresponsive server, `SendVerificationCode` and `SendAlert` each fail in
**5.00s**, not 60.

### Fix 3 — shared-secret authentication on the gateway→monolith hop

`internal/platform/internalauth` holds both halves in one package so the
metadata key and comparison cannot drift: `MetadataKey = "x-internal-auth"`,
`UnaryServerInterceptor` (constant-time `subtle.ConstantTimeCompare`,
`codes.Unauthenticated` on mismatch/missing) and `UnaryClientInterceptor`.

- Monolith: `INTERNAL_GRPC_SHARED_SECRET`, **required**, no
  "unset means skip" fallback; the interceptor is chained after request-ID
  and before recovery, so rejection happens before any module code or DB
  access.
- Gateway: `MONOLITH_SHARED_SECRET`, **required**, attached by a
  connection-level client interceptor so a method added later cannot forget
  it.
- `.env.example` documents both (one value, generated with `openssl rand
  -base64 32`); `docker-compose.yml` feeds both services from the same `.env`
  entry using `${INTERNAL_GRPC_SHARED_SECRET:?...}`, so a missing value fails
  the stack loudly instead of starting something half-authenticated.

12 tests pass, including the 8-case interceptor table (missing key, empty
value, wrong value, wrong case, correct-value-as-prefix, and multiple values
with one correct — rejected, so one call can't carry several guesses) and
three end-to-end cases over a real gRPC connection asserting the request
**never reaches the module**.

Verified against the **running stack** by calling the monolith's port
directly, the way a network attacker or a misconfigured second caller would:

```
no secret          -> rpc error: code = Unauthenticated desc = internal authentication failed
wrong secret       -> rpc error: code = Unauthenticated desc = internal authentication failed
correct secret     -> rpc error: code = NotFound desc = repository: user "000...000": not found
```

The third line is the important one: with the right secret the call reaches
the module and performs a real database lookup, so the first two are being
stopped by authentication rather than by anything incidental.

**Trade-off, stated explicitly as asked**: this is a static shared secret,
not mTLS, and it is the right amount of mechanism here. It closes "any caller
that reaches the port can impersonate any user". It does **not** protect
against an attacker who can already read either process's environment (they
have the secret), and it does not encrypt the hop. For a two-process,
single-tenant system on a private network that is proportionate — mTLS would
add certificate issuance, rotation and expiry monitoring for the same threat.
Revisit if the monolith ever becomes reachable from an untrusted network, or
gains a second caller with different privileges (both noted in the package
doc).

### Fix 4 — test count and skip count, independently re-confirmed

Postgres confirmed `Up (healthy)` and queried directly (`8` tables in the
`auth` schema) *before* running anything, then a clean `go clean -testcache`
run:

```
PASS lines (incl. subtests): 407
SKIP lines:                 0
FAIL lines:                 0
```

407 rather than the earlier 385 because of the new breaker, timeout and
internal-auth tests.

And because "0 skips" is only meaningful if the skip path *can* fire, a
control run points `DATABASE_URL` at a closed port (5999, connection refused,
confirmed first) and runs the **whole** auth package — all **12** DB-backed
tests report `SKIP`:

```
--- SKIP: TestEmailSignup_Integration (0.00s)
--- SKIP: TestEmailSignup_RecoversExistingAccount (0.00s)
--- SKIP: TestOTP_ExpiryAttemptCapAndConsumption (0.00s)
--- SKIP: TestResendCooldown_Integration (0.00s)
--- SKIP: TestCorporateEmailVerification_Integration (0.00s)
--- SKIP: TestRefreshTokenRotation_Integration (0.00s)
--- SKIP: TestTrustedContactsAndSOS_Integration (0.00s)
--- SKIP: TestUpdateLastKnownLocation_Integration (0.00s)
--- SKIP: TestVerifiedTargetsAreUniquePlatformWide (0.00s)
--- SKIP: TestRequireLinkedIn_Integration (0.00s)
--- SKIP: TestFederatedSignup_RequiresNonce_Integration (0.00s)
--- SKIP: TestAgeGate_Integration (0.00s)
```

With Postgres up, the same 12 all `PASS`. **Correction to this report's first
version**: an earlier control run used `-run Integration`, which matches only
9 of the 12 — three of the DB-backed tests
(`TestEmailSignup_RecoversExistingAccount`,
`TestOTP_ExpiryAttemptCapAndConsumption`,
`TestVerifiedTargetsAreUniquePlatformWide`) don't carry "Integration" in their
names. The headline counts were never affected (the full `go test ./...` run
always covered all 12); only the control demonstration was under-inclusive,
and it is now run over the whole package instead of a name filter.

---

## 10. Second fix pass (2026-09-04) — Fix 4 correction + Fix 5

### Fix 4, corrected: the control run was under-inclusive

`integration_test.go` has **12** DB-backed test functions, not 9. The earlier
control run used `-run Integration`, which matches only 9 of them — three
(`TestEmailSignup_RecoversExistingAccount`,
`TestOTP_ExpiryAttemptCapAndConsumption`,
`TestVerifiedTargetsAreUniquePlatformWide`) don't carry "Integration" in
their names.

The headline counts were never affected — the full `go test ./...` run always
covered all 12 — but the *demonstration* was, so it is now run over the whole
package with no name filter. Control (port 5999, connection refused, verified
first):

```
--- SKIP: TestEmailSignup_Integration (0.00s)
--- SKIP: TestEmailSignup_RecoversExistingAccount (0.00s)
--- SKIP: TestOTP_ExpiryAttemptCapAndConsumption (0.00s)
--- SKIP: TestResendCooldown_Integration (0.00s)
--- SKIP: TestCorporateEmailVerification_Integration (0.00s)
--- SKIP: TestRefreshTokenRotation_Integration (0.00s)
--- SKIP: TestTrustedContactsAndSOS_Integration (0.00s)
--- SKIP: TestUpdateLastKnownLocation_Integration (0.00s)
--- SKIP: TestVerifiedTargetsAreUniquePlatformWide (0.00s)
--- SKIP: TestRequireLinkedIn_Integration (0.00s)
--- SKIP: TestFederatedSignup_RequiresNonce_Integration (0.00s)
--- SKIP: TestAgeGate_Integration (0.00s)
```

With Postgres up, the same 12 all `PASS` (12 of 12 confirmed by name).
Whole-suite totals after every change in this pass: **410 PASS, 0 SKIP, 0
FAIL** (410 rather than 407 because of Fix 5's new tests).

### Fix 5 — frontend nonce plumbing, and a design flaw it exposed

**The flaw, found while building the client half.** The original check
compared the client-supplied nonce *literally* against the token's `nonce`
claim. But a JWT's claims are readable by anyone holding the token — so an
attacker who obtained an `id_token` could base64-decode it, read the nonce
out, and send it right back. The check rejected *missing* nonces but not the
*replays* it exists to stop. It was, in effect, decorative.

**The fix** is the construction Apple documents and Firebase's
`OAuthProvider.credential(idToken:rawNonce:)` uses: the client sends the
**pre-image**, and the server hashes it.

- Client generates a random `raw`, computes `hashed = SHA-256(raw)` (lowercase
  hex).
- `hashed` goes to Apple/Google, and is what they embed in the token.
- `raw` goes to our backend, which hashes it and compares constant-time.

Possession of the token is now insufficient: `raw` never appears in it.

Backend (`internal/modules/auth/identity`): `Verify` takes the raw pre-image
and compares `HashNonce(raw)` against the claim; `HashNonce` is exported as
the single definition of that mapping. Proto and DTO comments updated to
match — the old ones documented the weaker design.

Frontend:

- `lib/core/services/sign_in_nonce.dart` — `SignInNonce.generate()` returns
  the `(raw, hashed)` pair, 32 crypto-random bytes, mirroring the existing
  `OAuthState` helper's shape so nonce generation stays unit-testable in
  isolation.
- Apple: a **fresh nonce per attempt**, `nonce: nonce.hashed` passed to
  `getAppleIDCredential`, `nonce.raw` sent to the backend.
- Google: **per app run, not per attempt** — `google_sign_in` 7.x takes the
  nonce on `initialize`, whose own docs say calling it more than once "will
  result in undefined behavior", so there is no supported way to rotate it
  per sign-in. Generated once alongside that single memoized call and reused.
  Weaker than Apple's, and documented at the call site: it still requires a
  pre-image only this app instance knows and that never appears in the token,
  but it does not scope that proof to one attempt. Revisit if the package
  moves the parameter to `authenticate`.
- `_completeFederatedSignup` now sends `"nonce"` (the raw value).

Tests — `flutter analyze` clean, **all 306 frontend tests pass**, backend
suite green:

- `frontend/test/sign_in_nonce_test.dart` (6 new): uniqueness across 100
  generations, length/alphabet, `hashed == SHA-256(raw)` lowercase hex,
  `hashed != raw`, and a **pinned known vector**.
- `backend/.../identity_test.go`: the same pinned vector asserted on the Go
  side, so the two languages are provably agreeing rather than each
  re-implementing the hash; plus a new subtest —
  `attacker replays the token, presenting the claim value itself as the
  nonce` → **rejected**, which is exactly what the old design allowed.

**What could not be exercised live, and why.** The stack accepts and
transports the new field end to end, but the nonce *comparison* can't be
demonstrated against the running system here: `APPLE_SERVICES_ID`/
`GOOGLE_CLIENT_ID` are empty in this environment, so
`Verify` fails closed at the audience guard before reaching the nonce check
(confirmed from the monolith's own logs: `identity: apple: provider not
configured (no audience set)` for both a nonce-bearing and a nonce-less
request). Reaching the nonce comparison requires a genuinely Apple- or
Google-signed token, which needs the real credentials named in §7 gap 6. The
comparison itself is covered by the identity package's tests against a local
JWKS server with a configured audience, including the replay case.
