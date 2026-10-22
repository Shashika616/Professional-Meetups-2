# ADR-009: Email is the identity anchor, and a returning person claims their account

## Status

**Implemented in the working tree (migrations 0017 and 0018, `auth/accountclaim.go`),
not yet committed or deployed.** Written 2026-10-08 from a read of that code, because
the code already cites "ADR-009" for this decision and no such document existed in
this repo. See "Numbering note" at the end.

## Context

Until now a person who signed up with Google in March and came back through Apple in
October (or through LinkedIn, or email) was a stranger to the system: each provider
resolved by its own `(provider, subject)` pair, so they got a second, empty account
with none of their meetups, ratings or trust level, and no way to tell why.

Three facts made this worse than a cosmetic bug:

- `auth.users.personal_email` was unique **case-sensitively**, so `Ada@Gmail.com` and
  `ada@gmail.com` were two accounts and two logins.
- LinkedIn's userinfo response includes an email and the `email` scope was always
  requested, but the backend discarded it at decode. LinkedIn was the one provider
  that could not recognise a returning member by address.
- Apple and Google were storing the provider's email on `auth.user_identities` as
  display-only, never as an account key.

## Decision

1. **A verified email address is what says "this is the same person".**
   `auth.users.personal_email` is the account's single identity anchor, written from
   the provider's token at signup. The uniqueness rule is
   `UNIQUE (lower(personal_email)) WHERE personal_email IS NOT NULL` (migration 0017).
   Lookups use `lower()` on both sides so they use that index and cannot miss a
   mixed-case row.

2. **Only a provider-verified address may become an anchor.** Apple, Google and
   LinkedIn tokens are read for `email_verified`; the address is returned to callers
   only when it is true. The claim is decoded by `FlexibleBool`, which accepts a JSON
   boolean or the strings `"true"`/`"false"` (Apple has historically sent the string)
   and decodes anything else, including a missing claim, to **false**. Failing closed
   costs a user an email prompt; failing open would let anyone who can type a string
   into a provider profile claim someone else's account.

3. **One normalisation function.** `identity.NormalizeEmail` trims and lowercases,
   nothing more. Gmail dot-and-plus aliasing is deliberately **not** collapsed,
   because that rule belongs to Gmail alone.

4. **When a federated signup presents an address that already has an account, the
   signup pauses and the person claims the account.** The server returns
   `409 account_claim_required` with a signed ticket, mails a code to the address,
   and on a correct code attaches the new provider to the existing account and
   issues a session for it. They keep meetups, ratings, trust level and LinkedIn
   connection.

   - **Ticket.** `base64url(JSON{email, provider, subject, expiry}) "." hex(HMAC-SHA256)`,
     keyed with the existing work-email HMAC key under the domain prefix
     `account-claim-ticket.v1|`. Nothing in it is secret (the client's own id_token
     supplied every field), so only integrity matters and no table is needed.
     Expiry equals the OTP's. Verification is constant-time, signature first, then
     expiry; every failure returns one message.
   - **Single use** comes from the code row, which is deleted on first successful
     verify, not from the ticket.
   - **Own OTP purpose** `account_claim` (migration 0018), target-keyed by address,
     so a code minted for one ceremony cannot be spent on another.
   - **Code is checked before the account is looked up**, so a wrong guess costs the
     same whether or not the ticket points at a real account.
   - **What the 409 reveals:** that an account exists for the caller's own verified
     address, and that address echoed back. Nothing about the account (no name, photo,
     provider or date).
   - **LinkedIn is never overwritten.** If the claimed account already has a
     different `linkedin_sub`, the claim still succeeds (mailbox proof was real) but
     the LinkedIn link is left untouched and a WARN is logged. If the
     `(provider, subject)` is already linked to another account, the identity stays
     unattached, again logged, never merged.

5. **The unique index is the backstop, the pre-check is the usability layer.** Two
   signups for the same address can both pass the pre-check; the second `INSERT`
   fails on `idx_users_personal_email_lower` and the repository maps that to a
   conflict naming the email. The pre-check exists to make the common case a flow
   instead of an error.

## Consequences

### Deployment (order matters)

