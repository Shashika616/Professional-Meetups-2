Read `docs/plans/18-round6-security-design-fixes.md` in full first — it has
exact file/line locations, verified against source directly (not just
reported), and the reasoning behind each fix shape. Four independent fixes,
two High severity. Do all four; none depend on each other.

## Fix 1 (High) — enforce the `TEST_OTP_BYPASS_EMAILS` reserved-TLD rule at startup

`backend/internal/modules/auth/otp.go`: add `reservedTestTLDs` and
`isReservedTestAddress` as specified. Wire the check into
`backend/cmd/monolith/main.go`'s existing `TEST_OTP_BYPASS_EMAILS` warning
block (~line 149) — check every entry BEFORE logging the count, and if any
entry fails, log which one and call `os.Exit(1)` (or your process's existing
fatal-startup-error convention — check how other required-config failures
in this file exit) rather than continuing to boot. Update the doc comment
at `otp.go:244-256` accordingly. Add a test in `otp_test.go` proving a
non-reserved-TLD entry is caught.

## Fix 2 (High) — real age confirmation on the sign-in path, not a hardcoded `true`

Extract the age-confirmation check/copy `onboarding_flow.dart`'s
`AgeConfirmationStep` already uses into something reusable (don't duplicate
the copy/logic — find the cleanest extraction given how that step is
currently built). Wire `frontend/lib/features/auth/email_login_page.dart`'s
`_methodStep()` to show it once before any provider button can fire, and
thread the real confirmed value into `SocialSignInSection` in place of the
hardcoded `ageConfirmedOver18: true` at lines 127, 137, 147 of
`social_sign_in_section.dart`. `SocialSignInSection` is shared with the
sign-up flow — check whether it needs a parameter added (confirmed value
passed in) or keeps computing it internally; either way, sign-up's existing
behavior (age gate already shown before this widget mounts there) must not
regress. Add a test asserting the sign-in path's gate actually blocks the
provider call until confirmed — mirror whatever pattern already tests this
for the sign-up path, if one exists; if none does, say so in your report.

## Fix 3 (Low) — correct the stale doc comment in `sos.go`

`backend/internal/modules/auth/sos/sos.go:57-58`: reword per the plan doc —
state that phone is specifically required at the Go layer and that the DB
CHECK is intentionally looser (legacy) rather than claiming a mirror that
no longer exists. Do not touch the migration or the CHECK constraint itself.

## Fix 4 (Medium) — close the leaked `listenManual` subscription

`frontend/lib/features/home/home_page.dart`: store the `ProviderSubscription`
`listenManual` returns and close it in `dispose()`, exactly as shown in the
plan doc.

## Verification

Backend: `go build ./... && go test ./...`. Frontend: `flutter analyze &&
flutter test`. Report exact file/line diffs and test output — don't
summarize as "done," show the actual test names that now pass and confirm
none of the existing 21+ sites from prior rounds regressed.
