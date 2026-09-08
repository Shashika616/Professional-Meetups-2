package grpcapi

import (
	"context"
	"time"

	"professional-meetups-monolith/backend/internal/modules/meetup"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	meetupv1 "professional-meetups-monolith/backend/internal/proto/meetup/v1"
)

// MeetupServer adapts the meetup module to meetupv1.MeetupServiceServer —
// the same thin, business-rule-free shape as AuthServer: field copying,
// enum mapping, and apperror.ToGRPCStatus.
type MeetupServer struct {
	meetupv1.UnimplementedMeetupServiceServer
	svc meetup.Service
}

// NewMeetupServer constructs a MeetupServer over svc.
func NewMeetupServer(svc meetup.Service) *MeetupServer {
	return &MeetupServer{svc: svc}
}

// --- enum mapping ---

var intentFromProto = map[meetupv1.Intent]meetup.Intent{
	meetupv1.Intent_INTENT_COFFEE:     meetup.IntentCoffee,
	meetupv1.Intent_INTENT_LUNCH:      meetup.IntentLunch,
	meetupv1.Intent_INTENT_NETWORKING: meetup.IntentNetworking,
	meetupv1.Intent_INTENT_MENTORSHIP: meetup.IntentMentorship,
	meetupv1.Intent_INTENT_RIDE_SHARE: meetup.IntentRideShare,
	meetupv1.Intent_INTENT_DATING:     meetup.IntentDating,
}

var intentToProto = map[meetup.Intent]meetupv1.Intent{
	meetup.IntentCoffee:     meetupv1.Intent_INTENT_COFFEE,
	meetup.IntentLunch:      meetupv1.Intent_INTENT_LUNCH,
	meetup.IntentNetworking: meetupv1.Intent_INTENT_NETWORKING,
	meetup.IntentMentorship: meetupv1.Intent_INTENT_MENTORSHIP,
	meetup.IntentRideShare:  meetupv1.Intent_INTENT_RIDE_SHARE,
	meetup.IntentDating:     meetupv1.Intent_INTENT_DATING,
}

var statusToProto = map[meetup.Status]meetupv1.MeetupStatus{
	meetup.StatusOpen:      meetupv1.MeetupStatus_MEETUP_STATUS_OPEN,
	meetup.StatusFull:      meetupv1.MeetupStatus_MEETUP_STATUS_FULL,
	meetup.StatusCancelled: meetupv1.MeetupStatus_MEETUP_STATUS_CANCELLED,
	meetup.StatusCompleted: meetupv1.MeetupStatus_MEETUP_STATUS_COMPLETED,
}

var requestStatusToProto = map[meetup.RequestStatus]meetupv1.MeetupRequestStatus{
	meetup.RequestStatusPending:   meetupv1.MeetupRequestStatus_MEETUP_REQUEST_STATUS_PENDING,
	meetup.RequestStatusAccepted:  meetupv1.MeetupRequestStatus_MEETUP_REQUEST_STATUS_ACCEPTED,
	meetup.RequestStatusRejected:  meetupv1.MeetupRequestStatus_MEETUP_REQUEST_STATUS_REJECTED,
	meetup.RequestStatusWithdrawn: meetupv1.MeetupRequestStatus_MEETUP_REQUEST_STATUS_WITHDRAWN,
}

// unixPtr converts an optional time to the wire's optional unix seconds.
func unixPtr(t *time.Time) *int64 {
	if t == nil {
		return nil
	}
	seconds := t.Unix()
	return &seconds
}

