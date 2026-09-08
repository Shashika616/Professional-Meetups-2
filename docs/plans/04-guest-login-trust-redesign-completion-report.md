# Completion report — guest login + trust-level 0–3 redesign

All five sections (§A–§E) of `docs/plans/04-guest-login-trust-redesign.md`
are done, implementing `docs/decisions/adr-002-guest-login-and-trust-level-redesign.md`
(canonical product decision: the sibling repo's ADR-033).

Nothing outside §A–§D was touched: no billing, no notification outbox, no
change to any prior phase's behaviour beyond what the trust-ladder redefinition
necessarily implies.

## Verification

```
BACKEND
$ go build ./...                     PASS
$ go vet ./...                       PASS
$ golangci-lint run ./...            0 issues.        (v2.12.2)
$ go test ./...                      0 failures
$ go test -race ./...                0 failures
                                     714 test cases, 0 failures, 0 skips

FRONTEND
$ flutter analyze                    No issues found!
$ dart format --set-exit-if-changed  exit 0
$ flutter test                       322 tests, All tests passed!
```

Migration `0004` applied and rolled back against a scratch database:

```
4/u guest_and_company_name (452ms)
4/d guest_and_company_name  (21ms)
0 of the two columns remain after down
```

And live, through the running stack (`docker compose up --build`):

```
POST /v1/auth/guest/signup {"age_confirmed_over_18":true}
  → full_name: Guest-GoldenBeaver9057
  → JWT claims: {"trust_level":0, ...}
GET /v1/users/me            → trust_level 0, is_guest true, linkedin_connected false
POST /v1/auth/guest/signup {"age_confirmed_over_18":false}
  → HTTP 400 "you must confirm you are 18 or older to create an account"
POST /v1/auth/email/signup  → trust_level 1   (was 0 before this change)
GET /v1/users/me            → is_guest false, linkedin_connected FALSE
                              ^ Level 1 without LinkedIn — the state ADR-002 creates
```

---

## §A — Schema

`backend/migrations/0004_guest_and_company_name.up.sql` /
`.down.sql`. Exactly ADR-002 §1's DDL, as two `ALTER TABLE`s.

- `is_guest BOOLEAN NOT NULL DEFAULT false` — NOT NULL rather than nullable
  because a NULL would be a third state ("might be a guest") with no meaning,
  and every read feeds a trust-level decision that has to be unambiguous.
- `company_name TEXT` — nullable, no default; absent genuinely means "not
  provided yet", which is what Level 3 tests for.

No backfill: the `DEFAULT false` makes every pre-existing row non-guest, which
is correct — no account created before this was ever a guest.

The down migration notes, in the file, that dropping `is_guest` silently
converts every guest into a Level 1 account on the next recompute. That is the
only possible reversal, but it is a real change in data meaning rather than a
clean undo, so it is stated rather than left to be discovered.

---

## §B — Auth module

### `computeTrustLevel` — the full diff

`backend/internal/modules/auth/trustlevel.go:66-81`. Before:

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

After:

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

One subtlety worth naming, because getting it wrong would have been a silent
security regression: **the LinkedIn term had to MOVE INTO `level2`, not just
disappear.** The old code tested LinkedIn in the early-return guard, so
`level2` did not need to repeat it. Deleting the guard without moving that term
would have granted Level 2 to an account with no LinkedIn at all — exactly what
ADR-033 §3 says must not happen. There is a dedicated test case for it
("every level-2 field and work email set, but no LinkedIn linked" → 1).

### Existing test VALUES that changed (not just tests added)

Nine assertions across six tests. Every one was edited in place with a
`CHANGED (ADR-002 …)` comment stating the old value — none were left standing
next to a new contradicting case.

| File:line | Was | Now | Why |
|---|---|---|---|
| `trustlevel_test.go` "brand new federated account" | 0 | **1** | The headline change: any real signup path is Level 1 |
| `trustlevel_test.go` "every level-2 field, no LinkedIn" | 0 | **1** | Still cannot reach 2 (LinkedIn required), but not a guest, so floors at 1 |
| `trustlevel_test.go` "level 2 + work email, address empty" | 3 | **2** | Level 3 now also needs `company_name` |
| `trustlevel_test.go` "level 2 + work email, address set" | 3 | **2** | Same |
| `identity_resolution_test.go:30` (Apple) | 0 | **1** | "Apple alone never grants trust" is no longer true |
| `identity_resolution_test.go:245` (email) | 0 | **1** | Same for email-OTP |
| `service_test.go:146` federated signup | 0 | **1** | Same |
| `service_test.go:175` `Create` call arg | 0 | **1** | Asserted on the Create call, so the value written at creation is right |
| `service_test.go:487` email signup | 0 | **1** | Same |
| `auth/integration_test.go:339` email signup (real Postgres) | 0 | **1** | Same, end to end |
| `verification_test.go:683` Profile field-count guard | 15 | **18** | Three new fields, added to the allowlist deliberately |

That last one is a guard test that exists to catch an *accidental* field on
`Profile` (above all a raw work email, ADR-003). It did its job by failing when
`IsGuest`, `CompanyName` and `LinkedInConnected` arrived; all three were then
added to the allowlist explicitly rather than the count being bumped.

### `GuestSignup`

- Proto: `GuestSignupRequest` + `rpc GuestSignup` (`proto/auth/v1/auth.proto`).
- Service: `internal/modules/auth/guest.go`.
- gRPC: `internal/grpcapi/auth.go`.
- Gateway: `POST /v1/auth/guest/signup` (`handlers.go:89`).

The handle generator is 34 adjectives × 32 nouns × 9000 numbers (~9.8M
combinations), embedded, no new dependency. Collisions are cosmetic and there is
no uniqueness constraint, per ADR-002 §3.

The age check **mirrors the existing paths exactly** — same
`errAgeConfirmationRequired` sentinel — and runs before any write, so a rejected
attempt creates no row (asserted).

Rate limiting: the route is covered by the existing blanket per-(IP, path)
limit. No per-route limit was added, deliberately — matching the rate-limit
inventory exactly is a standing rule from the hardening pass, so widening it is
a decision to take rather than a side effect. It is noted in the handler that
this is the only endpoint in the system that creates an account with no
verification step, in case that call wants revisiting.

### `requireLinkedIn` — zero-diff proof

Unchanged, byte for byte. I hashed lines 30–50 (the function plus its doc
comment) **before making any edit**, and again at the end:

```
before: ad739b1cef594c81275eb242bb3c5356ab585fd35cd209f44ab9066d929eec03
after:  ad739b1cef594c81275eb242bb3c5356ab585fd35cd209f44ab9066d929eec03
```

It is also still at the same line (`verification.go:37`), and
`git diff -U0` on that file produces hunks only at lines 255+ and 302+ —
none within 30–50.

### `GetProfile` / `ProfileResponse` — exposed, deliberately

`is_guest` and `company_name` are both exposed, plus a third field
(`linkedin_connected`) explained below.

- `is_guest` — so the client can render guest chrome and route a guest to
  signup rather than the Level 2 checklist. Exposed rather than inferred from
  `trust_level == 0`: those coincide today but answer different questions, and
  this ladder has now been redefined once already.
- `company_name` — so the hosting-unlock page can show what was recorded, the
  same reason `company_domain` was already there.

### The `company_name` save mechanism: extended existing RPC, no new one

**`VerifyCorporateEmailCode` persists it**, in the same statement as
`work_email_verified` (`queries/users.sql`, `UpdateUserWorkEmailVerified`).

That RPC has *always* required, validated and length-capped `company_name` —
it feeds the known-companies name-vs-domain cross-check (ADR-019 §3). It simply
had nowhere to store it. The whole chain (Flutter → gateway → gRPC → service)
already carried the field.

Chosen over a new RPC for one reason that outweighs the convenience: **Level 3
requires both the verified email and the name, and writing them in one
statement makes it impossible for the row to hold one without the other.** A
separate save would have created a reachable state (name saved, email not, or
vice versa) that the Level 3 condition explicitly forbids, and a window in
which the two could disagree.

---

## §C — Meetup module

### The gate split

`internal/modules/meetup/trustgate.go` — `requiredTrustLevelToJoin` (unchanged
values) and `requiredTrustLevelToHost` (3 for the four ordinary intents, 4 for
ride-share/dating). `CreateMeetup` calls the host variant (`service.go:192`),
`RequestToJoin` the join variant (`requests.go:20`).

`checkTrustLevel` now takes the resolved level plus an `action` string, so a
rejection says *which* bar was missed — a Level 2 user who can already join
coffee meetups needs to know it was the hosting bar, not a mysteriously moved
one.

Two named functions rather than one function with a bool: `checkTrustLevel(intent, level, true)`
reads as nothing at a call site, and there are exactly two call sites.

Ride-share/dating are untouched at 4 for both actions, and nothing new was
built for them.

Added `TestHostBarIsNeverBelowJoinBar` (and its Dart mirror) as a property over
every intent: if hosting were ever easier than joining, someone could create a
meetup they could not themselves join.

### Redaction: this repo DID have ADR-028-style redaction — this NARROWED it

**Stating this explicitly, as §C asks: the redaction existed.** It was ported in
Phase 2 and lived at `internal/modules/meetup/convert.go:79`, keyed off
`viewerTrustLevel >= requiredTrustLevel(intent)`, nulling host name, host photo,
both coordinates, the label and the window. Levels 0 and 1 were indistinguishable.

So this is the **narrowing** path of §C's two options, not the build-fresh one.
Two independent narrowings:

1. **Who**: the trigger is now a flat `viewerTrustLevel >= 1`
   (`visibilityFloor`), independent of the intent's join/host numbers. A Level 1
   user sees every meetup in full, including ones they cannot join.
2. **What**: location (label and coordinates) and accepted-count/capacity now
   stay **visible** to guests. This is the one place the change is a
   *loosening*, and it is the product point — a guest is meant to see that real
   meetups are happening near them.

`LockedForViewer` still gets set for the guest tier.

**The host/accepted-participant exception is untouched.** It lives at
`GetMeetup`'s call site (`service.go:310-318`), not inside `redactForViewer`,
and was not modified. Its comment was updated to record that it is now *moot for
guests specifically* — a Level 0 account can never satisfy `IsParticipant` — but
still load-bearing for Level 2/3 users if a bar is raised under an existing
meetup, which is exactly what this change just did to hosting. It has an
explicit regression test.

### The participant-list redaction in ADR-002 §5 has no applicable surface here

ADR-002 §5 asks for per-entry name/photo nulling on `GetMeetup`'s participant
list. **This repo has no such list.** `GetMeetup` returns a single `Meetup`;
the only participant-listing RPC is `ListMeetupRequests`, which is **host-only**
(`service.go:441` rejects a non-host with `ErrForbidden`). A guest can never
reach it. Nothing was built for this rather than inventing a redaction path for
a list guests cannot see.

### Redaction tests: values changed, one test replaced outright

`TestRedactForViewer_UsesTheSameFloorAsTheTrustGate` asserted the *opposite* of
ADR-002 — that redaction used the same floor as the join gate. It was replaced
by `TestRedactForViewer_IsIndependentOfTheJoinAndHostGates`, which asserts the
decoupling. Keeping both would have meant a suite that contradicts itself with
the passing half hiding it.

Also changed: `TestListOpenMeetups_RedactsForUnderTrustViewer` (viewer 2 → 0;
the location assertions **inverted** rather than deleted, so the "location
survives" rule stays covered end to end) and
`TestGetMeetup_RedactionAndParticipantException` (stranger 2 → 0, plus a new
assertion that a Level 2 stranger now sees a dating meetup in full).

New: `TestListOpenMeetups_GuestTierRedaction` covers both tiers against real
SQL.

---

## §D — Frontend

- **Guest entry point**: `onboarding_flow.dart` — `Continue as Guest` on the
  chooseMethod step (so it is after age confirmation), going **straight to
  AppShell**, bypassing `_goToAppShell`'s `ProfileSetupScreen` detour. A guest
  has no name to confirm; theirs was generated a moment ago.
- **`IntentType`**: `requiredTrustLevelToJoin` / `requiredTrustLevelToHost`,
  and `isUnlockedFor` became `canJoin` / `canHost` — named for the action,
  because after this change a call site that does not say which action it means
  is probably wrong.
- **All 14 call sites reclassified** (9 `requiredTrustLevel` + 5
  `isUnlockedFor`). Join-side: `intent_slider`, `intent_picker_sheet`,
  `intent_grid`, `meetup_detail_page`, `matches_page` (×3),
  `home_page`'s `onFindMatches`. Host-side: `home_page`'s `onHostMeetup`,
  `schedule_flow` (×3). The home intent selector is join-side deliberately —
  gating *selection* at the host bar would stop a Level 2 user selecting an
  intent to browse.
- **`HostingUnlockPage`** (`features/verification/hosting_unlock_page.dart`),
  "UNLOCK HOSTING MEETUPS", same checklist pattern as
  `VerificationChecklistPage`. Level 2's items appear only as a signpost when
  genuinely unmet (linking to the existing page rather than duplicating its
  rows); the two new rows both open the existing
  `CorporateEmailVerificationPage`, because that page already collects the name
  *and* the address and the backend writes them together. COMPLETE requires
  both, plus Level 2.
- **Guest card treatment**: `LockedCardHeader` keeps the shimmer for the host
  name, but now renders the **real location label** (a guest receives it) and
  says "Sign up to see who's hosting" instead of "Verify to see details" — a
  guest has not failed to verify, and the old copy pointed at a checklist they
  cannot start.
- **`LocationViewPage.open`'s trust gate was REMOVED.** It blocked any
  `lockedForViewer` meetup behind a toast and the checklist, which was right
  when redaction nulled the location. Guests now receive it, so blocking would
  be a client-side-only gate on data the server deliberately sends — the exact
  pattern ADR-028 rejected as cosmetic and bypassable.

### `VerificationChecklistPage` needs no changes — but a signal it depends on did

The page's own logic is unchanged, as §D predicted. **What was broken is what it
reads.**

`UserProfile.linkedInConnected` was `trustLevel >= 1`. That was sound under the
old ladder, where Level 1 was reachable only via LinkedIn. ADR-002 §2 makes
every real signup path Level 1, so the expression now returns `true` for an
Apple/Google/email account that has never connected LinkedIn. The page would
have shown its LinkedIn row as done and unlocked the phone/personal-email/
personal-details rows beneath it — **every one of which the server then rejects**
(`requireLinkedIn`, unchanged). A user would have been shown a checklist telling
them to do things that immediately 403.

Fixed by adding a real `linkedin_connected` boolean to `ProfileResponse`
(derived server-side from `LinkedInSub != ""`, never the raw sub) and reading
that. Verified as §D asks — by running it, not by inspection:

- **Level 0**: the existing test already covered it; still passes.
- **Level 1 email-only (no LinkedIn)**: new test, the state ADR-002 creates.
  **Control run** — reverting the getter to `trustLevel >= 1` fails it with
  *"a Level 1 account with no LinkedIn was treated as already connected — the
  page would unlock rows the server rejects"*, and it passes again on restore.

Also confirmed live: `GET /v1/users/me` after an email signup returns
`trust_level: 1, linkedin_connected: false`.

---

## §E — Tests

- **`computeTrustLevel`**: 16-case table covering every case §E lists,
  including *"Level 2 + verified work email but NO company name is still 2"*
  (§E flags this as most likely to be skipped) and its mirror image (company
  name with no verified email). Plus two invariant tests.
- **Gate tests**: split into `TestCheckTrustLevel_JoinSide` /
  `_HostSide`, with the host values at 3, and a test that the rejection names
  the action.
- **`GuestSignup`**: 7 tests — read-only account created, age attestation
  rejected *before any write*, handles are not constant, handle shape, and both
  upgrade paths.
- **Redaction**: 4 unit tests + 2 integration tests covering both viewer tiers,
  plus the untouched participant exception.
- **Frontend**: 3 guest-entry-point tests (with a control run proving the
  "skips profile setup" assertion catches a regression), 10 `HostingUnlockPage`
  tests, and the Level-1-email-only checklist regression test.

---

## Two things I found that the plan did not anticipate

Both are reported rather than silently worked around.

### 1. Nothing cleared `is_guest` — ADR-002 §3's upgrade promise was unwired

ADR-002 §3 says a guest who completes any verification has `is_guest` flipped to
false "on the same `auth.users` row", with **no new RPC needed** because the
existing verification RPCs already write there.

They write there, but none of them cleared the flag. Without this a guest who
connects LinkedIn stays `is_guest = true`, `computeTrustLevel` keeps returning
0, and they are stranded at Level 0 permanently with nothing to indicate why.

Fixed in two places:
- **In SQL**, for every UPDATE that records a real verification (phone,
  personal email, personal details, LinkedIn sub, work email). Putting it in the
  query rather than at the call sites means one of them cannot forget it.
- **A dedicated `ClearGuestFlag`** for the Apple/Google link path, which writes
  only `user_identities` and so has no `users` UPDATE to ride along with. That
  path previously wrote nothing to `auth.users` at all, on the explicit ground
  that "linking Apple/Google never raises trust level (ADR-014 §1)" — a comment
  that ADR-033 §2 makes false.

### 2. The `hypothetical` pattern silently disagreed with the new SQL

The trust level written by each verification is computed in Go from a
"hypothetical" copy of the row. Since those statements now also clear
`is_guest`, every hypothetical had to reflect that — otherwise the statement
clears the flag while storing a trust level computed as though it had not.

This was not theoretical: the LinkedIn-link path did exactly that on the first
attempt, and `TestGuestSignup_UpgradeViaLinkedInClearsTheFlag` caught it
(`stored TrustLevel = 0, want 1`). Rather than patch each site, the
transformation is now a named helper, `afterVerification(u)`, used at all seven
sites — so the requirement is visible at each one instead of depending on
everyone remembering an invisible rule. The same class of bug applied to
`CompanyName` in `VerifyCorporateEmailCode` and is fixed the same way.

## One consequential change worth flagging for review

Removing `LocationViewPage`'s trust gate (§D above) is the only place this slice
makes something *more* visible than before, and it follows from ADR-002 §5's
decision to keep location visible to guests rather than from an independent
judgement of mine. If the intent was that guests see a location *label on a card*
but not a *map with directions*, that is a one-line change and the ADR should
say so — but as written, §5 says the location label and coordinates are not
redacted, and the server now sends both.

## Design review against ADR-001

- **No cross-schema foreign keys** — migration 0004 adds none.
- **No module reaches into another's SQL** — the meetup module still never
  reads `auth.users`; the only cross-schema read remains the backfill operator
  tools from the hardening pass.
- **Every SQL query parameterized** — the two new statements and the five
  amended ones are all sqlc-generated.
- **Every authorization decision from the verified caller context** — the trust
  gate reads the JWT's `trust_level` claim, threaded by the gateway;
  `GuestSignup` takes no identity input at all, and the display handle is
  generated server-side so a caller cannot choose it.
- **Nothing logged that should not be** — the new `linkedin_connected` is a
  derived boolean, never the raw sub; no new logging was added.

## Next

Phase 3 (billing) resumes as originally planned. Nothing in this slice touched
the billing surface.
