# Testing-only shortcuts — must not ship

Tracks active testing-only shortcuts in this repo, same purpose as the
sibling microservices repo's own `TESTING-NOTES.md`. Check this before
treating any verification or map/location behavior as production-real.

## Gated OTP bypass — off by default, explicit opt-in only

Unlike the source's version of this shortcut (`../Professional-Meetups/TESTING-NOTES.md`,
which comments out the real comparison entirely and unconditionally accepts
`123456`), this repo's version is deliberately safer in shape, added
2026-09-04 at Shashika's explicit request to unblock manual testing:

- **`backend/internal/modules/auth/otp.go`**'s `otpMatches` always runs the
  real `subtle.ConstantTimeCompare` check first. It additionally accepts the
  fixed code **`123456`** for every OTP purpose (phone, personal email,
  corporate email), but *only* when the environment variable
  `ALLOW_TEST_OTP_BYPASS=true` is explicitly set. Absent or any other value
  behaves exactly as if this code didn't exist.
- **`backend/cmd/monolith/main.go`** logs a loud `WARN`-level message on
  *every single startup* while this is enabled — deliberately noisy so it
  can't quietly go unnoticed in a deployed environment's logs the way a
  silent bypass could.
- **Never set `ALLOW_TEST_OTP_BYPASS=true` outside local development.** It
  is absent from `backend/.env.example` (add it to your own local
  `backend/.env` only) and must never be set in any deployed environment's
  config.

### How to use it

In your local `backend/.env`:

```
ALLOW_TEST_OTP_BYPASS=true
```

Then restart the monolith container to pick up the change:

```bash
cd backend
docker compose up -d monolith
```

`123456` then works as the OTP for any signup/login/verification flow.

**Confirm it is actually on before trusting it.** The monolith logs a
`WARN` naming this flag on every startup while it is enabled — if that line
is absent, the bypass is OFF regardless of what `backend/.env` says, and
`123456` will be rejected as an invalid code:

```bash
docker compose logs monolith | grep ALLOW_TEST_OTP_BYPASS
```

*Fixed 2026-09-05*: setting it in `.env` alone used to be silently
insufficient. Compose uses `.env` to **interpolate into `docker-compose.yml`**
— it does not pass those values into containers. Only variables named under a
service's `environment:` block reach the process, and this one was never
listed there, so the monolith never saw it: `123456` was rejected and the
startup warning above never fired either, which made the flag look enabled
while it was not. `docker-compose.yml`'s `monolith` service now forwards it
explicitly. Any future flag of this kind needs the same treatment.

The real generated code still works too, and still appears in the
`LoggingSmsSender`/`LoggingEmailSender` log line when Twilio/Resend/Gmail
credentials aren't configured — the bypass is a convenience on top of that,
not a replacement for it.

### How to revert before production

1. Remove `ALLOW_TEST_OTP_BYPASS` from wherever it's set (it should never
   have been set outside a local `.env` in the first place).
2. If retiring the mechanism entirely rather than just leaving it
   dormant: delete `allowTestOTPBypass`/`testOTPBypassCode` and the
   `if allowTestOTPBypass() ...` branch from `otp.go`'s `otpMatches`, and
   the corresponding `main.go` warning block.
3. Delete this file's OTP section (or the whole file, if nothing else in
   it is still active).

### Known side effect while this is active

None expected at the test-suite level — unlike the source's unconditional
bypass, which makes every test asserting a *real* generated OTP fail
outright, this version only changes behavior when `ALLOW_TEST_OTP_BYPASS=true`
is set, which the test suite never sets. If a future test does set it to
exercise the bypass path itself, list it here, same discipline as the
source's own tracking.

### The narrower mechanism: `TEST_OTP_BYPASS_PHONES` (the one actually set on the deployed service)

Everything above concerns `ALLOW_TEST_OTP_BYPASS`, which is **global** - it
accepts `123456` for every OTP purpose, for every account, the moment it is
set. That is fine for local `docker-compose`, which is never public, and it
is why that flag stays `false` on Cloud Run.

