# ADR-002 — Guest Login and Trust-Level 0–3 Redesign

**Status**: Accepted
**Date**: 2026-09-05
**Context**: implements, in this repo only, the product decision recorded in
`../../Professional-Meetups/docs/04-decisions/adr-033-guest-login-trust-level-0-3-redesign-and-read-access-blur.md`
(vault: `04 - Decisions/ADR-033 - Guest Login, Trust-Level 0-3 Redesign, and
Read-Access Blur.md`). ADR-033 is the canonical product/domain decision — this
ADR only records the monolith-specific implementation choices needed to build
it (exact schema, RPC shape, code locations). The source microservices backend
(`../../Professional-Meetups/backend`) is **not** touched by this change — its
`services/auth` and `services/meetup` stay on the pre-ADR-033 trust ladder
until/unless a parity pass ports this over.

## Why

Requested directly by Shashika, ahead of Phase 3 (billing): let a visitor use
the app with zero signup friction (a Reddit-style guest account), and raise
the bar for *hosting* a meetup above what's required to *join* one. See
ADR-033 for the full product reasoning; this document is implementation-only.

## Decisions

### 1. Schema: two new columns on `auth.users`

```sql
ALTER TABLE auth.users
    ADD COLUMN is_guest BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN company_name TEXT;
```

No other column changes. `phone_number`, `personal_email`, `legal_name`,
`linkedin_sub` are already nullable (migration `0001_auth_schema.up.sql`);
`full_name` stays `NOT NULL` and is populated with the generated guest handle
at guest-signup time — no separate "guest display name" column.

### 2. `computeTrustLevel` rewrite (`internal/modules/auth/trustlevel.go`)

Current code (pre-ADR-002):

```go
func computeTrustLevel(u repository.User) int {
	if u.LinkedInSub == "" {
		return 0
	}
	level2 := u.PhoneNumber != "" && u.PersonalEmail != "" && u.LegalName != ""
	switch {
	case level2 && u.WorkEmailVerified:
		return 3
	case level2:
		return 2
	default:
		return 1
	}
}
```

New:

```go
func computeTrustLevel(u repository.User) int {
	level2 := u.LinkedInSub != "" && u.PhoneNumber != "" && u.PersonalEmail != "" && u.LegalName != ""
	level3 := level2 && u.WorkEmailVerified && u.CompanyName != ""
	switch {
	case level3:
		return 3
	case level2:
		return 2
	case !u.IsGuest:
		return 1
	default:
		return 0
	}
}
```

The old "no LinkedIn → 0" floor is gone. `is_guest` is the only thing that
separates Level 0 from Level 1 now — any account created through any of the
four real signup paths (`CompleteFederatedSignup`, `CompleteEmailSignup`,
`CompleteLinkedInOnboarding`) has `is_guest = false` from the moment it's
created, landing it at Level 1 immediately with no further action. Level 2's
condition is unchanged from today's code (LinkedIn + phone + personal email +
legal name, ADR-023's definition) — only the branch it falls into when *not*
met has changed, from a LinkedIn-gated 0/1 split to the `is_guest` split
above. Level 3 gains `u.CompanyName != ""` alongside the existing
`WorkEmailVerified` check.

