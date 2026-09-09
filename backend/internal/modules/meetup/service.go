// Package meetup is the meetup module: scheduling, join requests, the
// Safety Gate sub-flow, ratings, lifecycle (close/cancel/auto-close),
// device tokens, and the three event-fed read-model caches.
//
// Ported from ../Professional-Meetups/backend/services/meetup. The business
// rules are the source's, unchanged; what changed is the shape around them,
// exactly as in Phase 1's auth module (ADR-001):
//
//   - One interface, Service (§2). Nothing outside this package touches its
//     repositories or SQL, and it never imports another module — the auth
//     module's data reaches it only as events (§3's read-model caches).
//   - Plain Go structs in and out (types.go), not protobuf (§7);
//     internal/grpcapi translates at the process boundary.
//   - Plain wrapped apperror sentinels, not gRPC statuses — same sentinels,
//     same messages, so wire behavior is unchanged.
//   - Events publish on the in-process bus after their business write
//     commits (§4), from the repository call sites that wrote outbox rows.
package meetup

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"time"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/geo"
	"professional-meetups-monolith/backend/internal/platform/geocoding"
)

// placeholderLocationLabels are location_label values CreateMeetup treats as
// "no real label was chosen" and replaces with a reverse-geocoded one.
// Matched case-insensitively. Defense in depth for any client that still
// submits one (old app builds, direct API callers) — the frontend already
// stopped sending it.
var placeholderLocationLabels = map[string]bool{
	"":                 true,
	"current location": true,
}

// isPlaceholderLocationLabel reports whether label should be replaced by a
// reverse-geocoded one. A host's own deliberately searched, real place name
// is never overridden — only an empty or known placeholder triggers it.
func isPlaceholderLocationLabel(label string) bool {
	return placeholderLocationLabels[strings.ToLower(strings.TrimSpace(label))]
}

// windowStartGracePeriod tolerates clock skew and normal request latency
// between a client picking "now" as a window start and the request actually
// arriving — anything staler (a window left over from a stale form, or
// literally yesterday) is rejected rather than silently accepted.
const windowStartGracePeriod = 5 * time.Minute

// maxFreeTextReasonLength caps CancelMeetup.Reason, WithdrawRequest.Note,
// DeclineCheckIn.Reason and CreateMeetup.LocationLabel. One shared constant,
// not four — all are the same kind of field (a short caller-supplied string)
// with no reason to diverge. Mirrors the auth module's own
// maxLegalNameLength-style caps.
const maxFreeTextReasonLength = 500

// sweepBatchSize bounds each lifecycle sweep's per-tick query — a
// `SELECT ... LIMIT N`, never unbounded.
const sweepBatchSize = 100

// nearbyNotifyRadiusStaleness excludes cache rows older than this from the
// nearby-notify fan-out — notifying someone about a meetup near where they
// used to be a week ago is worse than not notifying them.
const nearbyNotifyStaleness = 24 * time.Hour

