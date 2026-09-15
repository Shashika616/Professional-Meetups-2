# Phase 2 completion report — meetup module

Implements `02-phase2-meetup-module.md` against
`../decisions/adr-001-modular-monolith-architecture.md` (including its
Corrections section), at `00-overview.md`'s Quality Bar and
`../security-review-framework.md`'s six properties.

Everything below was run in this environment. Where something was not
exercised, it says so and why.

---

## 0. Read this first — three of this phase's premises were already true upstream

The phase plan and the security framework both describe gaps in
`../Professional-Meetups` that **no longer exist**. I ported the source's
current state, which already contains all three fixes. This matters because
"we fixed a vulnerability here" and "the source fixed it and we ported the
fix" are materially different claims, and because the framework doc will keep
misleading Phases 3-5 until it's corrected.

**1. The Safety Gate authorization gap is already fixed upstream.**
`security-review-framework.md` says "none of `GetSafetyState`,
`AcknowledgeSafetyChecklist`, `SetLiveLocationOptIn`, or `CheckIn` check that
the caller is actually a participant". The source's
`services/meetup/internal/service/safety.go` has `requireParticipant`, called
by all **five** methods, with a comment reading "it's also the fix for the
actual bug this ADR resolves — before this, none of them checked the caller
against the meetup at all." That is the source's own ADR-024 §3, marked
*"Accepted (2026-08-26), built and independently verified (2026-08-31)"*.

**2. The per-participant schema is already fixed upstream.** The framework
calls `meetup_safety_state` "one shared row per meetup". The source's
migration `0007_safety_state_per_participant.up.sql` drops and recreates it as
`PRIMARY KEY (meetup_id, user_id)` with `declined_at`/`decline_reason` — the
exact DDL the phase plan asks for, from ADR-024 §1.

**3. The `ListOpenMeetups` host-bypass fix is already in the source SQL.**
The plan says to "build the host-bypass fix in from the start" and calls it "a
real gap confirmed against the source". Both of the source's queries
(`ListOpenMeetupsByIntentFirstPage` and `…AfterCursor`) already contain
`m.host_user_id = $2 OR ST_DWithin(...)`, with a comment giving the same
rationale the plan gives, including the "deliberately reuses $2" note.

**Consequence for this phase**: it is a straight, faithful port with no
functional deviation from the source. The end state matches what the plan
asks for in all three cases — I just want the record to show these were
ported, not invented here. **Recommend correcting
`docs/security-review-framework.md`'s Authorization section** (its Phase-2
item is now factually wrong); I have not edited that doc, since it is the
governing document for later phases and changing it is your call.

**One more doc/source mismatch, this one load-bearing.** Plan Step 3 says
"`requiredTrustLevel` per intent is **2**, mirrored from
`IntentType.requiredTrustLevel` in the frontend (unchanged)". The frontend
says `rideShare || dating => 4, _ => 2`, and so does the source's
`trustgate.go`. Implementing a flat 2 would have let trust-level-2 users
create and join dating and ride-share meetups. **I ported the real 4/2 rule**
— the instruction's own "mirrored from the frontend (unchanged)" clause is
what I followed, not its "is 2" summary.

---

## 1. Toolchain verification (real output)

```
$ go build ./...          (clean)
$ go vet ./...            (clean)
$ golangci-lint run ./... 0 issues.
$ gofmt -l .              (nothing listed, excluding generated proto/sqlcgen)
```

`go test -race ./...`, with `DATABASE_URL` pointed at a real Postgres:

```
ok  .../internal/eventbus                     1.466s
ok  .../internal/gateway/handlers             9.195s
ok  .../internal/gateway/middleware           2.603s
ok  .../internal/modules/auth                10.876s
ok  .../internal/modules/auth/email          12.329s
ok  .../internal/modules/auth/identity        3.545s
ok  .../internal/modules/auth/linkedin        3.603s
ok  .../internal/modules/auth/repository      3.195s
ok  .../internal/modules/auth/sms             2.966s
ok  .../internal/modules/meetup               9.551s
ok  .../internal/platform/apperror            1.397s
ok  .../internal/platform/breaker             1.464s
ok  .../internal/platform/geocoding           1.834s
ok  .../internal/platform/internalauth        1.734s
ok  .../internal/platform/jwt                 1.980s
ok  .../internal/platform/logging             1.361s
ok  .../internal/platform/ratelimit           1.422s
```

