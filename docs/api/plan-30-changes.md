# Route behaviour changed by Plan 30

The routes without a page of their own under `docs/api/`, and what Plan 30
changed about them. Every change keeps the wire shape: no field was removed
or renamed, so app builds already on phones keep working.

## 30B: security and location (2026-11-01)

| Route | Change | Status and message |
|---|---|---|
| `POST /v1/auth/email/login/start`, `/signup/start`, `/v1/auth/account-claim/resend`, and the phone, personal-email and corporate-email `…/start` routes | At most 5 codes per address or number, per purpose, per Asia/Colombo day. Asking for a new code does not reset it. The allowlisted test addresses and numbers (`TESTING-NOTES.md`) are exempt | 429 "Too many codes requested for this address today, please try again tomorrow." The same wording whether or not an account exists |
| `POST /v1/auth/email/login`, `/signup`, `/v1/auth/account-claim`, and the `…/verify` routes | At most 10 wrong codes per address, per purpose, per day, across every code sent. A right code is not counted | 429 "Too many attempts for this address today, please try again tomorrow." |
| Every route whose limit reads the request body (`email`, `phone_number`) | The key is found whatever its case (`EMAIL`, `Email`); a body that names any top-level key twice, exactly or in another case, is refused | 400 "That didn't go through. Please try again." |
| Every route | The per-IP limit of 20 a minute counts per route pattern (`GET /v1/meetups/{id}`), not per raw path: one bucket for all meetup ids, one for all unknown paths | 429 as before |
| `POST /v1/verification/corporate-email/verify` | A company not in the known list no longer gives Level 3. The work address is proven and its domain kept, the account stays at Level 2 and the claim waits for review. Throwaway-inbox domains are refused like personal ones | 200 with the Level 2 session; 400 for a throwaway domain |
| `GET /v1/users/{id}` | Lists only meetups that have ended. A guest (Level 0) looking at someone else gets no meetups and empty `full_name` and `profile_photo_url` | 200 |
| `GET /v1/meetups/{id}` | `location_lat` and `location_lng` are left out unless the caller is the host or accepted, or is signed in at Level 1+ with a location from the last 24 hours within 50 km. Never for a guest. `location_label` is unchanged | 200 |
| `POST /v1/meetups/{id}/requests` | Needs a known location from the last 24 hours (the one the app reports when Home opens); refused for a meetup whose window has ended | 403 "Turn on location to join, so we can check this meetup is near you."; 409 for an ended meetup |
| `POST /v1/meetups/requests/{id}/respond` (accept) | Refused once the meetup's window has ended | 409 |
| `POST /v1/meetups` | An `Idempotency-Key` reused with different parameters | 409 "This request key was already used for a different meetup." An exact replay still returns the first meetup |
| Review and rating submissions | Refused more than 14 days after the meetup ended (or was cancelled), as Home already stopped offering them | 409 "The time to review this meetup has passed." |
| `POST /v1/meetups/{id}/safety/share` | Live meetups only (open or full, window not over); at most 2 contacts, repeats ignored; 3 shares per account per day; only contacts actually texted are recorded | 409 for a meetup that is over; 400 for more than 2; 429 for the 4th share |
| `POST /v1/sos/contacts` | 5 changes per account per day | 429 |
| `POST /v1/sos/trigger` | The 5-an-hour limit is now shared by every instance and does not count a retry with the same `client_request_id` | 429 with a pointer to the local emergency number |
| `POST /v1/users/me/location` | Stored to 3 decimals (about 110 m) whatever is sent; forgotten after 30 days | 204 as before |

## 30C: SOS and trusted contacts (ADR-013)

Old app builds keep working: they send `email` (ignored) and read a missing `email` and `status` as empty and confirmed.

