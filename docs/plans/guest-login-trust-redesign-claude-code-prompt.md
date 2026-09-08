# Claude Code prompt — guest login + trust-level 0–3 redesign

You're working in `/Users/as/Documents/Professional Meetups/Professional-Meetups-Monolith`.
Phases 1–2 and the hardening pass (§A–F) are built and independently
verified. This is a new, narrowly-scoped feature slice, requested directly by
Shashika, ahead of Phase 3 (billing) — it does not touch billing, the
notification/outbox work, or anything else already built.

## Read first, in this order

1. `docs/decisions/adr-002-guest-login-and-trust-level-redesign.md` in
   full — the exact code shapes (schema DDL, `computeTrustLevel` before/after,
   the new RPC, the trust-gate split, the redaction change, the two frontend
   pages). This is the real spec.
2. `docs/plans/04-guest-login-trust-redesign.md` — turns ADR-002 into a
   checklist with the tests and evidence required when done.
3. `../Professional-Meetups/docs/04-decisions/adr-033-guest-login-trust-level-0-3-redesign-and-read-access-blur.md`
   — the canonical product decision ADR-002 implements. Read this if anything
   in ADR-002 seems under-motivated; don't guess at intent, it's explained
   here.

## What this covers (§A–E of the plan doc)

- **§A — schema**: two new nullable/defaulted columns on `auth.users`
  (`is_guest`, `company_name`). No backfill needed.
- **§B — auth module**: `computeTrustLevel` rewritten so Level 0 is guest-only
  and any of the four real signup paths lands at Level 1 immediately (this
  changes existing test expectations — update them deliberately, don't leave
  stale assertions next to new ones); a new `GuestSignup` RPC issuing a real
  session for a randomly-named, no-email/phone/LinkedIn account;
  `requireLinkedIn` in `verification.go` stays **completely unchanged** —
  confirm this with a zero-diff statement in your completion report.
- **§C — meetup module**: `requiredTrustLevel` splits into
  `requiredTrustLevelToJoin` (unchanged values) and `requiredTrustLevelToHost`
  (raised to 3 for coffee/lunch/networking/mentorship, still 4 for
  ride-share/dating); visibility redaction becomes a flat Level 0 vs. Level 1+
  split, independent of the host/join numbers — first determine whether this
  repo already has ADR-028-style redaction ported from the source app, and
  say so explicitly either way before deciding whether you're narrowing
  existing behavior or building it fresh.
- **§D — frontend**: a "Continue as Guest" entry point on landing/onboarding;
  confirm (by actually running it against a Level 0 and a Level 1 test
  account, not by inspection alone) that the existing `VerificationChecklistPage`
  needs no changes; build a new hosting-unlock page (Level 2 → 3) reusing the
  existing corporate-email OTP widget, adding a plain company-name field;
  update every call site that read the old single `requiredTrustLevel` to use
  the correct host/join variant.
- **§E — tests**: table-driven `computeTrustLevel` cases (see plan doc for
  the exact case list — the "Level 2 + work email but no company name is
  still 2, not 3" case is the one most likely to get skipped); split
  host/join gate tests; `GuestSignup` tests; redaction tests for both viewer
  tiers; two new frontend widget tests.

## Bar for "done"

Same as every prior phase: cite file:line for each claim, don't just assert
"done." Specifically call out, per the plan doc's "When done" section: the
full `computeTrustLevel` diff and which existing test *values* changed (not
just which tests were added), proof `requireLinkedIn` has zero changes, which
of the two redaction starting points applied, which mechanism was used to
save `company_name`, and a clean `flutter analyze` +
`dart format --set-exit-if-changed` + `flutter test` + Go
`build`/`vet`/`golangci-lint`/`go test ./...`.

Do not touch billing, the notification outbox, or any file outside what
§A–D above actually requires.