**514 test cases pass (including subtests); 0 failures, 0 skips** — up from
Phase 1's 410. Zero skips is the evidence the DB-backed tests actually ran
rather than taking their skip path.

---

## 2. Completeness against the inventory

### 2a. Gateway routes — 20 meetup routes, diffed against the source

The extracted `(method, path)` lists for the meetup subset are **identical**
to the source gateway's, verified mechanically:

```
$ diff <(mine) <(source)   # → no differences, 20 routes
```

| # | Method | Path | Middleware | Extra limit |
|---|---|---|---|---|
| 1 | POST | `/v1/meetups` | `requireAuth` → `UserKeyedRateLimit` | user-keyed 10/hour |
| 2 | GET | `/v1/meetups` | `requireAuth` | — (deliberate, see below) |
| 3 | GET | `/v1/meetups/mine` | `requireAuth` | — |
| 4 | GET | `/v1/meetups/active` | `requireAuth` | — |
| 5 | GET | `/v1/meetups/{id}` | `requireAuth` | — |
| 6 | POST | `/v1/meetups/{id}/close` | `requireAuth` | — |
| 7 | POST | `/v1/meetups/{id}/cancel` | `requireAuth` | — |
| 8 | GET | `/v1/meetups/{id}/requests` | `requireAuth` | — |
| 9 | POST | `/v1/meetups/{id}/requests` | `requireAuth` | — |
| 10 | POST | `/v1/meetups/requests/{id}/withdraw` | `requireAuth` | — |
| 11 | POST | `/v1/meetups/requests/{id}/respond` | `requireAuth` | — |
| 12 | POST | `/v1/meetups/device-token` | `requireAuth` | — |
| 12a | POST | `/v1/auth/logout` (+`fcm_token`) | `optionalAuth` | 2026-09-15 (ADR-005): also drops the device's push registration when the bearer proves the account; the `DELETE /v1/meetups/device-token` route added on 2026-09-14 was folded into this and removed. |
| 13 | GET | `/v1/meetups/{id}/safety` | `requireAuth` | — |
| 14 | POST | `/v1/meetups/{id}/safety/checklist` | `requireAuth` | — |
| 15 | POST | `/v1/meetups/{id}/safety/live-location` | `requireAuth` | — |
| 16 | POST | `/v1/meetups/{id}/safety/check-in` | `requireAuth` | — |
| 17 | POST | `/v1/meetups/{id}/safety/decline` | `requireAuth` | — |
| 18 | POST | `/v1/meetups/{id}/feedback` | `requireAuth` | — |
| 19 | GET | `/v1/meetups/{id}/ratings/ratable` | `requireAuth` | — |
| 20 | POST | `/v1/meetups/{id}/ratings` | `requireAuth` | — |

`ListOpenMeetups` keeping only the blanket 20/min per-(IP, path) limit is the
source's own reasoned position, ported deliberately: it has no external
per-call cost (one indexed query, GiST-backed), and browsing is frequent,
low-stakes usage a tighter budget would break. Both limits are pinned by
tests (`TestCreateMeetupRoute_HasItsOwnPerUserRateLimit`,
`TestListOpenMeetupsRoute_HasNoPerUserRateLimit`).

### 2b. RPCs — 20 of 20

`proto RPCs: 20` / `grpcapi handlers: 20`. Every RPC in the source contract is
implemented, registered, and reachable through a gateway route:
CreateMeetup, ListOpenMeetups, GetMeetup, ListMyMeetups, ListActiveMeetups,
ListMeetupRequests, RequestToJoin, WithdrawRequest, RespondToRequest,
RegisterDeviceToken, GetSafetyState, AcknowledgeSafetyChecklist,
SetLiveLocationOptIn, CheckIn, DeclineCheckIn, SubmitMeetupFeedback,
ListRatableParticipants, SubmitRating, CloseMeetup, CancelMeetup.

### 2c. Schema — 9 tables

`meetup.meetups`, `meetup_requests`, `safety_state`, `meetup_feedback`,
`device_tokens`, `meetup_user_ratings`, `user_display_cache`,
`user_location_cache`, `subscription_cache` — the squashed final state of the
source's twelve migrations, minus `outbox_events` (ADR-001 §4) and minus the
`scheduled_for` column its own 0002 drops.

