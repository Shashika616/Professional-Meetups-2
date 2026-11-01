package meetup

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// CreationCharger is the billing module, seen from here (plan 29 §3.5).
//
// The meetup module owns this interface and the billing module knows nothing
// of it: an adapter in cmd/monolith translates between the two, the same way
// TrustedContactNotifier reaches auth. Either side can become a separate
// service by swapping the adapter for a gRPC client.
//
// It never decides whether someone may host. The trust gate, validation and
// every meetup rule run first and are unchanged; a charger can only make an
// allowed creation cost something, never make a forbidden one possible
// (plan 29 §1: premium never sells trust).
type CreationCharger interface {
	// QuoteCreation prices one creation for the host and reports their
	// limits. It refuses an app build too old to have shown a price
	// (apperror.ErrUpgradeRequired).
	QuoteCreation(ctx context.Context, host CreationHost, capacity int, windowStart time.Time) (CreationQuote, error)
	// Reserve holds the quoted cost. The same key returns the same hold.
	// An empty hold id means nothing needed holding.
	Reserve(ctx context.Context, hostUserID string, quote CreationQuote, key string) (holdID string, err error)
	// Release returns a hold that will not be used.
	Release(ctx context.Context, holdID string) error
}

// CreationHost is who is creating.
type CreationHost struct {
	UserID     string
	TrustLevel int
}

// CreationQuote is a charger's answer: what it costs and what is allowed.
type CreationQuote struct {
	Cost           int64
	PriceVersion   int
	CoveredByPlan  bool
	MaxCapacity    int
	MaxAdvanceDays int
}

// charged reports whether creating under this quote holds anything.
func (q CreationQuote) charged() bool { return q.Cost > 0 || q.CoveredByPlan }

// defaultMaxCapacity is the limit with no charger wired (tests, and any
// deployment without billing): today's 20.
const defaultMaxCapacity = 20

// creationLimits asks the charger for this host's limits and price, or
// returns today's limits when no charger is wired.
func (s *service) creationLimits(ctx context.Context, req CreateMeetupRequest) (CreationQuote, error) {
	if s.charger == nil {
		return CreationQuote{MaxCapacity: defaultMaxCapacity}, nil
	}
	return s.charger.QuoteCreation(ctx, CreationHost{UserID: req.HostUserID, TrustLevel: req.HostTrustLevel},
		req.Capacity, req.WindowStart)
}

// checkLimits applies the quote's limits to the request.
func checkLimits(req CreateMeetupRequest, q CreationQuote, now time.Time) error {
	maxCapacity := q.MaxCapacity
	if maxCapacity <= 0 {
		maxCapacity = defaultMaxCapacity
	}
	if req.Capacity < 1 || req.Capacity > maxCapacity {
		return fmt.Errorf("meetup: capacity must be between 1 and %d: %w", maxCapacity, apperror.ErrInvalidInput)
	}
	if q.MaxAdvanceDays > 0 && req.WindowStart.Sub(now) > time.Duration(q.MaxAdvanceDays)*24*time.Hour {
		return fmt.Errorf("meetup: meetups can be scheduled at most %d days ahead: %w", q.MaxAdvanceDays, apperror.ErrInvalidInput)
	}
	return nil
}

// checkExpectedCost refuses a charged creation whose cost the app did not
// show, or showed at a different price (409 price_changed with the new
// cost, so the app can show it and ask again).
func checkExpectedCost(req CreateMeetupRequest, q CreationQuote) error {
	if !q.charged() {
		return nil
	}
	if req.ExpectedCost != nil && *req.ExpectedCost == q.Cost {
		return nil
	}
	return &apperror.CodedError{
		Sentinel: apperror.ErrConflict, Code: apperror.CodePriceChanged,
		Message: "meetup: the price changed; check the new price and try again",
		Fields:  map[string]int64{"cost": q.Cost, "price_version": int64(q.PriceVersion)},
	}
}

// reserveKey is the billing idempotency key for one create request. With an
// Idempotency-Key, retries share it and so share one hold; without one,
// every request is its own creation.
func reserveKey(req CreateMeetupRequest) string {
	if req.IdempotencyKey != "" {
		return "meetup-create:" + req.IdempotencyKey
	}
	return "meetup-create:" + uuid.NewString()
}

// releaseAfterFailedCreate gives back a hold whose meetup was never created.
//
// Unless a retry with the same key DID create it: that meetup is paying with
// this very hold. The check is a read outside the create's lock, so a retry
// can still commit in the gap; billing's capture then re-spends a released
// hold (or records debt), which is the backstop for exactly this race.
func (s *service) releaseAfterFailedCreate(ctx context.Context, req CreateMeetupRequest, holdID string) {
	if holdID == "" {
		return
	}
	ctx = context.WithoutCancel(ctx)
	if req.IdempotencyKey != "" {
		if _, err := s.meetups.FindByCreationKey(ctx, req.HostUserID, req.IdempotencyKey); err == nil {
			return
		}
	}
	if err := s.charger.Release(ctx, holdID); err != nil {
		// The hold's TTL is the backstop: the expiry sweep releases it.
		s.logger.Error("release hold after a failed create", "hold_id", holdID, "error", err)
	}
}

// existingForKey turns a CreationKeyExistsError into the meetup that the
// earlier request created.
func (s *service) existingForKey(ctx context.Context, err error, hostUserID string) (Meetup, bool, error) {
	var exists *repository.CreationKeyExistsError
	if !errors.As(err, &exists) {
		return Meetup{}, false, nil
	}
	full, getErr := s.meetups.GetByID(ctx, exists.MeetupID, hostUserID)
	if getErr != nil {
		return Meetup{}, true, getErr
	}
	return meetupFromRepo(full, hostUserID), true, nil
}

// wakeBilling nudges the meetup billing-event poller after a write that may
// have queued an event, so a capture or refund happens in milliseconds
// rather than at the next tick.
func (s *service) wakeBilling() {
	if s.billingWake != nil {
		s.billingWake()
	}
}
