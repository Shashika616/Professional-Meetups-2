// Package repository is the persistence boundary for services/meetup:
// interfaces first, Postgres implementation second — same pattern as
// services/auth/internal/repository. internal/service/ depends on these
// interfaces, never directly on Postgres or sqlcgen.
package repository

import (
	"context"
	"time"
)

// Intent mirrors the intent_type Postgres enum (db/migrations/0003) and the
// frontend's IntentType (frontend/lib/core/models/intent_type.dart) — three-
// way duplication, noted explicitly (ADR-013, backend/meetup-scheduling-
// PLAN.md Step A).
type Intent string

const (
	IntentCoffee     Intent = "coffee"
	IntentLunch      Intent = "lunch"
	IntentNetworking Intent = "networking"
	IntentMentorship Intent = "mentorship"
	IntentRideShare  Intent = "ride_share"
	IntentDating     Intent = "dating"
	IntentOuting     Intent = "outing"
)

type MeetupStatus string

const (
	MeetupStatusOpen      MeetupStatus = "open"
	MeetupStatusFull      MeetupStatus = "full"
	MeetupStatusCancelled MeetupStatus = "cancelled"
	MeetupStatusCompleted MeetupStatus = "completed"
)

type MeetupRequestStatus string

const (
	RequestStatusPending   MeetupRequestStatus = "pending"
	RequestStatusAccepted  MeetupRequestStatus = "accepted"
	RequestStatusRejected  MeetupRequestStatus = "rejected"
	RequestStatusWithdrawn MeetupRequestStatus = "withdrawn"
)

// Meetup is a scheduled meetup, including host display info (name/photo/
// trust level) and rating aggregate. Name/photo/trust level come from
// user_display_cache, this service's own local read-model kept current by
// consuming services/auth's user-onboarded/user-profile-updated events
// (ADR-017's addendum) — no longer a live JOIN against a shared users
// table; the two services have separate databases now (ADR-017). Rating
// average/count are a live aggregate over this service's own
// meetup_user_ratings (RatingRepository.Submit both records a rating and
// publishes a rating-updated event for auth's own cache, ADR-018) — this
// service never reads or writes any users table at all anymore.
type Meetup struct {
	ID                  string
	HostUserID          string
	HostFullName        string
	HostProfilePhotoURL string
	HostTrustLevel      int
	HostRatingAverage   float64
	HostRatingCount     int
	Intent              Intent
	// WindowStart/WindowEnd replace the old nullable ScheduledFor (ADR-016)
	// — every meetup, "today" included, now requires a real time range,
	// both NOT NULL, DB-enforced WindowEnd > WindowStart.
	WindowStart   time.Time
	WindowEnd     time.Time
	LocationLat   float64
	LocationLng   float64
	LocationLabel string
	Capacity      int
	AcceptedCount int
	Status        MeetupStatus
	CreatedAt     time.Time
	CancelledAt   *time.Time
	// CancellationReason is set only alongside CancelledAt (ADR-020 §3) —
	// nil for every other status, and for cancelled rows that predate this
	// field (no backfill).
	CancellationReason *string
	// ClosedAt is set by CloseMeetup (ADR-016) — nil until a host closes the
	// meetup, mirrors CancelledAt's shape.
	ClosedAt *time.Time
	// MyRequestStatus is only populated by viewer-aware queries (GetByID,
	// ListOpen) — nil there means the viewer never requested to join. Always
	// nil from ListByHost (a host viewing their own meetups never has a
	// request on them) — callers must not read it from that path.
	MyRequestStatus *MeetupRequestStatus
	// MyRequestID is the id of the request MyRequestStatus describes — only
	// populated by GetByID (ADR-020 §4, added for the requester-side
	// withdraw action, which needs a request id, not just its status). Nil
	// wherever MyRequestStatus is nil, and nil from every other
	// viewer-aware query for now (ListOpen, ListRequestedByUser) since
	// nothing there needs it yet.
	MyRequestID *string
	// MyRequestAutoRejected is only meaningful when MyRequestStatus is
	// RequestStatusRejected, and only populated by ListRequestedByUser (the
	// "My Meetups" requested list) — that's the one place a requester needs
	// to distinguish the host's explicit rejection from a system auto-reject
	// (capacity filled before the host acted). False elsewhere.
	MyRequestAutoRejected bool
}