Includes both PostGIS `geography(Point,4326)` columns, their sync triggers,
both GiST indexes, the partial lifecycle-sweep index, the
`UNIQUE (meetup_id, requester_id, status) DEFERRABLE` constraint, and the
self-rating `CHECK` + one-rating-per-pair `UNIQUE`.

**Naming note**: the plan's Step 1 DDL names the table `meetup.safety_state`
(not `meetup_safety_state`); I followed the plan's literal DDL. Every other
table keeps its source name. Worth knowing for Phase 5's parity diff.

### 2d. Business rules — verified, not assumed

Capacity 1-20; `window_end > window_start` plus the 5-minute past-window grace
period; lat/lng validation on both create and browse; the 500-char cap on
every free-text field (cancel reason, withdrawal note, decline reason, and
location label); placeholder-label reverse geocoding that never overrides a
host's real label; per-intent trust gate (4 for ride_share/dating, 2
otherwise) on both create and join; one-pending-request-per-user; capacity
auto-reject inside the accept transaction; checklist-before-check-in; check-in
and decline as mutually exclusive terminal states; the three rating
eligibility branches; host-only close/cancel with window-started and
required-reason preconditions; auto-close and starting-soon sweeps with their
de-dup guard; device tokens upserted by token, not by user.

---

## 3. Security review — all six properties

### Confidentiality — clean

- Redaction covers host display fields, **coordinates**, label and window
  together — nulling the label while leaving raw GPS readable would be a real
  leak, and is tested explicitly
  (`TestListOpenMeetups_RedactsForUnderTrustViewer`).
- `GetMeetup` closes the bypass a locked browse card would otherwise leave
  open (its id stays visible so the join button has a target).
- The REST layer omits redacted keys entirely rather than sending zero values
  — a `0.0` coordinate is a real place, and "no photo" must stay
  distinguishable from "hidden from you" (`TestMeetupResponse_OmitsRedactedFields`).
- Participant enumeration via `ListRatableParticipants` is blocked for
  non-participants (`TestListRatableParticipants_RejectsNonParticipant`).
- The three caches hold only display-safe fields; no PII beyond name/photo.

### Integrity — clean

- Trust level is never read from a request — always the gateway's
  JWT-derived value, asserted per-route in
  `TestMeetupRoutes_IdentityAndTrustLevelComeFromTheToken`.
- Accept runs capacity check + auto-reject in one transaction with a row lock,
  so two near-simultaneous accepts can't both pass capacity.
- Close/auto-close are single atomic conditional `UPDATE`s — zero rows is a
  no-op, not an error, so a manual close racing the sweep is safe
  (`TestAutoCloseSweep` runs the sweep twice).
- Self-rating and duplicate ratings are blocked by DB constraint *and* service
  check; aggregates are recomputed with `AVG()`/`COUNT()` in-transaction, never
  incremented.
- All three caches use idempotent upserts with a strict `>` ordering guard on
  the event's own `OccurredAt` (`TestUserDisplayCache_OrderingGuard`).

### Availability — clean

- The nearby-notify fan-out is capped at `LIMIT 500` in SQL and excludes rows
  staler than 24h; both sweeps are `LIMIT 100` per tick.
- Every list query is cursor-paginated with a clamped page size.
- The reverse geocoder has a 3s timeout and falls back to a safe label rather
  than failing meetup creation.
- Notification failures are logged and skipped, never propagated — a push
  problem can't fail a committed meetup write.
- No breaker added here, correctly: there is no synchronous third-party
  vendor call on this module's request path (the geocoder already fails safe,
  and pushes are now an event publish, not an HTTP call).

### Authenticity — clean

Unchanged from Phase 1 and inherited wholesale: RS256-pinned JWT verification
at the gateway, the shared-secret gRPC interceptor below. This module mints
and verifies nothing of its own.

### Non-repudiation — clean

`safety_state.checklist_ack_at`/`checked_in_at`/`declined_at` +
`decline_reason` + `updated_at`, per participant — which is precisely the
audit trail the per-participant schema exists for; `meetup_feedback.submitted_at`;
`meetup_user_ratings.created_at`; `meetups.cancelled_at`/`closed_at`/
`cancellation_reason`; `meetup_requests.resolved_at`/`withdrawal_note`.