// Service is the meetup module's entire surface — one method per
// MeetupService RPC in the source's proto contract, in the same order, plus
// the two lifecycle sweeps the poller drives. Every method that takes a
// caller id takes it from the gateway's verified JWT; a client never
// supplies its own.
type Service interface {
	CreateMeetup(ctx context.Context, req CreateMeetupRequest) (Meetup, error)
	ListOpenMeetups(ctx context.Context, req ListOpenMeetupsRequest) (ListOpenMeetupsResult, error)
	GetMeetup(ctx context.Context, req GetMeetupRequest) (Meetup, error)
	ListMyMeetups(ctx context.Context, req ListMyMeetupsRequest) (ListMyMeetupsResult, error)
	ListActiveMeetups(ctx context.Context, userID string) ([]Meetup, error)
	ListMeetupRequests(ctx context.Context, req ListMeetupRequestsRequest) ([]MeetupRequest, error)
	RequestToJoin(ctx context.Context, req RequestToJoinRequest) (MeetupRequest, error)
	WithdrawRequest(ctx context.Context, req WithdrawRequestRequest) error
	RespondToRequest(ctx context.Context, req RespondToRequestRequest) (MeetupRequest, error)
	RegisterDeviceToken(ctx context.Context, req RegisterDeviceTokenRequest) error

	// --- Safety Gate: every one of these checks participation first ---
	GetSafetyState(ctx context.Context, req SafetyStateRequest) (SafetyState, error)
	AcknowledgeSafetyChecklist(ctx context.Context, req SafetyStateRequest) (SafetyState, error)
	SetLiveLocationOptIn(ctx context.Context, req SetLiveLocationOptInRequest) (SafetyState, error)
	// ShareWithContacts tells the caller's chosen trusted contacts where and
	// when this meetup is (see safety.go for why the message content is
	// read here rather than accepted from the client).
	ShareWithContacts(ctx context.Context, req ShareWithContactsRequest) (SafetyState, error)
	CheckIn(ctx context.Context, req SafetyStateRequest) (SafetyState, error)
	DeclineCheckIn(ctx context.Context, req DeclineCheckInRequest) (SafetyState, error)
	SubmitMeetupFeedback(ctx context.Context, req SubmitMeetupFeedbackRequest) error

	// ListMeetupParticipants returns who is on a meetup, with identities
	// withheld below participantIdentityFloor.
	// ListNotifications returns the caller's in-app notification history,
	// bounded by the outbox retention window.
	ListNotifications(ctx context.Context, userID string) ([]UserNotification, error)

	ListMeetupParticipants(ctx context.Context, req ListMeetupParticipantsRequest) (MeetupParticipants, error)

	ListRatableParticipants(ctx context.Context, req ListRatableParticipantsRequest) ([]RatableParticipant, error)
	SubmitRating(ctx context.Context, req SubmitRatingRequest) error
	// SubmitMeetupReview is the post-meetup review flow's single write —
	// overall score, note, and every participant's score and traits, all or
	// nothing. The only thing that marks a meetup reviewed.
	SubmitMeetupReview(ctx context.Context, req SubmitMeetupReviewRequest) error
	// GetMeetupReview reads back what the viewer themselves submitted.
	GetMeetupReview(ctx context.Context, meetupID, viewerID string) (MeetupReview, error)
	CloseMeetup(ctx context.Context, req CloseMeetupRequest) (Meetup, error)
	CancelMeetup(ctx context.Context, req CancelMeetupRequest) error

	// --- lifecycle sweeps, driven by the poller (lifecycle.go) ---
	NotifyStartingSoonSweep(ctx context.Context) (int, error)
	AutoCloseSweep(ctx context.Context) (int, error)

	// HandleMeetupCreated is this module's own subscriber to the
	// meetup-created event it publishes — the nearby-notify fan-out. Exported
	// because cmd/monolith wires the Subscribe call, the same way it wires
	// every other subscription.
	HandleMeetupCreated(ctx context.Context, payload NearbyNotifyPayload) error
}

type service struct {
	meetups       repository.MeetupRepository
	requests      repository.MeetupRequestRepository
	safetyState   repository.SafetyStateRepository
	feedback      repository.FeedbackRepository
	ratings       repository.RatingRepository
	deviceTokens  repository.DeviceTokenRepository
	userLocations repository.UserLocationCacheRepository
	outbox        repository.NotificationOutboxRepository
	// wake nudges the notification poller the instant a write that queued
	// notifications commits, instead of leaving them for the next tick
	// (§F5). Optional — a nil wake just means delivery waits for the tick,
	// which is what most tests want and is never incorrect, only slower.
	wake            func()
	geocoder        geocoding.ReverseGeocoder
	contactNotifier TrustedContactNotifier
	logger          *slog.Logger
}

// notifyPollerWake nudges the notification poller, if one is wired.
//
// Called AFTER the business write's transaction has committed, never before:
// nudging a poller toward rows that are not yet visible to any other
// transaction would just produce an empty claim, and the real delivery would
// then wait for the tick anyway.
func (s *service) notifyPollerWake() {
	if s.wake != nil {
		s.wake()
	}
}

// Deps groups the meetup module's dependencies — a struct rather than the
// source's positional parameters, same choice (and reason) as the auth
// module's Deps.
type Deps struct {
	Meetups       repository.MeetupRepository
	Requests      repository.MeetupRequestRepository
	SafetyState   repository.SafetyStateRepository
	Feedback      repository.FeedbackRepository
	Ratings       repository.RatingRepository
	DeviceTokens  repository.DeviceTokenRepository
	UserLocations repository.UserLocationCacheRepository
	// Outbox is where push notifications are queued for durable delivery
	// (§F). Required.
	Outbox repository.NotificationOutboxRepository
	// Wake, if set, is called after a write that queued notifications
	// commits — cmd/monolith passes the notification poller's Wake (§F5).
	Wake     func()
	Geocoder geocoding.ReverseGeocoder
	// ContactNotifier fans a meetup's details out to the caller's own
	// trusted contacts. Optional: nil means the share endpoint reports that
	// the feature is unavailable rather than silently pretending to send,
	// which is exactly the failure the old live-location switch had.
	ContactNotifier TrustedContactNotifier
	Logger          *slog.Logger
}

