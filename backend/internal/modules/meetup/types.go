package meetup

import "time"

// Request/response types for the meetup module's Service interface,
// translated mechanically from the proto message shapes in
// ../Professional-Meetups/backend/proto/meetup/v1/meetup.proto — same
// fields, same meanings, expressed as plain Go structs.
//
// Same rationale as the auth module's types.go: ADR-001 §2 makes a module's
// Go interface the boundary, and §7 keeps protobuf for the
// gateway<->monolith hop only. internal/grpcapi is the one place that
// translates between these and the wire types.
//
// Pointer fields mean genuinely absent, not zero — the proto's `optional`
// fields carry that distinction deliberately (a redacted meetup must be
// distinguishable from one with an empty label), so the Go shapes keep it.

// Intent mirrors the meetup.intent_type Postgres enum and the frontend's
// IntentType — three-way duplication, noted explicitly on all three sides so
// an edit to one isn't forgotten on the others.
type Intent string

const (
	IntentCoffee     Intent = "coffee"
	IntentLunch      Intent = "lunch"
	IntentNetworking Intent = "networking"
	IntentMentorship Intent = "mentorship"
	IntentRideShare  Intent = "ride_share"
	IntentDating     Intent = "dating"
)

// Status is a meetup's lifecycle state.
type Status string

const (
	StatusOpen      Status = "open"
	StatusFull      Status = "full"
	StatusCancelled Status = "cancelled"
	StatusCompleted Status = "completed"
)

// RequestStatus is a join request's state.
type RequestStatus string

const (
	RequestStatusPending   RequestStatus = "pending"
	RequestStatusAccepted  RequestStatus = "accepted"
	RequestStatusRejected  RequestStatus = "rejected"
	RequestStatusWithdrawn RequestStatus = "withdrawn"
)

// CreateMeetupRequest creates a meetup. HostUserID and HostTrustLevel are
// both set by the gateway from the verified JWT — the trust level in
// particular is never a client-supplied value, since it is what the
// per-intent gate is checked against.
type CreateMeetupRequest struct {
	HostUserID     string
	HostTrustLevel int
	Intent         Intent
	WindowStart    time.Time
	WindowEnd      time.Time
	LocationLat    float64
	LocationLng    float64
	// LocationLabel is display-only and never used for anything
	// security-relevant server-side. Empty or a known placeholder triggers
	// reverse geocoding (see the module's CreateMeetup).
	LocationLabel string
	Capacity      int
}

// Meetup is the module's view of a meetup, including host display info.
//
// The optional pointer fields are exactly the ones redaction nulls
// (HostFullName, HostProfilePhotoURL, LocationLat, LocationLng,
// LocationLabel, WindowStart, WindowEnd) — LockedForViewer is the signal a
// caller should key off, not field absence.
type Meetup struct {
	ID                  string
	HostUserID          string
	HostFullName        *string
	HostProfilePhotoURL *string
	HostTrustLevel      int
	HostRatingAverage   float64
	HostRatingCount     int
	Intent              Intent
	WindowStart         *time.Time
	WindowEnd           *time.Time
	LocationLat         *float64
	LocationLng         *float64
	LocationLabel       *string
	Capacity            int
	AcceptedCount       int
	Status              Status
	CreatedAt           time.Time
	CancelledAt         *time.Time
	CancellationReason  *string
	ClosedAt            *time.Time
	// IsHostedByMe/MyRequestStatus/MyRequestAutoRejected/MyRequestID are
	// computed relative to the requesting user, server-side — never trusted
	// from a client.
	IsHostedByMe          bool
	MyRequestStatus       *RequestStatus
	MyRequestAutoRejected bool
	MyRequestID           *string
	// LockedForViewer is true when the viewer is below this meetup's own
	// intent's required trust level, in which case the optional fields above
	// are nil. Only the two viewer-trust-aware reads (ListOpenMeetups,
	// GetMeetup) ever set it.
	LockedForViewer bool
}

