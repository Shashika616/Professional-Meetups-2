package auth

import (
	"testing"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
)

// TestComputeTrustLevel is the whole ladder, table-driven.
//
// # FOUR CASES IN THIS TABLE CHANGED VALUE IN ADR-002
//
// They are marked "CHANGED (ADR-002)" inline, with the old value stated, so
// the diff is legible without the git history. They were edited in place
// rather than left alongside new cases — a table asserting both 0 and 1 for
// a fresh federated signup would be self-contradicting, and the passing half
// would hide the contradiction.
//
//  1. fresh federated account, nothing set:        0 -> 1
//  2. every Level 2 field but no LinkedIn:         0 -> 1
//  3. Level 2 + work email, address empty:         3 -> 2
//  4. Level 2 + work email, address set:           3 -> 2
//
// (1) and (2) move because the old "no LinkedIn -> 0" floor is gone: the only
// thing that produces 0 now is is_guest. (3) and (4) move because Level 3
// gained the company-name requirement — a verified work email alone no longer
// reaches it.
func TestComputeTrustLevel(t *testing.T) {
	const sub = "linkedin-sub-123"

	// level2Fields is the full Level 2 bundle, spelled once. Cases that need
	// it start from a copy so a future change to what Level 2 means is a
	// one-line edit here rather than a search across the table.
	level2Fields := func() repository.User {
		return repository.User{
			LinkedInSub:   sub,
			PhoneNumber:   "+94771234567",
			PersonalEmail: "a@example.com",
			LegalName:     "Ada Lovelace",
		}
	}
	withWorkEmailAndCompany := func(u repository.User) repository.User {
		u.WorkEmailVerified = true
		u.CompanyName = "Acme Corporation"
		return u
	}

	tests := []struct {
		name string
		user repository.User
		want int
	}{
		// --- Level 0: guests, and only guests -----------------------------
		{
			// The ONLY shape that produces 0 after ADR-002.
			"guest with nothing set",
			repository.User{IsGuest: true},
			0,
		},
		{
			// A guest who somehow had a display name is still a guest —
			// full_name is populated for every guest by GuestSignup and says
			// nothing about verification.
			"guest with a generated handle is still level 0",
			repository.User{IsGuest: true, FullName: "Guest-CleverOtter4821"},
			0,
		},
		{
			// The upgrade path (ADR-002 §3): the guest flag flips on the
			// first real verification, and the SAME row is now Level 1.
			// Personal email is the cheapest of the four to reach.
			"guest that completes personal-email verification becomes level 1",
			repository.User{IsGuest: false, PersonalEmail: "a@example.com"},
			1,
		},

		// --- Level 1: any real signup path, equally -----------------------
		{
			// CHANGED (ADR-002): was 0. THE headline behaviour change — a
			// fresh Apple/Google/email signup is worth Level 1 immediately,
			// with nothing else done.
			"brand new federated account, nothing else set",
			repository.User{},
			1,
		},
		{
			// CHANGED (ADR-002): was 0. LinkedIn is still required for
			// Level 2 (ADR-033 §3 preserves the LinkedIn-first premise), so
			// this cannot reach 2 — but it is not a guest, so it floors at 1
			// rather than 0. This is the case that proves removing the old
			// LinkedIn guard did not accidentally grant Level 2 without
			// LinkedIn.
			"every level-2 field and work email set, but no LinkedIn linked",
			repository.User{
				PhoneNumber:       "+94771234567",
				PersonalEmail:     "a@example.com",
				LegalName:         "Ada Lovelace",
				Address:           "1 Main St, Colombo",
				WorkEmailVerified: true,
				CompanyName:       "Acme Corporation",
			},
			1,
		},
		{
			"linking LinkedIn to an otherwise-bare account is still level 1",
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

		// --- Level 2: unchanged in substance ------------------------------
		{
			// ADR-023 §1: address is not part of the bundle.
			"all level-2 fields set, address empty, work email not verified",
			level2Fields(),
			2,
		},
		{
			"all level-2 fields set, address also set, work email not verified",
			func() repository.User { u := level2Fields(); u.Address = "1 Main St, Colombo"; return u }(),
			2,
		},

		// --- Level 3: now needs BOTH work email and company name ----------
		{
			// CHANGED (ADR-002): was 3. THE case §E flags as most likely to
			// be skipped, and the one that would silently let people host
			// without registering a company.
			"level 2 + verified work email but NO company name is still 2",
			func() repository.User { u := level2Fields(); u.WorkEmailVerified = true; return u }(),
			2,
		},
		{
			// The mirror image: a company name with no verified work email
			// is equally insufficient. Unreachable in practice (both are
			// written by the same statement) but asserted so the condition
			// cannot be relaxed to an OR by accident.
			"level 2 + company name but NO verified work email is still 2",
			func() repository.User { u := level2Fields(); u.CompanyName = "Acme Corporation"; return u }(),
			2,
		},
		{
			"level 2 + verified work email + company name reaches 3",
			withWorkEmailAndCompany(level2Fields()),
			3,
		},
		{
			"level 3 with address also set",
			func() repository.User {
				u := withWorkEmailAndCompany(level2Fields())
				u.Address = "1 Main St, Colombo"
				return u
			}(),
			3,
		},
		{
			// Level 3 requires Level 2 to still hold in full — a verified
			// work email plus a company name, with the Level 2 bundle
			// incomplete, does not skip the ladder.
			"work email + company name but no level-2 fields at all",
			repository.User{LinkedInSub: sub, WorkEmailVerified: true, CompanyName: "Acme Corporation"},
			1,
		},
		{
			"work email + company name but only 2 of 3 level-2 fields",
			repository.User{
				LinkedInSub:       sub,
				PhoneNumber:       "+94771234567",
				PersonalEmail:     "a@example.com",
				WorkEmailVerified: true,
				CompanyName:       "Acme Corporation",
				// LegalName deliberately unset.
			},
			1,
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

// TestComputeTrustLevel_GuestFlagIsTheOnlyThingSeparating0From1 states the
// central invariant of ADR-002 §2 directly, rather than leaving it implicit
// across table rows: for an otherwise-identical user, is_guest is the entire
// difference between 0 and 1.
func TestComputeTrustLevel_GuestFlagIsTheOnlyThingSeparating0From1(t *testing.T) {
	guest := repository.User{IsGuest: true}
	real := repository.User{IsGuest: false}

	if got := computeTrustLevel(guest); got != 0 {
		t.Errorf("guest computed to %d, want 0", got)
	}
	if got := computeTrustLevel(real); got != 1 {
		t.Errorf("non-guest with nothing set computed to %d, want 1", got)
	}
}

// TestComputeTrustLevel_GuestCannotClimbWithoutLosingTheFlag guards the
// upgrade path from the other direction: while is_guest is still true, no
// amount of other data should produce Level 1 through the guest branch.
//
// Reaching Level 2/3 while still flagged a guest IS possible in this pure
// function, and deliberately so — those branches are evaluated before the
// guest check, so a row that genuinely satisfies Level 2 is Level 2 whatever
// the flag says. That state is unreachable in practice (every verification
// that fills those fields clears the flag), and having the higher branches
// win is the safe direction: it cannot under-grant someone who has done the
// work.
func TestComputeTrustLevel_GuestCannotClimbWithoutLosingTheFlag(t *testing.T) {
	// Partial progress, flag still set: stays at 0, not 1.
	partial := repository.User{IsGuest: true, PhoneNumber: "+94771234567", LinkedInSub: "linkedin-sub-123"}
	if got := computeTrustLevel(partial); got != 0 {
		t.Errorf("a still-flagged guest with partial progress computed to %d, want 0 — only clearing is_guest reaches level 1", got)
	}
}