// TrustedContactNotifier is the auth module's contact fan-out, seen from
// here.
//
// # WHY AN INTERFACE AND NOT A CALL
//
// The meetup module owns the meetup; the auth module owns trusted contacts,
// their phone numbers, and the SMS/email senders. Neither reads the other's
// schema (ADR-001 §3), so this is declared here as the narrowest thing the
// meetup module needs and satisfied by an adapter in cmd/monolith — the same
// place every other cross-module wire is made.
//
// The meetup module supplies the FACTS (window, label, coordinates, read off
// the meetup row) and auth supplies the IDENTITY and the delivery. Nothing
// in the resulting message comes from the client.
type TrustedContactNotifier interface {
	NotifyMeetupShare(ctx context.Context, userID string, share ContactShare) (notified int, err error)
}

// ContactShare is what the notifier needs to describe one meetup.
type ContactShare struct {
	ContactIDs    []string
	LocationLabel string
	Latitude      float64
	Longitude     float64
	WindowStart   time.Time
	WindowEnd     time.Time
}

// New constructs the meetup module's Service.
func New(deps Deps) Service {
	logger := deps.Logger
	if logger == nil {
		logger = slog.Default()
	}
	return &service{
		contactNotifier: deps.ContactNotifier,
		meetups:         deps.Meetups,
		requests:        deps.Requests,
		safetyState:     deps.SafetyState,
		feedback:        deps.Feedback,
		ratings:         deps.Ratings,
		deviceTokens:    deps.DeviceTokens,
		userLocations:   deps.UserLocations,
		outbox:          deps.Outbox,
		wake:            deps.Wake,
		geocoder:        deps.Geocoder,
		logger:          logger,
	}
}

func (s *service) CreateMeetup(ctx context.Context, req CreateMeetupRequest) (Meetup, error) {
	if !validIntent(req.Intent) {
		return Meetup{}, fmt.Errorf("meetup: unrecognized intent: %w", apperror.ErrInvalidInput)
	}

	// The HOST bar (ADR-002 §4) — raised to Level 3 for ordinary intents,
	// deliberately higher than the join bar this same meetup will apply to
	// everyone who asks to join it.
	if err := checkTrustLevel(req.Intent, req.HostTrustLevel,
		requiredTrustLevelToHost(req.Intent), "hosting"); err != nil {
		return Meetup{}, err
	}

	if req.Capacity < 1 || req.Capacity > 20 {
		return Meetup{}, fmt.Errorf("meetup: capacity must be between 1 and 20: %w", apperror.ErrInvalidInput)
	}

	// Defense in depth — the DB's CHECK(window_end > window_start) is the
	// backstop, not the only check.
	if !req.WindowEnd.After(req.WindowStart) {
		return Meetup{}, fmt.Errorf("meetup: window_end must be after window_start: %w", apperror.ErrInvalidInput)
	}
	if req.WindowStart.Before(time.Now().Add(-windowStartGracePeriod)) {
		return Meetup{}, fmt.Errorf("meetup: window_start can't be in the past: %w", apperror.ErrInvalidInput)
	}
	if err := geo.ValidateLatLng(req.LocationLat, req.LocationLng); err != nil {
		return Meetup{}, fmt.Errorf("meetup: %v: %w", err, apperror.ErrInvalidInput)
	}

	// Checked against the raw submitted value, not the trimmed one
	// isPlaceholderLocationLabel uses internally — an overlong string is
	// never empty or the known placeholder, so it always falls through to
	// being rejected here rather than being silently replaced.
	if len(req.LocationLabel) > maxFreeTextReasonLength {
		return Meetup{}, fmt.Errorf("meetup: location_label is too long: %w", apperror.ErrInvalidInput)
	}

	// A submitted label that's empty or a known placeholder gets replaced
	// with a reverse-geocoded one from the submitted coordinates; a host's
	// own real, searched label is never touched. Synchronous, but the
	// geocoder never returns a non-nil error (short internal timeout, falls
	// back to a safe generic label) — this can't fail or stall creation.
	locationLabel := req.LocationLabel
	if isPlaceholderLocationLabel(locationLabel) {
		geocoded, err := s.geocoder.ReverseGeocode(ctx, req.LocationLat, req.LocationLng)
		if err != nil {
			s.logger.Error("reverse geocode at meetup creation", "error", err)
			geocoded = geocoding.FallbackLabel
		}
		locationLabel = geocoded
	}

	created, err := s.meetups.Create(ctx, repository.NewMeetup{
		HostUserID:    req.HostUserID,
		Intent:        repository.Intent(req.Intent),
		WindowStart:   req.WindowStart,
		WindowEnd:     req.WindowEnd,
		LocationLat:   req.LocationLat,
		LocationLng:   req.LocationLng,
		LocationLabel: locationLabel,
		Capacity:      req.Capacity,
	})
	if err != nil {
		return Meetup{}, err
	}

	// The host gets their own Safety Gate row too ("a host, also a user" —
	// they go through the same checklist/check-in flow as every other
	// participant). Logged, not propagated: a transient failure here
	// shouldn't undo an already-committed meetup creation, the same
	// tolerance the accept-time call uses.
	if err := s.safetyState.EnsureExists(ctx, created.ID, req.HostUserID); err != nil {
		s.logger.Error("ensure safety state for host at meetup creation", "error", err)
	}
	// The host's own checklist prompt. Queued in its own transaction rather
	// than inside Create's: EnsureExists above is already a
	// logged-not-propagated best effort for the same reason (a transient
	// failure must not undo a committed meetup), and threading this one
	// notification into Create would mean the same transaction that
	// publishes meetup-created — the fan-out event — which is a heavier
	// coupling than a self-notification warrants. The outbox still gives it
	// retry and dead-lettering; only the atomicity is relaxed, and the fact
	// it accompanies is one the host already knows (they just created it).
	if err := s.outbox.WithinTx(ctx, func(ctx context.Context, tx repository.NotifyTx) error {
		return queueNotification(ctx, tx, req.HostUserID,
			TypeSafetyChecklist,
			"Review your safety checklist",
			fmt.Sprintf("Review the safety checklist for your new %s meetup", created.Intent),
			map[string]string{"meetup_id": created.ID},
		)
	}); err != nil {
		s.logger.Error("queue safety checklist notification at meetup creation", "error", err)
	}
	s.notifyPollerWake()

	// Create doesn't join against the display cache (nothing to join for a
	// brand-new row's host — it's the caller themselves); GetByID re-fetches
	// the fully-populated view for the response.
	full, err := s.meetups.GetByID(ctx, created.ID, req.HostUserID)
	if err != nil {
		return Meetup{}, err
	}
	return meetupFromRepo(full, req.HostUserID), nil
}