// meetupToProto copies a module Meetup onto the wire. The nil-able fields
// stay nil when the module redacted them — that absence, together with
// locked_for_viewer, is the contract the frontend keys its lock treatment
// off of.
func meetupToProto(m meetup.Meetup) *meetupv1.MeetupResponse {
	resp := &meetupv1.MeetupResponse{
		Id:                     m.ID,
		HostUserId:             m.HostUserID,
		HostFullName:           m.HostFullName,
		HostProfilePhotoUrl:    m.HostProfilePhotoURL,
		HostTrustLevel:         int32(m.HostTrustLevel),
		HostRatingAverage:      m.HostRatingAverage,
		HostRatingCount:        int32(m.HostRatingCount),
		Intent:                 intentToProto[m.Intent],
		WindowStartUnixSeconds: unixPtr(m.WindowStart),
		WindowEndUnixSeconds:   unixPtr(m.WindowEnd),
		LocationLat:            m.LocationLat,
		LocationLng:            m.LocationLng,
		LocationLabel:          m.LocationLabel,
		Capacity:               int32(m.Capacity),
		AcceptedCount:          int32(m.AcceptedCount),
		Status:                 statusToProto[m.Status],
		CreatedAtUnixSeconds:   m.CreatedAt.Unix(),
		CancelledAtUnixSeconds: unixPtr(m.CancelledAt),
		CancellationReason:     m.CancellationReason,
		ClosedAtUnixSeconds:    unixPtr(m.ClosedAt),
		IsHostedByMe:           m.IsHostedByMe,
		MyRequestAutoRejected:  m.MyRequestAutoRejected,
		MyRequestId:            m.MyRequestID,
		LockedForViewer:        m.LockedForViewer,
	}
	if m.MyRequestStatus != nil {
		status := requestStatusToProto[*m.MyRequestStatus]
		resp.MyRequestStatus = &status
	}
	return resp
}

func meetupsToProto(meetups []meetup.Meetup) []*meetupv1.MeetupResponse {
	out := make([]*meetupv1.MeetupResponse, 0, len(meetups))
	for _, m := range meetups {
		out = append(out, meetupToProto(m))
	}
	return out
}

func requestToProto(r meetup.MeetupRequest) *meetupv1.MeetupRequestResponse {
	return &meetupv1.MeetupRequestResponse{
		Id:                       r.ID,
		MeetupId:                 r.MeetupID,
		RequesterId:              r.RequesterID,
		RequesterFullName:        r.RequesterFullName,
		RequesterProfilePhotoUrl: r.RequesterProfilePhotoURL,
		RequesterTrustLevel:      int32(r.RequesterTrustLevel),
		RequesterRatingAverage:   r.RequesterRatingAverage,
		RequesterRatingCount:     int32(r.RequesterRatingCount),
		Status:                   requestStatusToProto[r.Status],
		AutoRejected:             r.AutoRejected,
		CreatedAtUnixSeconds:     r.CreatedAt.Unix(),
		ResolvedAtUnixSeconds:    unixPtr(r.ResolvedAt),
		WithdrawalNote:           r.WithdrawalNote,
		CheckedInAtUnixSeconds:   unixPtr(r.CheckedInAt),
		DeclinedAtUnixSeconds:    unixPtr(r.DeclinedAt),
		DeclineReason:            r.DeclineReason,
	}
}

func safetyStateToProto(s meetup.SafetyState) *meetupv1.SafetyStateResponse {
	return &meetupv1.SafetyStateResponse{
		MeetupId:                  s.MeetupID,
		ChecklistAckAtUnixSeconds: unixPtr(s.ChecklistAckAt),
		LiveLocationOptIn:         s.LiveLocationOptIn,
		CheckedInAtUnixSeconds:    unixPtr(s.CheckedInAt),
		DeclinedAtUnixSeconds:     unixPtr(s.DeclinedAt),
		DeclineReason:             s.DeclineReason,
		SharedWithContactIds:      s.SharedWithContactIDs,
	}
}

// --- RPCs ---

