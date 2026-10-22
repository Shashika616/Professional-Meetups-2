# Security and Optimization Review, 2026-10-01

**Scope:** `Professional-Meetups-Monolith` (Go gateway + monolith, Flutter app, Cloud Run deploy config, CI).
**Method:** read-only code review by four parallel reviewers (gateway/platform, auth+SOS, meetup/notification/outbox, Flutter/deploy), against `TESTING-NOTES.md`, `docs/security-review-framework.md` and ADR-001 to ADR-008. Nothing was executed: no Go or Flutter toolchain was available, so there was no `go vet`, `gosec`, `govulncheck` or advisory scan of `pubspec.lock`. Run those in CI as a follow-up.
**Verification:** findings marked **Verified** were re-read against the code by the lead reviewer. Findings marked **Reported** come from a slice review and were not independently re-read. Reviewer line numbers were unreliable (several exceeded the file length), so this report cites file and function only.

---

## 1. Test fixtures register

Per your instruction these are **not** treated as vulnerabilities. This register is the documentation of them, including where the existing docs are incomplete.

| Fixture | Where | Deployed? | Documented in TESTING-NOTES? | Notes |
|---|---|---|---|---|
| `ALLOW_TEST_OTP_BYPASS` (global `123456`) | `auth/otp.go`, `cmd/monolith/main.go` | **No.** `service.yaml` sets `"false"`. Local compose only. | Yes | Confirmed a no-op unless exactly `"true"`. Loud WARN on every startup. |
| `TEST_OTP_BYPASS_PHONES` | same | **Yes** (two physical test devices) | Yes | Phone purpose only, byte-exact target match, no content validation. Count-only startup WARN. |
| `TEST_OTP_BYPASS_EMAILS` | same | **Yes** | Yes | All four email purposes. Startup aborts unless every entry is on `.test`, `.example`, `.invalid` or `.localhost`, so a real address cannot be allowlisted. |
| 8 seeded `@meetups.test` users | `backend/testdata/seed-test-users.sql` | **Unverified** | Yes (the file and the L3 Alpha account) | Applied by hand, not a migration. The runbook does not say whether it was applied to the production database. See gap D-1. |
| `LoggingSmsSender` / `LoggingEmailSender` | `cmd/monolith/main.go` | Fallback when Twilio/Gmail secrets are absent | Yes | Prints live OTPs at Info. See V-9. |
| `debugLaunchUrlOverride` | `frontend/lib/.../location_view_page.dart` | Compiled into release builds | **No** | Harmless test hook, but undocumented. See gap D-4. |
| CI canary `backend/secrets/canary.pem` | `.github/workflows/backend-ci.yml` | CI only | Only in a CI comment | Confirms `.dockerignore` excludes secrets. |
| `aps-environment=development` | `frontend/ios/Runner/Runner.entitlements` | Dev builds | Deferred in Round 10 notes | Must become `production` for TestFlight/App Store. See D-5. |

**Undocumented shortcuts found:** none. `123456` appears only in `otp.go`.

**Documentation gaps to close** (add to `TESTING-NOTES.md`):

- **D-1.** State whether `seed-test-users.sql` has been applied to the production Supabase database. If yes, anyone can sign in as those eight accounts with `123456` on the live service (the notes already accept this risk). Their meetups also appear in real users' nearby feeds and trigger real push fan-out, so say so.
- **D-2.** The `main.go` comment says allowlisted numbers are never logged, but the skip-send log lines in `verification.go` and `service.go` print the **target and the real code** at WARN. The notes admit the code is logged; the comment contradicts it. Make them agree.
- **D-3.** `TEST_OTP_BYPASS_PHONES` is byte-exact, and phone numbers are not canonicalised (V-6). Record that `+94 77 123 4567` and `+94771234567` are different entries. The notes already say this; add the link to V-6.
- **D-4.** List `debugLaunchUrlOverride` as a release-compiled test hook.
- **D-5.** List the `aps-environment` change as a pre-release checklist item.
- **D-6.** `docs/deploy/service.yaml.template` is at revision r22; the live manifest is r34. Regenerate it so the documented env vars match what is deployed.
- **D-7.** Add a pre-release checklist to `TESTING-NOTES.md` that covers every row above: `ALLOW_TEST_OTP_BYPASS` unset, both allowlists removed or reviewed, seed users removed from production, aps-environment production, test hook removed.

---

## 2. Findings, ordered by priority

Severity is my judgment given a small, pre-launch user base. "Fix" is the smallest change that closes it.

