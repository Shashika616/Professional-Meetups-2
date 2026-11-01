package billing

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"professional-meetups-monolith/backend/internal/modules/billing/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/modules/billing/wallet"
)

// errNoWelcome rolls back a welcome grant that lost its race or was already
// claimed by the same person on another account.
var errNoWelcome = errors.New("billing: welcome grant not due")

// ensureWelcome grants the welcome credits (D1) the first time a user at
// hosting level touches billing — their first
// wallet, quote or entitlements call — rather than at the moment they level
// up, so the auth module needs no hook into billing at all.
//
// Once per account AND once per person: billing.welcome_grants is unique on
// both the user id and the identity fingerprint, so two accounts verified
// with the same phone share one grant, and concurrent first calls grant
// once.
//
// Best effort by design. A failure here is logged and the request carries
// on: a wallet page must not fail because the grant could not be written,
// and the next call tries again.
func (s *Service) ensureWelcome(ctx context.Context, caller Caller) {
	if caller.TrustLevel < HostingTrustLevel || s.fingerprints == nil {
		return
	}
	uid, err := parseUser(caller.UserID)
	if err != nil {
		return
	}
	if _, err := s.q.GetWelcomeGrant(ctx, uid); err == nil {
		return
	} else if !errors.Is(err, pgx.ErrNoRows) {
		s.logger.Warn("billing: read welcome grant", "error", err)
		return
	}

	fingerprint, err := s.fingerprints.Fingerprint(ctx, caller.UserID)
	if err != nil {
		s.logger.Warn("billing: identity fingerprint unavailable, welcome grant deferred", "error", err)
		return
	}
	if fingerprint == "" {
		// Level 3 without a verified phone or personal email should not
		// exist; if it does, granting without an anti-farming anchor would
		// be the wrong way to fail.
		return
	}
	rules, err := s.Rules(ctx)
	if err != nil || rules.Doc.Welcome.Credits <= 0 {
		return
	}
	w := rules.Doc.Welcome
	every := time.Duration(w.DecayEveryDays) * 24 * time.Hour

	err = s.ledger.Do(ctx, caller.UserID, func(t *wallet.Tx) error {
		expires := t.Now().Add(every * time.Duration(wallet.MaxPeriods(w.DecayPercent)))
		lotID, err := t.Grant(wallet.GrantInput{
			Kind: wallet.KindWelcome, Amount: w.Credits, ExpiresAt: &expires,
			Decay: &wallet.Decay{Percent: w.DecayPercent, Every: every},
			Key:   "welcome:" + uid.String(), RefType: "welcome",
		})
		if errors.Is(err, wallet.ErrAlreadyApplied) {
			return errNoWelcome
		}
		if err != nil {
			return err
		}
		n, err := t.Queries().InsertWelcomeGrant(ctx, sqlcgen.InsertWelcomeGrantParams{
			UserID: uid, IdentityFingerprint: fingerprint, LotID: lotID, Amount: w.Credits,
		})
		if err != nil {
			return fmt.Errorf("billing: record welcome grant: %w", err)
		}
		if n == 0 {
			return errNoWelcome
		}
		return nil
	})
	switch {
	case err == nil:
		s.logger.Info("billing: welcome credits granted", "user_id", caller.UserID, "credits", w.Credits)
	case errors.Is(err, errNoWelcome):
	default:
		s.logger.Warn("billing: welcome grant failed", "error", err)
	}
}