func (s *MeetupServer) CreateMeetup(ctx context.Context, req *meetupv1.CreateMeetupRequest) (*meetupv1.MeetupResponse, error) {
	m, err := s.svc.CreateMeetup(ctx, meetup.CreateMeetupRequest{
		HostUserID:     req.GetHostUserId(),
		HostTrustLevel: int(req.GetHostTrustLevel()),
		Intent:         intentFromProto[req.GetIntent()],
		WindowStart:    time.Unix(req.GetWindowStartUnixSeconds(), 0).UTC(),
		WindowEnd:      time.Unix(req.GetWindowEndUnixSeconds(), 0).UTC(),
		LocationLat:    req.GetLocationLat(),
		LocationLng:    req.GetLocationLng(),
		LocationLabel:  req.GetLocationLabel(),
		Capacity:       int(req.GetCapacity()),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return meetupToProto(m), nil
}

func (s *MeetupServer) ListOpenMeetups(ctx context.Context, req *meetupv1.ListOpenMeetupsRequest) (*meetupv1.ListOpenMeetupsResponse, error) {
	// INTENT_UNSPECIFIED -> nil, meaning every intent. The map lookup would
	// otherwise yield the zero Intent (""), which the service rejects — so
	// this branch is what turns a previously-invalid request into the "All"
	// case, rather than silently changing what any valid request means.
	var intent *meetup.Intent
	if req.GetIntent() != meetupv1.Intent_INTENT_UNSPECIFIED {
		resolved := intentFromProto[req.GetIntent()]
		intent = &resolved
	}

	result, err := s.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
		UserID:           req.GetUserId(),
		Intent:           intent,
		WithinDays:       req.GetWithinDays(),
		Cursor:           req.GetCursor(),
		PageSize:         int(req.GetPageSize()),
		ViewerLat:        req.GetViewerLat(),
		ViewerLng:        req.GetViewerLng(),
		ViewerTrustLevel: int(req.GetViewerTrustLevel()),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &meetupv1.ListOpenMeetupsResponse{
		Meetups:    meetupsToProto(result.Meetups),
		NextCursor: result.NextCursor,
	}, nil
}

func (s *MeetupServer) GetMeetup(ctx context.Context, req *meetupv1.GetMeetupRequest) (*meetupv1.MeetupResponse, error) {
	m, err := s.svc.GetMeetup(ctx, meetup.GetMeetupRequest{
		MeetupID:         req.GetMeetupId(),
		UserID:           req.GetUserId(),
		ViewerTrustLevel: int(req.GetViewerTrustLevel()),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return meetupToProto(m), nil
}

func (s *MeetupServer) ListMyMeetups(ctx context.Context, req *meetupv1.ListMyMeetupsRequest) (*meetupv1.ListMyMeetupsResponse, error) {
	result, err := s.svc.ListMyMeetups(ctx, meetup.ListMyMeetupsRequest{
		UserID:          req.GetUserId(),
		HostedCursor:    req.GetHostedCursor(),
		RequestedCursor: req.GetRequestedCursor(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &meetupv1.ListMyMeetupsResponse{
		Hosted:              meetupsToProto(result.Hosted),
		Requested:           meetupsToProto(result.Requested),
		HostedNextCursor:    result.HostedNextCursor,
		HostedHasMore:       result.HostedHasMore,
		RequestedNextCursor: result.RequestedNextCursor,
		RequestedHasMore:    result.RequestedHasMore,
	}, nil
}

func (s *MeetupServer) ListActiveMeetups(ctx context.Context, req *meetupv1.ListActiveMeetupsRequest) (*meetupv1.ListActiveMeetupsResponse, error) {
	meetups, err := s.svc.ListActiveMeetups(ctx, req.GetUserId())
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &meetupv1.ListActiveMeetupsResponse{Meetups: meetupsToProto(meetups)}, nil
}

func (s *MeetupServer) ListMeetupRequests(ctx context.Context, req *meetupv1.ListMeetupRequestsRequest) (*meetupv1.ListMeetupRequestsResponse, error) {
	requests, err := s.svc.ListMeetupRequests(ctx, meetup.ListMeetupRequestsRequest{
		MeetupID:   req.GetMeetupId(),
		HostUserID: req.GetHostUserId(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	out := make([]*meetupv1.MeetupRequestResponse, 0, len(requests))
	for _, r := range requests {
		out = append(out, requestToProto(r))
	}
	return &meetupv1.ListMeetupRequestsResponse{Requests: out}, nil
}

func (s *MeetupServer) RequestToJoin(ctx context.Context, req *meetupv1.RequestToJoinRequest) (*meetupv1.MeetupRequestResponse, error) {
	r, err := s.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID:            req.GetMeetupId(),
		RequesterID:         req.GetRequesterId(),
		RequesterTrustLevel: int(req.GetRequesterTrustLevel()),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return requestToProto(r), nil
}

func (s *MeetupServer) WithdrawRequest(ctx context.Context, req *meetupv1.WithdrawRequestRequest) (*meetupv1.WithdrawRequestResponse, error) {
	if err := s.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{
		RequestID:   req.GetRequestId(),
		RequesterID: req.GetRequesterId(),
		Note:        req.GetNote(),
	}); err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &meetupv1.WithdrawRequestResponse{Success: true}, nil
}

func (s *MeetupServer) RespondToRequest(ctx context.Context, req *meetupv1.RespondToRequestRequest) (*meetupv1.MeetupRequestResponse, error) {
	r, err := s.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID:  req.GetRequestId(),
		HostUserID: req.GetHostUserId(),
		Accept:     req.GetAccept(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return requestToProto(r), nil
}

func (s *MeetupServer) RegisterDeviceToken(ctx context.Context, req *meetupv1.RegisterDeviceTokenRequest) (*meetupv1.RegisterDeviceTokenResponse, error) {
	if err := s.svc.RegisterDeviceToken(ctx, meetup.RegisterDeviceTokenRequest{
		UserID:   req.GetUserId(),
		FCMToken: req.GetFcmToken(),
	}); err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &meetupv1.RegisterDeviceTokenResponse{Success: true}, nil
}

func (s *MeetupServer) GetSafetyState(ctx context.Context, req *meetupv1.GetSafetyStateRequest) (*meetupv1.SafetyStateResponse, error) {
	state, err := s.svc.GetSafetyState(ctx, meetup.SafetyStateRequest{
		MeetupID: req.GetMeetupId(),
		UserID:   req.GetUserId(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return safetyStateToProto(state), nil
}

func (s *MeetupServer) AcknowledgeSafetyChecklist(ctx context.Context, req *meetupv1.AcknowledgeSafetyChecklistRequest) (*meetupv1.SafetyStateResponse, error) {
	state, err := s.svc.AcknowledgeSafetyChecklist(ctx, meetup.SafetyStateRequest{
		MeetupID: req.GetMeetupId(),
		UserID:   req.GetUserId(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return safetyStateToProto(state), nil
}

func (s *MeetupServer) SetLiveLocationOptIn(ctx context.Context, req *meetupv1.SetLiveLocationOptInRequest) (*meetupv1.SafetyStateResponse, error) {
	state, err := s.svc.SetLiveLocationOptIn(ctx, meetup.SetLiveLocationOptInRequest{
		MeetupID: req.GetMeetupId(),
		UserID:   req.GetUserId(),
		OptIn:    req.GetOptIn(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return safetyStateToProto(state), nil
}

func (s *MeetupServer) ShareWithContacts(ctx context.Context, req *meetupv1.ShareWithContactsRequest) (*meetupv1.SafetyStateResponse, error) {
	state, err := s.svc.ShareWithContacts(ctx, meetup.ShareWithContactsRequest{
		MeetupID:   req.GetMeetupId(),
		UserID:     req.GetUserId(),
		ContactIDs: req.GetContactIds(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return safetyStateToProto(state), nil
}

func (s *MeetupServer) CheckIn(ctx context.Context, req *meetupv1.CheckInRequest) (*meetupv1.SafetyStateResponse, error) {
	state, err := s.svc.CheckIn(ctx, meetup.SafetyStateRequest{
		MeetupID: req.GetMeetupId(),
		UserID:   req.GetUserId(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return safetyStateToProto(state), nil
}

func (s *MeetupServer) DeclineCheckIn(ctx context.Context, req *meetupv1.DeclineCheckInRequest) (*meetupv1.SafetyStateResponse, error) {
	state, err := s.svc.DeclineCheckIn(ctx, meetup.DeclineCheckInRequest{
		MeetupID: req.GetMeetupId(),
		UserID:   req.GetUserId(),
		Reason:   req.GetReason(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return safetyStateToProto(state), nil
}

func (s *MeetupServer) SubmitMeetupFeedback(ctx context.Context, req *meetupv1.SubmitMeetupFeedbackRequest) (*meetupv1.SubmitMeetupFeedbackResponse, error) {
	// FeltSafe/ProfileAccurate/WouldMeetAgain are read via the raw pointers,
	// not the Get*() accessors: the accessor collapses "genuinely unset" to
	// false, which would be written as a real negative answer nobody gave.
	if err := s.svc.SubmitMeetupFeedback(ctx, meetup.SubmitMeetupFeedbackRequest{
		MeetupID:        req.GetMeetupId(),
		UserID:          req.GetUserId(),
		Happened:        req.GetHappened(),
		FeltSafe:        req.FeltSafe,
		ProfileAccurate: req.ProfileAccurate,
		WouldMeetAgain:  req.WouldMeetAgain,
		Notes:           req.Notes,
	}); err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &meetupv1.SubmitMeetupFeedbackResponse{Success: true}, nil
}

func (s *MeetupServer) ListRatableParticipants(ctx context.Context, req *meetupv1.ListRatableParticipantsRequest) (*meetupv1.ListRatableParticipantsResponse, error) {
	participants, err := s.svc.ListRatableParticipants(ctx, meetup.ListRatableParticipantsRequest{
		MeetupID: req.GetMeetupId(),
		ViewerID: req.GetViewerId(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	out := make([]*meetupv1.RatableParticipant, 0, len(participants))
	for _, p := range participants {
		out = append(out, &meetupv1.RatableParticipant{
			UserId:          p.UserID,
			FullName:        p.FullName,
			ProfilePhotoUrl: p.ProfilePhotoURL,
			TrustLevel:      int32(p.TrustLevel),
			AlreadyRated:    p.AlreadyRated,
			ContextNote:     p.ContextNote,
		})
	}
	return &meetupv1.ListRatableParticipantsResponse{Participants: out}, nil
}

func (s *MeetupServer) SubmitRating(ctx context.Context, req *meetupv1.SubmitRatingRequest) (*meetupv1.SubmitRatingResponse, error) {
	if err := s.svc.SubmitRating(ctx, meetup.SubmitRatingRequest{
		MeetupID:    req.GetMeetupId(),
		RaterUserID: req.GetRaterUserId(),
		RatedUserID: req.GetRatedUserId(),
		Score:       int(req.GetScore()),
	}); err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &meetupv1.SubmitRatingResponse{Success: true}, nil
}

func (s *MeetupServer) CloseMeetup(ctx context.Context, req *meetupv1.CloseMeetupRequest) (*meetupv1.CloseMeetupResponse, error) {
	m, err := s.svc.CloseMeetup(ctx, meetup.CloseMeetupRequest{
		MeetupID:   req.GetMeetupId(),
		HostUserID: req.GetHostUserId(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &meetupv1.CloseMeetupResponse{Meetup: meetupToProto(m)}, nil
}

func (s *MeetupServer) CancelMeetup(ctx context.Context, req *meetupv1.CancelMeetupRequest) (*meetupv1.CancelMeetupResponse, error) {
	if err := s.svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{
		MeetupID:   req.GetMeetupId(),
		HostUserID: req.GetHostUserId(),
		Reason:     req.GetReason(),
	}); err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &meetupv1.CancelMeetupResponse{Success: true}, nil
}
