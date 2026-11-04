# 30C completion report: SOS and trusted contacts rework

Status: **complete** (2026-11-04). Working tree only: nothing committed, pushed or deployed. The sign-in test codes and test users are untouched.

Decision recorded in `docs/decisions/adr-013-reactive-sos-and-unconfirmed-contacts.md`. Route changes: `docs/api/plan-30-changes.md`.

## Backend

1. **Migration 0036.** Contacts become `name` and an E.164 `phone_number` with `phone_normalized`, unique per user. Email is nulled and dropped, and email-only contacts deleted. `pending_trusted_contacts` and `contact_invites_sent` are dropped, so every contact is active. `sos_events` gains `location_source` and `location_captured_at`, which the 90-day sweep deletes with the row and the safety hold copies. `live_location_opt_in` is dropped. The down migration restores the columns, not the data. A test seeds the 0035 shape and migrates both ways; it caught the order bug where nulling email tripped the old check constraint.
2. **Contact rules.** At most 2 (count and insert under the user's lock), names 1 to 60 characters with no line breaks or links, numbers in E.164, 5 adds or edits a day through the shared limiter. There was no edit route, so `PUT /v1/sos/contacts/{id}` is new. Adding or editing sends nothing.
3. **SOS request.** `captured_at` and `source` are new; the chain falls back to the rounded stored location with its time, then unknown.
4. **Meetup section.** A port from auth to the meetup module: host or accepted, open or full, now within the window give or take 2 hours. A failed lookup costs the section, never the alert.
5. **Message.** Exactly the plan 2.2 template, in `sos/message.go`, GSM-7 only, Asia/Colombo times, 5-decimal links. SMS only, to the 2 oldest contacts. The meetup-share text is fixed the same way: it had an en dash and printed times in UTC.
6. **Retention.** The 30B sweep covers the new columns because it deletes the row.

**Tests:** 8 golden files (GPS with and without a meetup, device today and yesterday, server approximate, unknown with and without a meetup, a name and label with a line break and links), a GSM-7 check on each, the location chain, a 3rd contact refused under concurrency, a 6th edit refused, nothing sent on add or edit, 2 oldest of 3 against real Postgres, idempotent repeats, duplicates, ownership, the trust gate.

## App

7. **Contacts page.** Name and phone only, "2 of 2 added", edit and remove on each row, no waiting state, and the banner "Only two contacts are alerted. Remove one." for an account with 3.
8. **SOS.** Fresh fix (8 s), then `getLastKnownPosition`, then none, sending `captured_at` and `source`. One `client_request_id` per sheet for the automatic retry and the Retry button. Copy says "your location", also on the safety tip card. Location is read only once SOS is confirmed.
9. **Live location.** The dead client code is removed.

**Tests:** each location source, Retry reusing the id, a new sheet getting a new id, contacts page states, the banner with 3, the edit form, copy.

## Decisions I made that you may want to look at

- **A future `captured_at` does not refuse the SOS.** The plan says "rejects". I reject the *fix*, not the alert: a phone with a wrong clock must not stop an emergency message. 5 minutes of clock skew are forgiven.
- **A stored location over 24 hours old counts as unknown**, the same rule as a phone fix, so a contact is never sent a weeks-old place.
- **Retry after zero notified.** With one id per sheet, a Retry after every SMS failed would have returned "0 notified" forever. The server now sends again in that case, and the app shows zero as a failure with Retry rather than a success tick.
- **Gateway SOS limit raised to 30 an hour.** Its old in-memory 5 counted retries; 30B's report said retries were not counted, which was only true of the database limit. The real 5 and 10 are in the claim.
- **`PUBLIC_BASE_URL` retired**, with the deploy secret `SERVICE_URL`: nothing links to the gateway any more.
- **Non-GSM-7 names** read "A TieHere member" (tracker #125).

## Also fixed

`TestRefundPolicy` in billing was date-bombed since plan 29 and failed for everyone from 2026-11-03 (tracker #127).

## Gates

| Gate | Result |
|---|---|
| gofmt, `go vet`, `golangci-lint` | clean, 0 issues |
| gosec (as CI runs it) | 0 |
| `go test -race -count=1 ./...` | 40 packages pass, with Postgres up |
| govulncheck | nothing reached |
| sqlc, buf, `go mod tidy` | no stray diff |
| Migration 0036 up, down, up | clean |
| `flutter analyze --fatal-infos`, `dart format` | clean |
| `flutter test` | 888 pass |

## For the owner

- 0036 is destructive: take a backup first, and run it with the deploy (runbook §3a).
- Remove the `SERVICE_URL` value from the `production` environment if it was added.