func (s *service) GetMeetup(ctx context.Context, req GetMeetupRequest) (Meetup, error) {
	m, err := s.meetups.GetByID(ctx, req.MeetupID, req.UserID)
	if err != nil {
		return Meetup{}, err
	}
	out := meetupFromRepo(m, req.UserID)

	// Closes the redaction bypass ListOpenMeetups' own locked card leaves
	// open: that deliberately keeps meetup_id visible (the join button needs
	// a target), so without redaction here a caller could read the id off
	// their own locked browse response and fetch full data for it directly.
	//
	// The participation exception is applied here at the call site rather
	// than inside redactForViewer: unlike ListMyMeetups/ListActiveMeetups,
	// which only ever return meetups the viewer already belongs to, this is
	// reachable for any meetup id. A host or accepted participant must never
	// have their own meetup's data redacted from themselves.
	//
	// ADR-002 §5 makes this MOOT for the guest tier specifically — a Level 0
	// account can never legitimately host or join anything, so it can never
	// satisfy IsParticipant — but the exception is retained unchanged and
	// still load-bearing for Level 2/3 users: if an intent's required level
	// is ever raised again after a meetup under it already exists (exactly
	// what ADR-002 just did to hosting), someone who legitimately joined at
	// the old threshold would otherwise lose sight of their own meetup.
	//
	// A pending (not yet accepted) request does NOT satisfy this,
	// deliberately — someone who has merely expressed interest is not a
	// participant and should see the same locked view as any other stranger.
	isParticipant, err := s.ratings.IsParticipant(ctx, req.MeetupID, req.UserID)
	if err != nil {
		// Fails closed: a transient error checking participation must not
		// accidentally skip redaction.
		s.logger.Error("check meetup participant for GetMeetup redaction", "error", err)
		isParticipant = false
	}
	if !isParticipant {
		redactForViewer(&out, req.ViewerTrustLevel)
	}
	return out, nil
}

// maxWithinDays caps how far out a "starting within N days" filter may reach.
// Not a security boundary — an unrestricted list is still available by passing
// 0 — just a guard against a client sending a nonsense interval that Postgres
// would then have to reason about. A year is far past any real use.
const maxWithinDays = 365