// NewMeetup is the input to MeetupRepository.Create.
type NewMeetup struct {
	HostUserID    string
	Intent        Intent
	WindowStart   time.Time
	WindowEnd     time.Time
	LocationLat   float64
	LocationLng   float64
	LocationLabel string
	Capacity      int
}

// Cursor is an opaque (to callers outside this package) keyset-pagination
// position — the (created_at, id) of the last row of the previous page.
type Cursor struct {
	CreatedAt time.Time
	ID        string
}

// MeetupRepository is the persistence boundary for meetup records.
// OpenMeetupFilter narrows ListOpen. BOTH fields default to "no
// restriction", so a zero value behaves exactly as the pre-filter signature
// did — that is what lets every existing caller stay unchanged.
//
// A struct rather than two more positional parameters on an already
// seven-parameter method: the two are one concept ("which open meetups"), and
// a bare `nil, 0` at a call site says nothing about what it means.
type OpenMeetupFilter struct {
	// Intent nil means every intent — the home screen's "All" option. When
	// set, behaves exactly as the old required parameter did.
	Intent *Intent
	// WithinDays 0 means unrestricted. When > 0, only meetups whose
	// window_start falls within that many days from now are returned —
	// what makes a "Happening Soon" view possible.
	WithinDays int32
}

type MeetupRepository interface {
	Create(ctx context.Context, m NewMeetup) (Meetup, error)
	// GetByID returns apperror.ErrNotFound (wrapped) if id doesn't exist.
	// viewerID populates MyRequestStatus relative to that specific caller.
	GetByID(ctx context.Context, id, viewerID string) (Meetup, error)
	// ListParticipants returns the meetup's host plus everyone whose request
	// was accepted, host first. Viewer-independent: what a given viewer may
	// SEE of these people is decided in the service layer, not here.
	ListParticipants(ctx context.Context, meetupID string) ([]MeetupParticipant, error)

	// CanViewMemberProfile answers whether viewer may open target's public
	// profile — see member.sql for the rule.
	CanViewMemberProfile(ctx context.Context, viewerID, targetID string) (bool, error)
	// ListRecentMeetupsForMember returns target's latest meetups as host or
	// accepted participant, newest first, at most limit.
	ListRecentMeetupsForMember(ctx context.Context, viewerID, targetID string, limit int) ([]RecentMemberMeetup, error)
	// ListReviewComments returns the written review notes on the given
	// meetups, oldest first within each meetup.
	ListReviewComments(ctx context.Context, meetupIDs []string) ([]MeetupReviewComment, error)
	// ListOpen returns open meetups for intent, newest first, cursor-
	// paginated, within 40km of (viewerLat, viewerLng) (ADR-021 §2). cursor
	// nil means the first page. Returns one page of at most pageSize
	// meetups and the cursor for the next page (nil if this was the last
	// page).
	ListOpen(ctx context.Context, filter OpenMeetupFilter, viewerID string, viewerLat, viewerLng float64, cursor *Cursor, pageSize int) ([]Meetup, *Cursor, error)
	// ListByHost returns every meetup hostID hosts, newest first, cursor-
	// paginated (2026-08-31 round-3 hardening — real pagination, not just
	// a LIMIT, replacing round 2's hard 200-meetup completeness ceiling;
	// same cursor nil-means-first-page/next-page-cursor contract as
	// ListOpen). MyRequestStatus is always nil on these rows (see Meetup's
	// doc comment).
	ListByHost(ctx context.Context, hostID string, cursor *Cursor, pageSize int) ([]Meetup, *Cursor, error)
	// ListRequestedByUser returns one row per meetup userID has an active
	// or historical request on, newest-meetup first, cursor-paginated
	// (same shape as ListByHost above), MyRequestStatus always populated
	// (the requester's latest request status for that meetup).
	ListRequestedByUser(ctx context.Context, userID string, cursor *Cursor, pageSize int) ([]Meetup, *Cursor, error)
	// Cancel returns apperror.ErrNotFound (wrapped) if id doesn't exist or
	// isn't hosted by hostUserID. Host-ownership is checked by the service
	// layer before calling this (Round 11: also now checked in the query
	// itself, defense-in-depth, mirroring CloseMeetup's own clause — the
	// service-layer check stays, this doesn't replace it). reason is
	// required — the service layer rejects an empty one before ever
	// reaching here (ADR-020 §3).
	// notify runs inside the write's own transaction (see NotifyTx) so the
	// cancellation notices commit atomically with the cancellation itself.
	Cancel(ctx context.Context, id, reason, hostUserID string, notify NotifyMeetup) (Meetup, error)
	// Close transitions the meetup to 'completed' — the entire
	// authorization/precondition check (right host, currently open-ish,
	// window started) is the query's own WHERE clause, not a separate
	// SELECT-then-UPDATE (ADR-016). Returns apperror.ErrNotFound (wrapped)
	// if zero rows matched; the service layer re-fetches to distinguish
	// *why* (wrong host / already closed / window not started) for a
	// useful error message.
	// notify runs inside the write's own transaction (see NotifyTx).
	Close(ctx context.Context, id, hostUserID string, notify NotifyMeetup) (Meetup, error)
	// ClaimStartingSoon atomically claims up to limit open/full meetups
	// whose window starts within 30 minutes (and hasn't started yet) and
	// that haven't already been notified — setting the de-dup guard in the
	// same statement that selects them, under FOR UPDATE SKIP LOCKED, so a
	// second concurrent poller can never claim the same row (§C2).
	//
	// notify runs INSIDE the claim's transaction with the claimed rows, so
	// the reminders it queues commit atomically with the claim (§F3). A nil
	// notify claims without queuing anything; an error from notify rolls the
	// claim back so the next tick retries it.
	ClaimStartingSoon(ctx context.Context, limit int, notify NotifyMeetups) ([]Meetup, error)
	// ClaimReadyToAutoClose atomically closes up to limit open/full meetups
	// whose window has ended, with the same claiming and notification
	// semantics as ClaimStartingSoon. Replaces the previous
	// list-then-close-per-row pair, which prevented double-closing but not
	// duplicate notification (§C2).
	ClaimReadyToAutoClose(ctx context.Context, limit int, notify NotifyMeetups) ([]Meetup, error)
}