`TEST_OTP_BYPASS_PHONES` is a second, independent mechanism for a narrower
problem. Twilio cannot deliver long-code SMS to Sri Lanka's Dialog, Etisalat
or Hutchison networks (error 21612) until an Alphanumeric Sender ID
registration completes, so real phone OTP never arrives on the two physical
test devices - and phone verification gates Level 2 trust, which gates
joining meetups and the Safety Center (ADR-003). Device testing is blocked
entirely without something.

It is a comma-separated allowlist of exact phone-number strings, scoped on
two axes at once:

- **Purpose** - phone only. This mechanism never touches any email purpose.
  (Email OTP has since gained its own separate allowlist - see
  `TEST_OTP_BYPASS_EMAILS` below. The two share no state and neither widens
  the other: the test suite pins that the phone list is rejected for email
  purposes and vice versa.)
- **Target** - only numbers in the allowlist. Every other number, including
  ones nobody has used yet, still requires the real delivered code.

Matching is **byte-for-byte against what the client actually sends** - there
is no server-side normalization (`verifyAndConsumeCode` compares
`pending.Target != target` directly). An entry of `+94771234567` will not
match a client sending `+94 77 123 4567`. If in doubt, submit the number
once from the real app and read the exact string out of
`gcloud run services logs read` rather than hand-guessing the format.

**One mechanism, two effects:**

1. **Verify time** - `otpMatches` accepts `123456` for an allowlisted phone
   target, *in addition to* the real code, which keeps working.
2. **Send time** - `dispatchVerificationCode` skips the Twilio call for an
   allowlisted number entirely and logs a `WARN` carrying both the target
   and the real generated code. The call is already known to fail for these
   numbers, so making it anyway costs an API call, puts a 21612 in the logs
   that reads like a live incident, and returns `ErrInternal` to a client
   that is about to verify successfully regardless. The real code is in that
   log line, so if the fixed code ever stops working the real one is still
   recoverable.

A separate startup `WARN` fires on every monolith start while the var is
set, logging **how many** numbers are allowlisted - never the numbers
themselves. It is a distinct log line from the `ALLOW_TEST_OTP_BYPASS`
warning so either can be identified independently in
`gcloud run services logs read`.

#### Residual risk, stated plainly

This is not risk-free; it is risk reduced to a specific, named, small shape,
which is the point. **Anyone who knows an allowlisted number could use
`123456` to create or take over an account tied to that exact number.** That
is a real account-takeover surface on those numbers.

It is categorically smaller than the global flag. Before this change nobody
can complete phone verification with those numbers anyway - the real SMS
never arrives - so this exposes no account that currently works. It affects
only the numbers already non-functional for verification. No other user and
no other phone number is affected in any way.

#### How to revert

Remove `TEST_OTP_BYPASS_PHONES` from `backend/service.yaml` and redeploy
(`gcloud run services replace service.yaml --region=asia-south1`, bumping
the pinned `metadata.name` revision suffix). **No code rollback is needed** - 
an empty or unset value makes the whole mechanism a no-op, at both the
verify and send steps. Retire the code itself only if the mechanism is being
removed for good, in which case delete `testOTPBypassPhones` from `otp.go`,
its branch in `otpMatches`, the skip in `dispatchVerificationCode`, and the
`main.go` warning block.

### The email twin: `TEST_OTP_BYPASS_EMAILS`

`TEST_OTP_BYPASS_PHONES` answers an **undeliverability** problem - those
carriers reject the SMS, so the real code never arrives. `TEST_OTP_BYPASS_EMAILS`
does not. Email delivery works fine. It answers a **throughput** problem
instead: exercising the 0–3 trust ladder means signing in as eight different
accounts, and eight mailboxes is enough friction that the ladder goes untested
in practice.

Same shape as the phone list - comma-separated, scoped to purpose and target - 
with two differences that matter:

- **Purpose** - all four email purposes (`email_signup`, `email_login`,
  `personal_email`, `corporate_email`). Wider than the phone list, because
  the point is to exercise the whole ladder, including the Level 2 and
  Level 3 climbs.
- **The allowlist match is case-insensitive and trimmed**, unlike the phone
  list's byte-exact rule. An email domain is case-insensitive (RFC 4343) and
  the client sends whatever the user typed, so an allowlist entry of
  `l2.a@meetups.test` matches a target of `L2.A@Meetups.test`. A phone number
  arrives already normalized to E.164, which is why byte-exact is right there
  and wrong here.

  **This does NOT make the whole login flow case-insensitive**, and the
  distinction is worth knowing before it wastes anyone's afternoon. The
  allowlist branch in `otpMatches` will match mixed case, but the step after
  it - `GetUserByPersonalEmail`, `SELECT ... WHERE personal_email = $1` with
  no `LOWER()` - will not find the user, and the request fails with a generic
  `invalid email or code`. Verified against the deployed service: signing in
  as `L3.B@Meetups.TEST` returns 401 even though the allowlist matched.

  So **use the exact lowercase addresses**. This is pre-existing behaviour of
  the email-login path, unrelated to either bypass mechanism, and it applies
  to real users too: an account created as `John.Smith@example.com` cannot log
  in as `john.smith@example.com`. Worth fixing properly one day (a functional
  index or a normalize-on-write), but that is a schema and uniqueness decision,
  not a testing one.

#### The risk is genuinely larger than the phone list's, and differently shaped

`TEST_OTP_BYPASS_PHONES` could argue it exposed nothing: those numbers cannot
complete verification under any circumstances today, so no working account
became newly reachable. **That argument does not transfer.** Email works, so
an allowlisted address is an account that anyone who knows the address can
sign into with `123456`. That is a real account-takeover surface.

What contains it is the *contents* of the list, not the mechanism:

- Every entry is on `.test`, an **RFC 2606 reserved TLD**. It cannot be
  registered, cannot receive mail, and cannot belong to a real person or be
  recovered by one.
- They map 1:1 onto the eight seeded fixtures in
  `backend/testdata/seed-test-users.sql`, which hold no real data.
- Every other address, including any real user's, still requires the real
  delivered code.

**Never put a deliverable address in this variable.** A reserved-TLD fixture is
a test account; a real address is a published password.

#### How to revert

Remove `TEST_OTP_BYPASS_EMAILS` from `backend/service.yaml` and redeploy,
bumping the pinned `metadata.name` suffix. As with the phone list, **no code
rollback is needed** - unset makes the mechanism a no-op at both the verify
and the send step. To retire the code itself, delete `testOTPBypassEmails`,
`isEmailOTPPurpose` and `normalizeBypassEmail` from `otp.go`, the branch in
`otpMatches`, the skip in `dispatchVerificationCode` (verification.go), the
skip in `startTargetKeyedVerification` (service.go), and the `main.go`
warning block. Note there are **two** send sites, not one: the target-keyed
purposes never reach `dispatchVerificationCode`.

## Android map provider: OpenStreetMap by default (2026-09-13)