| Route | Change |
|---|---|
| `POST /v1/sos/contacts` | Body `name`, `phone_number`. Name 1 to 60 characters, one line, no links. The number is normalised to E.164 (a local `07...` becomes `+947...`). At most 2. Sends nothing. The response has no `email` or `status`. 409 for a number the user already has |
| `PUT /v1/sos/contacts/{id}` | New. Same body and rules, and the same 5 changes a day. Sends nothing. 403 for another user's contact |
| `POST /v1/sos/trigger` | New optional `captured_at` (RFC 3339) and `source` (`gps` or `device_last_known`). A future or day-old fix is ignored, never refused. SMS only, to the 2 oldest contacts. A retry with the same `client_request_id` alerts nobody twice, unless the first attempt reached nobody. The gateway's own limit is now 30 an hour: the real 5 and 10 are counted with the claim |
| `GET`, `POST /c/{token}` | Removed. 404 |
| `POST /v1/meetups/{id}/safety/live-location` | Removed. 404. `live_location_opt_in` is gone from the safety state |
| `POST /v1/meetups/{id}/safety/share` | The text is GSM-7, in Asia/Colombo time, and contacts need no confirmation |

## 30D: profile photos

New routes (gateway, signed-in):

| Route | Behaviour |
|---|---|
| `PUT /v1/users/me/photo` | Body is JPEG, PNG or WebP, at most 300 KB. Level 0 and up may upload their own. Returns `{"photo_url": "/v1/users/{id}/photo?v=<etag>"}`. 10 uploads an hour. |
| `DELETE /v1/users/me/photo` | Removes the photo. 204. |
| `GET /v1/users/{id}/photo` | The stored JPEG, with `ETag` and `If-None-Match` (304). Your own photo at any level; someone else's needs Level 1 or above, otherwise 403. |

Renamed fields. **Old builds read the old names, get nothing, and show initials**, which is the intended fallback:

| Old | New |
|---|---|
| `profile_photo_url` | `photo_url` |
| `host_profile_photo_url` | `host_photo_url` |
| `requester_profile_photo_url` | `requester_photo_url` |

The value is a path on this gateway, or empty. It is never an outside address: the gateway drops anything else. Clients send their token with it, and only to `/v1/` paths.

Sign-in no longer copies a LinkedIn photo over a user's own. It is captured once, when a LinkedIn account is created and has no photo.

## 30E: host profiles and client behaviour

`GET /v1/users/{id}`:

- `recent_meetups` lists only finished meetups this member **hosted**. Each has `intent`, `status`, `location_label`, `participant_count`, `overall_average`, `review_count`, and the day in `window_start_unix_seconds` (noon Asia/Colombo: read the date, not the time). The average leaves out the host's own review.
- New `reviews`: `[{"score": 4, "text": "...", "month": "2026-09"}]`, newest first, at most 20, at most 500 characters each. Same for every viewer. No author, photo, id, meetup or exact time, and none may be added.
- A member who only joined has empty `recent_meetups` and `reviews`. Their count and rating stay in `meetups_completed`, `rating_average` and `rating_count`.
- Kept only for builds already on phones: `id` is always `""`, `hosted` always `true`, `window_end_unix_seconds` equals the start. Old builds show no comments and read "12:00 PM" for every meetup; nothing crashes.
- `comments` and `viewer_was_in` are gone.

`POST /v1/analytics/events` accepts one new screen, `location_explanation`.

The app now treats `426` from any `/v1/billing/*` route as "update required", the same as a build below `min_supported_app_version`.

## Legal and forced updates

| Route | Behaviour |
|---|---|
| `GET /v1/legal` | Open to everyone. `{version, terms, privacy}`, the text as Markdown, or 404 before the first publish. |
| `GET /v1/legal/acceptance` | Signed in. `{accepted}` for the current version. |
| `POST /v1/legal/acceptance` | Signed in. Body `{"version": "..."}`. 204, or 409 if that is no longer the current version. |

`GET /v1/app-config` adds two flags: `legal.acceptance.required`, and `app.force_update`, whose value in `values` holds `min_version`, `message` and `store_url`. Old builds ignore both.

## Meetup list filters

`GET /v1/meetups` and `GET /v1/meetups/mine` accept optional `from` and `to`, in unix seconds. A meetup is returned when any part of its window falls inside `[from, to)`. `/mine` also accepts `intent`, and its filters apply to both the hosted and requested lists. A value that is not a positive whole number returns 400, and a range that ends before it starts is refused as invalid input.

