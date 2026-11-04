# 30B completion report: security and location fixes (backend)

Status: **complete** (2026-11-02). Every item has a test that failed before the change, except where noted. Working tree only, nothing committed (plan §1: commits only in 30A), pushed or deployed.

The sign-in test codes, the seeded test users and the scoped bypass are unchanged, and the allowlisted targets are exempt from the new budgets. `TestASeededTestAccountSignsInTwentyTimesInARow_Integration` signs a seeded account in 20 times in a row, with wrong guesses in between, and checks that no budget row is written.

Migrations: **0033** (OTP budgets, shared rate counters), **0034** (company-claim review status), **0035** (meetup creation request hash). All are additive; up, down 3, up is clean. Route-level changes are listed in `docs/api/plan-30-changes.md`.

## 1. #106 OTP budgets

**Storage:** `auth.otp_budgets` is keyed by a SHA-256 of the normalised target, plus purpose and Asia/Colombo day. No address or number is stored.

**Limits** (the same message whether or not an account exists):
- **Sends:** at most 5 per target, purpose and day, on every OTP start path: email login and signup start, account-claim resend, and phone, personal-email and corporate-email start.
- **Failed guesses:** at most 10 per target, purpose and day, on every verify path. A guess is taken atomically before the comparison and given back when it is right, so parallel guesses cannot overshoot and successful sign-ins never use up the allowance.
- **No reset:** a new code does not reset either count.
- **Fails closed:** if the database can't be reached, it refuses with 503.

**Exempt:** the allowlisted test addresses and numbers.

**Sweep:** `auth: otp budgets` keeps only today and yesterday.

**Not done (deliberate):** a per-target limit at the gateway for the start routes. The gateway can't see the test allowlist, so it would have locked out the test accounts. The service-level budget is shared across instances and does the job.

**Tests:**
- the 6th send is refused, including for another spelling of the same address;
- an existing account gets the same refusal;
- the refusal holds across codes after 10 failures;
- a right code isn't counted;
- 30 concurrent guesses allow exactly 10;
- the 20 sign-ins in a row above.

## 2. #107 limiter body peek

**Change:** the key is now found without regard to case, the way `encoding/json` matches it. A body that repeats any top-level key, exactly or in another case, is refused with 400.

**Tests:** `PHONE_NUMBER`, `Phone_Number`, `EMAIL`, an exact duplicate, a case conflict, and a duplicate on another key.

## 3. #81 shared limiter

**Mechanism:** `ops.rate_counters`, a one-statement claim that refuses at the cap. Keys are hashed, windows are aligned to Colombo days, and expired windows are swept.

**Where it is used:**
- **Trusted-contact changes:** 5 a day, fails closed.
- **Meetup shares:** 3 a day, fails open.
- **OTP:** uses `otp_budgets`.
- **SOS:** its 5-an-hour cap moved from gateway memory into the SOS claim, under the user lock, after a retry with the same `client_request_id` is recognised. A retry is therefore never counted, which a separate counter couldn't guarantee.
- **Photo upload:** comes in 30D.

**In-memory limiter:**
- keyed on the route pattern, so all meetup ids share one bucket and all unknown paths share another;
- capped at 100,000 keys, evicting the oldest first.

**Tests:** limits and independence; 30-way concurrency gives exactly 5; fail closed vs open; sweep; eviction order; route-pattern keying; SOS hourly cap counted with retries ignored; the 6th contact change; the 4th share.

## 4. #111 work email

**Unknown company:**
- the proven domain and name are kept;
- `work_email_verified` stays false, so the account stays at Level 2;
- the claim is stored as `pending_review`.

Only a known company with a matching domain reaches Level 3.

**Throwaway inboxes:** an embedded list of disposable domains (63) is refused like free-mail domains.

The seeded Level 3 test accounts are SQL fixtures and unaffected.

## 5. #103 profile

**Change:** `ListRecentMeetupsForMember` returns only meetups that have ended (completed, or past their window and not yet swept). The gateway passes the token's trust level. A guest viewing anyone else gets no meetups, and the gateway blanks the name and photo (`identity_hidden`). The fully anonymous host reviews come in 30E.

## 6. Location, server side (plan 3.3)

- **One radius:** a single constant, `geo.BrowseRadiusMeters`, and a test that every SQL `ST_DWithin` radius equals it. The stale 40 km comments are fixed.
- **`GetMeetup`:** returns exact coordinates only to the host, accepted participants, or a signed-in viewer whose location from the last 24 hours is within the radius. A guest never gets them. The label stays.
- **Join:** refused (403 "Turn on location to join") when the location is unknown or more than 24 hours old.
- **Stored precision:** last known locations are rounded to 3 decimals, both in auth and in the meetup cache.
- **Sweeps:**
  - auth last-known locations over 30 days old;
  - SOS events over 90 days old;
  - cache rows over 30 days old;
  - meetups that ended over 180 days ago, coarsened to 2 decimals (D4), with the geography column following through the trigger.
