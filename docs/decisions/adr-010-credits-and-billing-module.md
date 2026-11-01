# ADR-010: Credits, and the billing module that keeps them

## Status

**Accepted. Implemented in the working tree by plans 29A and 29B** (migrations
0025-0029, `internal/modules/billing`), not yet committed or deployed. The app
side follows in 29C. Written 2026-10-24; store purchases added 2026-10-25.

## Context

TieHere needs a way to charge for hosting that does not sell trust and does not
charge app builds already on people's phones a price they never showed. The plan (`docs/plans/29-credits-billing-analytics.md`) settles on an
app-only credit wallet: hosts spend credits to create a meetup, people get free
welcome credits when they first reach hosting level, and a subscription plan can
cover a number of creations per period.

Money paths have requirements the rest of the app does not:

- a charge must happen exactly once, whatever the client retries or races;
- every change must be explainable afterwards;
- the server, never the client, decides what anything costs;
- the module must stay liftable into its own service.

## Decision

1. **A `billing` module with its own schema.** Wallets, lots, holds, allocations,
   an append-only ledger, price rules, plans, subscriptions, plan usage, welcome
   grants, an outbox, a refund log, an admin audit and reconciliation runs, all in
   `billing.*`. No foreign key crosses into or out of the schema; user and meetup
   ids are plain UUIDs (ADR-001 §3). Own sqlc entry, own `config/`, own proto
   (`proto/billing/v1`), gRPC server in `internal/grpcapi/billing.go`.

2. **Credits are integer lots.** Every grant is a lot with its own expiry and decay
   policy. Spends draw from lots expiring first and purchased credits last, and
   record which lots they used, so a refund goes back to the lot it came from with
   its original expiry. Integers only (`BIGINT`); no floating point anywhere.

3. **Welcome credits decay by a cumulative formula.** A welcome lot is capped at
   `initial - floor(initial * percent * k / 100)` after `k` periods (default 10%
   of 60 credits every 7 days, so gone after 10 weeks). Cumulative, so rounding
   never drifts. Purchased credits never expire (App Review Guideline 3.1.1).

4. **One wallet row lock serialises a user's money.** Every write runs in one
   transaction that locks `billing.wallets` FOR UPDATE, materialises due decay and
   expiry, makes its change, appends ledger entries (each with an idempotency key
   unique per user) and updates the wallet. Lock order is always wallet, then lots,
   then holds. A trigger rejects `UPDATE` and `DELETE` on the ledger.

5. **Try-confirm-cancel for meetup creation.** The meetup module reserves (a hold:
   credits leave availability but are not spent), creates the meetup in its own
   transaction with the hold id and a `meetup.created` outbox row, and the outbox
   consumer captures the hold. A failed create releases the hold at once; a 2-hour
   TTL swept by the scheduled tick is the backstop. A capture that arrives after its
   hold lapsed spends what it can and records the rest as **debt**, which blocks
   creation until a grant pays it off. This is what a single "charge and create"
   transaction becomes once the two modules can live in separate databases.

6. **Meetup sees billing only through a port it owns.** `meetup.CreationCharger`
   (Quote, Reserve, Release) is declared in the meetup module and implemented by an
   adapter in `cmd/monolith/wiring.go`. Cancellations and closes travel the other
   way as facts (`accepted_count`, `window_start`, `ended_at`) on
   `meetup.billing_outbox`; billing owns what they mean for money (the refund
   policy).

7. **Prices, limits and policies are data.** A versioned JSON document in
   `billing.price_rules` (strictly parsed, validated, one active version) holds the
   base price, per-person price, lead-time bands, free limits, the welcome grant and
   its decay, the refund policy and the hold TTL. Pricing is a pure function with a
   property test: cost never falls as capacity or lead time rises. Every hold
   records the version it was priced under; a create quoted under an older version
   gets 409 `price_changed`.

8. **The server decides; the client only chooses.** The client sends capacity and
   start time and, on create, the cost it showed (`expected_cost`) and an
   `Idempotency-Key`. A mismatch is 409 `price_changed`; too few credits is 402
   `insufficient_credits` with `{cost, available, shortfall}`; outstanding debt is
   402 `credits_debt`. These travel from the module to the gateway as
   `apperror.CodedError` → a gRPC `ErrorInfo` detail → the HTTP status and body.