**No change** to `requireLinkedIn` in `verification.go` — phone, personal
email (the Level-2-ingredient verification, as distinct from the personal
email used as an account-creation OTP method, see § 3), and personal-details
verification stay gated behind LinkedIn being connected first, exactly as
today. This is deliberate (Shashika's explicit instruction): LinkedIn-first
for the Level 1→2 climb is unchanged by this ADR.

### 3. New `GuestSignup` RPC

Added to `proto/auth/v1/auth.proto` and the auth service, alongside the
existing `CompleteFederatedSignup`/`CompleteEmailSignup`/
`CompleteLinkedInOnboarding` trio:

```protobuf
rpc GuestSignup(GuestSignupRequest) returns (SessionResponse);

message GuestSignupRequest {
  bool age_confirmed_over_18 = 1; // same mandatory attestation every other path already requires
}
```

Server-side: reject if `age_confirmed_over_18` is false (mirror whatever the
other signup RPCs already do for this field — don't special-case guest).
Otherwise: generate a random display name (`Guest-<Adjective><Noun><4 digits>`,
e.g. `Guest-CleverOtter4821` — a small embedded word list is enough, no
external dependency; collisions are cosmetic only, no uniqueness constraint
needed), insert a new `auth.users` row with `is_guest = true`,
`full_name = <generated>`, everything else left at its column default (NULL/
false), `trust_level` computed as 0 via § 2. Issue a real access+refresh token
pair through the same session-issuance path every other signup RPC already
uses — `SessionResponse` shape is unchanged.

**Upgrade path, not a separate flow**: a guest later completing
`CompleteLinkedInOnboarding`/`LinkIdentity`, `StartPersonalEmailVerification`+
`VerifyPersonalEmailCode`, or linking Apple/Google, does so against this same
`auth.users` row (`user_id` sourced from the guest's own bearer token, same as
every other authenticated verification call) — whichever completes first sets
`is_guest = false` and `computeTrustLevel` returns 1 on the next JWT refresh.
No new RPC needed for the upgrade itself; existing verification RPCs already
write to the same row and already trigger a trust-level recompute + JWT
reissue (ADR-012's existing pattern).

### 4. Meetup trust gate split (`internal/modules/meetup/trustgate.go`)

Current:

```go
func requiredTrustLevel(intent Intent) int {
	switch intent {
	case IntentRideShare, IntentDating:
		return 4
	default:
		return 2
	}
}
```

New — two functions, `CreateMeetup` and `RequestToJoin` each call the correct
one instead of both sharing `requiredTrustLevel`:

```go
func requiredTrustLevelToJoin(intent Intent) int {
	switch intent {
	case IntentRideShare, IntentDating:
		return 4
	default:
		return 2 // unchanged
	}
}

func requiredTrustLevelToHost(intent Intent) int {
	switch intent {
	case IntentRideShare, IntentDating:
		return 4
	default:
		return 3 // raised from 2
	}
}
```

`checkTrustLevel` takes the already-resolved required level (unchanged
signature shape, just fed a different number depending on caller). Mirror the
same split in the frontend's `frontend/lib/core/models/intent_type.dart` —
`requiredTrustLevel` becomes `requiredTrustLevelToHost` /
`requiredTrustLevelToJoin` there too, same values. This is the same
mirrored-constant discipline ADR-013 already established; keep both sides in
sync in the same commit.

### 5. Visibility redaction (`ListOpenMeetups` / `GetMeetup`, wherever
`redactForViewer` lives in this repo's meetup module)

Per ADR-033 § 6: redaction becomes two independent checks, not one. Visibility
(this section) keys off a **flat `viewer_trust_level >= 1` check**, completely
independent of § 4's per-intent host/join numbers. Below that flat line
(i.e. `viewer_trust_level == 0`, guest only):

- Redact (null): `host_full_name`, `host_profile_photo_url`, formatted time
  window.
- Do **not** redact: location label, `accepted_count`/capacity. (If this
  repo's redaction already nulls location for the below-required-level case —
  check against whatever this repo actually ported from the source's ADR-028
  work before assuming — narrow that specifically for the guest tier per this
  ADR; Level 1+ callers must see location unconditionally.)
- `GetMeetup`'s participant list: same treatment per-entry (name/photo
  nulled), count stays whatever the card already showed.
- Preserve any existing host/accepted-participant exception (never redact a
  viewer's own meetup) — if this repo has ported that logic, it must still
  apply on top of the above, unchanged.
- Level 1 and above: full, unredacted — no behavior change from whatever this
  repo's "unlocked" rendering already does today.

If this repo's meetup module does not yet have `ListOpenMeetups`/`GetMeetup`
redaction at all (i.e. ADR-028's work was never ported from source into the
monolith), build the flat Level 0 vs. Level 1+ version described above
directly — there's no pre-existing behavior to preserve in that case, only
Shashika's confirmation needed that no such redaction exists yet before
skipping the "preserve existing exception" step.

### 6. Frontend

- New guest entry point on the landing/onboarding screen: age-confirmation
  (existing step, unchanged) → "Continue as Guest" → `GuestSignup` → straight
  into `AppShell`, no `ProfileSetupScreen` detour (a guest has no personal
  details to review yet).
- Reuse `VerificationChecklistPage` ("UNLOCK JOINING MEETUPS") as-is for the
  Level 0/1 → 2 flow — its scope (LinkedIn + phone + personal email + personal
  details) is unchanged by this ADR. No changes needed to this page's logic;
  it already works from any starting point since it renders per-field
  completion state, not a fixed starting level.
- New page (name suggestion: `HostingUnlockPage`, AppBar "UNLOCK HOSTING
  MEETUPS") for the Level 2 → 3 flow, shown when a sub-Level-3 user attempts to
  host: same checklist visual pattern as `VerificationChecklistPage`, showing
  Level 2's four rows (already satisfied, shown as done) plus two new rows —
  Company/Organization Name (plain text field, no verification needed, just
  saved) and Company/Organization Email (reuses the existing
  `CorporateEmailVerificationPage`/OTP flow unchanged). `Complete` enabled once
  both new rows are done.

## Consequences

- Every existing account in any local/dev database has `is_guest = false` by
  the column's `DEFAULT false` — no backfill needed, no existing account
  becomes a guest retroactively.
- `computeTrustLevel`'s tests need new cases: guest with nothing set → 0;
  guest that completes personal-email verification only → 1; non-guest with
  nothing else set (fresh Apple/Google/email/LinkedIn signup) → 1 (this is the
  main behavior change from today, where a fresh non-LinkedIn signup landed at
  0) — this discipline matters, check both old test cases these values, don't
  just add new ones.
- `checkTrustLevel`'s existing tests need splitting into host-side and
  join-side cases, with the new host-side values (3, not 2) for
  coffee/lunch/networking/mentorship.
- No change to `WorkEmailVerified`'s existing OTP mechanism, Firebase/FCM
  wiring, the outbox/durable-notification work from `03-hardening-pass.md`, or
  anything else from prior phases — this is scoped narrowly to trust-level
  computation, the meetup trust gate, and the two frontend pages above.

## Related

`docs/decisions/adr-001-modular-monolith-architecture.md` (this repo) ·
`../../Professional-Meetups/docs/04-decisions/adr-033-guest-login-trust-level-0-3-redesign-and-read-access-blur.md`
(canonical product decision) · that same repo's ADR-006, ADR-013, ADR-014,
ADR-023, ADR-028 (prior trust-level/visibility decisions ADR-033 builds on)
