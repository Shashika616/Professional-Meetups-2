# Claude Code prompt 30C: SOS and trusted contacts rework

Read first: `docs/plans/30-review-fixes-photos-sos-reviews.md` (sections 1 and 2.2, decisions D1, D5, D6), `docs/plans/30B-completion-report.md`, `backend/internal/modules/auth/sos/sos.go`, `backend/internal/modules/auth/repository/queries/sos.sql`, migrations `0021`, `0023`, `0024`, `backend/internal/gateway/handlers/sos.go`, and in `frontend/`: `lib/features/safety/safety_page.dart`, `lib/features/safety/manage_trusted_contacts_page.dart`, `lib/core/services/http_auth/safety.dart`, `lib/core/utils/location.dart`, and their tests.

Hard rules: plan section 1. Shashika decided that contacts do not confirm and have no email; record that in a new ADR (`docs/decisions/adr-013-reactive-sos-and-unconfirmed-contacts.md`) with the abuse limits as the mitigation.

## Backend

1. Migration: contacts become `name` and `phone` only (email nulled then dropped), consent and invite state retired (existing contacts active), unique `(user_id, phone_normalized)`, and the live-location columns and API removed. Down migration restores columns (data not restored; say so).
2. Contact rules: at most 2 (atomic insert with the count under the user's lock), names 1 to 60 characters with no line breaks or URLs, phones normalised to E.164 and validated, 5 adds or edits per user per day (shared limiter). Adding or editing sends nothing.
3. SOS request: `client_request_id`, optional `latitude`, `longitude`, `captured_at`, `source` (`gps` or `device_last_known`). Reject a future `captured_at`; treat a fix older than 24 hours as unknown. Fallback to the stored last-known location (rounded) with its time; then "unknown".
4. Meetup section: the caller's meetup where they host or are accepted, status open or full, `window_start - 2 h <= now <= window_end + 2 h`; venue label and venue coordinates.
5. Message: exactly the template in plan 2.2 (all three location variants, meetup section optional, Asia/Colombo times, date added when the capture was not today, GSM-7 characters only, Google Maps links with 5 decimals). Sent by SMS only, to the 2 oldest contacts. Keep the existing idempotency on `client_request_id`, SOS limits (5 per hour, 10 per day), the breaker and retries. Never log message bodies, names, numbers or coordinates.
6. Retention: SOS events deleted after 90 days (30B adds the sweep; make sure it covers the new columns).

Tests: message golden files for every variant (GPS, device last known today and yesterday, server last known approximate, unknown, with and without a meetup, a name with a newline and a URL), GSM-7 check, 3rd contact refused under concurrency, 6th edit in a day refused, nothing sent on add, SOS reaches only the 2 oldest when an account still has 3, idempotent repeat.

## App

7. Trusted contacts page: name and phone only, "2 of 2 added", no email field, no "waiting for confirmation" state; if an account has 3, a banner "Only two contacts are alerted. Remove one." Use the existing design system.
8. SOS: location chain fresh fix (8 s) then `getLastKnownPosition` then none, sending `captured_at` and `source`; one `client_request_id` per dialog for both the automatic retry and the user's Retry button; copy says "your location", not "live location" (also in the safety tip card). No location reads outside the moment SOS is confirmed.
9. Remove the dead live-location client code.

Tests: each location source, Retry reuses the id, contacts page states, banner with 3 contacts, copy.

Finish with the gates and `docs/plans/30C-completion-report.md`. Do not start 30D.