// MeetupRequest is another user's request to join a Meetup, including
// requester display info populated the same way Meetup carries host
// display info — see Meetup's own doc comment.
type MeetupRequest struct {
	ID                       string
	MeetupID                 string
	RequesterID              string
	RequesterFullName        string
	RequesterProfilePhotoURL string
	RequesterTrustLevel      int
	RequesterRatingAverage   float64
	RequesterRatingCount     int
	Status                   MeetupRequestStatus
	AutoRejected             bool
	CreatedAt                time.Time
	ResolvedAt               *time.Time
	// WithdrawalNote is set only alongside a withdrawal (ADR-020 §4) — nil
	// for every other status, and for withdrawn rows that predate this
	// field (no backfill).
	WithdrawalNote *string
	// CheckedInAt/DeclinedAt/DeclineReason (ADR-024 § 6) — host visibility
	// into an accepted participant's Safety Gate status, joined in by
	// ListForMeetup only (not GetByID/Create/Accept/Reject/Withdraw, which
	// don't need it); nil for anything that isn't an accepted request with
	// a touched meetup_safety_state row.
	CheckedInAt   *time.Time
	DeclinedAt    *time.Time
	DeclineReason *string
}

// MeetupRequestRepository is the persistence boundary for join requests.
type MeetupRequestRepository interface {
	// Create returns apperror.ErrConflict (wrapped) if requesterID already
	// has a pending or accepted request on meetupID — migration 0003's
	// UNIQUE(meetup_id, requester_id, status) constraint is what actually
	// enforces this; this method catches the resulting 23505 rather than
	// pre-checking (same pattern as users_postgres.go's phone/email
	// conflict handling). hostUserID is threaded through by the caller
	// (already fetched via MeetupRepository.GetByID before calling this)
	// purely to build the meetup-request-created outbox event payload
	// (ADR-018) — not looked up again here.
	// notify runs inside the write's own transaction (see NotifyTx), so the
	// host's "new join request" push is queued atomically with the request
	// row itself.
	Create(ctx context.Context, meetupID, requesterID, hostUserID string, notify NotifyRequest) (MeetupRequest, error)
	// GetByID returns apperror.ErrNotFound (wrapped) if id doesn't exist.
	GetByID(ctx context.Context, id string) (MeetupRequest, error)
	// ListForMeetup returns every request (any status) on meetupID, oldest
	// first — the host's request-management view.
	ListForMeetup(ctx context.Context, meetupID string) ([]MeetupRequest, error)
	// Withdraw returns apperror.ErrConflict (wrapped) if the request is
	// neither pending nor accepted (already rejected, or already
	// withdrawn). Both pending and accepted are withdrawable (ADR-020 §4,
	// widened from the original pending-only precondition) — note is
	// optional, may be empty. requesterID (Round 11, defense-in-depth
	// alongside the existing Go-level check in service.go's
	// WithdrawRequest) scopes the underlying query to the caller's own
	// request — a mismatched requesterID returns apperror.ErrConflict
	// (indistinguishable at this layer from "already resolved", same as
	// every other zero-rows-affected case in this file) rather than
	// touching someone else's row.
	// notify runs inside the write's own transaction (see NotifyTx).
	Withdraw(ctx context.Context, id, note, requesterID string, notify NotifyRequest) (MeetupRequest, error)
	// CancelPending deletes a request the host has not acted on. ErrConflict
	// when the request is no longer pending (accepted → that is a
	// withdrawal) or does not belong to requesterID.
	CancelPending(ctx context.Context, id, requesterID string) error
	// Reject is the host's explicit rejection — distinct from the
	// capacity-triggered auto-reject inside Accept. Returns
	// apperror.ErrConflict (wrapped) if the request is not currently
	// pending, or not owned by hostUserID (Round 11 — the query itself is
	// now also scoped to hostUserID, defense-in-depth alongside the
	// existing Go-level check in RespondToRequest; hostUserID was already
	// threaded through for the outbox payload, see Create's doc comment).
	// notify runs inside the write's own transaction (see NotifyTx).
	Reject(ctx context.Context, id, hostUserID string, notify NotifyRequest) (MeetupRequest, error)
	// Accept runs the capacity check and, if this acceptance fills the
	// meetup, the auto-reject-everyone-else transition — all inside one DB
	// transaction with a row lock on the meetup (backend/meetup-scheduling-
	// PLAN.md Step B): two near-simultaneous accept calls against the same
	// meetup can never both succeed past capacity. Returns
	// apperror.ErrConflict (wrapped) if the request is not pending, not
	// owned by hostUserID (Round 11, defense-in-depth alongside the
	// existing Go-level check in RespondToRequest), or the meetup is not
	// open (already full/cancelled/completed — a defensive re-check under
	// the lock, not just trusting an earlier read). meetupNowFull is true
	// iff this acceptance was the one that reached capacity; autoRejected
	// lists every other request that was rejected as a side effect, for
	// the caller to notify.
	// notify runs inside the write's own transaction (see NotifyTx) and
	// receives the auto-rejected requests too, since each of those needs its
	// own "meetup is full" notice queued with the same commit.
	Accept(ctx context.Context, id, hostUserID string, notify NotifyAccept) (accepted MeetupRequest, meetupNowFull bool, autoRejected []MeetupRequest, err error)
}