- Apply **0017 and 0018 before deploying the code**, over the session connection on
  port 5432 (the pooler on 6543 breaks golang-migrate's advisory lock; see the runbook).
  The code writes `account_claim` rows and queries `lower(personal_email)`.
- 0017 builds the new index **before** dropping the old one, so a collision aborts the
  migration with the old guarantee intact. Production was checked on 2026-10-07 and
  had zero case-insensitive collisions. It does **not** rewrite existing rows to
  lowercase; the `lower()` on both sides of the lookup is what makes legacy
  mixed-case rows safe.
- 0018 uses `ALTER TYPE ... ADD VALUE` inside golang-migrate's transaction. That is
  allowed from Postgres 12; local is 16 and Supabase is 15.
- **Rollback:** 0017's down restores the case-sensitive index. 0018's down is a
  deliberate no-op (Postgres cannot drop an enum value; an unused one is inert).
  Rolling the code back stops minting claims, which is all a rollback needs.
- The generated code (`auth.pb.go`, sqlc output) is committed, and the new
  `generated-code` CI job fails if it is stale, so run `buf generate` and
  `sqlc generate` before pushing.

### Things this decision changes that are easy to miss

- **`personal_email` now serves two purposes.** It is the identity anchor **and** an
  input to `computeTrustLevel` (Level 2 requires `PersonalEmail != ""`). A federated
  signup now writes it at creation, so that input is satisfied by the provider's
  verification instead of the app's own OTP. See Open question 1.
- **LinkedIn now yields an email** where it previously yielded none. This is new
  personal data stored on `auth.users` for LinkedIn signups; the vault's
  *Data Collection & Legal Basis* inventory has been updated to say so.
- **Test fixtures.** `account_claim` is **not** in `isEmailOTPPurpose`, so
  `TEST_OTP_BYPASS_EMAILS` does not accept `123456` for it. The send-site skip is
  purpose-agnostic, though, so an allowlisted `.test` address gets **no email** and
  can only complete a claim with the real code, which is in the WARN log line. See
  `TESTING-NOTES.md`.

### Residual risks (accepted or open)

- **The OTP attempt cap is check-then-act** (security review V-1). The claim code
  inherits that, since it goes through the same target-keyed verify. Exposure is
  lower than for email login because the attacker needs a valid ticket, which needs a
  provider-verified token for that address. Fix V-1 and this closes with it.
- **Email recycling.** If a mailbox is reassigned (a company address, a lapsed
  domain), the new holder passes both the provider's verification and the claim code
  and gets the old account. This is inherent to treating email as identity and is the
  same exposure `email_login` already has. Not mitigated here.
- **Claim routes have no per-target limit.** `/v1/auth/account-claim` and
  `/v1/auth/account-claim/resend` fall under the generic IP+path limiter only (their
  bodies carry a ticket, not an address, so the body-keyed limiter cannot see a
  target). The 60-second per-target resend cooldown in the shared sender is the
  effective bound. This inherits security review V-3 (the limiter's IP key behind
  Cloud Run).
- **One key, two uses.** The ticket signature reuses the work-email HMAC key. The
  `account-claim-ticket.v1|` prefix separates the domains, and a work-email input
  always contains `@` while a ticket body never does, so they cannot collide. Revisit
  if a third use of the key is ever added.
- **Authenticated LinkedIn linking is still unguarded** (security review V-14).
  `LinkIdentityToUser` writes `linkedin_sub` unconditionally. The claim path guards
  against overwrite; the signed-in "connect LinkedIn" path does not.

## Open questions for Shashika

1. **DECIDED 2026-10-08 by Shashika: yes, a provider-verified email counts as the personal email.** No separate `personal_email_verified` flag. (Original question follows.) **Should a provider-verified email count toward Level 2's "personal email"
   requirement?** Today it does, silently, because `computeTrustLevel` only tests
   that the column is non-empty. The alternative is a separate
   `personal_email_verified` flag so the in-app OTP step still gates Level 2. Level 2
   still needs LinkedIn, a phone and a legal name, so the impact is one skipped step,
   but it is a trust-model change nobody has recorded as a decision.
2. **Should `account_claim` be added to the test-email bypass?** Adding it to
   `isEmailOTPPurpose` lets test users claim with `123456`. Leaving it out keeps the
   claim ceremony closer to production behaviour. Either is defensible; the notes now
   say which is current.

## Numbering note

Code comments elsewhere in this repo cite "ADR-009" for **JWT rotation-as-theft-detection
and mobile token storage** (`session_storage.dart`, `auth_service.dart`,
`repository.go`, `auth.proto`). That is the **sibling microservices repo's** ADR-009
(*JWT Auth Strategy*), not this document. This repo's ADR-009 is the one above, because
`identity.go` already cites it for the identity anchor. When touching either set of
comments, say which repo's ADR is meant.
