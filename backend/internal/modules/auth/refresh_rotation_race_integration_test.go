package auth_test

import (
	"context"
	"sync"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/auth"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// TestRefreshRotation_ConcurrentRefreshesOfOneTokenForkNothing is tracker
// #83 (review finding N-A2, confirming #57).
//
// Rotation is supposed to be single-use. It was checked in Go against a
// row read OUTSIDE the transaction, and the UPDATE that marked the parent
// replaced had no guard at all — `WHERE id = $1`. Two refreshes
// presenting the same token together both passed the check, both
// inserted a child, and both marked the parent replaced: one parent, two
// live children, two session chains descended from one token.
//
// That fork is permanent and invisible. Reuse detection keys on
// replaced_by being set, and it is set — so neither chain ever looks
// stolen, and an attacker holding a copy of a rotated token keeps a
// working session indefinitely.
//
// Exactly one of the two may win. The loser must be treated as reuse,
// which revokes the whole family — so after the race, the winner's own
// new token must ALSO be dead. That last assertion is the one that
// distinguishes "we rejected the loser" from "we handled the reuse".
func TestRefreshRotation_ConcurrentRefreshesOfOneTokenForkNothing(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	const rounds = 5
	for round := 0; round < rounds; round++ {
		session, err := h.svc.CompleteLinkedInOnboarding(ctx, auth.CompleteLinkedInOnboardingRequest{
			AuthorizationCode: "code", RedirectURI: "app://cb", AgeConfirmedOver18: true,
		})
		if err != nil {
			t.Fatalf("round %d: onboarding: %v", round, err)
		}

		results := make([]auth.SessionResult, 2)
		errs := race(t, 2, func(i int) error {
			out, err := h.svc.RefreshSession(ctx, session.RefreshToken)
			results[i] = out
			return err
		})

		wins, winner := 0, auth.SessionResult{}
		for i, err := range errs {
			switch {
			case err == nil:
				wins++
				winner = results[i]
			case isSentinel(err, apperror.ErrUnauthorized):
			default:
				t.Fatalf("round %d: unexpected error: %v", round, err)
			}
		}
		if wins != 1 {
			t.Fatalf("round %d: %d of 2 concurrent refreshes of ONE token succeeded, want exactly 1 — "+
				"the session chain forked", round, wins)
		}

		// Exactly one child row exists for that parent, not two.
		var children int
		if err := h.pool.QueryRow(ctx, `
			SELECT count(*) FROM auth.refresh_tokens
			WHERE user_id = $1 AND replaced_by IS NULL AND revoked_at IS NULL`,
			session.UserID).Scan(&children); err != nil {
			t.Fatalf("round %d: count live tokens: %v", round, err)
		}

		// The loser was treated as reuse, so the family — including the
		// winner's brand new token — is revoked.
		if _, err := h.svc.RefreshSession(ctx, winner.RefreshToken); !isSentinel(err, apperror.ErrUnauthorized) {
			t.Errorf("round %d: the winner's new token still works after a detected reuse: error = %v, "+
				"want ErrUnauthorized", round, err)
		}
		if children != 0 {
			t.Errorf("round %d: %d live refresh tokens after the family was revoked, want 0",
				round, children)
		}
	}
}

// The ordinary path must keep working: one refresh at a time rotates and
// the old token stops working.
func TestRefreshRotation_SequentialRotationStillWorks(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	session, err := h.svc.CompleteLinkedInOnboarding(ctx, auth.CompleteLinkedInOnboardingRequest{
		AuthorizationCode: "code", RedirectURI: "app://cb", AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("onboarding: %v", err)
	}

	next, err := h.svc.RefreshSession(ctx, session.RefreshToken)
	if err != nil {
		t.Fatalf("first refresh: %v", err)
	}
	if next.RefreshToken == session.RefreshToken {
		t.Fatal("refresh returned the same token")
	}
	third, err := h.svc.RefreshSession(ctx, next.RefreshToken)
	if err != nil {
		t.Fatalf("second refresh: %v", err)
	}
	if third.RefreshToken == next.RefreshToken {
		t.Fatal("refresh returned the same token")
	}
}

// race runs fn n times concurrently, all released together, and returns
// each call's error in order. Same shape as the meetup package's own
// helper — a barrier, not a sleep, because a race that only sometimes
// overlaps proves only that it sometimes did not.
func race(t *testing.T, n int, fn func(i int) error) []error {
	t.Helper()
	results := make([]error, n)
	var (
		ready sync.WaitGroup
		done  sync.WaitGroup
		start = make(chan struct{})
	)
	for i := 0; i < n; i++ {
		ready.Add(1)
		done.Add(1)
		go func(i int) {
			defer done.Done()
			ready.Done()
			<-start
			results[i] = fn(i)
		}(i)
	}
	ready.Wait()
	close(start)
	done.Wait()
	return results
}