### High

**V-1. OTP attempt cap can be beaten with parallel guesses.** *Verified.*
`auth/verification.go` (`verifyAndConsumeCode`) and `auth/service.go` (the target-keyed equivalent) read the row, check `Attempts >= 5`, compare the code, and only increment on a mismatch. The increment is `UPDATE ... SET attempts = attempts + 1` with no lock or guard. Concurrent requests all read `attempts = 0` before any increment lands, so one code gets far more than five guesses. A fresh code can be requested every 60 seconds. For an unauthenticated email login this is an account-takeover path against any account with a personal email, limited only by the gateway rate limiter (which is weaker than intended, see V-3). The same race lets one valid code be consumed twice.
*Fix:* increment first with `UPDATE ... SET attempts = attempts + 1 WHERE ... AND attempts < 5 RETURNING ...`, then compare; consume with `DELETE ... WHERE code_hash = $x RETURNING`.

**V-2. Double accept miscounts capacity and closes the meetup early.** *Verified.*
`meetup/repository/meetup_requests_postgres.go` (the accept transaction) reads the request and checks `pending` **before** it locks the meetup row. The `AcceptMeetupRequest` SQL has no `status = 'pending'` predicate (the comment at the call site says it re-checks; it does not). A host double-tap sends two accepts. The second waits on the lock, then re-accepts the same row, and `newCount = acceptedCount + 1` counts the seat twice. With capacity 2 and one real acceptance, the meetup flips to `full` and every other pending request is auto-rejected with a push. Accept can also resurrect a request that was just rejected or withdrawn.
*Fix:* re-read the request `FOR UPDATE` after locking the meetup, add `AND status = 'pending'` to the accept query, treat zero rows as a conflict, and derive "full" from `CountAcceptedRequests` after the update.

**V-3. Rate limiter keys on the wrong IP behind Cloud Run, and shares one bucket.** *Mechanism verified; platform behaviour to confirm.*
`gateway/middleware/ratelimit.go` `clientIP` uses `RemoteAddr` only and never reads `X-Forwarded-For`. On Cloud Run `RemoteAddr` is Google's front end, not the caller. If so, every user shares one `(IP, path)` bucket per route: a single script can lock everyone out of login, OTP and guest signup, and ordinary traffic can trip it. Confirm in Cloud Run request logs what `RemoteAddr` shows.
Related (**F-02, Reported**): `service.yaml` allows `maxScale: 8` with a per-process in-memory limiter, so effective limits multiply up to 8x, and scale-to-zero resets counters on cold start.
*Fix:* read the client IP from the right-most trusted `X-Forwarded-For` hop (configurable hop count, never the left-most entry). Set `maxScale: 1`, or move auth/OTP counters to Postgres.

**V-4. Rate limiter memory exhaustion by unauthenticated callers.** *Reported.*
The limiter runs before auth and before the body cap. Target keys embed the raw request body (up to ~1 MiB) and live for an hour; the IP key includes the raw URL path, which is attacker-controlled. Repeated unique large `phone_number` values, or random long paths, grow the map until the one-minute sweep, which holds the mutex while scanning.
*Fix:* hash targets (SHA-256) and skip the keyed check above ~320 bytes, key IP limits on the matched route pattern or a constant `"unmatched"`, and cap bucket count.

**V-5. Android release builds are signed with the debug key.** *Verified.*
`frontend/android/app/build.gradle.kts`: the `release` build type uses `signingConfigs.getByName("debug")` (the TODO is still in the file), and `build.sh` ships these APKs by sideload. Anyone with a debug keystore can build an APK that updates over the real install; Google Play will reject debug-signed bundles. The single SHA-1 in `google-services.json` is most likely the debug key.
*Fix:* create a release keystore, read it from a gitignored `key.properties` or CI secrets, and register its SHA-1 and SHA-256 in Firebase and the Google OAuth Android client.

### Medium

**V-6. Email and phone are not canonicalised.** *Reported; the email part matches TESTING-NOTES.*
`GetUserByPersonalEmail` is `WHERE personal_email = $1` with a plain unique index. Effects: duplicate accounts for the same mailbox, users locked out if they retype a different case, and one mailbox backing several accounts (inflating Level 2). Phone numbers accept spaces and hyphens and are stored raw, so one SIM can verify several accounts, and the byte-exact test allowlist interacts with this.
*Fix:* trim and lowercase email and normalise phone to E.164 at service entry; add `UNIQUE (lower(personal_email))` after a dedupe migration.

