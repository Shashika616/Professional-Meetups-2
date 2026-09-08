# Plan — Guest login + trust-level 0–3 redesign

Implements `docs/decisions/adr-002-guest-login-and-trust-level-redesign.md`
(monolith-specific detail) and
`../../Professional-Meetups/docs/04-decisions/adr-033-guest-login-trust-level-0-3-redesign-and-read-access-blur.md`
(canonical product decision, vault-sourced). Read both before starting —
ADR-002 has the exact code shapes; this document turns that into a checklist
with tests and a verification bar. Scoped narrowly: trust-level computation,
one new signup RPC, the meetup host/join trust-gate split, visibility
redaction, and two frontend pages. Nothing else from prior phases changes.

## §A — Schema

- Migration adding `is_guest BOOLEAN NOT NULL DEFAULT false` and
  `company_name TEXT` to `auth.users` (see ADR-002 §1 for the exact DDL).
  `down` migration drops both columns.
- No backfill needed — `DEFAULT false` means every existing row is
  automatically non-guest.

## §B — Auth module

- `computeTrustLevel` rewritten per ADR-002 §2. **This changes behavior for
  existing test fixtures**: a fresh non-LinkedIn signup (Apple/Google/email)
  now computes to 1, not 0 — find every existing test asserting the old
  behavior and update it deliberately, don't just add new passing cases next
  to old wrong ones.
- New `GuestSignup` RPC per ADR-002 §3: proto message, service method, random
  guest-handle generator (small embedded adjective/noun word list — no new
  dependency), session issuance reusing the existing helper every other
  signup RPC already calls. Reject if age attestation is false, same as the
  other signup paths — find that check and mirror it exactly, don't
  reimplement it differently for this one path.
- No change to `requireLinkedIn` in `verification.go` — confirm this
  explicitly in the completion report (don't just "not touch it," show the
  diff has zero lines changed in that function).
- `GetProfile`/`ProfileResponse`: confirm `is_guest` and `company_name` are
  either exposed where the frontend needs them (e.g. to render "you're
  browsing as a guest" chrome, and to prefill the hosting-unlock page if
  `company_name` was already set once) or deliberately not exposed — state
  which, don't leave it unconsidered.

## §C — Meetup module

- `requiredTrustLevel` split into `requiredTrustLevelToJoin` /
  `requiredTrustLevelToHost` per ADR-002 §4. `CreateMeetup` calls the host
  variant, `RequestToJoin` calls the join variant. Ride-share/dating stay at
  4 for both — unaffected, still deferred (ADR-004), don't build anything new
  for those two intents as a side effect of touching this function.
- Visibility redaction (`ListOpenMeetups`/`GetMeetup`, or wherever this repo's
  equivalent of the source's `redactForViewer` lives) changed to the flat
  Level 0 vs. Level 1+ split described in ADR-002 §5. **Before changing this,
  find out whether this repo ported the source's ADR-028 redaction work at
  all** (Phase 2's completion report should say either way) — if it did,
  narrow the guest-tier field set as described (location and count stay
  visible, only host name/photo/time + participant identity null) without
  breaking the existing below-required-level behavior for other cases; if it
  didn't, this is new code, build the flat version directly and say so
  clearly in the completion report so this isn't mistaken for "narrowing
  existing behavior."
- If a host/accepted-participant exception exists (never redact a viewer's
  own meetup), confirm it's untouched by this change — add a regression test
  for it if one doesn't already exist, since ADR-002 explicitly calls out
  this as easy to accidentally break.

## §D — Frontend

- New guest entry point on the landing/onboarding flow: age-confirmation
  (existing, unchanged) → "Continue as Guest" button → `GuestSignup` →
  `AppShell` directly, skipping `ProfileSetupScreen` (a guest has no name to
  confirm yet beyond the generated handle).
- `VerificationChecklistPage` ("UNLOCK JOINING MEETUPS"): confirm it needs no
  changes (it renders from per-field state, not a fixed starting level) —
  actually launch it from a Level 0 and from a Level 1 (email-only, no
  LinkedIn) test account and confirm both render correctly, don't just assert
  it by reading the code.
- New page for the Level 2 → 3 hosting-unlock flow ("UNLOCK HOSTING
  MEETUPS", ADR-002 §6 naming suggestion `HostingUnlockPage`, not mandatory —
  pick a name consistent with this repo's existing file/class naming). Same
  checklist visual pattern as `VerificationChecklistPage`. Rows: the existing
  Level 2 items (rendered as already-done, non-interactive, since this page
  is only reachable once Level 2 is already met) plus two new interactive
  rows — Company/Organization Name (plain text input, saved via whatever RPC
  ADR-002 §3/§6 or your own judgment routes it through — a small new RPC or
  an extension of `StartCorporateEmailVerification`'s request are both fine,
  pick one and document which) and Company/Organization Email (reuses the
  existing `CorporateEmailVerificationPage`/OTP widget, not new verification
  logic).
- `IntentType`: mirror the backend's host/join split — `requiredTrustLevel`
  becomes two values or two getters, whichever fits this file's existing
  shape better; update every call site that reads the old single value
  (there were roughly half a dozen per ADR-028's own audit — check each one
  for whether it's gating a host action or a join action, they are not
  interchangeable anymore).
- Guest-tier card rendering: blurred host name/photo/time treatment on
  `_MeetupCard` (or this repo's equivalent) for `locked_for_viewer` meetups
  viewed by a Level 0 account, with location and participant count rendered
  normally; blurred participant entries on the detail page's participant
  list for the same viewer tier.

## §E — Tests

- `computeTrustLevel`: table-driven, covering guest+nothing (0), guest that
  verifies personal email only (1), non-guest fresh signup with nothing else
  set (1 — the actual behavior change from today), full Level 2 combination
  (2), Level 2 + work email but no company name (still 2, not 3 — this is the
  case most likely to be gotten wrong), full Level 3 combination (3).
- `checkTrustLevel`/gate tests split into host-side and join-side cases, with
  the new host threshold (3) for coffee/lunch/networking/mentorship.
- `GuestSignup`: rejects missing age attestation; succeeds and returns a
  valid session; the created row has `is_guest = true` and `trust_level = 0`;
  a second call produces a different generated handle (not a strict
  uniqueness test, just confirm the generator isn't returning a constant).
- Redaction: a Level 0 viewer's response has host/time nulled and
  location/count populated; a Level 1 viewer's response is fully populated;
  existing below-Level-2 (now: not applicable to visibility, only to the
  join/host gate) and host/participant-exception tests still pass unchanged
  or are deliberately updated with a stated reason.
- Frontend: widget test for the new guest button reaching `AppShell`; widget
  test for the new hosting-unlock page's two new rows gating its `Complete`
  button correctly.

## When done

For each of §A–§E, cite the actual file:line changed, not just "done." In
particular:

- Show the full diff of `computeTrustLevel` and confirm which existing tests
  changed value (not just which new tests were added).
- Show `requireLinkedIn` in `verification.go` is byte-for-byte unchanged.
- State explicitly whether ADR-028-style redaction existed in this repo
  before this change, and which of the two paths in §C's redaction bullet was
  actually taken.
- State which mechanism (new RPC vs. extended existing RPC) was used to save
  `company_name`, and why.
- Confirm `flutter analyze`, `dart format --set-exit-if-changed`, and
  `flutter test` all pass, and the Go side's `build`/`vet`/`golangci-lint`/
  `go test ./...` all pass — same bar every prior phase was held to.
