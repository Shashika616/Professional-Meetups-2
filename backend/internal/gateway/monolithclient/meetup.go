package monolithclient

import (
	"context"
	"fmt"

	meetupv1 "professional-meetups-monolith/backend/internal/proto/meetup/v1"
)

// The meetup half of the gateway's view of the monolith — same connection,
// same shared-secret client interceptor, just a second generated stub
// (ADR-001 §1: one gRPC target, not three). Phase 3 adds billing the same
// way.

// Meetup is this package's own representation of a meetup, decoupled from
// the generated protobuf type. The pointer fields are the ones the monolith
// redacts for an under-trust viewer — absent, not zeroed, so the frontend
// can tell "no photo uploaded" from "hidden from you". LockedForViewer is
// the signal to key UI off, not field absence.
type Meetup struct {
	ID                     string
	HostUserID             string
	HostFullName           *string
	HostProfilePhotoURL    *string
	HostTrustLevel         int32
	HostRatingAverage      float64
	HostRatingCount        int32
	Intent                 string
	WindowStartUnixSeconds *int64
	WindowEndUnixSeconds   *int64
	LocationLat            *float64
	LocationLng            *float64
	LocationLabel          *string
	Capacity               int32
	AcceptedCount          int32
	Status                 string
	CreatedAtUnixSeconds   int64
	CancelledAtUnixSeconds *int64
	ClosedAtUnixSeconds    *int64
	IsHostedByMe           bool
	MyRequestStatus        *string
	MyRequestAutoRejected  bool
	CancellationReason     *string
	MyRequestID            *string
	LockedForViewer        bool
}

// MeetupRequest is a join request as the gateway sees it.
type MeetupRequest struct {
	ID                       string
	MeetupID                 string
	RequesterID              string
	RequesterFullName        string
	RequesterProfilePhotoURL string
	RequesterTrustLevel      int32
	RequesterRatingAverage   float64
	RequesterRatingCount     int32
	Status                   string
	AutoRejected             bool
	CreatedAtUnixSeconds     int64
	ResolvedAtUnixSeconds    *int64
	WithdrawalNote           *string
	CheckedInAtUnixSeconds   *int64
	DeclinedAtUnixSeconds    *int64
	DeclineReason            *string
}

// SafetyState is one participant's own Safety Gate row.
type SafetyState struct {
	MeetupID                  string
	ChecklistAckAtUnixSeconds *int64
	LiveLocationOptIn         bool
	CheckedInAtUnixSeconds    *int64
	DeclinedAtUnixSeconds     *int64
	DeclineReason             *string
	SharedWithContactIDs      []string
}

// RatableParticipant is one other participant the viewer can rate.
type RatableParticipant struct {
	UserID          string
	FullName        string
	ProfilePhotoURL string
	TrustLevel      int32
	AlreadyRated    bool
	ContextNote     *string
}

// --- enum mapping: wire enums to the lowercase strings the REST API and the
// frontend both use. One place, not duplicated in the handlers. ---

var intentToWire = map[meetupv1.Intent]string{
	meetupv1.Intent_INTENT_COFFEE:     "coffee",
	meetupv1.Intent_INTENT_LUNCH:      "lunch",
	meetupv1.Intent_INTENT_NETWORKING: "networking",
	meetupv1.Intent_INTENT_MENTORSHIP: "mentorship",
	meetupv1.Intent_INTENT_RIDE_SHARE: "ride_share",
	meetupv1.Intent_INTENT_DATING:     "dating",
}

var intentFromWire = map[string]meetupv1.Intent{
	"coffee":     meetupv1.Intent_INTENT_COFFEE,
	"lunch":      meetupv1.Intent_INTENT_LUNCH,
	"networking": meetupv1.Intent_INTENT_NETWORKING,
	"mentorship": meetupv1.Intent_INTENT_MENTORSHIP,
	"ride_share": meetupv1.Intent_INTENT_RIDE_SHARE,
	"dating":     meetupv1.Intent_INTENT_DATING,
}