// ListOpenMeetupsRequest browses open meetups for one intent. ViewerLat/
// ViewerLng are the device's current on-demand location read — required,
// and validated server-side.
type ListOpenMeetupsRequest struct {
	UserID string
	// Intent nil means EVERY intent — the home screen's "All" filter. It was
	// a required, non-nullable Intent before; nil is the only new state, and
	// a set value behaves exactly as it always did, so every existing caller
	// is unaffected.
	Intent *Intent
	// WithinDays 0 means unrestricted. When > 0, only meetups starting
	// within that many days are returned — what backs the "Happening Soon"
	// section. Validated below rather than trusted: it reaches SQL.
	WithinDays       int32
	Cursor           string // empty for the first page
	PageSize         int    // clamped to a sane default/cap
	ViewerLat        float64
	ViewerLng        float64
	ViewerTrustLevel int
}

// ListOpenMeetupsResult is one page of open meetups.
type ListOpenMeetupsResult struct {
	Meetups    []Meetup
	NextCursor string // empty when there are no more pages
}

// GetMeetupRequest reads one meetup. ViewerTrustLevel is gateway-sourced
// from the verified JWT, never client-supplied — it closes the redaction
// bypass that would otherwise exist, since a locked browse card still shows
// its meetup id (the join button needs a target).
type GetMeetupRequest struct {
	MeetupID         string
	UserID           string
	ViewerTrustLevel int
}

// ListMyMeetupsRequest reads the caller's hosted and requested meetups.
// The two paginate independently — unrelated sets, so they don't share one
// cursor.
type ListMyMeetupsRequest struct {
	UserID          string
	HostedCursor    string
	RequestedCursor string
}

// ListMyMeetupsResult carries both lists and their independent cursors.
type ListMyMeetupsResult struct {
	Hosted              []Meetup
	Requested           []Meetup
	HostedNextCursor    string
	HostedHasMore       bool
	RequestedNextCursor string
	RequestedHasMore    bool
}

// MeetupRequest is a join request, including requester display info.
type MeetupRequest struct {
	ID                       string
	MeetupID                 string
	RequesterID              string
	RequesterFullName        string
	RequesterProfilePhotoURL string
	RequesterTrustLevel      int
	RequesterRatingAverage   float64
	RequesterRatingCount     int
	Status                   RequestStatus
	AutoRejected             bool
	CreatedAt                time.Time
	ResolvedAt               *time.Time
	WithdrawalNote           *string
	// CheckedInAt/DeclinedAt/DeclineReason give the host visibility into an
	// accepted participant's Safety Gate status — populated only by the
	// host's own request-list read, nil everywhere else.
	CheckedInAt   *time.Time
	DeclinedAt    *time.Time
	DeclineReason *string
}

// RequestToJoinRequest asks to join a meetup. RequesterID and
// RequesterTrustLevel are both gateway-sourced from the verified JWT.
type RequestToJoinRequest struct {
	MeetupID            string
	RequesterID         string
	RequesterTrustLevel int
}

// WithdrawRequestRequest withdraws the caller's own pending or accepted
// request. Note is optional.
type WithdrawRequestRequest struct {
	RequestID   string
	RequesterID string
	Note        string
}

// RespondToRequestRequest is the host's accept/reject decision.
type RespondToRequestRequest struct {
	RequestID  string
	HostUserID string
	Accept     bool
}

// ListMeetupRequestsRequest is the host's request-management view.
type ListMeetupRequestsRequest struct {
	MeetupID   string
	HostUserID string
}

// SafetyStateRequest identifies one participant's own Safety Gate row.
// UserID is always the verified caller — every Safety Gate method checks it
// against the meetup's participant set before reading or writing anything.
type SafetyStateRequest struct {
	MeetupID string
	UserID   string
}

// SetLiveLocationOptInRequest toggles the caller's own live-location
// sharing for one meetup.
type SetLiveLocationOptInRequest struct {
	MeetupID string
	UserID   string
	OptIn    bool
}

// DeclineCheckInRequest declines at the checklist/check-in stage. Reason is
// required.
type DeclineCheckInRequest struct {
	MeetupID string
	UserID   string
	Reason   string
}

// SafetyState is one participant's own Safety Gate progress on one meetup.
// DeclinedAt/DeclineReason are set together and are mutually exclusive with
// CheckedInAt.
type SafetyState struct {
	MeetupID          string
	ChecklistAckAt    *time.Time
	LiveLocationOptIn bool
	CheckedInAt       *time.Time
	DeclinedAt        *time.Time
	DeclineReason     *string
	// SharedWithContactIDs are the caller's own trusted contacts who have
	// already been told about this meetup. Returned so the screen can show
	// what it did rather than asking again blind — an action a user cannot
	// confirm afterwards is one they cannot rely on.
	SharedWithContactIDs []string
}