### Authorization & accountability — clean, and the focus of this phase

- **Safety Gate**: all five methods call `requireParticipant` first.
  `TestSafetyGate_RejectsNonParticipantOnEveryMethod` runs each as a separate
  subtest (so a partial regression is visible) and additionally asserts the
  outsider's failed calls created **zero** rows. Confirmed live: all five
  return 403.
- **Ownership scoping is in the SQL**, not only the service layer.
  `TestRequestAuthzScoping_AtRepositoryLayer` calls accept/reject/withdraw/
  cancel/close with a *wrong* owner id **directly at the repository**, and
  asserts each affects zero rows and leaves status unchanged — that is the
  guarantee that survives a service-layer refactor.
  `TestRequestAuthzScoping_AtServiceLayer` covers the errors callers see.
- Every route's identity comes from the token; a body/query `user_id` is
  ignored (tested across 11 routes).
- `TestNoCrossSchemaForeignKeys` queries `pg_constraint` for any FK crossing
  schemas — the ADR-001 §3 rule, asserted against the live catalog rather
  than by reading the migration.
- `TestSafetyStateIsPerParticipantInTheSchema` pins the primary key columns,
  so a future migration can't quietly regress to one shared row.

### Cross-cutting

- **Every query parameterized** — all 47 are sqlc-generated; a grep for
  string-built SQL in non-test code returns nothing.
- **No secrets logged**; the module logs ids and errors only.
- **Rate limits match the inventory** (§2a), both pinned by tests.
- **No N+1 introduced**: the host request list joins safety state in one
  query, and the fan-out uses the batched `ListForUsers`.

---

## 4. The two named fixes — test evidence

### Safety Gate (ported fix, verified here)

Unit/integration: `TestSafetyGate_RejectsNonParticipantOnEveryMethod` — five
subtests, all `PASS`, plus a zero-rows-written assertion. Live, through both
containers:

```
GET  safety                  HTTP 403
POST safety/checklist        HTTP 403
POST safety/live-location    HTTP 403
POST safety/check-in         HTTP 403
POST safety/decline          HTTP 403
```

…while the accepted participant gets `200`, is refused check-in before
acknowledging (`409`), then succeeds — and the host's own row stays untouched
by the guest's check-in (`host checked_in: False`), which is the
per-participant schema doing its job.

**One deliberate mechanism difference**: the source infers participation from
the *existence* of a safety_state row; the plan asked for the ratings code's
`IsParticipant` shape, which I used. Same authorization outcome, and strictly
more robust — it derives participation from the authoritative
meetups/meetup_requests tables rather than from a side-table row's presence,
so a genuine participant whose row was never created isn't locked out of their
own meetup. `EnsureExists` is still called at both source call sites.

### Host-bypass radius (ported fix, verified here)