var statusToWire = map[meetupv1.MeetupStatus]string{
	meetupv1.MeetupStatus_MEETUP_STATUS_OPEN:      "open",
	meetupv1.MeetupStatus_MEETUP_STATUS_FULL:      "full",
	meetupv1.MeetupStatus_MEETUP_STATUS_CANCELLED: "cancelled",
	meetupv1.MeetupStatus_MEETUP_STATUS_COMPLETED: "completed",
}

var requestStatusToWire = map[meetupv1.MeetupRequestStatus]string{
	meetupv1.MeetupRequestStatus_MEETUP_REQUEST_STATUS_PENDING:   "pending",
	meetupv1.MeetupRequestStatus_MEETUP_REQUEST_STATUS_ACCEPTED:  "accepted",
	meetupv1.MeetupRequestStatus_MEETUP_REQUEST_STATUS_REJECTED:  "rejected",
	meetupv1.MeetupRequestStatus_MEETUP_REQUEST_STATUS_WITHDRAWN: "withdrawn",
}

func meetupFromProto(m *meetupv1.MeetupResponse) Meetup {
	out := Meetup{
		ID:                     m.GetId(),
		HostUserID:             m.GetHostUserId(),
		HostFullName:           m.HostFullName,
		HostProfilePhotoURL:    m.HostProfilePhotoUrl,
		HostTrustLevel:         m.GetHostTrustLevel(),
		HostRatingAverage:      m.GetHostRatingAverage(),
		HostRatingCount:        m.GetHostRatingCount(),
		Intent:                 intentToWire[m.GetIntent()],
		WindowStartUnixSeconds: m.WindowStartUnixSeconds,
		WindowEndUnixSeconds:   m.WindowEndUnixSeconds,
		LocationLat:            m.LocationLat,
		LocationLng:            m.LocationLng,
		LocationLabel:          m.LocationLabel,
		Capacity:               m.GetCapacity(),
		AcceptedCount:          m.GetAcceptedCount(),
		Status:                 statusToWire[m.GetStatus()],
		CreatedAtUnixSeconds:   m.GetCreatedAtUnixSeconds(),
		CancelledAtUnixSeconds: m.CancelledAtUnixSeconds,
		ClosedAtUnixSeconds:    m.ClosedAtUnixSeconds,
		IsHostedByMe:           m.GetIsHostedByMe(),
		MyRequestAutoRejected:  m.GetMyRequestAutoRejected(),
		CancellationReason:     m.CancellationReason,
		MyRequestID:            m.MyRequestId,
		LockedForViewer:        m.GetLockedForViewer(),
	}
	if m.MyRequestStatus != nil {
		status := requestStatusToWire[m.GetMyRequestStatus()]
		out.MyRequestStatus = &status
	}
	return out
}

func meetupsFromProto(meetups []*meetupv1.MeetupResponse) []Meetup {
	out := make([]Meetup, 0, len(meetups))
	for _, m := range meetups {
		out = append(out, meetupFromProto(m))
	}
	return out
}

func meetupRequestFromProto(r *meetupv1.MeetupRequestResponse) MeetupRequest {
	return MeetupRequest{
		ID:                       r.GetId(),
		MeetupID:                 r.GetMeetupId(),
		RequesterID:              r.GetRequesterId(),
		RequesterFullName:        r.GetRequesterFullName(),
		RequesterProfilePhotoURL: r.GetRequesterProfilePhotoUrl(),
		RequesterTrustLevel:      r.GetRequesterTrustLevel(),
		RequesterRatingAverage:   r.GetRequesterRatingAverage(),
		RequesterRatingCount:     r.GetRequesterRatingCount(),
		Status:                   requestStatusToWire[r.GetStatus()],
		AutoRejected:             r.GetAutoRejected(),
		CreatedAtUnixSeconds:     r.GetCreatedAtUnixSeconds(),
		ResolvedAtUnixSeconds:    r.ResolvedAtUnixSeconds,
		WithdrawalNote:           r.WithdrawalNote,
		CheckedInAtUnixSeconds:   r.CheckedInAtUnixSeconds,
		DeclinedAtUnixSeconds:    r.DeclinedAtUnixSeconds,
		DeclineReason:            r.DeclineReason,
	}
}

