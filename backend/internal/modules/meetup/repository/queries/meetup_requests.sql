-- name: CreateMeetupRequest :one
-- One live request per person per meetup, and no second ask after a
-- rejection (tracker #79, plan decision D1).
--
-- Two different rules, enforced in two different places, because they are
-- not the same shape:
--
--   * "one live request" is the partial unique index from migration 0019
--     — (meetup_id, requester_id) WHERE status IN ('pending','accepted').
--     A second live row raises 23505, which the caller maps to
--     ErrConflict. The index is the right home for it: it holds against
--     concurrent inserts, which no application check can.
--
--   * "a rejected user may not re-request, a withdrawn user may" is the
--     NOT EXISTS below. It cannot be an index: expressing it would mean
--     including 'rejected' in the uniqueness, which is precisely the
--     mistake 0019 removes — it is what made the host's reject and the
--     final-seat accept collide with an old rejected row.
--
-- Conditional INSERT rather than SELECT-then-INSERT so the check and the
-- write are one statement. Zero rows back means "previously rejected",
-- which the caller separates from a plain 23505 because the two want
-- different words: one is "the host already said no", the other is "you
-- have already asked".
--
-- Withdrawing and asking again stays open on purpose. Backing out of a
-- meetup is not misconduct and should not be a permanent bar, and the
-- host sees the withdrawal in the request's own history either way.
INSERT INTO meetup.meetup_requests (meetup_id, requester_id)
SELECT sqlc.arg(meetup_id)::uuid, sqlc.arg(requester_id)::uuid
WHERE NOT EXISTS (
    SELECT 1
      FROM meetup.meetup_requests prior
     WHERE prior.meetup_id = sqlc.arg(meetup_id)::uuid
       AND prior.requester_id = sqlc.arg(requester_id)::uuid
       AND prior.status = 'rejected'
)
RETURNING *;

-- name: GetMeetupRequestByID :one
-- Plain, no join — used inside Accept's transaction where requester
-- display info is irrelevant, and as the base row write queries (Accept/
-- Reject/Withdraw) RETURNING against. Callers needing display info should
-- use GetMeetupRequestWithRequesterInfoByID instead.
SELECT * FROM meetup.meetup_requests WHERE id = $1;

-- name: GetMeetupRequestWithRequesterInfoByID :one
-- See meetup.meetups.sql's GetMeetupByID for why user_display_cache/
-- meetup_user_ratings are both LEFT JOINed (not JOIN) here.
SELECT
  r.*,
  COALESCE(u.full_name, '') AS requester_full_name,
  u.profile_photo_url AS requester_profile_photo_url,
  COALESCE(u.trust_level, 0) AS requester_trust_level,
  COALESCE(ratings.rating_average, 0)::numeric(3,2) AS requester_rating_average,
  COALESCE(ratings.rating_count, 0)::int AS requester_rating_count
FROM meetup.meetup_requests r
LEFT JOIN meetup.user_display_cache u ON u.user_id = r.requester_id
LEFT JOIN LATERAL (
  SELECT ROUND(AVG(score), 2) AS rating_average, count(*) AS rating_count
  FROM meetup.meetup_user_ratings mr WHERE mr.rated_user_id = r.requester_id
) ratings ON true
WHERE r.id = $1;

-- name: ListRequestsForMeetup :many
-- LEFT JOIN meetup.safety_state (ADR-024 §6) — host visibility into each
-- accepted participant's check-in status, piggybacking on this query's
-- existing host-only ListMeetupRequests call site rather than a new
-- endpoint. A pending/rejected/withdrawn request never has a safety-state
-- row (EnsureExists only ever runs at accept-time), so these columns are
-- naturally NULL for anything that isn't accepted — no extra WHERE needed.
-- One join, not a per-row follow-up query (avoids N+1).
SELECT
  r.*,
  COALESCE(u.full_name, '') AS requester_full_name,
  u.profile_photo_url AS requester_profile_photo_url,
  COALESCE(u.trust_level, 0) AS requester_trust_level,
  COALESCE(ratings.rating_average, 0)::numeric(3,2) AS requester_rating_average,
  COALESCE(ratings.rating_count, 0)::int AS requester_rating_count,
  safety.checked_in_at AS requester_checked_in_at,
  safety.declined_at AS requester_declined_at,
  safety.decline_reason AS requester_decline_reason
FROM meetup.meetup_requests r
LEFT JOIN meetup.user_display_cache u ON u.user_id = r.requester_id
LEFT JOIN LATERAL (
  SELECT ROUND(AVG(score), 2) AS rating_average, count(*) AS rating_count
  FROM meetup.meetup_user_ratings mr WHERE mr.rated_user_id = r.requester_id
) ratings ON true
LEFT JOIN meetup.safety_state safety
  ON safety.meetup_id = r.meetup_id AND safety.user_id = r.requester_id
WHERE r.meetup_id = $1
ORDER BY r.created_at ASC;

-- name: CountAcceptedRequests :one
SELECT count(*) FROM meetup.meetup_requests WHERE meetup_id = $1 AND status = 'accepted';

-- name: AcceptMeetupRequest :one
-- host_user_id scoping (Round 11, docs/00-project/action-tracker.md
-- § 4b-26) is defense-in-depth alongside the existing Go-level ownership
-- check in RespondToRequest/acceptRequest — meetup_requests has no
-- host_user_id column of its own, so this goes through a subquery against
-- meetups, the same relationship the Go check already enforces. The
-- Go-level check stays, this doesn't replace it.
--
-- `status = 'pending'` added for V-2 (security review 2026-10-01). The
-- comment above used to claim the call site re-checked pending. It did read
-- it — but BEFORE it took the meetup's row lock, so two accepts of the same
-- request both read 'pending', both waited on the lock, and both ran this
-- UPDATE. The second one re-accepted an already-accepted row, and the seat
-- was counted twice: on a capacity-2 meetup with one real acceptance the
-- meetup flipped to 'full' and every other pending request was
-- auto-rejected with a push. The same gap let an accept resurrect a request
-- that had just been rejected or withdrawn.
--
-- The predicate is what makes that impossible rather than unlikely. The
-- call site now locks the meetup first and re-reads this row FOR UPDATE,
-- so by the time this runs the status it checked is the committed one; this
-- clause is the backstop that holds even if that ordering is ever lost
-- again. Zero rows means "not pending any more", which the repository maps
-- to a conflict.
UPDATE meetup.meetup_requests SET status = 'accepted', resolved_at = now()
WHERE meetup.meetup_requests.id = $1
  AND meetup.meetup_requests.status = 'pending'
  AND meetup.meetup_requests.meetup_id IN (SELECT m.id FROM meetup.meetups m WHERE m.host_user_id = $2)
RETURNING *;

-- name: GetMeetupRequestByIDForUpdate :one
-- The request row, locked until the transaction ends (V-2).
--
-- Taken AFTER the meetup's own lock, never before: meetups-then-requests is
-- the order every transaction that touches both uses, and taking them the
-- other way round is how two transactions end up each holding what the
-- other needs.
--
-- This is what makes the accept path's status check true rather than
-- hopeful. The unlocked read it replaced happened before the meetup lock,
-- so a concurrent accept could resolve the row in the window between.
SELECT * FROM meetup.meetup_requests WHERE id = $1 FOR UPDATE;

-- name: RejectMeetupRequest :one
-- WHERE status = 'pending' guards against rejecting an already-resolved
-- request (double-tap, or a race with auto-reject) — zero rows affected
-- (pgx.ErrNoRows) is the repository's signal to map to apperror.ErrConflict.
-- host_user_id scoping (Round 11) added the same way as AcceptMeetupRequest
-- above — defense-in-depth alongside the existing Go-level check.
UPDATE meetup.meetup_requests SET status = 'rejected', resolved_at = now()
WHERE meetup.meetup_requests.id = $1 AND meetup.meetup_requests.status = 'pending' AND meetup.meetup_requests.meetup_id IN (SELECT m.id FROM meetup.meetups m WHERE m.host_user_id = $2)
RETURNING *;

-- name: AutoRejectPendingRequestsForMeetup :many
-- Returns the rejected rows so the caller can notify each requester
-- (backend/meetup-scheduling-PLAN.md Step E).
UPDATE meetup.meetup_requests SET status = 'rejected', resolved_at = now(), auto_rejected = true
WHERE meetup_id = $1 AND status = 'pending'
RETURNING *;

-- name: WithdrawMeetupRequest :one
-- Both 'pending' and 'accepted' are withdrawable (ADR-020 §4) — widened
-- from the original pending-only precondition: a requester backing out
-- *after* being accepted is exactly the case the withdrawal-rating path
-- exists for ("the meetup continues for everyone else," ADR-020's own
-- framing — only meaningful if they'd actually been accepted into it).
-- note is optional (may be NULL). requester_id scoping (Round 11,
-- docs/00-project/action-tracker.md § 4b-26) is defense-in-depth
-- alongside the existing Go-level check in service.go's WithdrawRequest —
-- scoped to the *requester*, not the host, unlike Accept/Reject/Cancel.
-- The Go-level check stays, this doesn't replace it.
--
-- # THE MEETUP HAS TO STILL BE RUNNING (tracker #84, finding N-B2)
--
-- The join to meetups and the two conditions on it are the fix. Without
-- them an accepted participant could withdraw from a meetup that had
-- already ENDED or been CANCELLED, which is not "backing out" — it is
-- editing history after the fact, and it had a real consequence: the
-- people who were there lose the right to rate them (eligibility is
-- keyed on being an accepted participant), while the host keeps it
-- through the separate withdrawal-rating path. Someone could attend,
-- behave badly and then delete everyone's ability to say so.
--
-- 'open' and 'full' are the live states; 'cancelled' and 'completed' are
-- over. window_end > now() additionally catches the meetup that has
-- physically happened but whose auto-close has not run yet, which is
-- exactly the window the abuse above lives in.
--
-- A request that is live but whose meetup is not returns zero rows,
-- which the caller already maps to ErrConflict — the same answer an
-- already-resolved request gets, and the right one: the state the caller
-- believed in is gone.
UPDATE meetup.meetup_requests r
SET status = 'withdrawn', resolved_at = now(), withdrawal_note = $2
FROM meetup.meetups m
WHERE r.id = $1
  AND r.requester_id = $3
  AND r.status IN ('pending', 'accepted')
  AND m.id = r.meetup_id
  AND m.status IN ('open', 'full')
  AND m.window_end > now()
RETURNING r.*;

-- name: ReopenMeetupIfSeatFreed :execrows
-- A seat came back, so the meetup is joinable again (tracker #85,
-- finding N-B3).
--
-- A meetup goes 'full' when the last seat is taken, and nothing ever put
-- it back: an accepted participant withdrawing left a meetup with a free
-- seat that still said 'full', dropped out of browse, and refused new
-- requests. The seat was simply lost, permanently, and the host had no
-- way to get it back.
--
-- Runs in the withdrawal's own transaction, after the row above and
-- under the meetup lock that transaction already holds, so the count
-- below cannot race a concurrent accept: the accept path takes the same
-- lock before it decides whether the meetup is full.
--
-- Conditional in one statement rather than read-then-write, and
-- re-checking status = 'full' inside it, so a meetup that is already
-- 'open' (the withdrawer was merely pending) is untouched and reports
-- zero rows.
UPDATE meetup.meetups m
SET status = 'open'
WHERE m.id = sqlc.arg(meetup_id)
  AND m.status = 'full'
  AND (
    SELECT count(*)
    FROM meetup.meetup_requests r
    WHERE r.meetup_id = m.id AND r.status = 'accepted'
  ) < m.capacity;

-- name: CancelPendingMeetupRequest :one
-- A requester taking back a request the host has not acted on yet. This
-- is a DELETE, not a status change, and deliberately so: nothing happened
-- — the host never accepted, no seat was held, nobody is owed a rating —
-- so there is nothing worth a row. It also keeps the door open: the
-- UNIQUE (meetup_id, requester_id, status) key means a requester who
-- cancels, re-requests and cancels again would collide on a second
-- 'withdrawn' row, where a deleted row leaves nothing to collide with.
-- Scoped to the requester and to 'pending' in the WHERE, like Withdraw:
-- an accepted request is a withdrawal (ADR-020 §4), never a cancellation.
DELETE FROM meetup.meetup_requests
WHERE id = $1 AND requester_id = $2 AND status = 'pending'
RETURNING *;