**V-7. Refresh-token rotation can fork.** *Reported (two reviewers agree).*
Rotation reads the old token without `FOR UPDATE` and the mark-replaced update has no `replaced_by IS NULL AND revoked_at IS NULL` guard. Two concurrent refreshes with the same token both succeed, so reuse detection never fires in that window.
*Fix:* a single conditional `UPDATE ... WHERE id = $1 AND replaced_by IS NULL AND revoked_at IS NULL RETURNING`; zero rows means reuse, revoke the family.

**V-8. Request uniqueness constraint breaks re-request flows.** *Reported.*
`UNIQUE(meetup_id, requester_id, status)` lets a rejected user re-request; a second rejection (or the auto-reject on fill) then violates the key, giving the host a 500 and rolling back the last accept. Accepted, withdraw, re-request, accept, withdraw again hits the same collision.
*Fix:* replace with a partial unique index `WHERE status IN ('pending','accepted')`.

**V-9. Production fallback prints OTPs.** *Reported.* If Twilio/Gmail secrets are missing, the monolith silently falls back to loggers that print live codes at Info. *Fix:* fail startup or log ERROR when running in production without senders.

**V-10. Cancel has no status or time guard.** *Verified.* `CancelMeetup` is `WHERE id = $1 AND host_user_id = $3`. A host can cancel a completed meetup, flip it to cancelled (removing it from their public history), re-notify participants, and block reviews. *Fix:* add `AND status IN ('open','full')` and a window check; map zero rows to a conflict.

**V-11. Join request is not atomic with meetup state.** *Reported.* The open check runs outside the transaction; the insert does not recheck state or the window, and an already-accepted participant can open a second pending request. *Fix:* single `INSERT ... SELECT ... WHERE EXISTS (open, not ended) AND NOT EXISTS (pending/accepted)`.

**V-12. Spam and cost abuse surfaces.** *Reported.* (a) SOS/trusted contacts: contacts do not confirm, context text is free-form, there is no SOS cooldown, and the 3-contact cap is count-then-insert, so a Level 2 user can loop SMS/email to a third party at your Twilio cost. (b) A host can create back-to-back meetups, each pushing to up to 500 nearby users; requesters can loop request/cancel to push a host. (c) `ShareWithContacts` re-sends on every call. *Fix:* per-user daily caps, contact opt-in confirmation, atomic cap, dedupe on share, cap window length and lead time.

