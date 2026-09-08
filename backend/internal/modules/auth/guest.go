package auth

import (
	"context"
	"crypto/rand"
	"fmt"
	"math/big"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// Guest handle vocabulary (ADR-002 §3). A small embedded word list rather
// than a dependency: the requirement is "a friendly, non-identifying name",
// which two arrays and a number satisfy completely.
//
// The words are deliberately bland and positive — a handle is shown to other
// users on a meetup card, so the list must not be able to produce something
// insulting, political, or accidentally meaningful when an adjective and a
// noun collide. Every pairing here is safe in any order.
var (
	guestAdjectives = []string{
		"Amber", "Brave", "Bright", "Calm", "Clever", "Cosmic", "Crimson",
		"Curious", "Daring", "Eager", "Gentle", "Golden", "Happy", "Jolly",
		"Keen", "Lively", "Lucky", "Mellow", "Merry", "Nimble", "Noble",
		"Polar", "Quiet", "Rapid", "Royal", "Silent", "Silver", "Smooth",
		"Sunny", "Swift", "Tidy", "Vivid", "Witty", "Zesty",
	}
	guestNouns = []string{
		"Otter", "Falcon", "Badger", "Heron", "Lynx", "Marten", "Osprey",
		"Panda", "Puffin", "Raven", "Robin", "Sparrow", "Stoat", "Tapir",
		"Toucan", "Walrus", "Weasel", "Wombat", "Beaver", "Bison", "Cobra",
		"Dingo", "Ferret", "Gecko", "Ibis", "Jackal", "Koala", "Lemur",
		"Meerkat", "Narwhal", "Ocelot", "Quokka",
	}
)

// guestHandlePrefix is what makes a generated name recognisable as a guest
// account at a glance, in the UI and in a database row alike.
const guestHandlePrefix = "Guest-"

// generateGuestHandle returns a display name like "Guest-CleverOtter4821".
//
// COLLISIONS ARE FINE AND EXPECTED. There is no uniqueness constraint on
// full_name and none is wanted: the handle is cosmetic, accounts are
// identified by their UUID everywhere that matters, and two guests sharing a
// name is a curiosity rather than a bug. With 34 adjectives x 32 nouns x
// 9000 numbers there are ~9.8M combinations, which is ample for a label that
// does not have to be unique at all.
//
// crypto/rand, not math/rand, purely because this package already has it
// imported for token generation and there is no reason to introduce a second,
// weaker source of randomness in a file that produces user-facing identifiers.
// The security requirement here is genuinely nil; the consistency one is not.
func generateGuestHandle() (string, error) {
	adjective, err := randomFrom(guestAdjectives)
	if err != nil {
		return "", err
	}
	noun, err := randomFrom(guestNouns)
	if err != nil {
		return "", err
	}
	// 1000-9999: always four digits, so every handle has the same shape.
	suffix, err := randomInt(9000)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%s%s%s%d", guestHandlePrefix, adjective, noun, 1000+suffix), nil
}

func randomFrom(words []string) (string, error) {
	i, err := randomInt(int64(len(words)))
	if err != nil {
		return "", err
	}
	return words[i], nil
}

func randomInt(n int64) (int64, error) {
	v, err := rand.Int(rand.Reader, big.NewInt(n))
	if err != nil {
		return 0, fmt.Errorf("auth: generate guest handle: %w", err)
	}
	return v.Int64(), nil
}

// GuestSignup creates a read-only guest account and issues a real session for
// it (ADR-002 §3).
//
// # WHAT MAKES THIS A REAL ACCOUNT
//
// A persisted auth.users row, not a client-side or ephemeral session. That is
// the whole point: a guest who later connects LinkedIn, verifies an email or
// links Apple/Google does so against THIS SAME ROW, so nothing is recreated
// and no history is lost. Whichever verification completes first flips
// is_guest to false and the next computeTrustLevel returns 1.
//
// # NO NEW UPGRADE PATH WAS BUILT, DELIBERATELY
//
// There is no "convert guest to real account" RPC, because every existing
// verification RPC already does it: they all take the caller's user id from
// the verified JWT, write to that row, recompute the trust level and reissue
// a session. Adding a separate upgrade path would have been a second way to
// do the same thing, with its own opportunity to diverge.
//
// # AGE ATTESTATION IS NOT SPECIAL-CASED
//
// Guests pass the same mandatory 18+ check as every other signup path, using
// the same errAgeConfirmationRequired sentinel — it is an eligibility gate,
// not a trust step, and it applies uniformly (ADR-033 §1). This is checked
// before anything is written, so a rejected attempt creates no row.
func (s *service) GuestSignup(ctx context.Context, req GuestSignupRequest) (SessionResult, error) {
	if !req.AgeConfirmedOver18 {
		return SessionResult{}, errAgeConfirmationRequired
	}

	handle, err := generateGuestHandle()
	if err != nil {
		return SessionResult{}, fmt.Errorf("%w: %w", apperror.ErrInternal, err)
	}

	// TrustLevel is computed rather than written as a literal 0, for the same
	// reason every other creation path computes it: one source of truth. The
	// hypothetical row carries only IsGuest, which is precisely what makes it
	// Level 0 — if that rule ever changes, this call site follows
	// automatically instead of silently disagreeing with computeTrustLevel.
	created, err := s.users.Create(ctx, repository.NewUser{
		FullName:           handle,
		TrustLevel:         computeTrustLevel(repository.User{IsGuest: true}),
		AgeConfirmedOver18: true,
		IsGuest:            true,
	})
	if err != nil {
		return SessionResult{}, err
	}

	return s.finishSignupSession(ctx, created, true)
}