// SafetyState is one participant's own Safety Gate progress on one meetup
// (ADR-013 § 3; per-participant since ADR-024 § 1 — a shared row per meetup
// let a non-participant overwrite the real participants' state, which is
// exactly the bug ADR-024 fixes).
type SafetyState struct {
	MeetupID          string
	UserID            string
	ChecklistAckAt    *time.Time
	LiveLocationOptIn bool
	CheckedInAt       *time.Time
	// DeclinedAt/DeclineReason (ADR-024 § 4) are set together, mutually
	// exclusive with CheckedInAt — enforced at the service layer, not here.
	DeclinedAt    *time.Time
	DeclineReason *string
}

// SafetyStateRepository is the persistence boundary for Safety Gate state —
// every method scoped to one (meetupID, userID) row, never the meetup as a
// whole (ADR-024 § 1/§ 3: this is also the actual authorization primitive —
// the service layer treats "no row for this (meetupID, userID)" as "caller
// was never a participant," see safety.go).
type SafetyStateRepository interface {
	// EnsureExists creates the row if it doesn't already exist — idempotent,
	// called once per participant: at meetup creation for the host, and at
	// accept-time for each accepted requester (ADR-024 § 2).
	EnsureExists(ctx context.Context, meetupID, userID string) error
	// Get returns apperror.ErrNotFound (wrapped) if no row exists for this
	// (meetupID, userID) — the service layer maps that to ErrForbidden,
	// since it means this caller was never this meetup's host or an
	// accepted requester on it, not a generic "not found."
	Get(ctx context.Context, meetupID, userID string) (SafetyState, error)
	AcknowledgeChecklist(ctx context.Context, meetupID, userID string) (SafetyState, error)
	SetLiveLocationOptIn(ctx context.Context, meetupID, userID string, optIn bool) (SafetyState, error)
	CheckIn(ctx context.Context, meetupID, userID string) (SafetyState, error)
	// Decline sets declined_at/decline_reason on the caller's own row
	// (ADR-024 § 4). Mutual exclusion with CheckIn is a service-layer
	// concern (both states need to be visible together to enforce it).
	// notify runs inside the write's own transaction (see NotifyTx).
	Decline(ctx context.Context, meetupID, userID, reason string, notify NotifySafetyState) (SafetyState, error)

	// RecordShare notes that contactID was told about this meetup by userID.
	// Idempotent — re-recording the same contact keeps the original
	// notified_at rather than adding a second row (migration 0007).
	RecordShare(ctx context.Context, meetupID, userID, contactID string) error
	// ListShareContactIDs returns the contacts this user has already told
	// about this meetup, so the screen can show what it did instead of
	// asking again blind.
	ListShareContactIDs(ctx context.Context, meetupID, userID string) ([]string, error)
}

