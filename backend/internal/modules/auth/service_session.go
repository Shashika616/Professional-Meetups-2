package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// RefreshSession rotates a refresh token for a new pair. The presented token
// is invalidated whether or not it was valid to begin with.
//
// ADR-001 §6 splits this call in two: this module still owns validating and
// rotating the auth.refresh_tokens row and still mints the new refresh
// token, but the new ACCESS token is signed by the gateway from the UserID
// and TrustLevel returned here.
// handleRefreshTokenReuse ends every session the user has and returns the
// rejection for the request that triggered it.
//
// A refresh token presented twice is the signature of a STOLEN one, not a
// client bug: rotation is single-use and transactional, so a well-behaved
// client physically cannot present the same token twice — it discarded
// the old value the moment it received the replacement.
//
// Rejecting just this one request is not enough (§B1). If an attacker has
// a copy of a token the legitimate client has since rotated, the attacker
// plausibly has the rest of that session's chain, and the server has no
// way to tell which side of this exchange is the thief. Ending the whole
// family makes both parties re-authenticate — the legitimate user is
// logged out too, which is the correct trade: a forced re-login is a
// minor annoyance, a silently-shared session is an account takeover.
//
// Called from two places since #83, which is why it is a function: the
// pre-check on the row as read, and the rotation's own claim failing
// because another transaction won the race. Both are the same event and
// must produce the same response, and a second copy of this block would
// eventually drift from the first.
func (s *service) handleRefreshTokenReuse(ctx context.Context, userID string) error {
	revoked, revokeErr := s.refreshTokens.RevokeAllForUser(ctx, userID)
	if revokeErr != nil {
		// Logged, not propagated: the caller must still be rejected, and
		// returning the revocation's error instead would turn a definite
		// "no" into an ambiguous 500 that a client might retry.
		s.logger.Error("refresh token reuse detected but revoking the session family failed",
			"event", "refresh_token_reuse",
			"user_id", userID,
			"error", revokeErr,
		)
	} else {
		// Deliberately loud, and deliberately without the token or its
		// hash: this is the one log line that says an account may be
		// compromised, and it is what an operator would alert on. There
		// is no session-revoked event on the bus to publish alongside it
		// — this log line is the signal.
		s.logger.Warn("refresh token reuse detected — revoked the user's entire session family",
			"event", "refresh_token_reuse",
			"user_id", userID,
			"sessions_revoked", revoked,
		)
	}
	return fmt.Errorf("refresh token already used: %w", apperror.ErrUnauthorized)
}

func (s *service) RefreshSession(ctx context.Context, refreshToken string) (SessionResult, error) {
	old, err := s.refreshTokens.FindByHash(ctx, hashToken(refreshToken))
	if errors.Is(err, apperror.ErrNotFound) {
		// Unknown to us: the session is over, the same as an expired token.
		// As a 404 it read to the app as a network problem, so the app stayed
		// signed in and retried on every call.
		return SessionResult{}, fmt.Errorf("invalid refresh token: %w", apperror.ErrUnauthorized)
	}
	if err != nil {
		return SessionResult{}, err
	}

	// A replayed, already-rotated (or revoked) refresh token is the
	// signature of a STOLEN one, not a client bug: rotation is single-use
	// and transactional, so a well-behaved client physically cannot present
	// the same token twice — it discarded the old value the moment it
	// received the replacement.
	//
	// §B1: rejecting just this one request is not enough. If an attacker has
	// a copy of a token the legitimate client has since rotated, the
	// attacker also plausibly has the rest of that session's chain, and the
	// server has no way to tell which side of this exchange is the thief.
	// The standard response is to end the whole session family and make both
	// parties re-authenticate — the legitimate user is logged out too, which
	// is the correct trade-off: a forced re-login is a minor annoyance, a
	// silently-shared session is an account takeover.
	if old.RevokedAt != nil || old.ReplacedBy != nil {
		return SessionResult{}, s.handleRefreshTokenReuse(ctx, old.UserID)
	}
	if time.Now().After(old.ExpiresAt) {
		return SessionResult{}, fmt.Errorf("refresh token expired: %w", apperror.ErrUnauthorized)
	}

	user, err := s.users.GetByID(ctx, old.UserID)
	if err != nil {
		return SessionResult{}, err
	}

	newRawToken, newHash, err := newRefreshToken()
	if err != nil {
		return SessionResult{}, fmt.Errorf("%w: %w", apperror.ErrInternal, err)
	}

	if _, err := s.refreshTokens.Rotate(ctx, old.ID, newHash, time.Now().Add(RefreshTokenTTL)); err != nil {
		// The check above read a snapshot; this is the row's own answer
		// (#83). Two refreshes of one token race past that check
		// together, and the loser lands here — same situation, same
		// response, so the family is revoked exactly as if the reuse had
		// been visible up front.
		if errors.Is(err, repository.ErrRefreshTokenAlreadyRotated) {
			return SessionResult{}, s.handleRefreshTokenReuse(ctx, old.UserID)
		}
		return SessionResult{}, err
	}

	return SessionResult{
		UserID:          user.ID,
		RefreshToken:    newRawToken,
		FullName:        user.FullName,
		ProfilePhotoURL: user.ProfilePhotoURL,
		TrustLevel:      user.TrustLevel,
	}, nil
}

// RevokeSession revokes a refresh token (logout). Idempotent — revoking an
// already-revoked or unknown token is not an error.
func (s *service) RevokeSession(ctx context.Context, refreshToken string) error {
	return s.refreshTokens.Revoke(ctx, hashToken(refreshToken))
}

// issueSession persists a fresh refresh-token row for user and returns the
// facts the gateway needs to mint the access token (ADR-001 §6). The source's
// equivalent also signed a JWT here; this process cannot.
func (s *service) issueSession(ctx context.Context, user repository.User) (SessionResult, error) {
	rawToken, hash, err := newRefreshToken()
	if err != nil {
		return SessionResult{}, fmt.Errorf("%w: %w", apperror.ErrInternal, err)
	}

	if _, err := s.refreshTokens.Create(ctx, user.ID, hash, time.Now().Add(RefreshTokenTTL)); err != nil {
		return SessionResult{}, err
	}

	return SessionResult{
		UserID:          user.ID,
		RefreshToken:    rawToken,
		FullName:        user.FullName,
		ProfilePhotoURL: user.ProfilePhotoURL,
		TrustLevel:      user.TrustLevel,
	}, nil
}

// newRefreshToken generates a new random refresh token, returning both the
// raw value (returned to the client exactly once) and its SHA-256 hash — the
// only thing ever persisted.
func newRefreshToken() (raw, hash string, err error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", "", fmt.Errorf("generate refresh token: %w", err)
	}
	raw = hex.EncodeToString(buf)
	return raw, hashToken(raw), nil
}

func hashToken(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}
