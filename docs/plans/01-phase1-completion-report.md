# Phase 1 completion report — scaffold, gateway, auth module

Implements `01-phase1-scaffold-gateway-auth.md` against
`../decisions/adr-001-modular-monolith-architecture.md`, at the quality bar
in `00-overview.md` and the security checklist in
`../security-review-framework.md`.

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

**385 test cases pass (including subtests); 0 failures, 0 skips.** The skip
count matters: the integration tests self-skip when Postgres is unreachable,
so "0 skips" is the evidence they really ran.

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
- **Accepted regression (deliberate, per ADR-001 §7)**: the source wraps each
  SOS alert send in a per-channel circuit breaker so that once Twilio/Resend
  is down, later contacts fail fast. `shared/breaker` is explicitly not
  carried into this repo, so the breaker is gone; the bounded retry (2
  attempts, fixed 500 ms) is kept. Consequence: during a full channel outage,
  `TriggerSOS` can take up to (contacts × channels × 2 × per-send timeout)
  instead of short-circuiting. This is on an emergency path — see §7, gap 1.
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
5. **SOS circuit breaker not ported** (ADR-001 §7 + the phase prompt). Retry
   kept, breaker dropped. See Availability above and §7, gap 1.
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

1. **SOS alert resilience regressed relative to the source** — the circuit
   breaker is gone per ADR-001 §7 (§6.5). If the intent was that the ADR's
   "breaker not carried over" applied only to the event-delivery machinery,
   this is a one-file change in `internal/modules/auth/sos`. Flagged for an
   explicit decision rather than silently restored.
2. **Apple/Google sign-in needs a frontend change for the nonce** — generate a
   random nonce per attempt, pass it to `getAppleIDCredential` / Google's
   authenticate call (for Apple, hand the provider the SHA-256 and send that
   same value), and include it as `"nonce"` in the
   `/v1/auth/federated/signup` and `/v1/auth/identities/link` bodies. Backend
   side is done and tested; the client half is not in this phase's scope.
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
