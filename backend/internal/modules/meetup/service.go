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
	"fmt"
	"log/slog"
	"time"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/geocoding"
)

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

// nearbyNotifyMaxPerHostPerDay bounds how many of one host's meetups a day
// push to everyone nearby (#89). Each fan-out can reach 500 people, and the
// gateway allows a host 10 creations an hour, so without this one account
// could push well over 100,000 notifications a day at the neighbourhood.
// Meetups past the cap are still created and still appear in browse; they
// just do not ring anyone's phone.
const nearbyNotifyMaxPerHostPerDay = 3

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

	// CheckAccountDeletable is asked by the gateway before it deletes an
	// account. It returns nil when the user owes nobody their presence, and
	// apperror.ErrConflict otherwise, with a message that names what is
	// outstanding and how to clear it. Whether someone still has a live
	// meetup is this module's knowledge alone, so this module answers it.
	CheckAccountDeletable(ctx context.Context, userID string) error
	// HandleUserDeleted is this module's subscriber for
	// eventbus.TopicUserDeleted: it cancels any meetup the user still hosts
	// and deletes everything this schema holds about them. Idempotent, as
	// every outbox consumer must be (delivery is at least once).
	HandleUserDeleted(ctx context.Context, p eventbus.UserDeletedPayload) error
	// CheckSchedule answers the one-meetup-at-a-time rule ahead of time:
	// the meetup userID is already committed to in [windowStart,
	// windowEnd), and false when the window is free. Advisory; CreateMeetup
	// and RequestToJoin enforce the rule under the lock regardless.
	CheckSchedule(ctx context.Context, userID string, windowStart, windowEnd time.Time) (Meetup, bool, error)
	ListMeetupRequests(ctx context.Context, req ListMeetupRequestsRequest) ([]MeetupRequest, error)
	RequestToJoin(ctx context.Context, req RequestToJoinRequest) (MeetupRequest, error)
	WithdrawRequest(ctx context.Context, req WithdrawRequestRequest) error
	RespondToRequest(ctx context.Context, req RespondToRequestRequest) (MeetupRequest, error)
	RegisterDeviceToken(ctx context.Context, req RegisterDeviceTokenRequest) error
	// UnregisterDeviceToken removes the caller's registration of a device
	// token (sign-out). Without it, a signed-out phone kept receiving the
	// account's pushes until the next sign-in reassigned the token.
	UnregisterDeviceToken(ctx context.Context, req UnregisterDeviceTokenRequest) error

	// --- Safety Gate: every one of these checks participation first ---
	GetSafetyState(ctx context.Context, req SafetyStateRequest) (SafetyState, error)
	AcknowledgeSafetyChecklist(ctx context.Context, req SafetyStateRequest) (SafetyState, error)
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
	// GetMemberActivity gates and returns another member's public profile
	// history — see member.go.
	GetMemberActivity(ctx context.Context, viewerID string, viewerTrustLevel int, targetID string) (MemberActivity, error)

	// SweepStaleUserLocations and SweepOldMeetupCoordinates are the
	// location retention sweeps (plan 30B, 3.3, D4), run by the scheduled
	// tick.
	SweepStaleUserLocations(ctx context.Context) (int, error)
	SweepOldMeetupCoordinates(ctx context.Context) (int, error)

	// ActiveMeetup is the meetup an SOS message mentions (plan 2.2).
	ActiveMeetup(ctx context.Context, userID string, at time.Time) (repository.ActiveMeetup, bool, error)

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
	retention     repository.RetentionRepository
	outbox        repository.NotificationOutboxRepository
	// wake nudges the notification poller the instant a write that queued
	// notifications commits, instead of leaving them for the next tick
	// (§F5). Optional — a nil wake just means delivery waits for the tick,
	// which is what most tests want and is never incorrect, only slower.
	wake            func()
	geocoder        geocoding.ReverseGeocoder
	contactNotifier TrustedContactNotifier
	charger         CreationCharger
	billingWake     func()
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
	// Retention reduces old location data (plan 30B, 3.3). Nil: the two
	// retention sweeps do nothing (unit tests).
	Retention repository.RetentionRepository
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
	// Charger prices and reserves meetup creation (plan 29 §3.5). Optional:
	// nil means creation is free and limits are today's, which is what
	// most tests want.
	Charger CreationCharger
	// BillingWake, if set, is called after a write that may have queued a
	// meetup billing event — cmd/monolith passes that poller's Wake.
	BillingWake func()
	Logger      *slog.Logger
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
	// NotifyMeetupShare returns the ids of the contacts actually told, so
	// only those are recorded (D1).
	NotifyMeetupShare(ctx context.Context, userID string, share ContactShare) (notified []string, err error)
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
		retention:       deps.Retention,
		outbox:          deps.Outbox,
		wake:            deps.Wake,
		geocoder:        deps.Geocoder,
		charger:         deps.Charger,
		billingWake:     deps.BillingWake,
		logger:          logger,
	}
}

func (s *service) RegisterDeviceToken(ctx context.Context, req RegisterDeviceTokenRequest) error {
	if req.FCMToken == "" {
		return fmt.Errorf("meetup: fcm_token is required: %w", apperror.ErrInvalidInput)
	}
	return s.deviceTokens.Upsert(ctx, req.UserID, req.FCMToken)
}

func (s *service) UnregisterDeviceToken(ctx context.Context, req UnregisterDeviceTokenRequest) error {
	if req.FCMToken == "" {
		return fmt.Errorf("meetup: fcm_token is required: %w", apperror.ErrInvalidInput)
	}
	return s.deviceTokens.DeleteForUser(ctx, req.UserID, req.FCMToken)
}

func (s *service) ActiveMeetup(ctx context.Context, userID string, at time.Time) (repository.ActiveMeetup, bool, error) {
	if s.retention == nil {
		return repository.ActiveMeetup{}, false, nil
	}
	return s.retention.ActiveMeetup(ctx, userID, at)
}