Android's map and place search moved off Stadia Maps' metered free tier to
OpenStreetMap-based services: OpenFreeMap vector tiles (`liberty` style, a light
Google-Maps-like look in both themes, no key; the ODbL credit lives behind
MapLibre's (i) corner control rather than a text overlay) and Photon for
type-ahead search, with a Nominatim fallback for a direct search when
Photon is unavailable (never for keystrokes; Nominatim's policy forbids
type-ahead). Both OSM services get an identifying `User-Agent`. The switch
is `MAP_PROVIDER` in `frontend/.env` (`osm` default, `stadia` to opt back
in with `STADIA_MAPS_API_KEY`), implemented in
`frontend/lib/core/maps/`. iOS is unaffected: Apple MapKit, no key.
`./build.sh` verifies the selected provider is compiled into a production
APK.

## One meetup at a time (2026-09-15)

A test account that already hosts, or has a pending/accepted request on, a
live meetup cannot host or join another one in the same window (ADR-005).
The seeded L3 Alpha account holds several, so a second meetup "later today"
often collides with one of them and the app shows the ONE MEETUP AT A TIME
sheet instead of scheduling. That is the rule working, not a fault: pick a
window after the existing meetup ends, or open it from the sheet and cancel
it. The 409 body carries `code: schedule_conflict` and the meetup in the
way, which is also how the sheet knows what to show.

Verifying it by hand against a local stack:

```bash
# Host an overlapping meetup as an account that already hosts one
curl -s -X POST localhost:8080/v1/meetups -H "Authorization: Bearer $AT" \
  -H 'Content-Type: application/json' \
  -d '{"intent":"coffee","window_start_unix_seconds":...,"window_end_unix_seconds":...,"location_lat":6.93,"location_lng":79.86,"location_label":"Cafe","capacity":2}'
# → 409 {"error":"You are already hosting ...","code":"schedule_conflict","conflict":{...}}
```

To reach another host's meetup for the join-side check without the browse
list, seed a notification for the test account that points at it
(`meetup.notification_outbox`, `data.meetup_id`, `processed_at = now()`)
and open it from the Notifications page. The browse list itself works on
the emulator again; see the next section for what had broken it.

## The Android emulator and location (2026-09-17)

For two days the Happening Soon list never loaded on the emulator while
every real phone was fine. Two separate causes, both now handled:

**1. The app stopped asking for GPS.** The browse read requests medium
accuracy (`viewer_location_provider.dart`, since `76068f6` on 2026-09-15)
so a phone answers from network positioning in a second. On Android that
maps to "balanced power", which never turns the GPS on. A phone has Wi-Fi
and cell databases to answer from; an emulator has nothing but the injected
GPS fix, so a medium read there could never resolve. `requestCurrentLocation`
now escalates ONCE to a high-accuracy read (10 s) when a lower-accuracy read
times out with nothing cached (`core/utils/location.dart`,
`test/location_request_test.dart`). On a phone that only triggers where
network positioning has failed, which is when GPS is the right next step.
The fast path, the 110 m coordinate quantisation and the keyed cache are
untouched; it adds no server traffic.

**2. The AVD was rendering in software.** `~/.android/avd/Pixel_8.avd/config.ini`
had `hw.gpu.mode=software`, so every frame was drawn on the CPU: qemu at
650%+ of the host's 8 cores, `surfaceflinger` at 30% in the guest, ANRs in
our app, Settings and Messages alike, and one hang inside the geolocator
plugin's NMEA unregistration (a binder call the starved system server never
answered). Set to `hw.gpu.mode=auto` (the previous file is kept as
`config.ini.bak-2026-09-17`); qemu now idles around 60%.

Injecting a fix: `adb emu geo fix <lng> <lat>` (longitude first), repeated
every couple of seconds while the app is reading; one shot is not always
picked up. `adb shell dumpsys location | grep -A3 "gps provider"` shows
whether the app's request reached the GPS (`HIGH_ACCURACY, WorkSource{...
profconn...}`) and whether a fix landed (`last location=Location[gps ...]`).

The emulated Wi-Fi (`netsimd`) has been flapping after cold boots; if the
gateway never sees a request, `adb shell svc wifi disable` routes the guest
over the emulated cellular link, which reaches the host at `10.0.2.2` fine.

A cold boot with `-no-snapshot-load` also wiped the installed app on this
AVD; reinstall and sign in again (l3.a@meetups.test, code 123456).

**iOS simulator:** a different, simpler thing. It reports a location only
when one is set (Features > Location in the Simulator menu, or
`xcrun simctl location booted set 6.9271,79.8612`), and that setting does not
always survive a reboot; accuracy does not come into it.
