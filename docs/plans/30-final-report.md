# Plan 30 final report

Status: **all five phases are complete in the working tree** (2026-11-04). All gates pass. Nothing is pushed or deployed. Commits exist only for the 30A step on `plan-28-29`, as the plan required, so **everything from 30A onward is uncommitted**.

## What changed

- **30A, deploy:** manifest generated in CI, migration 0019 cleans up after itself, cron budgets, image pinning and scanning, deploy gated on CI.
- **30B, security:** OTP budgets, shared rate limits, work-email rules, location limits and retention, join and accept window checks, outbox leases, JWKS refetch.
- **30C, SOS:** contacts are a name and a number with no confirmation step (ADR-013), up to 2, with reactive SOS texts.
- **30D, photos:** users own their photo: one JPEG in Postgres, signed-in access, no outside addresses.
- **30E:** anonymous host reviews, seven client fixes, the file splits, docs.

Details are in `30A` to `30E-completion-report.md`.

## Migrations, in deploy order

All through **0037**, in one `migrate up` (runbook §3a).

| Migration | Note |
|---|---|
| 0017 | Pre-flight in §3a |
| 0019 | Cleans up first; pre-flight in §3a |
| 0033-0035 | Additive |
| **0036** | **Destructive.** Deletes contact emails, email-only contacts, duplicate numbers and pending invitations. The down migration restores columns, not data. Take a backup. SOS fails until the new revision serves, so run it in a quiet hour |
| 0037 | Additive |

## Final review, read-only

Checked against the OWASP API Security Top 10 and MASVS across everything Plan 30 changed.

| Area | Finding |
|---|---|
| API1 object authorisation | Photo `GET` needs sign-in and Level 1 for someone else. Profiles keep the existing gate. Reviews expose no author to any viewer |
| API2 authentication | OTP budgets hold across instances. Only the sign-in, signup and refresh routes are open |
| API3 property exposure | The gateway test pins a review to exactly three keys |
| API4 resources | Upload, photo fetch, share, contact and SOS limits. Bombs refused before decoding |
| API7 SSRF | The LinkedIn fetch allows https and `.licdn.com` only, redirects included, with size and time caps |
| API8 configuration | Query strings stay out of spans. Inbound trace baggage is dropped. No SQL built with `Sprintf` |
| API10 third parties | Nominatim responses capped, throttled and cached |
| MASVS storage | Tokens in secure storage. Backups off. Preferences hold no secrets |
| MASVS network | The token goes only to our own `/v1/` paths. No arbitrary-load exception on iOS |
| MASVS privacy | Rounded location, explanation screen, install id rotation, opt-out stops sending |

No High or Medium finding remains open. A scan of the diff found no secrets. In `backend/secrets`, only `.gitkeep` and `README.md` are tracked.

**Open items, all Low:**

| # | Item |
|---|---|
| 122 | SOS sends without a claim if only the claim write fails |
| 123 | Route-pattern IP limit is tight behind a carrier NAT |
| 124 | Parked: no analytics archive for now |
| 125 | Sinhala and Tamil names read "A TieHere member" in texts |
| 126 | Two racing SOS retries after zero notified could double-send |
| 129 | A host with very few guests can guess a review's author |
| 130 | Photos can show initials while the access token is expired |
| 131 | The iOS update link is a store search until the app is listed |
| 132 | A redelivered purchase of a withdrawn plan stays pending |

## Steps only you can do

1. **Decide on commits and push.** Say the word and the rest can be committed and pushed; the branch has no off-disk copy until then.
2. **On or after 2026-11-10:** upgrade `golang.org/x/net` to v0.62.0 (S-8).
3. **Before deploying:** run the §3a pre-flights and take a backup for 0036.
4. **Create** the secrets and environment values in §3a step 3.
5. **Set `ANALYTICS_REPORT_RECIPIENTS`,** or the daily report goes nowhere.
6. **After deploying:** run `backfill-photos`, then `backfill-user-display-cache` (§3a step 5a). Until then LinkedIn users show initials.
7. **Update the privacy policy wording.** The vault note lists what changed; it still needs legal review.
8. **Test what needs real accounts:** sandbox purchases and the iOS build.
9. **Tell testers:** joining needs Home to have reported a location in the last 24 hours, and builds from before Plan 30 show initials for everyone.
