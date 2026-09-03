# Additive prompt — paste into the currently-running Phase 1 session

New requirements were added to this repo's docs after you started — read
them now and fold them into what you're building/have built, rather than
treating them as a future cleanup pass:

1. `docs/plans/00-overview.md`'s new **"Quality bar"** section — applies to
   this phase in full.
2. `docs/security-review-framework.md` (new file) — walk all six properties
   against the auth module before you call this phase done.
3. `docs/plans/01-phase1-scaffold-gateway-auth.md`'s new **"Security fix
   required in this phase"** section, and the matching updates to
   `docs/plans/phase1-claude-code-prompt.md`'s ground rules and "When done"
   list.

Concretely, on top of whatever you've already built or are mid-building:

- **Fix the Apple/Google `id_token` nonce-replay gap as part of this phase**,
  not later. The source (`../Professional-Meetups/backend`) never checks a
  `nonce` claim on Apple/Google `id_token` verification — a real replay
  exposure. Add a client-generated `nonce` to the federated-signup/link
  request shape and check it server-side against the token's own `nonce`
  claim in `internal/identity`'s verifier, the same way LinkedIn's
  `state`-based CSRF check already works in this codebase. Write a test that
  proves a mismatched/missing nonce is rejected.
- **No client-side-only validation** — every validation rule in the auth
  module (phone format, OTP expiry/attempts, corporate-email free-provider
  rejection, trusted-contacts cap of 3, SOS message length cap, etc.) must
  be enforced server-side regardless of what the copied `frontend/` already
  checks. If you ported a rule by inferring it from a field name instead of
  reading the source's actual validator/service code, go back and confirm
  it against the real logic.
- **No vulnerabilities**: every SQL query parameterized (no exceptions);
  every authorization/identity decision sourced only from the gateway's
  verified caller context, never a client-supplied field; secrets and
  tokens never appear in log output; rate limits match the inventory
  exactly (same routes, same numbers, same key shape).
- **Algorithms/data structures**: no unbounded queries, no accidental O(n²)
  or N+1 where the source used a single query/batch call, pagination capped
  the same way the source caps it.
- **Real tests, actually run** — not just written. Add adversarial/negative
  cases if they're missing: wrong-user access attempts, an expired or
  algorithm-confused JWT, the nonce-mismatch case above, oversized input,
  rate-limit boundary behavior. Run `go build ./...` / `go vet ./...` /
  `go test ./...` for real and report the actual output.
- **Design review**: confirm what you built still matches ADR-001 — no
  cross-schema foreign keys, no outbox/relay/circuit-breaker machinery
  reintroduced, no module reaching into another module's repository
  directly, `eventbus.Bus.Publish` calls in the same transaction as their
  business write.

When you report back, structure it per `docs/plans/phase1-claude-code-
prompt.md`'s "When done" list (now updated) — completeness checklist against
the inventory, the six-property security walk, confirmation of the nonce fix
and its test, and anything you're leaving as an explicit known gap.