func safetyStateFromProto(s *meetupv1.SafetyStateResponse) SafetyState {
	return SafetyState{
		MeetupID:                  s.GetMeetupId(),
		ChecklistAckAtUnixSeconds: s.ChecklistAckAtUnixSeconds,
		LiveLocationOptIn:         s.GetLiveLocationOptIn(),
		CheckedInAtUnixSeconds:    s.CheckedInAtUnixSeconds,
		DeclinedAtUnixSeconds:     s.DeclinedAtUnixSeconds,
		DeclineReason:             s.DeclineReason,
		SharedWithContactIDs:      s.GetSharedWithContactIds(),
	}
}

// --- calls ---

func (c *grpcClient) CreateMeetup(
	ctx context.Context, hostUserID string, hostTrustLevel int32, intent string,
	windowStart, windowEnd int64, lat, lng float64, label string, capacity int32,
) (Meetup, error) {
	intentProto, ok := intentFromWire[intent]
	if !ok {
		return Meetup{}, fmt.Errorf("monolithclient: unknown intent %q", intent)
	}
	resp, err := c.meetup.CreateMeetup(ctx, &meetupv1.CreateMeetupRequest{
		HostUserId:             hostUserID,
		HostTrustLevel:         hostTrustLevel,
		Intent:                 intentProto,
		WindowStartUnixSeconds: windowStart,
		WindowEndUnixSeconds:   windowEnd,
		LocationLat:            lat,
		LocationLng:            lng,
		LocationLabel:          label,
		Capacity:               capacity,
	})
	if err != nil {
		return Meetup{}, err
	}
	return meetupFromProto(resp), nil
}

// intent "" means every intent — the browse screen's "All" filter. It maps
// to INTENT_UNSPECIFIED on the wire, which the monolith reads as "no intent
// filter". Any other value must still name a real intent; an unrecognised one
// is a client bug and is rejected here rather than silently widened to "all",
// which would turn a typo into a much broader query than intended.
//
// withinDays 0 means unrestricted.
func (c *grpcClient) ListOpenMeetups(
	ctx context.Context, userID, intent, cursor string, pageSize int32,
	viewerLat, viewerLng float64, viewerTrustLevel, withinDays int32,
) ([]Meetup, string, error) {
	intentProto := meetupv1.Intent_INTENT_UNSPECIFIED
	if intent != "" {
		resolved, ok := intentFromWire[intent]
		if !ok {
			return nil, "", fmt.Errorf("monolithclient: unknown intent %q", intent)
		}
		intentProto = resolved
	}
	resp, err := c.meetup.ListOpenMeetups(ctx, &meetupv1.ListOpenMeetupsRequest{
		UserId:           userID,
		Intent:           intentProto,
		Cursor:           cursor,
		PageSize:         pageSize,
		ViewerLat:        viewerLat,
		ViewerLng:        viewerLng,
		ViewerTrustLevel: viewerTrustLevel,
		WithinDays:       withinDays,
	})
	if err != nil {
		return nil, "", err
	}
	return meetupsFromProto(resp.GetMeetups()), resp.GetNextCursor(), nil
}

func (c *grpcClient) GetMeetup(ctx context.Context, meetupID, userID string, viewerTrustLevel int32) (Meetup, error) {
	resp, err := c.meetup.GetMeetup(ctx, &meetupv1.GetMeetupRequest{
		MeetupId: meetupID, UserId: userID, ViewerTrustLevel: viewerTrustLevel,
	})
	if err != nil {
		return Meetup{}, err
	}
	return meetupFromProto(resp), nil
}