func (s *service) ListOpenMeetups(ctx context.Context, req ListOpenMeetupsRequest) (ListOpenMeetupsResult, error) {
	// A nil intent is the "All" case and is valid; a non-nil one must still
	// name a real intent. Validated here rather than left to the database's
	// enum cast so the caller gets ErrInvalidInput rather than a 500.
	if req.Intent != nil && !validIntent(*req.Intent) {
		return ListOpenMeetupsResult{}, fmt.Errorf("meetup: unrecognized intent: %w", apperror.ErrInvalidInput)
	}
	if req.WithinDays < 0 || req.WithinDays > maxWithinDays {
		return ListOpenMeetupsResult{}, fmt.Errorf("meetup: within_days must be between 0 and %d: %w", maxWithinDays, apperror.ErrInvalidInput)
	}

	cursor, err := decodeCursor(req.Cursor)
	if err != nil {
		return ListOpenMeetupsResult{}, fmt.Errorf("meetup: invalid cursor: %w", apperror.ErrInvalidInput)
	}

	// Viewer coordinates flow into the ST_DWithin filter — validated rather
	// than passed through unchecked.
	if err := geo.ValidateLatLng(req.ViewerLat, req.ViewerLng); err != nil {
		return ListOpenMeetupsResult{}, fmt.Errorf("meetup: %v: %w", err, apperror.ErrInvalidInput)
	}

	filter := repository.OpenMeetupFilter{WithinDays: req.WithinDays}
	if req.Intent != nil {
		intent := repository.Intent(*req.Intent)
		filter.Intent = &intent
	}

	meetups, next, err := s.meetups.ListOpen(ctx, filter, req.UserID, req.ViewerLat, req.ViewerLng, cursor, req.PageSize)
	if err != nil {
		return ListOpenMeetupsResult{}, err
	}

	// Redaction against the viewer's own gateway-sourced trust level. No
	// longer per-intent (ADR-002 §5): visibility is a flat Level 0 vs. 1+
	// question now, so every meetup in the page gets the same treatment and
	// the loop is only here because the field-nulling is per-struct.
	out := meetupsFromRepo(meetups, req.UserID)
	for i := range out {
		redactForViewer(&out[i], req.ViewerTrustLevel)
	}

	return ListOpenMeetupsResult{Meetups: out, NextCursor: encodeCursor(next)}, nil
}

func (s *service) ListMyMeetups(ctx context.Context, req ListMyMeetupsRequest) (ListMyMeetupsResult, error) {
	// Hosted and requested paginate independently — unrelated sets, separate
	// cursors.
	hostedCursor, err := decodeCursor(req.HostedCursor)
	if err != nil {
		return ListMyMeetupsResult{}, fmt.Errorf("meetup: invalid hosted_cursor: %w", apperror.ErrInvalidInput)
	}
	requestedCursor, err := decodeCursor(req.RequestedCursor)
	if err != nil {
		return ListMyMeetupsResult{}, fmt.Errorf("meetup: invalid requested_cursor: %w", apperror.ErrInvalidInput)
	}

	hosted, hostedNext, err := s.meetups.ListByHost(ctx, req.UserID, hostedCursor, 0)
	if err != nil {
		return ListMyMeetupsResult{}, err
	}
	requested, requestedNext, err := s.meetups.ListRequestedByUser(ctx, req.UserID, requestedCursor, 0)
	if err != nil {
		return ListMyMeetupsResult{}, err
	}

	return ListMyMeetupsResult{
		Hosted:              meetupsFromRepo(hosted, req.UserID),
		Requested:           meetupsFromRepo(requested, req.UserID),
		HostedNextCursor:    encodeCursor(hostedNext),
		HostedHasMore:       hostedNext != nil,
		RequestedNextCursor: encodeCursor(requestedNext),
		RequestedHasMore:    requestedNext != nil,
	}, nil
}

