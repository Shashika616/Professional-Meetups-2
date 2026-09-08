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

## Inherited: Stadia Maps API key — not the production decision

`frontend/.env`'s `STADIA_MAPS_API_KEY` was copied unmodified from the
source repo when this project was scaffolded (2026-09-03/04) — same
provisional status as documented in
`../Professional-Meetups/TESTING-NOTES.md`'s Stadia Maps section: Android's
final map-tile vendor is still an open decision between Google Maps and
OpenStreetMap/Stadia; iOS already uses Apple MapKit, settled, no key. This
repo hasn't changed that status, just inherited it — resolve it in the
source's own decision process, not independently here.
