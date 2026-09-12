# Plan 17 — Finish the scoped OTP bypass and redeploy so device testing actually works

Supersedes nothing in `docs/plans/16-scoped-otp-bypass-for-test-devices.md` —
that plan's design (the `TEST_OTP_BYPASS_PHONES` allowlist, purpose+target
scoped, `ALLOW_TEST_OTP_BYPASS` untouched) is correct and this plan
implements it in full, plus one thing Plan 16 didn't cover and a redeploy.
Read Plan 16 first for the full reasoning; this doc doesn't repeat it.

## What Plan 16 was missing

Plan 16 only changed `otpMatches` (the code-comparison step, at *verify*
time). It didn't touch `startVerification`/`dispatchVerificationCode` (the
*send* step). Checked directly against source just now:

- `startVerification` (`verification.go:364-395`) calls
  `s.verificationCodes.Upsert(...)` (stores the real code's hash) **before**
  calling `dispatchVerificationCode`. So the pending row exists in the DB
  even if the Twilio send that follows fails — this part already works
  without any further change.
- But `dispatchVerificationCode` failing still makes `startVerification`
  return `apperror.ErrInternal` ("failed to send verification code, please
  try again") to the client. Checked `frontend/lib/features/verification/phone_verification_page.dart`:
  the UI transitions to the OTP-entry screen optimistically regardless
  (`_showOtp()`'s own comment says this is deliberate, for exactly a
  "slow or failing backend"), so the user still reaches a code box — but
  they'll see a failure toast on top of it, a wasted real Twilio API call
  (cost, and a 21612 error in the logs that looks like a live incident),
  and no server-side certainty that skip-worthy failures are actually the
  known carrier issue rather than something else.

Fix: skip the real Twilio call entirely for allowlisted numbers, since it's
already known to fail for them — don't waste the call or show a scary error
for an outcome that's expected.

## Code changes

### 1. `backend/internal/modules/auth/otp.go` — as specified in Plan 16

`testOTPBypassPhones()` helper, `otpMatches` signature widened to
`(hash, code string, purpose repository.VerificationPurpose, target string) bool`,
second bypass branch scoped to `purpose == VerificationPurposePhone &&
testOTPBypassPhones()[target]`. Update both call sites
(`verification.go:437`, `service.go:519`). Exactly as Plan 16 describes —
no changes to that part.

### 2. `backend/internal/modules/auth/verification.go` — new: skip send for allowlisted numbers

In `dispatchVerificationCode` (line ~397), change the phone case:

```go
case repository.VerificationPurposePhone:
	if purpose == repository.VerificationPurposePhone && testOTPBypassPhones()[target] {
		s.logger.Warn("TEST_OTP_BYPASS_PHONES: real SMS send skipped for allowlisted test number; fixed test code and the real generated code (below) both work", "target", target, "code", code)
		return nil
	}
	return s.sms.SendVerificationCode(ctx, target, code)
```

(The `purpose ==` check is redundant inside the `case
repository.VerificationPurposePhone:` branch — keep it anyway, it makes the
condition self-explanatory if this function is ever restructured away from
a switch later, and costs nothing.)

This logs the real code too (same info `LoggingSmsSender` already puts in
logs when Twilio isn't configured at all) — so if the fixed code ever stops
working for some unrelated reason, the real one is still recoverable from
`gcloud run services logs read`.

### 3. `backend/internal/modules/auth/otp_test.go` — Plan 16's four cases, plus one more

Add a fifth case: `dispatchVerificationCode` for an allowlisted phone target
does NOT call the (test-double) SMS sender at all, and returns nil.

### 4. `TESTING-NOTES.md` — extend Plan 16's subsection

Add the dispatch-skip behavior to the same subsection Plan 16 adds (don't
create a third section) — one mechanism, two effects (skip send, accept
fixed code), documented together.

### 5. Minor cleanup — `backend/.env`

Line 44's `TWILIO_PHONE_NUMBER` has a trailing `# Twilio number, E.164
format` comment. `docker-compose`/`.env` interpolation strips it, so
nothing is currently broken locally, and the deployed `service.yaml` value
is already clean (`"+14302085668"`, verified directly) — but tidy the local
`.env` line so it can't cause confusion later if this value is ever copied
by hand again. Low priority, bundle it with this change since a file's
already being touched.

## Deploy changes — `backend/service.yaml`

1. Add to the `monolith` container's `env:` (same place `ALLOW_TEST_OTP_BYPASS`
   already sits):
   ```yaml
   - name: TEST_OTP_BYPASS_PHONES
     value: "+94XXXXXXXXX,+94YYYYYYYYY"
   ```
   **Real values, not placeholders — ask Shashika directly for the two test
   phones' local numbers (e.g. `771234567`, i.e. without the `+94`) before
   writing this line.** The exact string sent by the app is
   `'+94' + <what the user typed into the phone field, trimmed>` — confirmed
   directly from `phone_verification_page.dart`'s `_fullNumber` getter and
   the fact that the field has no input formatter — so `+94` followed by
   whatever digits Shashika gives you, no spaces, is the exact string to use.
   Do not guess digits; ask.
2. **Bump the pinned revision name.** `service.yaml` currently pins
   `name: meetups-backend-r5`. This deploy changes the container spec, so
   reusing `-r5` will error (revision names are immutable, not reusable for
   a different spec) — change it to `meetups-backend-r6`.

## Redeploy and verify

```bash
cd backend
gcloud run services replace service.yaml --region=asia-south1
gcloud run services describe meetups-backend --region=asia-south1 --format="value(status.url)"
curl -s -o /dev/null -w "%{http_code}\n" <url>/readyz   # expect 200
```

Then do one real end-to-end check before declaring this done: attempt phone
verification from the actual Flutter app (or `curl -X POST <url>/v1/verification/phone/start`
with one of the allowlisted numbers) and confirm via
`gcloud run services logs read meetups-backend --region=asia-south1` that
the new `WARN` line fires (send skipped) rather than a Twilio error, then
submit `123456` and confirm verification succeeds.

## Report

State exactly what changed (file/line), the two allowlisted numbers actually
written into `service.yaml` (confirm you asked rather than guessed), test
results, the redeploy output, and the live end-to-end check's result. If
Shashika hasn't given you the two numbers yet, stop and ask before touching
`service.yaml` — every other change in this plan is safe to make first.