// MeetupParticipant is one person on a meetup — the host, or someone whose
// request was accepted. Carries no viewer-dependent redaction; that is the
// service layer's job.
type MeetupParticipant struct {
	UserID          string
	IsHost          bool
	FullName        string
	ProfilePhotoURL string
	TrustLevel      int
}

// RecentMemberMeetup is one row of a member's recent activity, as the
// member.sql queries return it — the aggregate per meetup, plus whether the
// VIEWER was on that meetup (which the service uses to decide whether the
// comment authors below may be named).
type RecentMemberMeetup struct {
	ID               string
	Intent           Intent
	Status           MeetupStatus
	WindowStart      time.Time
	WindowEnd        time.Time
	LocationLabel    string
	TargetIsHost     bool
	ParticipantCount int
	OverallAverage   float64
	ReviewCount      int
	ViewerWasIn      bool
}

// MeetupReviewComment is one written review note on a meetup, with the
// author's display name attached; the service decides whether the viewer
// gets to keep the name.
type MeetupReviewComment struct {
	MeetupID   string
	AuthorID   string
	AuthorName string
	Note       string
	WrittenAt  time.Time
}

// FeedbackRepository is the persistence boundary for post-meetup feedback
// (Safety UX Flows.md's five questions — felt_safe/profile_accurate/
// would_meet_again are nil when happened is false, there's nothing
// meaningful to ask if the meetup didn't happen).
type FeedbackRepository interface {
	Upsert(ctx context.Context, meetupID, userID string, happened bool, feltSafe, profileAccurate, wouldMeetAgain *bool, notes *string) error
	// IDsAwaitingReview returns the ids of meetups userID took part in whose
	// window has ended after cutoff and which they have not finished
	// reviewing — what keeps a finished meetup on Home until it is reviewed.
	IDsAwaitingReview(ctx context.Context, userID string, cutoff time.Time) ([]string, error)
	// Get returns userID's feedback row for meetupID, or ErrNotFound.
	Get(ctx context.Context, meetupID, userID string) (MeetupFeedback, error)
}