// ListActiveMeetups merges "I'm host" and "I'm an accepted participant" into
// one server-sorted (soonest window_start first) list, scoped to
// status IN ('open','full') AND window_end >= now(). Reuses the same two
// repository calls ListMyMeetups makes rather than a new combined query —
// the decision of what counts as active stays entirely server-side (the
// filter below); only the merge-and-sort happens in Go.
func (s *service) ListActiveMeetups(ctx context.Context, userID string) ([]Meetup, error) {
	hosted, _, err := s.meetups.ListByHost(ctx, userID, nil, 0)
	if err != nil {
		return nil, err
	}
	requested, _, err := s.meetups.ListRequestedByUser(ctx, userID, nil, 0)
	if err != nil {
		return nil, err
	}

	now := time.Now()

	// Meetups whose window has ended and that this user still owes a review
	// on. They stay on Home so the review prompt survives long enough to be
	// used — it used to appear the moment the window passed and vanish on
	// the very next refresh, because the filter below dropped anything whose
	// window had ended. Bounded by reviewWindow so an ignored review does
	// not sit here forever.
	awaitingIDs, err := s.feedback.IDsAwaitingReview(ctx, userID, now.Add(-reviewWindow))
	if err != nil {
		return nil, err
	}
	awaiting := make(map[string]bool, len(awaitingIDs))
	for _, id := range awaitingIDs {
		awaiting[id] = true
	}

	// Live: still open/full and not yet over. Awaiting: over, unreviewed,
	// and inside the window. A cancelled meetup is neither — there is
	// nothing to attend and nothing to review.
	isLive := func(m repository.Meetup) bool {
		return (m.Status == repository.MeetupStatusOpen || m.Status == repository.MeetupStatusFull) &&
			m.WindowEnd.After(now)
	}
	include := func(m repository.Meetup) bool {
		return isLive(m) || awaiting[m.ID]
	}

	seen := make(map[string]bool)
	var active []repository.Meetup
	for _, m := range hosted {
		if !include(m) || seen[m.ID] {
			continue
		}
		seen[m.ID] = true
		active = append(active, m)
	}
	for _, m := range requested {
		if !include(m) || seen[m.ID] {
			continue
		}
		// Only an accepted request counts as "I'm active in this meetup" — a
		// pending/rejected/withdrawn one doesn't belong on the dashboard.
		if m.MyRequestStatus == nil || *m.MyRequestStatus != repository.RequestStatusAccepted {
			continue
		}
		seen[m.ID] = true
		active = append(active, m)
	}

	// Live meetups first, soonest-first among them, so the card the user
	// swipes to first is always the one that is next — a newly created
	// meetup takes the front of the deck ahead of anything merely waiting to
	// be reviewed. Reviews follow, most recently finished first, which is
	// the order someone would actually want to write them in.
	sort.SliceStable(active, func(i, j int) bool {
		a, b := active[i], active[j]
		aLive, bLive := isLive(a), isLive(b)
		if aLive != bLive {
			return aLive
		}
		if aLive {
			return a.WindowStart.Before(b.WindowStart)
		}
		return a.WindowEnd.After(b.WindowEnd)
	})

	return meetupsFromRepo(active, userID), nil
}

func (s *service) ListMeetupRequests(ctx context.Context, req ListMeetupRequestsRequest) ([]MeetupRequest, error) {
	m, err := s.meetups.GetByID(ctx, req.MeetupID, req.HostUserID)
	if err != nil {
		return nil, err
	}
	if m.HostUserID != req.HostUserID {
		return nil, fmt.Errorf("meetup: caller does not host meetup %s: %w", req.MeetupID, apperror.ErrForbidden)
	}

	requests, err := s.requests.ListForMeetup(ctx, req.MeetupID)
	if err != nil {
		return nil, err
	}
	return requestsFromRepo(requests), nil
}

// CloseMeetup is the host-only "meetup is done" action. The repository's
// Close does the entire authorization/precondition check (right host,
// currently open-ish, window started) as a single UPDATE ... WHERE — no
// separate check-then-act a concurrent request could race. Zero rows updated
// surfaces as ErrNotFound; re-fetching distinguishes *why* for a useful
// message, without a second authoritative check duplicating the query.
//
// Explicitly does not touch rating eligibility — that gate is each
// participant's own feedback.happened, independent of status. Closing is an
// organizational move, not a new security gate.
func (s *service) CloseMeetup(ctx context.Context, req CloseMeetupRequest) (Meetup, error) {
	// Everyone's "meetup ended" notice is queued inside Close's own
	// transaction (§F3) — the close and the notifications about it commit
	// together. notifyMeetupClosed is shared with the auto-close sweep so
	// the manual and automatic paths can never drift on what gets sent.
	if _, err := s.meetups.Close(ctx, req.MeetupID, req.HostUserID,
		func(ctx context.Context, tx repository.NotifyTx, closed repository.Meetup) error {
			return s.queueMeetupClosed(ctx, tx, closed)
		},
	); err != nil {
		if errors.Is(err, apperror.ErrNotFound) {
			current, getErr := s.meetups.GetByID(ctx, req.MeetupID, req.HostUserID)
			if getErr != nil {
				return Meetup{}, getErr
			}
			switch {
			case current.HostUserID != req.HostUserID:
				return Meetup{}, fmt.Errorf("meetup: only the host can close this meetup: %w", apperror.ErrForbidden)
			case current.Status != repository.MeetupStatusOpen && current.Status != repository.MeetupStatusFull:
				return Meetup{}, fmt.Errorf("meetup: already closed or cancelled: %w", apperror.ErrConflict)
			case time.Now().Before(current.WindowStart):
				return Meetup{}, fmt.Errorf("meetup: can't close before the meetup's window has started: %w", apperror.ErrForbidden)
			}
		}
		return Meetup{}, err
	}

	s.notifyPollerWake()

	// Close's own RETURNING has no host display info to join against —
	// re-fetch the fully-populated view for the response.
	full, err := s.meetups.GetByID(ctx, req.MeetupID, req.HostUserID)
	if err != nil {
		return Meetup{}, err
	}

	return meetupFromRepo(full, req.HostUserID), nil
}

