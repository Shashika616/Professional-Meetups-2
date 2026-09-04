# Phase 2 — meetup module

Ports `backend/services/meetup` from the source into `internal/modules/meetup`,
adds its gateway routes, and wires the event-bus subscriptions Phase 1 left
dangling on purpose (`user-onboarded`/`user-profile-updated`/
`user-location-updated`/`subscription-activated`/`subscription-deactivated`
already have topic constants and payload types in `internal/eventbus/events.go`
— nothing to invent, they're just unsubscribed so far). Read
`docs/decisions/adr-001-modular-monolith-architecture.md` (including its
Corrections section) and `docs/plans/00-overview.md`'s Quality Bar before
starting — both apply in full here.

This phase also fixes the Safety Gate authorization gap named in
`docs/security-review-framework.md`'s Authorization section: build it
per-participant from the start, don't port the source's per-meetup shape and
fix it after.

## Step 1 — schema

New migration `backend/migrations/0002_meetup_schema.up.sql` (+ matching
`.down.sql`), schema-qualified under `meetup.*`, same one-database rule as
Phase 1 (ADR-001 §3 — no FK from any `meetup.*` table to `auth.users`, even
though it's physically possible now).

Port every table from the source's `db/migrations/meetup/*.up.sql` (full
column lists already captured in ADR-001's grounding inventory) with **one
deliberate change**: `meetup_safety_state` is built **per-participant from
day one** —

```sql
CREATE TABLE meetup.safety_state (
  meetup_id            UUID NOT NULL REFERENCES meetup.meetups(id) ON DELETE CASCADE,
  user_id              UUID NOT NULL,
  checklist_ack_at     TIMESTAMPTZ,
  live_location_opt_in BOOLEAN NOT NULL DEFAULT false,
  checked_in_at        TIMESTAMPTZ,
  declined_at          TIMESTAMPTZ,
  decline_reason       TEXT,
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (meetup_id, user_id)
);
```

— matching `meetup_feedback`'s already-correct shape, not the source's
`PRIMARY KEY (meetup_id)` alone. Every other table (`meetups`, `meetup_requests`,
`meetup_feedback`, `device_tokens`, `meetup_user_ratings`, `user_display_cache`,
`user_location_cache`, `subscription_cache`) ports as-is, including the
PostGIS `geography(Point,4326)` columns + sync triggers + GiST indexes on
`meetups.location` and `user_location_cache.location` (the `postgis`
extension is already available — Phase 1's Postgres image is `postgis/postgis`
— just `CREATE EXTENSION IF NOT EXISTS postgis;` once in this migration if
Phase 1's migration didn't already, and confirm it didn't so this doesn't
double-create it).

## Step 2 — event bus wiring

In `cmd/monolith/main.go` (additive — this file already has a comment
marking exactly where this goes):

- **Subscribe** `eventbus.TopicUserOnboarded` / `TopicUserProfileUpdated` →
  upsert `meetup.user_display_cache` (idempotent, guarded on the payload's
  `OccurredAt` vs. the stored row's `updated_at`, same pattern as every
  other consumer in this codebase).
- **Subscribe** `TopicUserLocationUpdated` → upsert `meetup.user_location_cache`
  (same guard pattern), keeping its `location` geography column in sync via
  the same trigger approach as `meetups.location`.
- **Subscribe** `TopicSubscriptionActivated` / `TopicSubscriptionDeactivated`
  → upsert `meetup.subscription_cache`. No publisher exists until Phase 3 —
  wire it anyway, same reasoning Phase 1 used for publishing events nothing
  consumed yet.
- **Publish** `TopicMeetupCreated` on every successful `CreateMeetup`, in the
  same call, after the DB write commits (no outbox, ADR-001 §4). Also
  **subscribe** to it, in the same file — this is the one same-module,
  different-subscription consumer (the nearby-notify fan-out, Step 4c below).
- **Publish** `TopicRatingUpdated` on every `SubmitRating`. This needs a
  **subscriber on the auth side** that Phase 1 deliberately left unwired
  (see `cmd/monolith/main.go`'s existing comment: "it CONSUMES rating-updated
  — but only the meetup module publishes that, and it doesn't exist yet").
  Add whatever method the auth module needs to update
  `auth.users.rating_average`/`rating_count`/`rating_updated_at` from this
  payload (check whether `internal/modules/auth` already has a repository
  method for this — Phase 1 may not have built one since it had nothing to
  call it from) and wire the `Subscribe` call in `main.go` now, next to
  meetup's registration.
- **Publish** `TopicPushNotificationRequested` wherever the source's
  `OutboxPushSender` did (meetup-created nearby-notify, `CloseMeetup`,
  auto-close, `CancelMeetup`) — resolve FCM tokens from `meetup.device_tokens`
  before publishing, matching `PushNotificationRequestedPayload`'s shape
  exactly (it already expects resolved tokens, not a user ID). **No
  subscriber exists until Phase 4** — this is a real, expected, documented
  no-op until then, same bootstrapping pattern as every other
  not-yet-consumed event in this codebase. Don't build a stand-in sender.

## Step 3 — CreateMeetup

Port validation as-is (capacity 1-20, `window_end > window_start`, lat/lng
via `internal/platform/geo`), port the Nominatim reverse-geocoding fallback
(`geocoding.go` in the source's `shared/` — same generic package, no DB/
service coupling, reuse directly) for the "use current location" label path.
Trust-level gate: `requiredTrustLevel` per intent is **2**, mirrored from
`IntentType.requiredTrustLevel` in the frontend (unchanged) — reject with
the same error the source's `trustgate.go`-equivalent does if the caller's
JWT-derived trust level is below it.

## Step 4 — browsing: ListOpenMeetups, GetMeetup, ListMyMeetups, ListActiveMeetups

**4a. `ListOpenMeetups` — build the host-bypass fix in from the start, not
as a follow-up.** The `WHERE` clause is:

```sql
WHERE m.status = 'open' AND m.intent = $1
  AND (
    m.host_user_id = $2
    OR ST_DWithin(
      m.location,
      ST_SetSRID(ST_MakePoint(sqlc.arg(viewer_lng)::float8, sqlc.arg(viewer_lat)::float8), 4326)::geography,
      40000
    )
  )
```

(`$2` is the viewer's own ID, already needed for the `my_request_status`
join — reuse it, don't add a new parameter.) This closes a real gap
confirmed against the source: a host's own meetup, scheduled outside 40km of
their current location, is otherwise invisible to them on this exact
screen. Cursor-paginated (fetch `limit+1`, keyset on `(created_at, id)`,
`DISTINCT ON (m.id)` deduped against `meetup_requests` the same way the
source does it). Redact locked fields (`locked_for_viewer`) for a caller
below the intent's required trust level, same field list as the source.

**4b. `GetMeetup`** — same redaction, with the participant exception (a
host or accepted requester sees their own meetup's full data even if a
later trust-level change would otherwise lock it — port this exception
faithfully, it's a deliberate, already-reasoned-through behavior in the
source, not a gap).

**4c. Nearby-notify fan-out** (the `TopicMeetupCreated` subscriber from Step
2) — `ST_DWithin` against `meetup.user_location_cache.location`, 40km,
excluding rows staler than 24h and excluding the host, batched send via the
`push-notification-requested` publish from Step 2. Per-recipient failures
log-and-continue, never fail the whole handler (matches `eventbus.Publish`'s
own "log and skip" posture already, so this should fall out naturally, not
need its own separate error handling).

**4d. `ListMyMeetups` / `ListActiveMeetups`** — no distance filter at all
(host's own + requested-by-me, merged for the latter with the "accepted
requests only" rule for the active-dashboard case), cursor-paginated the
same way as 4a.

## Step 5 — requests

`RequestToJoin` (trust-level gate, capacity check, one-pending-request-
per-user), `WithdrawRequest`, `RespondToRequest` (accept/reject),
`ListMeetupRequests` (host-only). **Ownership scoping goes in the SQL
itself, not just the service layer** — same pattern as the source's Round-11
hardening, port it exactly:

- Accept/reject: `... WHERE id = $1 AND meetup_id IN (SELECT id FROM meetup.meetups WHERE host_user_id = $2)`
- Withdraw: `... WHERE id = $1 AND requester_id = $3`
- Auto-reject-on-capacity-full: same transactional shape as the source.

Add the same authz-scoping test shape as the source's
`authz_scoping_integration_test.go` — a mismatched-owner ID must affect zero
rows and return the correct error, verified at the repository layer, not
just asserted at the service layer.

## Step 6 — Safety Gate (built correctly from the start)

`GetSafetyState`, `AcknowledgeSafetyChecklist`, `SetLiveLocationOptIn`,
`CheckIn`, `DeclineCheckIn` — every one of these **must** call an
`IsParticipant(meetupID, callerID)` check (host or accepted requester)
before reading or mutating anything, using the per-participant schema from
Step 1. This is the fix for the gap named in
`docs/security-review-framework.md` — without it, any authenticated user
could read or forge another meetup's safety state just by guessing its ID.
Write a test proving a non-participant is rejected on all five methods, not
just some of them.

## Step 7 — ratings

`ListRatableParticipants` (participant-only, same IDOR check the source's
own review already caught and fixed there — port the fix, not a pre-fix
state), `SubmitRating` (self-rating blocked by both a DB `CHECK` constraint
and a service-level check, one-rating-per-pair `UNIQUE`, `AVG()`/`COUNT()`
recomputed in-transaction, publishes `rating-updated` per Step 2).

## Step 8 — lifecycle: close, cancel, auto-close

`CloseMeetup` (host-only, ownership-scoped `UPDATE ... WHERE host_user_id = $N`,
same shape as `CancelMeetup`), `CancelMeetup` (host-only, mandatory reason,
same scoping). Both publish `push-notification-requested` per Step 2
(no-op until Phase 4, expected).

**Auto-close poller**: an in-process goroutine started from
`cmd/monolith/main.go`, ticking every 60s (mirrors the source's
`internal/lifecycle/poller.go` shape, which itself mirrors the outbox
relay's own ticker/query/mark-done pattern) — sweeps `status IN ('open','full')
AND window_end <= now()`, closes each via the same atomic
`UPDATE ... WHERE id = $1 AND status IN (...) RETURNING *` a concurrent
manual close can't race with (zero rows affected is a no-op, not an error),
and calls the same shared close-notification path `CloseMeetup` uses — one
helper, not two copies.

## Step 9 — device tokens

`RegisterDeviceToken` — upsert on the `fcm_token` unique constraint.

## Step 10 — gateway routes

Replace the `/v1/meetups/*` stubs in `internal/gateway/handlers/unavailable.go`
with real handlers for every route in ADR-001's grounding inventory (method,
path, middleware — `CreateMeetup` keeps its 10/hour user-keyed rate limit,
`ListOpenMeetups` stays unlimited per-user same as the source). The
shared-secret gRPC interceptor added in Phase 1's fix prompt already covers
these automatically (it's wired at the server level in `cmd/monolith/main.go`,
not per-service) — confirm this rather than re-implementing anything for
meetup specifically.

## Explicitly not in this phase

`billing` module, `notification` module (pushes are published but
consumed by nothing until then — see Step 2), the Phase 5 parity pass.

## When done

Everything in `docs/plans/00-overview.md`'s Quality Bar, plus: a completeness
checklist against every meetup RPC/route in ADR-001's inventory; a walk of
`docs/security-review-framework.md`'s six properties against this module,
explicitly confirming the Safety Gate fix with a real rejected-non-participant
test and the host-bypass-radius fix with a real test (a host's own
out-of-radius meetup returned by `ListOpenMeetups`, a stranger's equivalent
meetup correctly still excluded); real `go build`/`go vet`/`go test -race`
output; and anything left as an explicit gap for Phase 3+.
