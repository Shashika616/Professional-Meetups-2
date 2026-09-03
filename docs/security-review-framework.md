# Security Review Framework

Ported from `../../Professional-Meetups/docs/03-architecture/security-review-framework.md`
(the sibling repo's own framework, introduced there 2026-08-19) — same
structure, same six properties, reused here because it's already
proven against this exact product's business logic, not reinvented.
Organized by security *property* (Confidentiality, Integrity, Availability,
Authenticity, Non-repudiation, Authorization/accountability), not by attack
scenario — every non-trivial phase of this build must walk this checklist
explicitly before being reported "done," not just get an unstructured bug
hunt.

## How to use this in this repo

For each phase (auth, meetup, billing, notification), walk all six
properties against the module just built and write the findings into that
phase's own completion report — "confirmed clean" is a valid finding, silence
is not. Two properties need special attention here specifically because this
port is a rewrite, not a copy: **anything the source code got wrong stays
wrong unless this port deliberately fixes it** — porting business logic
faithfully (per every phase plan's own instruction) does not mean porting
its bugs faithfully. The two known, currently-unfixed findings from the
sibling repo's own last review pass are reproduced below so they're not
silently carried forward.

## Confidentiality — only authorized parties see the data

What this means concretely here: raw verification material stays scoped to
the person it verifies, ratings stay anonymous to the ratee, secrets never
leave the layer they belong to (JWT private key: gateway only, per ADR-001
§6; work-email HMAC key: auth module only).

Known-good patterns to preserve from the source (port these rules, not just
the fields): raw work-email address never persisted past the verification
round-trip; phone/personal email never returned in full over an API
response to anyone but the profile's own owner; ratings anonymous to the
ratee, aggregate-only; LinkedIn/Apple/Google tokens verified then discarded,
never persisted; no password hash anywhere (passwordless-only auth) — this
should be structurally true (no such field exists in the auth module's
response types at all), not just "the code happens not to send it."

## Integrity — data can't be modified in unauthorized or undetected ways

Known-good patterns to preserve: trust level computed server-side only,
never client-supplied, in any request; refresh-token rotation detects reuse
of an already-rotated token; DB `CHECK`/`UNIQUE` constraints enforce
invariants (self-rating blocked, one-rating-per-pair, capacity caps) rather
than relying on application logic alone; rating aggregates recomputed via
`AVG()`/`COUNT()` in-transaction, not incrementally updated (avoids drift);
every JWT signature verified before any claim in it is trusted.

## Availability — the system keeps working, including under partial failure

Known-good patterns to preserve: every external HTTP call (LinkedIn, FCM,
JWKS, Resend/Twilio) needs an explicit timeout — the zero-value `http.Client`
has none, and one hung dependency must not exhaust request-handling
goroutines. **Different from the source here**: the source's gateway rate
limiter fails open on a Redis error, because Redis was an external
dependency that could itself go down independently of the request. This
repo's in-memory limiter has no such external-dependency failure mode
(ADR-001 §5) — there's no "fails open" case to preserve, every check
either succeeds or correctly 429s.

## Authenticity — an entity really is who/what it claims to be

Known-good patterns to preserve: RS256 pinned on every third-party token
verification (`WithValidMethods`, blocks `alg=none`/HS256-confusion
forgery); issuer + audience checked, not just signature; LinkedIn's OAuth
callback protected by `state`-based CSRF.

**Known, currently-unfixed gap in the source — fix it during this port,
don't carry it forward**: Apple/Google `id_token` verification checks
signature, issuer, audience, and expiry, but never checks a `nonce` claim.
Without one, a valid `id_token` intercepted within its short validity window
could in principle be replayed to authenticate as that user. There's already
a working precedent for exactly this shape of protection in the same
codebase (LinkedIn's `state`-based CSRF check) — generate a nonce
client-side per sign-in attempt, thread it through `getAppleIDCredential`/
Google's authenticate call, verify it server-side against the token's
`nonce` claim. This is auth-module scope, so it belongs in **Phase 1**, not
a later phase — see `docs/plans/01-phase1-scaffold-gateway-auth.md`.

## Non-repudiation — a party can't credibly deny having done something

Known-good pattern: every security-relevant state change carries its own
timestamp, attributable to a specific `user_id`, durable in Postgres
(checklist-ack/check-in timestamps, feedback submission time, refresh-token
rotation's `replaced_by` chain). No dedicated tamper-evident audit log
exists for admin/moderation actions in the source either — acceptable to
leave as an explicitly-named gap here too, since there's no admin surface
built anywhere yet for it to cover; don't build one speculatively.

## Authorization & accountability

Distinct from authenticity — not "who are you" but "are you allowed to do
*this specific thing*." Known-good patterns to preserve: trust-level gating
never trusts a client-supplied level, only the verified-JWT-derived value;
every module method takes the caller's identity from the gateway's verified
context, never from the request body; cross-account identity-linking
collisions hard-reject rather than silently merge.

**Known, currently-unfixed gap in the source — fix it during the port, don't
carry it forward**: none of `GetSafetyState`, `AcknowledgeSafetyChecklist`,
`SetLiveLocationOptIn`, or `CheckIn` check that the caller is actually a
participant (host or accepted requester) of the given meetup before reading
or mutating its safety state — any authenticated user can act on *any*
meetup's safety state just by knowing or guessing its ID. Compounded by a
schema gap: the source's `meetup_safety_state` is one shared row per
*meetup*, not per participant (unlike `meetup_feedback`, which correctly
keys on `(meetup_id, user_id)`). This is **meetup-module scope — fix it as
part of Phase 2**, not carried over from the source schema as-is; add the
same `IsParticipant`-style guard the ratings code already uses to all four
methods, and make the per-participant-vs-host-only intent an explicit design
decision in Phase 2's own plan, not left ambiguous.

## Also apply, every phase, regardless of the property checklist above

- **No client-side-only validation, anywhere.** The frontend's own
  validators (kept, unmodified, for instant UI feedback) are never the
  source of truth — every module method re-validates every rule
  server-side, exactly as if the frontend didn't exist. If a phase plan or
  prompt doesn't explicitly restate a validation rule, that's not
  permission to skip it — go read the source's actual validation code.
- **Every SQL query is parameterized.** No string-built SQL, ever, even for
  values that "can't" contain injection-shaped input (rate-limit keys, log
  messages, etc. included).
- **Secrets are never logged** — request bodies, tokens, and codes get
  redacted or omitted from log lines, not just "shouldn't come up in
  practice."
- **Rate limits, once ported, must match the inventory exactly** (same
  routes, same numbers, same key shape) — a silently-looser or
  silently-tighter limit is itself a finding to report, not something to
  fix unilaterally without saying so.

## Related

`docs/decisions/adr-001-modular-monolith-architecture.md` ·
`../../Professional-Meetups/docs/03-architecture/threat-model.md` (source
repo, scenario-based, complements this property-based checklist).
