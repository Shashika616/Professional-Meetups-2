Read `docs/plans/16-scoped-otp-bypass-for-test-devices.md` in full before
doing anything — it explains why this exists (Twilio can't deliver to
Shashika's two test phones' carriers) and why it's shaped as a
purpose+target-scoped allowlist rather than reusing the existing
`ALLOW_TEST_OTP_BYPASS` flag, which stays exactly as-is and unset in the
deployed environment. This is a small, precise change — resist the urge to
generalize it further.

## Changes

1. **`backend/internal/modules/auth/otp.go`**: add `testOTPBypassPhones()`
   (parses `TEST_OTP_BYPASS_PHONES`, comma-separated, into a `map[string]bool`,
   nil if unset). Change `otpMatches`'s signature to
   `otpMatches(hash, code string, purpose repository.VerificationPurpose, target string) bool`,
   adding the second, narrower bypass branch scoped to
   `purpose == repository.VerificationPurposePhone` AND
   `testOTPBypassPhones()[target]`. Keep the existing
   `allowTestOTPBypass()` branch unchanged. Update the doc comment above the
   function to describe both mechanisms — copy the plan doc's "why not the
   global flag" reasoning rather than writing new reasoning from scratch.

2. **Both call sites** — update to the new signature, passing the `purpose`
   and `target` already in scope at that point:
   - `backend/internal/modules/auth/verification.go:437`
   - `backend/internal/modules/auth/service.go:519`

3. **`backend/cmd/monolith/main.go`**: near the existing
   `ALLOW_TEST_OTP_BYPASS` warning block (~line 119), add a second,
   independent check that logs a `WARN` if `TEST_OTP_BYPASS_PHONES` is set —
   log how many numbers are allowlisted, never the numbers themselves.

4. **`backend/.env.example`**: add `TEST_OTP_BYPASS_PHONES=` (empty) near
   the existing `ALLOW_TEST_OTP_BYPASS=false` line, one-line comment
   pointing at `TESTING-NOTES.md`.

5. **`TESTING-NOTES.md`**: add a new subsection (don't replace the existing
   OTP section — both mechanisms coexist and serve different purposes) per
   the plan doc's description: what it does, that it's the mechanism
   actually used on the deployed service (unlike the global flag), the
   residual-risk paragraph verbatim from the plan doc, and how to revert.

6. **Tests** — add to `backend/internal/modules/auth/otp_test.go` the four
   cases listed in the plan doc's Tests section. Run
   `go test ./internal/modules/auth/...` and confirm they pass alongside
   the existing suite (don't just add tests — actually run them).

7. **`backend/service.yaml`** (from Plan 15 — check whether it's already
   been written to disk; if Plan 15's Phase 1 already ran, this file
   exists): add `TEST_OTP_BYPASS_PHONES` as a plain (non-secret) env var on
   the `monolith` container. **Do not fill in real phone numbers yourself**
   — leave the value as a placeholder comment
   (`# TODO: Shashika to fill in exact target strings, see plan 16's "one
   thing to confirm" section`) and say so explicitly in your report. Do not
   guess a phone-number format.

## Verification before reporting done

- `go build ./...` and `go test ./...` both pass.
- Grep confirms no other call site of `otpMatches` was missed.
- Confirm `ALLOW_TEST_OTP_BYPASS`'s existing behavior and tests are
  untouched — this change is additive, not a replacement.
- If `service.yaml` doesn't exist yet (Plan 15 Phase 1 hasn't run), say so
  in the report and note the env var still needs adding whenever that file
  is written.

## Report

State plainly: what changed, exact file/line locations, test results, and
the one open item (real phone-number values for `TEST_OTP_BYPASS_PHONES`
still need to come from Shashika, in the exact format the live app sends —
plan doc explains how to get that value reliably rather than guessing).
Do not deploy anything as part of this task — this is a code change, Plan
15's own Phase 1/Phase 2 sequencing still governs when it actually reaches
Cloud Run.
