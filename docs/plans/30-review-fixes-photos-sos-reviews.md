# Plan 30: fix the 2026-11-01 review findings, user profile photos, SOS rework, anonymous host reviews

Sources: `docs/full-review-2026-11-01.md` (tracker #100-#121), `docs/security-review-2026-11-01.md` (S-8, S-9 open), earlier open items (#81, #87, #88, #89, #91, #95, #96), and Shashika's product changes of 2026-11-01. Prompts: `30A` to `30E` (`docs/plans/30*-claude-code-prompt.md`), run in order.

## 1. Rules for every phase

- Working tree only. No push, no deploy, no `gcloud`, no production database. Commits only in 30A, on a local branch, after Shashika says yes in the session.
- **Keep the sign-in test codes.** `TEST_OTP_BYPASS_EMAILS` and `_PHONES`, the seeded test users and the scoped bypass keep working exactly as today (`TESTING-NOTES.md`). New OTP limits must not lock out allowlisted test targets (they never send real mail or SMS). A test asserts this.
- A provider-verified email still counts as the personal email for Level 2.
- Premium never sells trust. Joining stays free.
- Every fix and feature ships with a test that fails before the change. Money, OTP and SOS paths get concurrency tests with `-race` where concurrency matters.
- No over-engineering: the simplest design that is correct, small, and cheap to run on the free tier. No new infrastructure (no buckets, queues or caches) unless a phase says so.
- Migrations continue after the latest (`0032`); every migration has a down migration and a pre-flight note in the runbook if production data could make it fail.
- After each phase: `go vet ./...`, `gofmt`, `golangci-lint run ./...`, `go test -race ./...`, `govulncheck ./...`, `flutter analyze --fatal-infos`, `dart format --set-exit-if-changed`, `flutter test`, and a report `docs/plans/30X-completion-report.md` ("progress" until every item has a passing test).

## 2. Product changes (decided by Shashika, 2026-11-01)

### 2.1 Profile photos owned by the user

- Users add, change and remove their own photo from their Profile, choosing camera or gallery, then a crop screen to position the square/circle crop (pinch and drag, like other apps).
- LinkedIn photo: taken **once**, when an account is created through LinkedIn onboarding and has no photo. The repeating LinkedIn photo sync is removed. Connecting LinkedIn later, or signing in again with it, never changes a photo the account already has. Google and Apple sign-in do not set or change photos.
- Storage without a bucket: one small JPEG per user in Postgres.
  - The app crops and compresses before upload (`image_cropper` with max 640 px and JPEG quality about 85, so uploads stay small and the phone does the work natively).
  - The server accepts at most 300 KB, checks the image header before decoding (JPEG, PNG or WebP magic bytes; dimensions at most 4096 px per side), decodes, resizes to **320 x 320** (enough for the largest avatar, 96 pt at 3x), and re-encodes as JPEG quality 80. Re-encoding strips EXIF, including GPS. Typical stored size is 15-30 KB.
  - Table `auth.user_photos (user_id PK, jpeg BYTEA, etag TEXT, width, height, bytes, updated_at)`, separate from `auth.users` so ordinary user reads never load image bytes.
  - Served by `GET /v1/users/{id}/photo` with `ETag` (first 16 hex of SHA-256 of the bytes), `Cache-Control: private, max-age=86400`, and `304` on `If-None-Match`. Profile and card payloads carry `photo_url = /v1/users/{id}/photo?v=<etag>`, so a changed photo changes the URL and caches never show a stale one.
  - The same visibility rules as names: guests (Level 0) do not see other members' photos where they do not see their names today; every caller sees their own.
  - Upload `PUT /v1/users/me/photo` (raw `image/jpeg` body), delete `DELETE /v1/users/me/photo`; 10 uploads per user per hour.
  - Existing LinkedIn URLs: a one-off `cmd/backfill-photos` downloads each still-valid LinkedIn URL once into `user_photos`; failures leave no photo. After that, no external photo URLs are stored or served.
  - The server-side LinkedIn fetch only goes to `https` hosts ending in `.licdn.com`, follows no redirects to other hosts, has a 5 s timeout and a 2 MB cap.
- Account deletion deletes the photo row. Photos never appear in analytics.

### 2.2 Trusted contacts and SOS

- **At most 2 trusted contacts**, each just a **name and phone number**. No email, no confirmation text, no OTP to the contact. Adding a contact sends nothing.
- **SOS is strictly reactive**: contacts receive a message only when the user presses SOS. No invites, no live tracking, no background location. The unused live-location API and state are removed.
- Existing data: contact emails are nulled and the column dropped; consent and invite tables are retired; existing contacts become active. Accounts with 3 contacts keep them, SOS alerts the 2 oldest, and the app asks the user to remove one.
- Abuse limits that stay or are added (contacts did not opt in): 2 contacts, 5 contact adds or edits per user per day, phone numbers validated and normalised (E.164), SOS 5 per hour and 10 per day per user, fixed message template, user name sanitised (no line breaks or URLs, at most 60 characters).
- **Location for SOS**, in this order:
  1. a fresh fix from the phone (8 s);
  2. the phone's own last known position (`getLastKnownPosition`) with its timestamp;
  3. the last known location stored on the server (rounded, see 3.3) with its time;
  4. none: the message says the current location is unknown.
  The app sends `latitude`, `longitude`, `captured_at` and `source` (`gps` or `device_last_known`); the server rejects a future `captured_at` and treats a fix older than 24 hours as unknown.
- **Message** (SMS through Twilio, times in Asia/Colombo, plain hyphen instead of an em dash so the SMS stays in the cheaper GSM-7 alphabet):

```
<Name> triggered an SOS alert through TieHere and may need assistance.

Current location
GPS location captured at 6:45 PM
View current location on Google Maps: https://maps.google.com/?q=6.90123,79.85432

Meetup location
Coffee meetup - Colombo 07
View meetup venue on Google Maps: https://maps.google.com/?q=6.91234,79.86543

Triggered: 30 October 2026, 6:45 PM (Sri Lanka time)
```

  Variants: "Last known location / Location captured at 5:10 PM" (add the date when it is not today) for sources 2 and 3 (3 adds "approximate"); "Current location / Current location unknown" with no link for 4. The meetup section appears only when the user hosts or is accepted on a meetup with status open or full and `window_start - 2 hours <= now <= window_end + 2 hours`; otherwise it is left out.
- SOS events are kept 90 days, then deleted (see 3.3).

### 2.3 Host profile: recent meetups and anonymous reviews

- A host's profile shows their recent **completed** meetups (intent, date, area label, participant count, average rating) and the written reviews participants left, **always anonymous**: no name, photo, id or "you were there" hint for any viewer. Each review shows its score, text and the month.
- Upcoming, open or full meetups are never listed on a profile (fixes N1-B1).
- Review text is rendered as plain text (no links), at most 500 characters.
- A member who only joined meetups shows their completed-meetup count and rating, without listing meetups.

## 3. Review fixes

### 3.1 Deploy and repo (30A)
#100 manifest in git or generated in CI; #101 migration 0019 pre-flight and cleanup; #102 cron tick write deadline and per-sweep budgets; #104 commit on a branch; #105 manifest settings; #116 bucket IAM; #117 analytics flush sweep; runbook drift (#121 part); S-8 `golang.org/x/net` upgrade once v0.62.0 is two weeks old; base images digest-pinned, SBOM and image scan, deploy gated on CI (#95).

### 3.2 Security (30B)
- #106 OTP: email login, signup and claim-resend routes become target-keyed; per normalised target, at most 5 sends and 10 failed guesses per 24 hours, counted in Postgres and not reset by a resend; allowlisted test targets exempt. Consider moving production mail from Gmail SMTP to a transactional provider (decision D2).
- #107 limiter body peek case-insensitive and refuses duplicate keys; better, the target limit lives in the service after decoding.
- #81 shared Postgres counters for OTP, login, phone, SOS, contacts, share and photo upload; in-memory limiter keyed by route pattern (not raw path) with a size cap.
- #111 unknown company: Level 3 only for a known company domain; otherwise Level 2 plus a pending review row; add a disposable-mail list.
- #103 profile (2.3), #109 privacy copy, #113 purchase listener (30E), #114 join and accept require `window_end > now()`, #115 outbox visibility timeout per row, #120 JWKS refetch throttle, `Idempotency-Key` reuse 409, review and rating window enforced, #119 install id validated, edge trace headers not trusted, UUID-shaped id attributes refused, archive streamed, #110 archive identifiers stripped before upload plus a 90-day lifecycle rule documented.
- Meetup share: live meetups only, capped and deduplicated contact ids, only notified contacts recorded, per-user cap 3 per day.

### 3.3 Location (30B and 30E)
- `GetMeetup`: exact coordinates only within the 50 km radius of the viewer's stored location, or for the host and accepted participants; Level 0 never gets coordinates. Join refuses when the requester's location is unknown or older than 24 hours ("Turn on location to join").
- One shared radius constant; stale 40 km comments fixed.
- Last known location stored rounded to 3 decimals (about 110 m) server-side, whatever the app sends; app also rounds before upload. Location cache rows older than 30 days are deleted by a sweep. SOS events deleted after 90 days. Meetup coordinates of meetups ended more than 180 days ago reduced to 2 decimals (about 1 km) by a sweep (decision D4).
- Nominatim: no URL in logs, response capped, real User-Agent with a contact address, a small in-process cache keyed by rounded coordinates, at most 1 request per second.
- Browse coordinates stay in the query (rounded), and request logging never records query strings.
- App: no location read from the meetup page when Home is not mounted; a short explanation screen before the first permission prompt; iOS usage text matches real use, the unused Always text removed; SOS copy says "your location", not "live location"; the map picker starts at the user's rounded location when known.

### 3.4 Structure (30E)
Split the largest files without behaviour changes: `meetups_postgres.go`, `meetup/service.go`, `auth/service.go`, `handlers/meetups.go`, `profile_page.dart`, `schedule_flow.dart`, `events_page.dart`, `meetup_detail_page.dart`. Router migration stays out of scope (N-D13).

## 4. Decisions (defaults unless `docs/plans/30-decisions.md` says otherwise)

| # | Question | Default |
|---|---|---|
| D1 | Keep "Tell a trusted contact" meetup sharing? | Keep, SMS only, live meetups only, 3 per user per day |
| D2 | Production mail provider | Keep Gmail SMTP for now; document Resend as the switch (already supported) |
| D3 | Photo size | 320 x 320 JPEG quality 80 |
| D4 | Old meetup coordinates | Reduce to about 1 km after 180 days |
| D5 | Accounts with 3 contacts | Keep all, alert the 2 oldest, prompt to remove one |
| D6 | Contacts not opting in | Accepted by Shashika; limits in 2.2 are the mitigation; record in ADR |

## 5. Phases

| Phase | Prompt | Scope |
|---|---|---|
| 30A | `30A-deploy-blockers-claude-code-prompt.md` | 3.1 |
| 30B | `30B-security-location-claude-code-prompt.md` | 3.2, 3.3 server side |
| 30C | `30C-sos-trusted-contacts-claude-code-prompt.md` | 2.2 |
| 30D | `30D-profile-photos-claude-code-prompt.md` | 2.1 |
| 30E | `30E-host-reviews-client-fixes-claude-code-prompt.md` | 2.3, client fixes, 3.3 app side, 3.4, docs, final review |