// MeetupFeedback is one user's answers about one meetup — the safety
// questions plus, once the review flow completes, the overall score and the
// stamp that says it is done.
type MeetupFeedback struct {
	Happened          bool
	OverallScore      *int
	Notes             *string
	ReviewCompletedAt *time.Time
}

// RatableParticipant is another participant of a meetup the viewer can
// (or already did) rate — see RatingRepository.ListRatable.
type RatableParticipant struct {
	UserID          string
	FullName        string
	ProfilePhotoURL string
	TrustLevel      int
	AlreadyRated    bool
	// ContextNote is set only for a withdrawal-triggered entry (ADR-020
	// §5) — that request's withdrawal_note, if any. Nil for every
	// happened-based or cancellation-triggered entry.
	ContextNote *string
}

// ReviewSubmission is one complete post-meetup review: the overall score
// for the meetup, an optional note, and one entry per participant being
// rated. Written atomically — see RatingRepository.SubmitReview.
type ReviewSubmission struct {
	MeetupID     string
	RaterID      string
	OverallScore int
	Notes        *string
	Participants []ReviewParticipant
	// Happened is what the feedback row records: true for a meetup that
	// took place, false for a cancelled one being reviewed for the
	// cancellation itself. The service decides; the repository writes it.
	Happened bool
}

// ReviewParticipant is one person's line in a review.
type ReviewParticipant struct {
	UserID string
	Score  int
	// Trait keys from the server's own vocabulary, already validated by the
	// service layer (see meetup/traits.go).
	Traits []string
}

// SubmittedRating is a rating the viewer themselves gave, read back for the
// history view.
type SubmittedRating struct {
	UserID          string
	FullName        string
	ProfilePhotoURL string
	Score           int
	Traits          []string
}