9. **Live from day one, with no flag; kind to old builds.** Hosts use and buy
   credits from the first release: creating a meetup always costs credits (or plan
   quota), and a hosting-level user's first billing call grants the welcome
   credits. Only subscription plans, which launch later, sit behind a flag
   (`billing.plans.visible`, ADR-012). An app build older than
   `MIN_CREDITS_APP_VERSION` gets 426 "Update TieHere to host a meetup." on create
   and is never charged a price it did not show. (29A first built a
   `credits.enforced` kill switch; it was removed on 2026-10-25.)

10. **Premium never sells trust.** Charging runs after the trust gate and every
    meetup rule, and can only make an allowed creation cost something. Hosting
    still needs Level 3. Joining is always free.

11. **Admin by CLI only.** `cmd/billingadmin` grants, adjusts, sets plans and flags
    against the database; every action names an operator and a reason and lands in
    the ledger or an audit table. There is no admin HTTP surface.

## Alternatives considered

- **A single balance column.** Simplest, but cannot express decaying welcome
  credits next to non-expiring purchased ones, cannot refund to the original expiry,
  and an audit of "where did these credits go" becomes guesswork. Rejected.
- **Charge inside the meetup create transaction.** Exactly-once for free, but only
  while both schemas share a database; it would make billing impossible to lift
  out. Rejected for try-confirm-cancel with an outbox.
- **Decay by a scheduled job only.** Leaves balances wrong between runs, so a spend
  could use credits that should already have decayed. Rejected: every write applies
  due decay first, and the sweep only catches up idle wallets.
- **Optimistic concurrency on a version column.** Works, but retries under load
  and is harder to reason about than one row lock per user. The `version` column
  is kept for observability.
- **Client-supplied prices validated server-side.** Invites drift and tampering;
  the server prices from what the user chose. Rejected.

## Consequences

- Every money operation is one transaction with an audit trail; a daily
  reconciliation checks that each wallet equals its lots, its open holds and its
  ledger replayed, and records any mismatch.
- Charging does not depend on a flag read, so there is no flag fail mode to
  choose: an unreadable flags table affects only whether plans are shown.
- **Deploy order:** every app build released before the credits UI (29C) gets the
  426 when it tries to host. The backend change that charges must ship with, or
  after, the 29C app release and `MIN_CREDITS_APP_VERSION` set to that build.
- An `Idempotency-Key` is bound to the request it first reserved for: a different
  request under it is 409 `idempotency_key_reused`; the same request after a
  failed create reserves afresh (29A review fix 1).
- The meetup create path gains one quote call and, when enforced, one reserve call
  before the existing transaction.
- The free advance window is 14 days without a plan (it was 90 in the app before
  credits). Plans raise it to 30.
- A deleted account's wallet is closed and its remaining purchased credits are
  recorded in `billing.admin_audit`; its welcome-grant row is kept so deleting and
  re-creating an account does not earn a second grant.
- The welcome-grant fingerprint is an HMAC of the verified phone (or personal
  email) under the work-email HMAC key with its own domain prefix; billing never
  sees the phone number or address.
- **Store purchases (29B)** go through `billing/store` (ported from the sibling's
  reviewed ADR-031 code). A purchase is granted only from the store's own
  answer, bound to the account by a UUIDv5 account token, once per store
  transaction (`billing.store_purchases` unique key), as a purchase lot that
  never expires. Without store credentials verification is 503, never a
  grant. Store webhooks are verified before they are read and applied once by
  notification id. A store refund of a pack removes what is left of its lot
  and turns what was spent into debt.
- **The catalog is data** (`billing.store_products`) and carries no prices;
  subscription plans are the one part of billing behind a flag
  (`billing.plans.visible`). A paid subscription is granted even while the
  plans are hidden from that account.
- **Plan quota resets monthly** inside any billing period, so the yearly
  product includes its 10 meetups every month.