**V-13. Guest redaction can be bypassed via public profile.** *Partly verified.* `redactForViewer` nulls window times and host name but leaves `host_user_id`. The `/v1/users/{id}` gate allows any viewer when the target "hosts a meetup", and returns recent-meetup window times unredacted. A guest can read hidden windows. Exact coordinates and labels are visible to guests by design (ADR-002). *Fix:* apply the trust floor in `GetMemberActivity` and drop `host_user_id` for guests; decide whether exact location should be participant-only (ADR-004's coarsening is client-side only).

**V-14. LinkedIn can be re-pointed on an account that already has one.** *Reported.* `LinkIdentityToUser` never checks for an existing `linkedin_sub`, so a verified identity can be swapped while keeping trust and ratings. *Fix:* reject if a different sub is already linked, or require an explicit unlink.

**V-15. Rating inflation without attending.** *Reported.* "Happened" feedback is self-asserted and needs only `now >= window_start`; check-in is not required, so sock-puppet hosts and participants can rate each other. *Fix:* require check-in or mutual confirmation after `window_end`.

**V-16. `verification_codes` never swept, and holds PII.** *Reported.* Target-keyed rows (unauthenticated email signup/login) are unbounded, keep raw email addresses, and are not removed by account deletion; the sweeper comment claiming the table is self-limiting is wrong. *Fix:* hourly delete of expired rows with an index on `expires_at`; delete by target on account deletion.

**V-17. Mobile client.** *Reported.* (a) Any refresh error, including a transient 5xx or network drop, clears the stored session and logs the user out. (b) Only one of ~15 auth HTTP calls has a timeout; a stalled socket can block every request through `getValidSession`. *Fix:* clear the session only on explicit 401/invalid-grant; add a shared 20-30 s timeout.

**V-18. Database role and backups.** *Reported.* The app connects to Supabase as the `postgres.<ref>` admin role with `sslmode=require` (no certificate verification); the nightly full-PII backup workflow uses a long-lived service-account key with `objectAdmin`. *Fix:* a dedicated least-privilege `app_rw` role, `sslmode=verify-full` with the Supabase CA, Workload Identity Federation for CI, `objectCreator` only, and bucket retention lock.

**V-19. Push circuit breaker and duplicate delivery.** *Reported.* A single bad device token (foreign-project token, 403) counts as a breaker failure; five trip the breaker for all users for 30 s. Outbox rows are claimed 50 at a time with a 60 s lease that sequential delivery can exceed, so a second instance can double-send. *Fix:* classify 4xx token errors as unregistered, count only 5xx/network toward the breaker, extend the lease per row, add an FCM collapse key.

**V-20. Latent bug: subscription cache SQL.** *Reported.* `subscription_cache_postgres.go` uses an unqualified table name while the table is `meetup.subscription_cache`, so it will fail once billing events arrive. Also reported: `internal/modules/billing` is an empty directory, so no receipt or entitlement verification exists in this repo; confirm where premium entitlement is enforced.

### Low / hardening

- **JWT:** no `aud` check, `exp` not required, no empty-`UserID` guard (`platform/jwt/verifier.go` has only `WithValidMethods` and `WithIssuer`). Verified. Add `WithAudience`, `WithExpirationRequired`, reject empty user id.
- **`/metrics`** is served unauthenticated on the public listener. Verified route. Move to an internal port or require a secret header.
- **Deleted-account access tokens** stay valid up to 15 minutes (documented; safe direction).
- **gRPC client calls** have no gateway-side deadline; add an 8 s client interceptor.
- **`X-Request-ID`** accepted unbounded from the client; restrict to `^[A-Za-z0-9-]{8,64}$`.
- **Geocoding:** no `io.LimitReader`, no 1 req/s throttle (Nominatim policy), coordinates logged in error URLs.
- **Free-email domain list** has only 7 entries, so `proton.me`, `live.com`, `googlemail.com` and similar pass as "work email". ADR-019 accepts the MVP trade-off.
- **Free text:** feedback notes and device tokens have no length limits; cancel/decline reasons go into push bodies and the outbox.
- **Rating anonymity:** per-meetup averages show for 1-2 reviews; suppress below 3.
- **Android:** no `allowBackup="false"`, no R8/obfuscation, `INTERNET` permission only in debug/profile manifests (verify release merges it).
- **iOS:** `aps-environment` development (see D-5).
- **Custom-scheme deep link** has no PKCE; the LinkedIn flow binds `state` correctly, and the pubspec comment mentioning PKCE is stale.
- **Third-party geocoding** sends typed queries and IP to Photon/Nominatim; disclose in the privacy policy and debounce.
- **STADIA key** is compiled into the binary if `MAP_PROVIDER=stadia`; restrict by referrer or proxy it.
- **Compose** publishes Postgres/gRPC on all interfaces with `app/app` credentials; bind to `127.0.0.1`.
- **CI:** third-party actions are not pinned to SHAs, workflows lack `permissions:` blocks, the service uses the default compute service account.
- **Firebase `google-services.json`** is tracked in git, which is acceptable, but confirm the `AIza...` key is restricted to Firebase APIs and your app's package/SHA/bundle in the GCP console.

---

## 3. Performance and optimization

1. **Browse query cost scales with all matching meetups, not the page** (`queries/meetups.sql`): the `DISTINCT ON` CTE computes ratings and accepted counts for every meetup in radius before the cursor and `LIMIT`. Page first, then aggregate for those rows.
2. **Profile queries scan whole tables** (`queries/member.sql`): a UNION ALL CTE referenced three times is materialised, and `CanViewMemberProfile` self-joins unscoped subqueries. Filter by target inside each arm or use `EXISTS`.
3. **Sweeps are not index-friendly:** `ClaimMeetupsStartingSoon` uses `window_start - now() <= interval '30 minutes'`, which is not sargable (use `window_start <= now() + interval '30 minutes'`); `ClaimMeetupsToAutoClose` sorts on `window_end` against an index led by `window_start`; `ListForMeetup` is unbounded.
4. **Refresh-token and guest sweeps do full scans:** rotated tokens are kept ~37 days, with no index on `revoked_at`/`expires_at` or on `users(is_guest, updated_at)`. Add partial indexes and retention for rotated rows.
5. **Event publishing uses the request context:** a client disconnect after commit cancels the nearby-notify fan-out. Publish with `context.WithoutCancel` or route through the outbox.
6. **Notification history gaps:** outbox rows are written only for recipients with tokens, so the in-app list misses entries for token-less users.
7. **Client:** shared timeout helper for auth calls (see V-17); pagination, `ListView.builder` and avatar `cacheWidth/Height` are already in place.

---

## 4. Confirmed clean (checked, no issue found)

- **Secrets hygiene:** `backend/.env`, `frontend/.env`, the JWT keys and the HMAC key are gitignored and none were ever committed to git history. Deployed secrets come from Secret Manager. Only client IDs, the Twilio SID/number and the allowlists are plain env.
- **Topology:** the monolith is a localhost sidecar, not a public service; every gRPC call needs the shared secret, compared in constant time.
- **JWT core:** RS256 pinned, issuer checked, unknown `kid` rejected, only public keys in the verifier set.
- **OTP basics:** `crypto/rand`, SHA-256 hashed at rest, constant-time compare, 10-minute expiry, 60-second cooldown.
- **Federated sign-in:** Apple/Google audience, issuer, RS256 and raw/hash nonce correct; linking is by `(provider, subject)`, never by email.
- **Authorization:** participant/host checks verified on request list/respond/withdraw, cancel, close, all five safety methods, feedback, review and participant list; identity always comes from the verified gateway context.
- **SQL:** all queries are sqlc or `$n` parameterised.
- **Account deletion (ADR-008):** one transaction, idempotent; only the documented 90-day safety hold keeps PII.
- **Containers:** distroless nonroot, `.dockerignore` excludes secrets and CI asserts it.
- **Client:** tokens in `flutter_secure_storage`, no WebView, no custom certificate handling, no ATS exception.

---

## 5. Suggested order of work

1. ~~V-1 (OTP race), V-2 (double accept), V-10 (cancel guard)~~ - **done 2026-10-08, Plan 26.**
2. V-3 and V-4 together (client IP, bucket keys, `maxScale`), then confirm `RemoteAddr` in Cloud Run logs.
3. V-5 (release signing) before any TestFlight/Play/sideload distribution beyond your own devices.
4. V-6, V-7, V-8, V-11: canonicalisation and constraint migrations (needs a dedupe migration first).
5. V-12 caps and V-13 guest gating.
6. Documentation items D-1 to D-7.


---

## 6. Status update 2026-10-08

Reviewed the uncommitted working tree against the findings above. No code was changed by this update.

- **V-6 (canonicalisation):** the email half is addressed in the working tree (`identity.NormalizeEmail`, migration 0017 `UNIQUE (lower(personal_email))`). Not deployed yet. The phone half is still open.
- **V-1, V-2, V-10: FIXED 2026-10-08 (Plan 26), in the working tree, not deployed.** See `docs/plans/26-otp-race-double-accept-cancel-guard-completion-report.md`. V-1: the OTP attempt is claimed atomically before the code is compared, and a correct code is consumed with a conditional delete, on both the user-keyed and the target-keyed path. V-2: the accept transaction locks the meetup first, re-reads the request under its own lock, carries `status = 'pending'` in the UPDATE, and derives full-ness from a fresh count. V-10: `CancelMeetup` carries `status IN ('open','full')` and a wrong state is a conflict rather than a not-found. No migrations.
- **V-3, V-4, V-5:** unchanged, still open.
- **New account-claim flow (ADR-009):** HMAC-signed ticket plus a new OTP purpose `account_claim` (migration 0018). **It no longer inherits V-1** - the claim path goes through the same target-keyed verify as email signup and login, so the atomic attempt claim covers it. Still open: no per-target claim limit, it shares the work-email HMAC key, and it is not covered by `TEST_OTP_BYPASS_EMAILS`. See gap-tracker #72-#74.
- **Open decisions:** whether to add `account_claim` to the test bypass. (The Level 2 question was decided on 2026-10-08 - a provider-verified email counts as the personal email - and is now pinned by a test, gap-tracker #72.)
- **Test fixtures:** documented in `TESTING-NOTES.md`. Whether `seed-test-users.sql` was applied to production is not recorded.
- **Account deletion is self-only, verified and pinned 2026-10-08.** `DELETE /v1/users/me` accepts no user identifier in any form; the id comes from `middleware.UserIDFromContext`, populated only after `verifier.Verify` validates the token signature. No header influences identity, there is no admin or impersonation route, Cloud Run publishes only the gateway's port 8080 (the monolith listens on `localhost:9090`), and the monolith's own RPC - which does take a `user_id` - additionally requires `INTERNAL_GRPC_SHARED_SECRET`. Pinned by `delete_account_authz_test.go`, including a case asserting that a body or query naming another user is ignored.
- Tracker items #51-#76 in `docs/gap-tracker.md` mirror these findings.
