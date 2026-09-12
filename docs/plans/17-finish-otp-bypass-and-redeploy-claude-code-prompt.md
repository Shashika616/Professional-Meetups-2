Read `docs/plans/17-finish-otp-bypass-and-redeploy.md` in full first, and
`docs/plans/16-scoped-otp-bypass-for-test-devices.md` for the base design
it builds on. This is a single zero-shot task — code changes, tests,
`service.yaml` update, and the actual redeploy — because the deployed
service is already live and Shashika wants to test on real devices today.

## Do, in order

1. **Ask Shashika for the two test phones' local numbers** (e.g.
   `771234567`, without `+94`) before touching `service.yaml` at all — do
   not guess or use placeholders for these. Everything else below can be
   done first while waiting for that answer if it's more convenient.

2. **`backend/internal/modules/auth/otp.go`**: add `testOTPBypassPhones()`
   and widen `otpMatches`'s signature exactly as both plan docs specify.

3. **Both call sites** — `verification.go:437` and `service.go:519` —
   update to the new `otpMatches` signature.

4. **`backend/internal/modules/auth/verification.go`**'s
   `dispatchVerificationCode`: add the allowlisted-number skip in the phone
   case, exactly as Plan 17 specifies (log a `WARN` with the target and the
   real code, return nil, don't call `s.sms.SendVerificationCode`).

5. **`backend/cmd/monolith/main.go`**: add the second startup-warning check
   for `TEST_OTP_BYPASS_PHONES` (count only, not the numbers) as Plan 16
   specifies.

6. **`backend/.env.example`**: add the commented `TEST_OTP_BYPASS_PHONES=`
   line as Plan 16 specifies.

7. **`backend/.env`**: strip the trailing comment on the
   `TWILIO_PHONE_NUMBER` line (Plan 17 §5) — cosmetic, but do it while
   you're in the file.

8. **`TESTING-NOTES.md`**: extend the OTP bypass section to cover both the
   verify-time acceptance and the send-time skip, plus the residual-risk
   paragraph from Plan 16.

9. **Tests**: add Plan 16's four `otp_test.go` cases plus Plan 17's fifth
   (dispatch skip doesn't call the SMS sender for an allowlisted number).
   Run `go test ./internal/modules/auth/...` and `go build ./...` — both
   must pass before continuing.

10. **`backend/service.yaml`**: add `TEST_OTP_BYPASS_PHONES` to the
    `monolith` container's env (value: `+94` + each number Shashika gave
    you, comma-separated, no spaces), and bump `metadata.name` from
    `meetups-backend-r5` to `meetups-backend-r6`.

11. **Redeploy**:
    ```bash
    cd backend
    gcloud run services replace service.yaml --region=asia-south1
    gcloud run services describe meetups-backend --region=asia-south1 --format="value(status.url)"
    curl -s -o /dev/null -w "%{http_code}\n" <url>/readyz
    ```
    Expect `200`. If not, `gcloud run services logs read meetups-backend --region=asia-south1`
    before guessing at the cause.

12. **Live end-to-end check** — actually exercise the new path, don't just
    trust the deploy succeeded:
    ```bash
    curl -X POST <url>/v1/verification/phone/start \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer <a real session token>" \
      -d '{"phone_number":"<one allowlisted number>"}'
    ```
    Then check `gcloud run services logs read` for the new `WARN` line
    (proves the send was skipped, not silently failed), then submit
    `123456` to `/v1/verification/phone/verify` for that same number and
    confirm it succeeds. If you don't have an easy way to get a session
    token for this curl test, it's fine to instead have Shashika do this
    step from the actual Flutter app and report back what happened — say so
    explicitly rather than skipping verification silently.

## Report

Exact files/lines changed, the two number strings actually written into
`service.yaml`, test output, build output, redeploy output, and the
end-to-end result (whichever way you verified it). If anything in step 1
wasn't answered yet, say clearly what's blocked and what you completed
anyway.
