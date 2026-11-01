# ADR-012: Remote config and feature flags

## Status

**Accepted. Implemented in the working tree by plan 29A** (migration 0025,
`internal/platform/flags`, `internal/platform/clientinfo`, `GET /v1/app-config`),
not yet committed or deployed. Written 2026-10-24.

## Context

Billing has to be switchable without a deploy (a kill switch for charging), hidden
features have to be testable in production by the seeded test accounts, and the
app has to change behaviour — show plans, show the credit store — without a new
build going through review. Old builds stay on people's phones for months, so the
server also has to know which build it is talking to.

## Decision

1. **Flags live in `ops.feature_flags`** (`key`, `enabled`, ordered `rules`,
   optional JSON `value`, `updated_at`, `updated_by`) with every change written to
   `ops.feature_flag_audit` with the operator and reason. Schema `ops` because the
   flags belong to no single module and are served by the ops service.
2. **Evaluation is a pure function** (`flags.Evaluate`): rules run in order and the
   first match decides; a flag no rule matches is `enabled`. Rule types: user-id
   allowlist, email-domain allowlist (for the `@meetups.test` fixtures), minimum app
   version, and percentage rollout by `sha256(key, user_id) % 100`. A rule may carry
   `"result": false` to exclude. Table-tested without a database.
3. **Cached in-process for 30 seconds**, one query for the whole table. A failed
   reload keeps serving the previous copy; an unknown or invalid flag is off. The
   caller's email is looked up (through auth) only when a rule needs it, and a failed
   lookup fails closed.
4. **The app's build travels with every request.** The app sends `X-App-Version` and
   `X-Platform`; gateway middleware reads them into the context, the monolith
   client's interceptor forwards them as gRPC metadata, and the monolith's server
   interceptor puts them back (`clientinfo.From(ctx)`). Values are sanitised and
   never trusted for access — a client lying about its version only gets the newer
   behaviour it claims to support.
5. **`GET /v1/app-config`**, signed in or out, returns every flag evaluated for the
   caller, the flags' values, `min_supported_app_version` and the billing catalog
   version.
6. **Changes only through `cmd/billingadmin flags set`.** No HTTP surface can change
   a flag.

Flags this plan seeds: `billing.plans.visible` (off, on for the seeded test
accounts by user id and by the `meetups.test` domain), `analytics.enabled` (on),
`analytics.sample_rate` (value 100). Credits have no flag: they are live from day
one, and only subscription plans, which launch later, are switched (decided
2026-10-25; `credits.enforced` and `billing.credit_packs.visible` were dropped).

## Alternatives considered

- **Firebase Remote Config.** Free and mature, but a second source of truth the
  server cannot evaluate for its own decisions (a flag the monolith acts on must
  be read consistently with what the app is told). Rejected.
- **Environment variables.** Need a deploy to change, and cannot target users.
  Kept only for settings that should need a deploy (`MIN_CREDITS_APP_VERSION`).
- **A dedicated flag service (Unleash, LaunchDarkly).** More capability than five
  flags need, and either a cost or another thing to host. Rejected for now; the
  evaluator's rule shapes are close enough to swap later.

## Consequences

- A flag change takes up to 30 seconds to reach every instance.
- Apple asks that apps contain no hidden features (Guideline 2.3.1): the review notes
  must describe the server flags, and App Review's test account must be on the
  `billing.plans.visible` allowlist (plan 29 §6).
