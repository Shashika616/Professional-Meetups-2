package auth

import (
	"testing"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
)

func TestComputeTrustLevel(t *testing.T) {
	const sub = "linkedin-sub-123"

	tests := []struct {
		name string
		user repository.User
		want int
	}{
		// ADR-014: Level 0 is a real, reachable outcome now — a federated
		// (Apple/Google) account with no LinkedIn linked, regardless of
		// what else is set. This is the load-bearing regression case: even
		// every Level 2 field being set must NOT be enough without
		// LinkedIn, since ADR-014 §4 makes LinkedIn a hard prerequisite for
		// Level 2+, not just one signal among several.
		{"brand new federated account, nothing else set", repository.User{}, 0},
		{
			"every level-2 field and work email set, but no LinkedIn linked",
			repository.User{
				PhoneNumber:       "+94771234567",
				PersonalEmail:     "a@example.com",
				LegalName:         "Ada Lovelace",
				Address:           "1 Main St, Colombo",
				WorkEmailVerified: true,
			},
			0,
		},
		{
			"linking LinkedIn to an otherwise-bare account reaches level 1, not higher",
			repository.User{LinkedInSub: sub},
			1,
		},
		{"only phone set", repository.User{LinkedInSub: sub, PhoneNumber: "+94771234567"}, 1},
		{
			"2 of 3 level-2 fields set, no partial credit",
			repository.User{
				LinkedInSub:   sub,
				PhoneNumber:   "+94771234567",
				PersonalEmail: "a@example.com",
				// LegalName deliberately unset.
			},
			1,
		},
		{
			// ADR-023 §1: address is no longer part of the Level 2 bundle —
			// reaching Level 2 must not depend on it being set.
			"all 3 level-2 fields set, address empty, work email not verified",
			repository.User{
				LinkedInSub:   sub,
				PhoneNumber:   "+94771234567",
				PersonalEmail: "a@example.com",
				LegalName:     "Ada Lovelace",
				// Address deliberately unset — must still reach 2.
			},
			2,
		},
		{
			"all 3 level-2 fields set, address also set, work email not verified",
			repository.User{
				LinkedInSub:   sub,
				PhoneNumber:   "+94771234567",
				PersonalEmail: "a@example.com",
				LegalName:     "Ada Lovelace",
				Address:       "1 Main St, Colombo",
			},
			2,
		},
		{
			// The load-bearing case the addendum calls out explicitly: work
			// email verified alone, with every Level 2 field unset, must
			// NOT compute to 3.
			"work email verified but no level-2 fields set at all",
			repository.User{LinkedInSub: sub, WorkEmailVerified: true},
			1,
		},
		{
			"work email verified but only 2 of 3 level-2 fields set",
			repository.User{
				LinkedInSub:       sub,
				PhoneNumber:       "+94771234567",
				PersonalEmail:     "a@example.com",
				WorkEmailVerified: true,
				// LegalName deliberately unset — must not reach 3.
			},
			1,
		},
		{
			// ADR-023 §1: address empty must not block Level 3 either —
			// only the 3-field bundle plus work email matter now.
			"all 3 level-2 fields plus work email verified, address empty",
			repository.User{
				LinkedInSub:       sub,
				PhoneNumber:       "+94771234567",
				PersonalEmail:     "a@example.com",
				LegalName:         "Ada Lovelace",
				WorkEmailVerified: true,
			},
			3,
		},
		{
			"all 3 level-2 fields plus work email verified, address also set",
			repository.User{
				LinkedInSub:       sub,
				PhoneNumber:       "+94771234567",
				PersonalEmail:     "a@example.com",
				LegalName:         "Ada Lovelace",
				Address:           "1 Main St, Colombo",
				WorkEmailVerified: true,
			},
			3,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := computeTrustLevel(tt.user); got != tt.want {
				t.Errorf("computeTrustLevel(%+v) = %d, want %d", tt.user, got, tt.want)
			}
		})
	}
}