`TestListOpenMeetups_HostBypassesRadius` — the viewer's own 200km-away meetup
is returned, a **stranger's equally distant one is not**, and a stranger's
nearby one still is (proving the filter isn't just returning everything).
`TestListOpenMeetups_HostBypassSurvivesPagination` guards the failure the
source's own comment warns about: the bypass must be in the after-cursor query
too, or the meetup appears on page 1 and vanishes from page 2. Live:

```
host sees own far-away meetup: True  | total returned: 1
stranger sees the far-away meetup: False | total returned: 0
```

---

## 5. Event wiring

Publishes: `meetup-created` (every CreateMeetup), `rating-updated` (every
SubmitRating), `meetup-request-created/-accepted/-rejected` (ported as-is,
still zero consumers — a tracked gap in the source, not a decision made here),
`push-notification-requested` (all six source call sites).

Subscribes, all wired in `cmd/monolith/main.go`: `user-onboarded` +
`user-profile-updated` → `user_display_cache`; `user-location-updated` →
`user_location_cache`; `subscription-activated`/`-deactivated` →
`subscription_cache` (no publisher until Phase 3, wired anyway);
`meetup-created` → the nearby-notify fan-out; `rating-updated` → the auth
module.

**The auth-side consumer, named as asked**:
`backend/internal/modules/auth/rating_consumer.go` — adds
`Service.ApplyRatingUpdate`, which delegates to the `UpsertRatingCache`
repository method Phase 1 had already ported but had nothing to call it from.
Verified live end to end: rating a participant through the REST API left
`auth.users` reading `avg=5.00 count=1 updated=true`.

Every publish happens **after** its transaction commits, not inside it
(ADR-001 §4). With an in-process bus the subscriber runs immediately, so
publishing inside the open transaction would let a handler read rows its own
caller hasn't committed. The accept path collects its events during the
transaction and drains them after.

---

## 6. Shared-secret interceptor — confirmed, not re-implemented

The Phase-1 interceptor is wired at the **server** level in
`cmd/monolith/main.go`, so registering `MeetupServiceServer` on that same
server covers all 20 new RPCs with nothing meetup-specific added. Probed
against the running monolith:

```
meetup RPC, no secret     -> Unauthenticated: internal authentication failed
meetup RPC, wrong secret  -> Unauthenticated: internal authentication failed
meetup RPC, right secret  -> PermissionDenied: caller is not a participant...
```

The third line is the proof: with the right secret the call reaches the
module and hits its own participant guard, so the first two are stopped by
authentication rather than anything incidental.

---

## 7. Live end-to-end (both containers + Postgres)

Signup → promote to trust 4 → refresh → create (far + near) → browse (host
bypass + stranger control) → request → outsider-accept rejected `403` → host
accept `200` → Safety Gate (5×403 outsider, participant flow with the `409`
step-order rejection) → per-participant isolation → ratings (outsider
enumeration blocked, participant allowed) → rating cache in `auth.users` →
`user_display_cache` and `user_location_cache` populated with the geography
column synced → billing still `503`.

Also confirmed: `CreateMeetup` at trust level 0 →
`403 intent "coffee" requires trust level 2, caller has 0`.

---

## 8. Design review against ADR-001

- **§2 module boundaries** — one `Service` interface; the module imports no
  other module; auth data reaches it only as events. ✅
- **§3 one DB, schema per module, no cross-schema FKs** — asserted against
  `pg_constraint` at runtime, not just by reading the migration. The three
  read-model caches are kept and event-fed, not collapsed into joins. ✅
- **§4 in-process bus, no outbox** — no `outbox_events`, no relay, no
  breaker for events; publishes after commit. ✅
- **§7 breaker** — none added here; the SOS breaker restored in Phase 1 is a
  vendor-call breaker with no analog on this path. ✅
- **Phase 1 untouched structurally** — `cmd/monolith/main.go` extended at its
  marked wiring points; the only Phase-1 edits were the additive
  `ApplyRatingUpdate` and replacing the meetup 503 stubs. ✅

---

## 9. Known gaps for Phase 3+

1. **`push-notification-requested` has no subscriber** until Phase 4 — every
   publish is a real, expected no-op. Deliberately no stand-in sender.
2. **`subscription-activated`/`-deactivated` have no publisher** until Phase
   3; the consumer and `subscription_cache` are wired and tested.
   `IsEntitled` is exposed but has no call site until paid-tier gating.
3. **`meetup-request-created/-accepted/-rejected` still have zero consumers**
   — ported as-is per ADR-001 §4, a tracked gap in the source.
4. **The lifecycle poller assumes a single monolith instance** (no
   `FOR UPDATE SKIP LOCKED`), same as the source. Each sweep's write is an
   atomic conditional UPDATE, so a second replica would be redundant rather
   than incorrect — but worth revisiting before scaling out.
5. **`security-review-framework.md`'s Authorization section is factually
   wrong** about the source (see §0). Not edited by me; recommend correcting
   it before Phase 3 reads it.
6. **Frontend not exercised against a running app** — the REST shapes are
   byte-compatible by construction (handlers ported field-for-field, route
   list diffed identical), but no `flutter run` was pointed at this gateway.
   Same limitation and reason as Phase 1.
7. **Source test suite not ported wholesale.** The source's ~3,900 lines of
   meetup tests are fakes-based unit tests over the same logic; I wrote
   integration tests against real Postgres instead, which cover the ported
   SQL (the part most at risk in this port) plus every adversarial case the
   prompt named. The pure-logic tests (cursor, trust gate) *are* ported
   verbatim. Worth a follow-up pass if you want the unit-level coverage too.