// queueMeetupClosed queues the "meetup ended — rate your experience" push
// for the host and every accepted participant, on the transaction that
// closed the meetup.
//
// Shared by CloseMeetup's manual path and the auto-close sweep, so the two
// can never drift on what gets sent — the one behaviour §E4's checklist
// specifically calls out as needing to be identical from either direction.
//
// The participant list is read on the SAME transaction as the close. That is
// not incidental: reading it afterwards, on another connection, could
// observe a request accepted or withdrawn in between and notify a set that
// never matched the close it is describing.
func (s *service) queueMeetupClosed(ctx context.Context, tx repository.NotifyTx, m repository.Meetup) error {
	participants, err := tx.ListRequestsForMeetup(ctx, m.ID)
	if err != nil {
		return err
	}

	body := fmt.Sprintf("Your %s meetup has ended. Rate your experience!", m.Intent)
	data := map[string]string{"meetup_id": m.ID}

	// The host and the participants get identical copy, so they are queued
	// as one recipient set rather than a special case plus a loop.
	recipients := append([]string{m.HostUserID}, acceptedRequesters(participants)...)
	_, err = queueNotifications(ctx, tx, recipients, TypeMeetupClosed, "Meetup ended", body, data)
	return err
}

// NotifyStartingSoonSweep is one tick of the poller's starting-soon sweep.
//
// The claim and every reminder it produces are one transaction (§C2 + §F3):
// ClaimMeetupsStartingSoon sets the de-dup guard in the same statement that
// selects the rows, under FOR UPDATE SKIP LOCKED, and the notifications are
// queued before that transaction commits. A second monolith instance ticking
// at the same moment claims a disjoint set rather than re-notifying the same
// meetups, and there is no state in which a meetup is marked notified but
// its reminder was never queued.
func (s *service) NotifyStartingSoonSweep(ctx context.Context) (int, error) {
	claimed, err := s.meetups.ClaimStartingSoon(ctx, sweepBatchSize,
		func(ctx context.Context, tx repository.NotifyTx, ms []repository.Meetup) error {
			for _, m := range ms {
				participants, err := tx.ListRequestsForMeetup(ctx, m.ID)
				if err != nil {
					return err
				}
				recipients := append([]string{m.HostUserID}, acceptedRequesters(participants)...)
				if _, err := queueNotifications(ctx, tx, recipients,
					TypeMeetupStartingSoon,
					"Meetup starting soon",
					fmt.Sprintf("Your %s meetup starts soon — review your safety checklist.", m.Intent),
					map[string]string{"meetup_id": m.ID},
				); err != nil {
					return err
				}
			}
			return nil
		})
	if err != nil {
		return 0, fmt.Errorf("meetup: claim starting-soon batch: %w", err)
	}
	if len(claimed) > 0 {
		s.notifyPollerWake()
	}
	return len(claimed), nil
}

// AutoCloseSweep is one tick of the poller's auto-close sweep — the same
// claim-and-queue-in-one-transaction shape as NotifyStartingSoonSweep, and
// the same queueMeetupClosed helper CloseMeetup's manual path uses, so a
// meetup that ends on its own and one the host closes by hand produce
// byte-identical notifications.
func (s *service) AutoCloseSweep(ctx context.Context) (int, error) {
	claimed, err := s.meetups.ClaimReadyToAutoClose(ctx, sweepBatchSize,
		func(ctx context.Context, tx repository.NotifyTx, ms []repository.Meetup) error {
			for _, m := range ms {
				if err := s.queueMeetupClosed(ctx, tx, m); err != nil {
					return err
				}
			}
			return nil
		})
	if err != nil {
		return 0, fmt.Errorf("meetup: claim auto-close batch: %w", err)
	}
	if len(claimed) > 0 {
		s.notifyPollerWake()
	}
	return len(claimed), nil
}