func (c *grpcClient) ListMyMeetups(ctx context.Context, userID, hostedCursor, requestedCursor string) (
	hosted, requested []Meetup, hostedNextCursor string, hostedHasMore bool, requestedNextCursor string, requestedHasMore bool, err error,
) {
	resp, err := c.meetup.ListMyMeetups(ctx, &meetupv1.ListMyMeetupsRequest{
		UserId: userID, HostedCursor: hostedCursor, RequestedCursor: requestedCursor,
	})
	if err != nil {
		return nil, nil, "", false, "", false, err
	}
	return meetupsFromProto(resp.GetHosted()), meetupsFromProto(resp.GetRequested()),
		resp.GetHostedNextCursor(), resp.GetHostedHasMore(),
		resp.GetRequestedNextCursor(), resp.GetRequestedHasMore(), nil
}

func (c *grpcClient) ListActiveMeetups(ctx context.Context, userID string) ([]Meetup, error) {
	resp, err := c.meetup.ListActiveMeetups(ctx, &meetupv1.ListActiveMeetupsRequest{UserId: userID})
	if err != nil {
		return nil, err
	}
	return meetupsFromProto(resp.GetMeetups()), nil
}

func (c *grpcClient) ListMeetupRequests(ctx context.Context, meetupID, hostUserID string) ([]MeetupRequest, error) {
	resp, err := c.meetup.ListMeetupRequests(ctx, &meetupv1.ListMeetupRequestsRequest{
		MeetupId: meetupID, HostUserId: hostUserID,
	})
	if err != nil {
		return nil, err
	}
	out := make([]MeetupRequest, 0, len(resp.GetRequests()))
	for _, r := range resp.GetRequests() {
		out = append(out, meetupRequestFromProto(r))
	}
	return out, nil
}

func (c *grpcClient) RequestToJoin(ctx context.Context, meetupID, requesterID string, requesterTrustLevel int32) (MeetupRequest, error) {
	resp, err := c.meetup.RequestToJoin(ctx, &meetupv1.RequestToJoinRequest{
		MeetupId: meetupID, RequesterId: requesterID, RequesterTrustLevel: requesterTrustLevel,
	})
	if err != nil {
		return MeetupRequest{}, err
	}
	return meetupRequestFromProto(resp), nil
}

func (c *grpcClient) WithdrawRequest(ctx context.Context, requestID, requesterID, note string) error {
	_, err := c.meetup.WithdrawRequest(ctx, &meetupv1.WithdrawRequestRequest{
		RequestId: requestID, RequesterId: requesterID, Note: note,
	})
	return err
}

func (c *grpcClient) RespondToRequest(ctx context.Context, requestID, hostUserID string, accept bool) (MeetupRequest, error) {
	resp, err := c.meetup.RespondToRequest(ctx, &meetupv1.RespondToRequestRequest{
		RequestId: requestID, HostUserId: hostUserID, Accept: accept,
	})
	if err != nil {
		return MeetupRequest{}, err
	}
	return meetupRequestFromProto(resp), nil
}

func (c *grpcClient) RegisterDeviceToken(ctx context.Context, userID, fcmToken string) error {
	_, err := c.meetup.RegisterDeviceToken(ctx, &meetupv1.RegisterDeviceTokenRequest{
		UserId: userID, FcmToken: fcmToken,
	})
	return err
}

func (c *grpcClient) GetSafetyState(ctx context.Context, meetupID, userID string) (SafetyState, error) {
	resp, err := c.meetup.GetSafetyState(ctx, &meetupv1.GetSafetyStateRequest{MeetupId: meetupID, UserId: userID})
	if err != nil {
		return SafetyState{}, err
	}
	return safetyStateFromProto(resp), nil
}

func (c *grpcClient) AcknowledgeSafetyChecklist(ctx context.Context, meetupID, userID string) (SafetyState, error) {
	resp, err := c.meetup.AcknowledgeSafetyChecklist(ctx, &meetupv1.AcknowledgeSafetyChecklistRequest{
		MeetupId: meetupID, UserId: userID,
	})
	if err != nil {
		return SafetyState{}, err
	}
	return safetyStateFromProto(resp), nil
}

func (c *grpcClient) SetLiveLocationOptIn(ctx context.Context, meetupID, userID string, optIn bool) (SafetyState, error) {
	resp, err := c.meetup.SetLiveLocationOptIn(ctx, &meetupv1.SetLiveLocationOptInRequest{
		MeetupId: meetupID, UserId: userID, OptIn: optIn,
	})
	if err != nil {
		return SafetyState{}, err
	}
	return safetyStateFromProto(resp), nil
}