// RatingRepository is the persistence boundary for post-meetup star ratings
// (ADR-015, docs/02-domain/domain-model.md § Rating). Authorization
// (participant checks, the rater's confirmed-attendance gate) is enforced
// by the service layer before calling Submit, same division of
// responsibility as MeetupRequestRepository — this layer only encodes the
// invariants a DB constraint can't be trusted to explain on its own
// (self-rating, duplicate submission) via the error mapping documented on
// Submit itself.
type RatingRepository interface {
	// IsParticipant reports whether userID is the host or an accepted
	// requester of meetupID — the "ratable set."
	IsParticipant(ctx context.Context, meetupID, userID string) (bool, error)
	// HasConfirmedHappened reports whether userID has a meetup_feedback row
	// for meetupID with happened=true — the rating-eligibility gate,
	// checked against the *rater* only (ADR-015).
	HasConfirmedHappened(ctx context.Context, meetupID, userID string) (bool, error)
	// ListRatable returns meetupID's other participants (host + accepted
	// requesters, excluding viewerID), each flagged with whether viewerID
	// already rated them. Also includes, per ADR-020 §5: the host, for an
	// accepted requester once the meetup is cancelled (already covered by
	// the same query that handles the happened-based case — no separate
	// source needed, meetup_requests.status stays 'accepted' through a
	// cancellation); and withdrawn requesters, visible only when viewerID
	// is the meetup's host, each carrying ContextNote from that request's
	// withdrawal_note.
	ListRatable(ctx context.Context, meetupID, viewerID string) ([]RatableParticipant, error)
	// IsEligibleForCancellationRating reports whether meetupID is
	// cancelled, ratedID is its host, and raterID has an accepted request
	// on it (ADR-020 §3) — the second SubmitRating eligibility branch.
	IsEligibleForCancellationRating(ctx context.Context, meetupID, raterID, ratedID string) (bool, error)
	// IsEligibleForWithdrawalRating reports whether there's a withdrawn
	// meetup_requests row for meetupID with requester_id = ratedID and
	// raterID as that meetup's host (ADR-020 §4) — the third SubmitRating
	// eligibility branch, and also the alternative to IsParticipant for
	// ratedID specifically, since a withdrawn requester never satisfies
	// that check by definition.
	IsEligibleForWithdrawalRating(ctx context.Context, meetupID, raterID, ratedID string) (bool, error)
	// Submit records raterID's score for ratedID on meetupID, computes
	// ratedID's fresh rating aggregate, and writes a rating-updated outbox
	// event carrying it — all in the same transaction (ADR-017's addendum
	// Step 5b, ADR-018). No longer writes a users.rating_average column
	// directly; this database has no users table, and auth's own copy is
	// now a cache kept current by consuming that event. Returns
	// apperror.ErrConflict (wrapped) on a duplicate
	// (meetup_id, rater_user_id, rated_user_id) submission, and
	// apperror.ErrInvalidInput (wrapped) if the DB's
	// CHECK(rater_user_id <> rated_user_id) fires (a malformed direct API
	// call — the UI never offers self as ratable).
	Submit(ctx context.Context, meetupID, raterID, ratedID string, score int) error
	// SubmitReview writes a whole review — overall score, note, every
	// participant's rating and traits, and the completion stamp — in one
	// transaction. Same error mapping as Submit for the per-rating
	// constraints. A partial review is not a state this system can leave a
	// user in: ratings are immutable, so a half-applied review can never be
	// retried to completion.
	SubmitReview(ctx context.Context, review ReviewSubmission) error
	// ListMyRatings returns only what viewerID themselves submitted on
	// meetupID — never what anyone else gave.
	ListMyRatings(ctx context.Context, meetupID, viewerID string) ([]SubmittedRating, error)
}

// UserDisplayCacheRepository is the persistence boundary for
// user_display_cache — the local, event-fed read-model replacing the live
// JOIN users this service used to perform (ADR-017's addendum, Step 4).
// Written only by the Pub/Sub consumer (internal/events/consumer.go),
// never by request-handling code.
type UserDisplayCacheRepository interface {
	// Upsert applies a user-onboarded/user-profile-updated event's values.
	// occurredAt is the event's own timestamp, not time.Now() — applied is
	// false (no error) if occurredAt is not strictly newer than what's
	// already stored for userID, the ordering guard (ADR-018 Decision 2)
	// silently no-op'ing a stale/out-of-order redelivery.
	Upsert(ctx context.Context, userID, fullName, profilePhotoURL string, trustLevel int, occurredAt time.Time) (applied bool, err error)
}