// CancelMeetup is host-only with a required reason. A meetup with confirmed
// participants can be cancelled — each is notified, and each gains a
// rating-eligibility path against the host.
func (s *service) CancelMeetup(ctx context.Context, req CancelMeetupRequest) error {
	reason := strings.TrimSpace(req.Reason)
	if reason == "" {
		return fmt.Errorf("meetup: reason is required: %w", apperror.ErrInvalidInput)
	}
	if len(reason) > maxFreeTextReasonLength {
		return fmt.Errorf("meetup: reason is too long: %w", apperror.ErrInvalidInput)
	}

	m, err := s.meetups.GetByID(ctx, req.MeetupID, req.HostUserID)
	if err != nil {
		return err
	}
	if m.HostUserID != req.HostUserID {
		return fmt.Errorf("meetup: caller does not host meetup %s: %w", req.MeetupID, apperror.ErrForbidden)
	}

	// Every accepted requester's cancellation notice is queued inside
	// Cancel's own transaction (§F3). This is the call site where that
	// matters most: a cancellation the participants are never told about is
	// people showing up to a meetup that is not happening.
	if _, err := s.meetups.Cancel(ctx, req.MeetupID, reason, req.HostUserID,
		func(ctx context.Context, tx repository.NotifyTx, cancelled repository.Meetup) error {
			participants, err := tx.ListRequestsForMeetup(ctx, cancelled.ID)
			if err != nil {
				return err
			}
			_, err = queueNotifications(ctx, tx, acceptedRequesters(participants),
				TypeMeetupCancelled,
				"Meetup cancelled",
				fmt.Sprintf("The host cancelled your %s meetup: %s", m.Intent, reason),
				map[string]string{"meetup_id": m.ID},
			)
			return err
		},
	); err != nil {
		return err
	}

	s.notifyPollerWake()
	return nil
}

func (s *service) RegisterDeviceToken(ctx context.Context, req RegisterDeviceTokenRequest) error {
	if req.FCMToken == "" {
		return fmt.Errorf("meetup: fcm_token is required: %w", apperror.ErrInvalidInput)
	}
	return s.deviceTokens.Upsert(ctx, req.UserID, req.FCMToken)
}

// NearbyNotifyPayload is what HandleMeetupCreated needs off the
// meetup-created event. A struct of its own rather than taking the bus's
// payload type directly, so the module's interface doesn't expose the
// eventbus package — cmd/monolith does that translation in one place, the
// same way internal/grpcapi translates protobuf.
type NearbyNotifyPayload struct {
	MeetupID    string
	HostUserID  string
	Intent      string
	LocationLat float64
	LocationLng float64
}

// HandleMeetupCreated is the nearby-notify fan-out: everyone with a
// non-stale cached location within 40km of the new meetup, excluding the
// host, gets one push.
//
// Per-recipient failures are already log-and-continue by construction — the
// batch sender skips recipients with no registered device rather than
// failing, and a publish error returns without touching the ones already
// sent. The bus itself also logs and swallows a handler error, so a failure
// here can never fail the CreateMeetup that triggered it.
func (s *service) HandleMeetupCreated(ctx context.Context, payload NearbyNotifyPayload) error {
	nearby, err := s.userLocations.ListWithinRadius(ctx, payload.LocationLat, payload.LocationLng, time.Now().Add(-nearbyNotifyStaleness))
	if err != nil {
		return fmt.Errorf("meetup: list nearby users for meetup-created notify: %w", err)
	}

	recipients := make([]string, 0, len(nearby))
	for _, u := range nearby {
		// The host already knows about their own meetup.
		if u.UserID == payload.HostUserID {
			continue
		}
		recipients = append(recipients, u.UserID)
	}
	if len(recipients) == 0 {
		return nil
	}

	// The one publisher with no business write of its own to be atomic with:
	// this runs as an event handler, after CreateMeetup has already
	// committed. It still queues through the outbox rather than sending
	// directly, so the fan-out gets the same retry, backoff and dead-letter
	// treatment as every other notification — and its own transaction means
	// a fan-out can never be half-queued.
	var notified int
	if err := s.outbox.WithinTx(ctx, func(ctx context.Context, tx repository.NotifyTx) error {
		var err error
		notified, err = queueNotifications(ctx, tx, recipients,
			TypeMeetupNearby,
			"New meetup nearby",
			fmt.Sprintf("A new %s meetup was just scheduled near you", payload.Intent),
			map[string]string{"meetup_id": payload.MeetupID},
		)
		return err
	}); err != nil {
		return fmt.Errorf("meetup: notify nearby users: %w", err)
	}
	s.notifyPollerWake()
	s.logger.Info("nearby-notify fan-out", "meetup_id", payload.MeetupID, "candidates", len(recipients), "notified", notified)
	return nil
}

// validIntent rejects an unrecognized intent before it reaches the database,
// where it would surface as an opaque enum-cast error.
func validIntent(i Intent) bool {
	switch i {
	case IntentCoffee, IntentLunch, IntentNetworking, IntentMentorship, IntentRideShare, IntentDating:
		return true
	default:
		return false
	}
}
