package auth

import "professional-meetups-monolith/backend/internal/modules/auth/repository"

// computeTrustLevel is the one place trust-level rules live (backend/PLAN.md's
// Level 2/3 addendum, Step H) — same "single mapping table" discipline
// shared/apperror already uses. Called after every mutation that changes a
// verification field, before the row is persisted or a fresh
// SessionResponse/JWT is issued.
//
// # THE LADDER (ADR-002, implementing the sibling repo's ADR-033)
//
//	0 — guest. An account created by GuestSignup: no email, no phone, no
//	    LinkedIn, a generated display name. Read-only, and its READ access is
//	    further reduced by the meetup module's redaction (ADR-002 §5).
//	1 — any real signup path, equally and immediately. Apple, Google,
//	    email-OTP and LinkedIn all land here on first successful completion,
//	    with nothing else required.
//	2 — LinkedIn + phone + personal email + legal name. Unlocks JOINING.
//	3 — Level 2 + verified work email + company name. Unlocks HOSTING.
//
// # WHAT CHANGED IN ADR-002, AND WHAT DID NOT
//
// The old code opened with a hard `if u.LinkedInSub == "" { return 0 }`
// floor, which meant a fresh Apple/Google/email signup computed to 0 —
// indistinguishable from someone who had done nothing at all. ADR-033 §2
// deliberately overrides that: having completed ANY of the four real signup
// paths is now worth Level 1, and `is_guest` is the only thing that
// separates 0 from 1.
//
// Level 2's condition is UNCHANGED in substance (ADR-023's definition:
// LinkedIn + phone + personal email + legal name, address excluded). It only
// looks different here because the LinkedIn term moved INTO it — the old code
// tested LinkedIn in the early-return guard above, so `level2` did not need to
// repeat it. Removing the guard without moving that term would have silently
// granted Level 2 to an account with no LinkedIn at all, which is the exact
// regression ADR-033 §3 says must not happen (the LinkedIn-first premise is
// preserved, at Shashika's explicit instruction).
//
// Level 3 gains `CompanyName != ""` alongside the existing WorkEmailVerified
// check (ADR-033 §4) — a verified work email alone is no longer enough. Both
// are written in the same statement (UpdateUserWorkEmailVerified), so a row
// cannot hold one without the other.
//
// There is deliberately no partial credit within a level: Level 2 is the
// bundle, not four independent gates. A user who verified only a corporate
// email while skipping phone/personal-email/legal-name computes to 1, not 3.
//
// requireLinkedIn (verification.go) is a separate, UNCHANGED enforcement
// point: phone/personal-email/personal-details verification still refuse to
// start until LinkedIn is connected. This function is the passive backstop,
// not the only guard.
func computeTrustLevel(u repository.User) int {
	level2 := u.LinkedInSub != "" && u.PhoneNumber != "" && u.PersonalEmail != "" && u.LegalName != ""
	level3 := level2 && u.WorkEmailVerified && u.CompanyName != ""

	switch {
	case level3:
		return 3
	case level2:
		return 2
	case !u.IsGuest:
		// Any of the four real signup paths. Reached by every account that
		// is not a guest and has not yet completed the Level 2 bundle.
		return 1
	default:
		return 0
	}
}

// afterVerification returns u as it will look once a verification-recording
// UPDATE has run: identical, except that is_guest is false.
//
// # WHY THIS EXISTS RATHER THAN A LINE AT EACH CALL SITE
//
// Every one of those statements sets `is_guest = false` in SQL (ADR-002 §3,
// see queries/users.sql). The trust level they write is computed in Go from a
// "hypothetical" copy of the row beforehand, so that copy has to reflect
// EVERY change the statement makes — including this one. Miss it and the
// statement clears the flag while storing a trust_level computed as though it
// had not, stranding a freshly-upgraded guest at Level 0 until some unrelated
// write happens to recompute it.
//
// That is not hypothetical: it is exactly what the LinkedIn-link path did on
// the first attempt at this change, and the test caught it. Naming the
// transformation makes the requirement visible at each site instead of
// depending on everyone remembering an invisible one.
func afterVerification(u repository.User) repository.User {
	u.IsGuest = false
	return u
}