// UserLocation is one row of user_location_cache — a user's last-known
// coordinate as of updatedAt.
type UserLocation struct {
	UserID    string
	Lat       float64
	Lng       float64
	UpdatedAt time.Time
}

// UserLocationCacheRepository is the persistence boundary for
// user_location_cache — the local, event-fed read-model backing the
// meetup-created consumer's nearby-notification fan-out (ADR-021 §4,
// corrected 2026-08-26 to live in services/meetup rather than
// services/auth). Written only by the Pub/Sub consumer
// (internal/events/consumer.go), never by request-handling code — same
// shape as UserDisplayCacheRepository.
type UserLocationCacheRepository interface {
	// Upsert applies a user-location-updated event's values. occurredAt is
	// the event's own timestamp, not time.Now() — applied is false (no
	// error) if occurredAt is not strictly newer than what's already stored
	// for userID, the ordering guard (ADR-018 Decision 2) silently no-op'ing
	// a stale/out-of-order redelivery.
	Upsert(ctx context.Context, userID string, lat, lng float64, occurredAt time.Time) (applied bool, err error)
	// ListWithinRadius returns every cached user location within 40km of
	// (centerLat, centerLng) whose updated_at is after notBefore (the
	// staleness cutoff — Step 4: "non-stale... within 24 hours").
	ListWithinRadius(ctx context.Context, centerLat, centerLng float64, notBefore time.Time) ([]UserLocation, error)
}

// SubscriptionCacheRepository is the persistence boundary for
// subscription_cache — the local, event-fed entitlement read-model
// ADR-031 §2 step 5 exists for (Slice E's future paid-tier gating reads
// this, never calls services/billing synchronously per request). Written
// only by the Pub/Sub consumer (internal/events/consumer.go), never by
// request-handling code — same shape as UserDisplayCacheRepository.
type SubscriptionCacheRepository interface {
	// Upsert applies a subscription-activated/subscription-deactivated
	// event's values. occurredAt is the event's own timestamp, not
	// time.Now() — applied is false (no error) if occurredAt is not
	// strictly newer than what's already stored for userID, the same
	// ordering guard (ADR-018 Decision 2) every other cache in this
	// service already uses.
	Upsert(ctx context.Context, userID, tier string, entitled bool, occurredAt time.Time) (applied bool, err error)
	// IsEntitled reports whether userID's cached subscription counts as
	// active (tier + whether the cached row exists at all — a user never
	// seen by either event is free/not-entitled, the safe default). Not
	// consumed by anything in this slice yet (Slice E, later) — exposed
	// now so that future call site is a read against an existing,
	// already-tested repository method, not new plumbing.
	IsEntitled(ctx context.Context, userID string) (bool, error)
}

// DeviceTokenRepository is the persistence boundary for FCM push tokens.
type DeviceTokenRepository interface {
	// Upsert reassigns fcmToken to userID if it was previously registered
	// under a different account (shared device, account switch) — see
	// migration 0003's comment on device_tokens.
	Upsert(ctx context.Context, userID, fcmToken string) error
	ListForUser(ctx context.Context, userID string) ([]string, error)
	// ListForUsers is the batched form of ListForUser (2026-08-31 round-3
	// hardening) — one query for all of userIDs instead of one per user.
	// A user with no registered tokens simply has no key in the returned
	// map (not an empty-slice entry) — same "not an error" treatment
	// ListForUser gives a single user with none.
	ListForUsers(ctx context.Context, userIDs []string) (map[string][]string, error)
	// DeleteForUser removes userID's own registration of fcmToken (sign-out).
	// A token the user no longer owns is left alone; idempotent.
	DeleteForUser(ctx context.Context, userID, fcmToken string) error
	// DeleteToken removes a device token FCM has reported as permanently
	// unregistered (§E2c). Idempotent — deleting an already-absent token is
	// not an error.
	DeleteToken(ctx context.Context, fcmToken string) error
}
