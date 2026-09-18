package meetup_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/modules/meetup"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// createMeetupAt is createMeetup with an explicit window, for the tests
// that are about the window itself.
func (h *harness) createMeetupAt(t *testing.T, host string, start, end time.Time) (meetup.Meetup, error) {
	t.Helper()
	return h.svc.CreateMeetup(context.Background(), meetup.CreateMeetupRequest{
		HostUserID:     host,
		HostTrustLevel: 4,
		Intent:         meetup.IntentCoffee,
		WindowStart:    start,
		WindowEnd:      end,
		LocationLat:    colomboLat,
		LocationLng:    colomboLng,
		LocationLabel:  "Test Cafe",
		Capacity:       5,
	})
}

func asScheduleConflict(t *testing.T, err error) *meetup.ScheduleConflictError {
	t.Helper()
	var conflict *meetup.ScheduleConflictError
	if !errors.As(err, &conflict) {
		t.Fatalf("error = %v, want *meetup.ScheduleConflictError", err)
	}
	if !isSentinel(err, apperror.ErrConflict) {
		t.Errorf("a schedule conflict must still classify as ErrConflict (409); got %v", err)
	}
	return conflict
}

// TestScheduleConflict_OneMeetupAtATime is the rule from 2026-09-15: a
// person hosts or joins at most one live meetup per time window. Hosting,
// a pending request and an accepted request all count; a finished or
// cancelled meetup and a back-to-back window do not.
func TestScheduleConflict_OneMeetupAtATime(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	other := newUserID(t, h)
	joiner := newUserID(t, h)

	base := time.Now().Add(2 * time.Hour).Truncate(time.Second)
	first, err := h.createMeetupAt(t, host, base, base.Add(time.Hour))
	if err != nil {
		t.Fatalf("first meetup: %v", err)
	}

	t.Run("host cannot host an overlapping meetup", func(t *testing.T) {
		_, err := h.createMeetupAt(t, host, base.Add(30*time.Minute), base.Add(90*time.Minute))
		conflict := asScheduleConflict(t, err)
		if conflict.Conflict.ID != first.ID || !conflict.Conflict.IsHostedByMe {
			t.Errorf("conflict = %+v, want the hosted meetup %s with IsHostedByMe", conflict.Conflict, first.ID)
		}
	})

	t.Run("a window that only touches is not an overlap", func(t *testing.T) {
		if _, err := h.createMeetupAt(t, host, base.Add(time.Hour), base.Add(2*time.Hour)); err != nil {
			t.Errorf("back-to-back meetup: %v, want success", err)
		}
	})

	// Another host's meetup in the same window, for the join half.
	overlapping, err := h.createMeetupAt(t, other, base, base.Add(time.Hour))
	if err != nil {
		t.Fatalf("other host's meetup: %v", err)
	}

	t.Run("host cannot join a meetup during their own", func(t *testing.T) {
		_, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
			MeetupID: overlapping.ID, RequesterID: host, RequesterTrustLevel: 4,
		})
		conflict := asScheduleConflict(t, err)
		if conflict.Conflict.ID != first.ID {
			t.Errorf("conflict = %s, want the hosted meetup %s", conflict.Conflict.ID, first.ID)
		}
	})

	t.Run("a pending request blocks a second overlapping request and hosting", func(t *testing.T) {
		if _, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
			MeetupID: first.ID, RequesterID: joiner, RequesterTrustLevel: 4,
		}); err != nil {
			t.Fatalf("first request: %v", err)
		}
		_, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
			MeetupID: overlapping.ID, RequesterID: joiner, RequesterTrustLevel: 4,
		})
		conflict := asScheduleConflict(t, err)
		if conflict.Conflict.ID != first.ID || conflict.Conflict.IsHostedByMe {
			t.Errorf("conflict = %+v, want the requested meetup %s, not hosted", conflict.Conflict, first.ID)
		}
		if conflict.Conflict.MyRequestStatus == nil || *conflict.Conflict.MyRequestStatus != meetup.RequestStatusPending {
			t.Errorf("MyRequestStatus = %v, want pending so the app can say 'cancel your request'", conflict.Conflict.MyRequestStatus)
		}
		_, err = h.createMeetupAt(t, joiner, base.Add(45*time.Minute), base.Add(2*time.Hour))
		_ = asScheduleConflict(t, err)
	})

	t.Run("cancelling the request frees the window", func(t *testing.T) {
		got, err := h.svc.GetMeetup(ctx, meetup.GetMeetupRequest{MeetupID: first.ID, UserID: joiner, ViewerTrustLevel: 4})
		if err != nil {
			t.Fatalf("GetMeetup: %v", err)
		}
		if err := h.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{
			RequestID: *got.MyRequestID, RequesterID: joiner,
		}); err != nil {
			t.Fatalf("WithdrawRequest: %v", err)
		}
		if _, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
			MeetupID: overlapping.ID, RequesterID: joiner, RequesterTrustLevel: 4,
		}); err != nil {
			t.Errorf("request after withdrawing the other: %v, want success", err)
		}
	})

	t.Run("CheckSchedule answers the same question ahead of time", func(t *testing.T) {
		conflict, found, err := h.svc.CheckSchedule(ctx, host, base.Add(30*time.Minute), base.Add(90*time.Minute))
		if err != nil || !found || conflict.ID != first.ID || !conflict.IsHostedByMe {
			t.Errorf("CheckSchedule over the hosted window = (%+v, %v, %v), want the hosted meetup", conflict, found, err)
		}
		if _, found, err := h.svc.CheckSchedule(ctx, host, base.Add(48*time.Hour), base.Add(49*time.Hour)); err != nil || found {
			t.Errorf("CheckSchedule over a free window = (found %v, err %v), want free", found, err)
		}
		// A draft whose end is not after its start is simply free here; the
		// create path is where that is rejected.
		if _, found, err := h.svc.CheckSchedule(ctx, host, base, base); err != nil || found {
			t.Errorf("CheckSchedule over an empty window = (found %v, err %v), want free", found, err)
		}
	})

	t.Run("a cancelled meetup no longer blocks its host", func(t *testing.T) {
		cancelHost := newUserID(t, h)
		m, err := h.createMeetupAt(t, cancelHost, base, base.Add(time.Hour))
		if err != nil {
			t.Fatalf("create: %v", err)
		}
		if err := h.svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{MeetupID: m.ID, HostUserID: cancelHost, Reason: "plans changed"}); err != nil {
			t.Fatalf("cancel: %v", err)
		}
		if _, err := h.createMeetupAt(t, cancelHost, base, base.Add(time.Hour)); err != nil {
			t.Errorf("hosting after cancelling: %v, want success", err)
		}
	})

	t.Run("a meetup that has ended no longer blocks", func(t *testing.T) {
		pastHost := newUserID(t, h)
		m := h.createMeetup(t, pastHost, meetup.IntentCoffee, colomboLat, colomboLng)
		backdateMeetup(t, h, m.ID) // window now in the past, status untouched
		// The same window createMeetup used, which the backdated row would
		// have overlapped had it still been live.
		if _, err := h.createMeetupAt(t, pastHost, time.Now().Add(time.Hour), time.Now().Add(3*time.Hour)); err != nil {
			t.Errorf("hosting after the earlier window ended: %v, want success", err)
		}
	})
}

