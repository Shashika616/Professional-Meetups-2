package meetup

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
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

	// Charging (plan 29 §3.5), after every rule above and never instead of
	// one. A retry with the same Idempotency-Key returns the original
	// meetup before anything is priced or held.
	requestHash := creationRequestHash(req)
	if req.IdempotencyKey != "" {
		if existing, err := s.meetups.FindByCreationKey(ctx, req.HostUserID, req.IdempotencyKey); err == nil {
			if existing.CreationRequestHash != "" && existing.CreationRequestHash != requestHash {
				return Meetup{}, errIdempotencyKeyReused
			}
			full, err := s.meetups.GetByID(ctx, existing.ID, req.HostUserID)
			if err != nil {
				return Meetup{}, err
			}
			return meetupFromRepo(full, req.HostUserID), nil
		} else if !errors.Is(err, apperror.ErrNotFound) {
			return Meetup{}, err
		}
	}
	quote, err := s.creationLimits(ctx, req)
	if err != nil {
		return Meetup{}, err
	}
	if err := checkLimits(req, quote, time.Now()); err != nil {
		return Meetup{}, err
	}
	if err := checkExpectedCost(req, quote); err != nil {
		return Meetup{}, err
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

	holdID := ""
	if quote.charged() {
		holdID, err = s.charger.Reserve(ctx, req.HostUserID, quote, reserveKey(req))
		if err != nil {
			return Meetup{}, err
		}
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
		CreationKey:   req.IdempotencyKey,
		ChargeHoldID:  holdID,
		// Only with a key: without one there is nothing to replay.
		CreationRequestHash: hashIfKeyed(req.IdempotencyKey, requestHash),
		// One meetup at a time: checked under the host's schedule lock in
		// the same transaction as the insert (ScheduleConflictError names
		// the meetup in the way).
	}, scheduleGuard(req.HostUserID, req.WindowStart, req.WindowEnd, ""))
	if err != nil {
		// A concurrent retry with the same key won the race: its meetup is
		// this request's answer, and it is paying with the same hold.
		if existing, isRetry, getErr := s.existingForKey(ctx, err, req.HostUserID, requestHash); isRetry {
			return existing, getErr
		}
		s.releaseAfterFailedCreate(ctx, req, holdID)
		return Meetup{}, err
	}
	if holdID != "" {
		s.wakeBilling()
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
			fmt.Sprintf("Review the safety checklist for your new %s meetup", Intent(created.Intent).DisplayName()),
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

// validIntent rejects an unrecognized intent before it reaches the database,
// where it would surface as an opaque enum-cast error.
func validIntent(i Intent) bool {
	switch i {
	case IntentCoffee, IntentLunch, IntentNetworking, IntentMentorship, IntentRideShare, IntentDating, IntentOuting:
		return true
	default:
		return false
	}
}

// errIdempotencyKeyReused: the key names a different request (N1-B6). A
// 409 rather than the first meetup with a 200, which would tell the app the
// new meetup had been made.
var errIdempotencyKeyReused = fmt.Errorf("meetup: this request key was already used for a different meetup: %w", apperror.ErrConflict)

// creationRequestHash identifies what a create asked for, as the client
// sent it (before any label is geocoded), for comparing replays.
func creationRequestHash(req CreateMeetupRequest) string {
	sum := sha256.Sum256(fmt.Appendf(nil, "%s|%d|%d|%.7f|%.7f|%s|%d",
		req.Intent, req.WindowStart.Unix(), req.WindowEnd.Unix(),
		req.LocationLat, req.LocationLng, req.LocationLabel, req.Capacity))
	return hex.EncodeToString(sum[:])
}

func hashIfKeyed(key, hash string) string {
	if key == "" {
		return ""
	}
	return hash
}
