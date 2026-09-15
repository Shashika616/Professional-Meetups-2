# ADR-005 - One Meetup at a Time, and Sign-Out as One Request

## Status

Accepted (2026-09-15).

## Context

Nothing stopped a host from scheduling two meetups in the same hour, or a
member from asking to join several meetups that overlap. Both were found by
using the app: the host ends up owing two tables at once, and a requester
accepted by two hosts has to let one of them down after the fact.

Separately, sign-out waited on the network. `AuthSessionNotifier.signOut`
made two authenticated calls (unregister the push token, then revoke the
refresh token) before clearing the local session, so on a slow link the
SIGN OUT button sat idle for seconds and people tapped it again.

## Decision

### The rule

A person is committed to at most one live meetup per time window.
"Committed" means hosting it, or holding a **pending or accepted** request on
it. "Live" means `open`/`full` with `window_end > now()`. Windows compare
half-open, so back-to-back meetups are allowed.

A pending request counts on purpose. If only accepted requests counted, the
double booking would be created at acceptance time, by two hosts who could
not have known about each other; there is no good message to give either of
them. Counting the request keeps the rule enforceable at the two moments the
person acts (host, join), with a message that names their own commitment.

### Where it is enforced

Server only, **under a lock**. `meetup.scheduleGuard` runs inside the same
transaction as the insert, in `CreateMeetup` and `RequestToJoin`, after
that transaction has taken `pg_advisory_xact_lock(hashtext(user_id))`
(`LockUserSchedule` in `meetups.sql`; the guard reads
`FindScheduleConflict` on the locked connection). Two concurrent calls
from the same person therefore serialise: the second waits for the first
to commit and then sees its row. An unlocked check-then-write was the
first cut and was shown (Plan 19, `TestScheduleConflict_ConcurrentCallsSerialize`)
to let both of two simultaneous calls through in every round; the lock
closed it without a migration, which an exclusion constraint would have
needed against production's already-overlapping rows.

The client never pre-checks: it has no complete view of the person's
requests, and the codebase's rule is that the client displays and never
decides.

The failure is `meetup.ScheduleConflictError`, which wraps
`apperror.ErrConflict` (so every existing 409 mapping holds) and carries the
meetup in the way. It crosses gRPC as an `ALREADY_EXISTS` status with a
`meetupv1.ScheduleConflict` detail, and the gateway writes it as

```json
{"error": "...", "code": "schedule_conflict", "conflict": { ...meetup... }}
```

This is the only error with a `code`. The app maps it to
`MeetupScheduleConflictException` and shows `ScheduleConflictSheet`: which
meetup, when it ends, and OPEN THAT MEETUP (the detail page already owns
cancel and withdraw) or I'LL WAIT.

### Sign-out

`signOut()` clears storage and flips state **first**, then runs the server
work in the background, bounded and best-effort: one `POST /v1/auth/logout`
carrying `refresh_token` and `fcm_token`, with the bearer token still
attached. The gateway revokes the refresh token, and, when the bearer proves
the account (`middleware.OptionalAuth`), drops that device's push
registration. The device-side FCM token delete comes last and is skipped if
another session signed in meanwhile. `DELETE /v1/meetups/device-token` was
removed; it had one caller and this replaced it.

### The meal intent

The `lunch` intent is presented as **MEAL** and the app names the sitting
from the meetup's local start hour: breakfast 04:00–10:59, lunch
11:00–13:59, evening meal 14:00–17:59, dinner 18:00–21:59, late-night meal
22:00–03:59 (`MealSitting` in `intent_type.dart`). The wire value and the
Postgres enum stay `lunch`. Server copy says only "meal": it does not know
the host's time zone.

## Consequences

- Tests that create several meetups for one host must space their windows;
  the meetup harness's `createMeetup` now does (`nextWindow`).
- A member cannot express interest in two overlapping meetups at once. The
  sheet tells them to cancel the request on the other one first.
- The lock key is `hashtext` of the user id (int4): two users can collide
  and briefly wait for each other, which is a false serialisation, never a
  missed conflict. The lock is held only for the create transaction.
- No exclusion constraint: existing production rows already overlap and
  the migration would fail. The advisory lock is a serialisation primitive,
  not a data constraint, so it is safe over that data.

## Addendum (2026-09-16): push notifications carry the app's mark

System-rendered Android pushes showed a grey square: Android draws a
notification's small icon as a single-colour silhouette and the app gave
it nothing but the full-colour launcher icon. The app now ships
`drawable-*/ic_stat_notification` (a white-on-transparent silhouette of
the mark, generated from the launcher foreground with its white plate
removed) and declares it, with the brand-green accent, as the FCM
defaults in `AndroidManifest.xml`. The backend sets the same
`android.notification.icon` / `color` on every message
(`notification/fcm.go`) so the two cannot drift. iOS needs nothing: APNs
always shows the app icon. Verified with a real FCM delivery to the
emulator.
