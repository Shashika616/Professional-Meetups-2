# Claude Code prompt 30B: security and location fixes (backend)

Read first: `docs/plans/30-review-fixes-photos-sos-reviews.md` (sections 1, 3.2, 3.3), `docs/full-review-2026-11-01.md`, `docs/plans/30A-completion-report.md`, `TESTING-NOTES.md`, and the files each item names below.

Hard rules: plan section 1. **The sign-in test codes must keep working**: allowlisted test emails and phones are exempt from the new OTP budgets, and a test proves a seeded test account can sign in 20 times in a row.

## Work, in order (tests first for each)

1. **#106 OTP budgets** (`auth/service.go`, `verification.go`, `gateway/middleware/ratelimit.go`): email login start, signup start and claim resend become target-keyed; a Postgres table `auth.otp_budgets (target_normalized, purpose, day, sends, failed_guesses)` with atomic upserts; at most 5 sends and 10 failed guesses per target per Colombo day, not reset by a new code; generic error text so it does not reveal whether an account exists. Allowlisted test targets skip the budget.
2. **#107 limiter peek**: case-insensitive key match, refuse bodies with duplicate or conflicting keys (400). Test `EMAIL`, `Email` and duplicate-key bodies.
3. **#81 shared limiter**: `ops.rate_counters (key_hash, window_start, count)` with an atomic increment, used for OTP, login, phone verification, SOS, contact changes, share and photo upload; keys hashed (no raw emails or phones stored); expired rows swept; fails closed for OTP, SOS and contacts when the database is unavailable, open for the rest. The in-memory limiter keys on the route pattern and has a size cap with oldest eviction.
4. **#111 work email**: Level 3 only for a known company domain; unknown companies give Level 2 plus a `pending_review` claim; add an embedded disposable-mail domain list with a test.
5. **#103 profile**: `ListRecentMeetupsForMember` returns only completed meetups; pass the viewer's trust level; Level 0 gets no names, photos or meetups of others (full anonymous reviews come in 30E).
6. **Location server side** (plan 3.3): `GetMeetup` radius rule with host and participant exceptions and no coordinates for Level 0; join refuses unknown or stale (over 24 h) location; one radius constant; stored last-known location rounded to 3 decimals; sweeps for location cache rows older than 30 days, SOS events older than 90 days, and old meetup coordinates (D4); Nominatim fixes (no URL in logs, 64 KB cap, real User-Agent, small cache, 1 request per second); request logs never include query strings.
7. **#114** join and accept require `window_end > now()` inside the conditional statements; **#115** outbox claims re-stamped per row and mark-processed checks ownership; **Idempotency-Key** reuse with different parameters returns 409 on meetup create; review and rating submissions enforce the 14-day window; **#120** Google JWKS refetch at most once a minute with a negative cache.
8. **Analytics** (#110, #119): strip `user_key` and `install_id` from archived rows (or archive daily aggregates only; choose the simpler that keeps the archive useful, document it) and document a 90-day lifecycle rule; validate `install_id` as a UUID at the gateway; start a new root span at the edge and drop inbound baggage; refuse UUID-shaped values for `id` attributes; stream the archive upload.
9. **Meetup share (D1)**: live meetups only, contact ids capped at 2 and deduplicated, record only contacts actually notified, 3 shares per user per day.
10. Anything else you find while doing this (run `gosec`, `govulncheck`, read the touched files critically): fix it with a test or add a tracker row with severity.

Finish with the gates and `docs/plans/30B-completion-report.md`. Do not start 30C.
