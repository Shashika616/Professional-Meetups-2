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

## Inherited: Stadia Maps API key — not the production decision

`frontend/.env`'s `STADIA_MAPS_API_KEY` was copied unmodified from the
source repo when this project was scaffolded (2026-09-03/04) — same
provisional status as documented in
`../Professional-Meetups/TESTING-NOTES.md`'s Stadia Maps section: Android's
final map-tile vendor is still an open decision between Google Maps and
OpenStreetMap/Stadia; iOS already uses Apple MapKit, settled, no key. This
repo hasn't changed that status, just inherited it — resolve it in the
source's own decision process, not independently here.