- **Nominatim:**
  - no URL or coordinates in errors;
  - a 64 KB response cap;
  - a real User-Agent;
  - coordinates rounded before sending;
  - a 256-entry, 24-hour cache;
  - at most one request a second.
- **Query strings:** request logs already logged only the path. The OTel server span recorded `url.query`, which carries browse coordinates, so the edge wrapper hides it from the span.

## 7. Correctness and limits

- **#114 window_end:**
  - **Join:** the conditional insert requires an open meetup with `window_end > now()`, and when zero rows come back it tells "ended" apart from "rejected".
  - **Accept:** checks under the meetup lock and in the statement.
- **#115 outbox leases:** the claim's stamp is a lease. A new `outbox.Leaser` renews it just before each delivery and marks a row processed only under the same stamp. Tested against Postgres with two claimers.
- **Idempotency-Key:** a request hash is stored beside the key (0035). An exact replay returns the first meetup; different parameters get 409.
- **Review window:** reviews and ratings are refused 14 days after the meetup ended or was cancelled.
- **#120 JWKS** (the identity providers' published key sets):
  - **Bug found:** the bare storage never fetched again on an unknown key id, so a Google or Apple key rotation broke sign-in until the hourly refresh.
  - **Fix:** a small rotating set fetches again at most once a minute and refuses at once in between, which is the negative cache.
  - **Test:** fails on the old code.

## 8. Analytics (#110, #119)

- **Archive contents:** archived rows carry no `user_key` or `install_id`. I chose this over archiving aggregates only, because sessions, screens, flows and attributes keep the archive useful.
- **Archive retention:** a 90-day lifecycle rule is documented with the command (runbook §14).
- **Streaming:** the export is gzipped into a pipe and uploaded through Cloud Storage's resumable protocol in 8 MiB chunks, create-only, with a 412 treated as done.
- **`install_id`:** must be a 36-character UUID at the gateway. The app always sends one.
- **`id` attributes:** UUID-shaped values are refused.
- **Edge tracing:** the edge span is a new root linked to any inbound `traceparent`; inbound baggage is dropped, and the query string is never recorded.

## 9. Meetup share (D1)

- live meetups only (open or full, window not over);
- at most 2 contacts, with repeats removed;
- 3 shares a day;
- `NotifyMeetupShare` returns the ids it actually reached, and only those are recorded.

## 10. Found while doing this

| # | Finding | Severity | State |
|---|---|---|---|
| — | JWKS never refetched on an unknown key id (sign-in broken for up to an hour after a key rotation) | Medium | Fixed, tested |
| — | gosec findings from plan 29 would fail CI | — | Fixed in 30A |
| 122 | SOS sends without a claim if only the claim write fails | Low | Accepted. The contact read fails first when the database is down, so in practice it fails closed |
| 123 | The route-pattern IP limit is tighter for `{id}` routes behind a carrier NAT | Low | Watch; `pathLimits` is the knob |
| 124 | The resumable upload is verified against a strict fake, not real Cloud Storage | Medium-Low | Check the first production archive (a failure keeps the day rather than losing it) |

I also re-ran gosec and govulncheck, and reread the touched files.

## Gates

| Gate | Result |
|---|---|
| `gofmt` | clean |
| `go vet ./...` | clean |
| `golangci-lint run ./...` | 0 issues |
| gosec (as CI runs it) | 0 |
| `go test -race -count=1 ./...` | 40 packages pass. The integration tests ran against Postgres, which I restarted after Docker stopped overnight; an earlier "pass" with Postgres down was a skip and is not counted |
| `govulncheck` | nothing reached; `golang.org/x/net` S-8 waits for 2026-11-10 |
| sqlc / buf regenerate | no stray diff |
| `go mod tidy` | `golang.org/x/time` moved to a direct dependency (used by the JWKS limiter; already in the graph) |
| Migrations up, down 3, up | clean |
| `flutter analyze --fatal-infos` | no issues |
| `dart format --set-exit-if-changed` | no changes |
| `flutter test` | 877 pass |

## For the owner

- **Archive lifecycle rule:** apply it (runbook §14).
- **Testers:** know that joining now needs Home to have reported a location in the last 24 hours (TESTING-NOTES).
- **First production archive:** confirm it after the deploy (#124).