// ShareWithContactsRequest tells the caller's chosen trusted contacts where
// and when this meetup is. ContactIDs must belong to the caller; the auth
// module rejects any that do not.
type ShareWithContactsRequest struct {
	MeetupID   string
	UserID     string
	ContactIDs []string
}

// SubmitMeetupFeedbackRequest records the post-meetup questions. FeltSafe/
// ProfileAccurate/WouldMeetAgain are pointers so "genuinely unanswered"
// stays distinct from a real "no" — collapsing them to false would write a
// negative answer nobody gave.
type SubmitMeetupFeedbackRequest struct {
	MeetupID        string
	UserID          string
	Happened        bool
	FeltSafe        *bool
	ProfileAccurate *bool
	WouldMeetAgain  *bool
	Notes           *string
}

// ListRatableParticipantsRequest lists who the caller can rate.
// ViewerTrustLevel is gateway-sourced from the verified JWT and drives the
// partial redaction described on ListRatableParticipants (rating.go).
type ListRatableParticipantsRequest struct {
	MeetupID         string
	ViewerID         string
	ViewerTrustLevel int
}

// RatableParticipant is one other participant the viewer can (or already
// did) rate. ContextNote carries a withdrawal note for withdrawal-triggered
// entries only.
type RatableParticipant struct {
	UserID          string
	FullName        string
	ProfilePhotoURL string
	TrustLevel      int
	AlreadyRated    bool
	ContextNote     *string
}

// SubmitRatingRequest records one 1-5 score. RaterUserID is gateway-sourced
// from the verified JWT.
type SubmitRatingRequest struct {
	MeetupID    string
	RaterUserID string
	RatedUserID string
	Score       int
}

// CloseMeetupRequest is the host's "meetup is done" action.
type CloseMeetupRequest struct {
	MeetupID   string
	HostUserID string
}

// CancelMeetupRequest is host-only with a required reason.
type CancelMeetupRequest struct {
	MeetupID   string
	HostUserID string
	Reason     string
}

// RegisterDeviceTokenRequest registers (or re-registers, on rotation) an FCM
// device token. Upserts by token, not by user — a token identifies one
// physical device install.
type RegisterDeviceTokenRequest struct {
	UserID   string
	FCMToken string
}

// reviewWindow bounds how long a finished meetup keeps asking to be
// reviewed. After it, the meetup drops off the home list unreviewed and
// lives only in history.
//
// Without a bound, "keep it until reviewed" means a user who ignores three
// meetups permanently carries three dead cards on their main screen, and the
// prompt stops reading as a task and starts reading as clutter. Fourteen
// days is long enough that a fortnight's holiday doesn't lose the review,
// and short enough that Home stays about what is next.
const reviewWindow = 14 * 24 * time.Hour

// SubmitMeetupReviewRequest is the whole post-meetup review, submitted by
// the Confirm at the end of the flow. RaterID is gateway-sourced from the
// verified JWT.
type SubmitMeetupReviewRequest struct {
	MeetupID     string
	RaterID      string
	OverallScore int
	Notes        *string
	Participants []ReviewParticipantInput
}

// ReviewParticipantInput is one person's line in a submitted review.
type ReviewParticipantInput struct {
	UserID string
	Score  int
	Traits []string
}

// MeetupReview is a review read back — what the viewer themselves said.
type MeetupReview struct {
	Completed    bool
	OverallScore int
	Notes        *string
	Participants []ReviewedParticipant
}

// ReviewedParticipant is one rating the viewer gave, for display.
type ReviewedParticipant struct {
	UserID          string
	FullName        string
	ProfilePhotoURL string
	Score           int
	Traits          []string
}

// ListMeetupParticipantsRequest asks who is on a meetup. ViewerTrustLevel is
// gateway-sourced from the verified JWT, never client-supplied — it decides
// whether identities are disclosed at all.
type ListMeetupParticipantsRequest struct {
	MeetupID         string
	ViewerID         string
	ViewerTrustLevel int
}