// TestScheduleConflict_OnlyTheCallersOwnMeetupsCount is the regression
// guard for gap #42 (Plan 20 Fix 1). The query used to scan every live
// meetup on the platform and narrow to the caller afterwards; the rewrite
// looks only at meetups the caller hosts or has requested. Seed a crowd of
// OTHER people's live meetups and requests, all overlapping the window
// under test, and confirm that a person with nothing of their own in that
// window is told the window is free, by the advisory check and by the
// locked create and join paths alike.
func TestScheduleConflict_OnlyTheCallersOwnMeetupsCount(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	base := time.Now().Add(3 * time.Hour).Truncate(time.Second)
	window := func(offset time.Duration) (time.Time, time.Time) {
		return base.Add(offset), base.Add(offset + time.Hour)
	}

	// Forty hosts, each with a live meetup overlapping the window, and a
	// requester on each: eighty other-people commitments in the way of a
	// platform-wide scan, none of them the caller's.
	const crowd = 40
	var hosted []meetup.Meetup
	for i := 0; i < crowd; i++ {
		host := newUserID(t, h)
		start, end := window(time.Duration(i) * time.Minute)
		m, err := h.createMeetupAt(t, host, start, end)
		if err != nil {
			t.Fatalf("crowd meetup %d: %v", i, err)
		}
		hosted = append(hosted, m)
		requester := newUserID(t, h)
		if _, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
			MeetupID: m.ID, RequesterID: requester, RequesterTrustLevel: 4,
		}); err != nil {
			t.Fatalf("crowd request %d: %v", i, err)
		}
	}

	clean := newUserID(t, h)
	start, end := window(20 * time.Minute)

	t.Run("the advisory check finds nothing for a clean user", func(t *testing.T) {
		conflict, found, err := h.svc.CheckSchedule(ctx, clean, start, end)
		if err != nil {
			t.Fatalf("CheckSchedule: %v", err)
		}
		if found {
			t.Fatalf("CheckSchedule found %s (host %s) for a user with no commitments: another user's meetup leaked into the caller's conflict check", conflict.ID, conflict.HostUserID)
		}
	})

	t.Run("a clean user can join a crowded window", func(t *testing.T) {
		if _, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
			MeetupID: hosted[20].ID, RequesterID: clean, RequesterTrustLevel: 4,
		}); err != nil {
			t.Fatalf("RequestToJoin: %v, want success", err)
		}
	})

	t.Run("having joined one, the same user is blocked from a second, by their own request only", func(t *testing.T) {
		_, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
			MeetupID: hosted[21].ID, RequesterID: clean, RequesterTrustLevel: 4,
		})
		conflict := asScheduleConflict(t, err)
		if conflict.Conflict.ID != hosted[20].ID {
			t.Errorf("conflict = %s, want the meetup this user requested, %s", conflict.Conflict.ID, hosted[20].ID)
		}
	})

	t.Run("a second clean user can host in the crowded window", func(t *testing.T) {
		another := newUserID(t, h)
		if _, err := h.createMeetupAt(t, another, start, end); err != nil {
			t.Fatalf("CreateMeetup: %v, want success", err)
		}
	})
}