func (c *grpcClient) ShareWithContacts(ctx context.Context, meetupID, userID string, contactIDs []string) (SafetyState, error) {
	resp, err := c.meetup.ShareWithContacts(ctx, &meetupv1.ShareWithContactsRequest{
		MeetupId: meetupID, UserId: userID, ContactIds: contactIDs,
	})
	if err != nil {
		return SafetyState{}, err
	}
	return safetyStateFromProto(resp), nil
}

func (c *grpcClient) CheckIn(ctx context.Context, meetupID, userID string) (SafetyState, error) {
	resp, err := c.meetup.CheckIn(ctx, &meetupv1.CheckInRequest{MeetupId: meetupID, UserId: userID})
	if err != nil {
		return SafetyState{}, err
	}
	return safetyStateFromProto(resp), nil
}

func (c *grpcClient) DeclineCheckIn(ctx context.Context, meetupID, userID, reason string) (SafetyState, error) {
	resp, err := c.meetup.DeclineCheckIn(ctx, &meetupv1.DeclineCheckInRequest{
		MeetupId: meetupID, UserId: userID, Reason: reason,
	})
	if err != nil {
		return SafetyState{}, err
	}
	return safetyStateFromProto(resp), nil
}

func (c *grpcClient) SubmitMeetupFeedback(
	ctx context.Context, meetupID, userID string, happened bool,
	feltSafe, profileAccurate, wouldMeetAgain *bool, notes *string,
) error {
	_, err := c.meetup.SubmitMeetupFeedback(ctx, &meetupv1.SubmitMeetupFeedbackRequest{
		MeetupId:        meetupID,
		UserId:          userID,
		Happened:        happened,
		FeltSafe:        feltSafe,
		ProfileAccurate: profileAccurate,
		WouldMeetAgain:  wouldMeetAgain,
		Notes:           notes,
	})
	return err
}

func (c *grpcClient) ListRatableParticipants(ctx context.Context, meetupID, viewerID string) ([]RatableParticipant, error) {
	resp, err := c.meetup.ListRatableParticipants(ctx, &meetupv1.ListRatableParticipantsRequest{
		MeetupId: meetupID, ViewerId: viewerID,
	})
	if err != nil {
		return nil, err
	}
	out := make([]RatableParticipant, 0, len(resp.GetParticipants()))
	for _, p := range resp.GetParticipants() {
		out = append(out, RatableParticipant{
			UserID:          p.GetUserId(),
			FullName:        p.GetFullName(),
			ProfilePhotoURL: p.GetProfilePhotoUrl(),
			TrustLevel:      p.GetTrustLevel(),
			AlreadyRated:    p.GetAlreadyRated(),
			ContextNote:     p.ContextNote,
		})
	}
	return out, nil
}

func (c *grpcClient) SubmitRating(ctx context.Context, meetupID, raterUserID, ratedUserID string, score int32) error {
	_, err := c.meetup.SubmitRating(ctx, &meetupv1.SubmitRatingRequest{
		MeetupId: meetupID, RaterUserId: raterUserID, RatedUserId: ratedUserID, Score: score,
	})
	return err
}

func (c *grpcClient) CloseMeetup(ctx context.Context, meetupID, hostUserID string) (Meetup, error) {
	resp, err := c.meetup.CloseMeetup(ctx, &meetupv1.CloseMeetupRequest{MeetupId: meetupID, HostUserId: hostUserID})
	if err != nil {
		return Meetup{}, err
	}
	return meetupFromProto(resp.GetMeetup()), nil
}

func (c *grpcClient) CancelMeetup(ctx context.Context, meetupID, hostUserID, reason string) error {
	_, err := c.meetup.CancelMeetup(ctx, &meetupv1.CancelMeetupRequest{
		MeetupId: meetupID, HostUserId: hostUserID, Reason: reason,
	})
	return err
}
