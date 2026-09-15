# Plan 18 — Round 6 findings: OTP-bypass TLD enforcement, sign-in age-gate bypass, two small drifts

Fresh from-scratch security/design sweep (backend + frontend, independent
reviews, each told to read `docs/gap-tracker.md`'s 34 existing items first
and find new territory only). All four findings below were personally
verified against source, not relayed from the review reports as-is. Full
detail and file/line citations are in `docs/gap-tracker.md`'s new Round 6
section — this doc is the fix spec.

## Fix 1 (High) — `TEST_OTP_BYPASS_EMAILS` has no runtime enforcement of its own safety claim

**The problem.** `otp.go`'s doc comments say this mechanism is safe because
every entry is on a reserved TLD (`.test`) that can't be a real mailbox.
Nothing in the code checks that. `parseOTPBypassAllowlist` (`otp.go:109-121`)
just splits on commas and normalizes case — it will happily accept
`someone@gmail.com` as an allowlist entry, and `main.go`'s boot warning
(`main.go:149-156`) only logs a *count*, so a safe list and an unsafe one
produce an identical-looking log line. `CompleteEmailLogin` (`service.go`)
is a real passwordless-sign-in RPC — an allowlisted address becomes a
permanent, credential-free login for whatever real account owns it. Today's
8 deployed entries (`service.yaml:139`) do happen to all be on `.test` — but
that fact is enforced by nobody and nothing, at parse time, deploy time, or
runtime. One future copy-paste mistake (adding a real tester's address "just
this once" to cut through the friction this mechanism was built to solve)
creates a silent, permanent account-takeover with no visible difference in
logs.

**Fix.** In `backend/internal/modules/auth/otp.go`, add a small allowlist of
accepted reserved TLDs/hosts and validate every `TEST_OTP_BYPASS_EMAILS`
entry against it inside `testOTPBypassEmails()` (or a wrapper it calls):

```go
// reservedTestTLDs are the RFC 2606 (and RFC 6761) suffixes that cannot be
// registered or resolve to a real mailbox — the only domains that make
// TEST_OTP_BYPASS_EMAILS's safety argument actually true rather than just
// stated in a comment.
var reservedTestTLDs = []string{".test", ".example", ".invalid", ".localhost"}

func isReservedTestAddress(email string) bool {
	for _, suffix := range reservedTestTLDs {
		if strings.HasSuffix(email, suffix) {
			return true
		}
	}
	return false
}
```

Call this from wherever `testOTPBypassEmails()` is read (or better, once at
process startup in `main.go`, alongside the existing warning block) and
**fail loudly and refuse to continue** if any entry fails — this is a
security control, not a UX validation, so the failure mode should be a
startup `Fatal`/non-zero exit with the offending address logged, not a
silent skip. Update `main.go`'s existing warning block (`main.go:149-156`)
to run this check before logging the count, and exit non-zero with a clear
message naming which entry is invalid if the check fails. Add a unit test
in `otp_test.go` proving a non-`.test` entry is rejected at startup-check
time. Update the doc comment at `otp.go:244-256` to say the TLD restriction
is enforced, not just documented.

## Fix 2 (High) — Sign-in screen creates new accounts with a hardcoded, unshown age confirmation

**The problem.** `frontend/lib/features/auth/social_sign_in_section.dart`
hardcodes `ageConfirmedOver18: true` on all three provider sign-in calls
(lines 127, 137, 147). This widget is shared between the sign-up flow
(`onboarding_flow.dart`, which correctly shows `AgeConfirmationStep` first)
and the new `email_login_page.dart`'s `_methodStep()` ("Welcome back" —
the sign-IN screen, reached directly from the landing page's "SIGN IN" text,
`landing_page.dart:116-119`) — which has no age-confirmation step anywhere
in that path. `identity_resolution.go` confirms this isn't decorative: a
provider tap that doesn't match an existing account creates a new one via
`ResolveOrCreateIdentity`, and `ageConfirmedOver18` is checked and recorded
as a real, enforced legal self-attestation at exactly that moment
(`identity_resolution.go:57,98,217`). A brand-new user who taps "Sign In"
(not "Sign Up") from a fresh install and picks a provider gets an account
created with the server believing it confirmed 18+ — a confirmation that
was never shown. This is a second, independent instance of the age-gate
concern `docs/07-research/app-store-and-play-store-compliance.md` already
tracks for the `dating` intent chip — same underlying compliance exposure,
different code path.

**Fix.** Don't try to conditionally detect "is this tap going to create a
new account" client-side (the client can't know that before the server
responds — that's the whole reason this is a resolve-or-create call). The
simple, safe fix: show the same one-time age confirmation on the sign-in
path too, before any provider call. Concretely, add an
`AgeConfirmationGate` (extract the existing check/copy from
`onboarding_flow.dart`'s `AgeConfirmationStep` into something both flows can
use — don't duplicate the copy) that `email_login_page.dart`'s
`_methodStep()` shows once (a lightweight inline checkbox/confirmation
row above `SocialSignInSection`, or a one-time dialog before the first
provider tap — implementer's call on which reads better, but it must block
the provider call, not just be decorative) and threads the real confirmed
value into `SocialSignInSection` instead of the hardcoded `true`. The cost
to an already-registered user signing back in is one extra tap the first
time; that's an acceptable trade against recording a false legal attestation
for a new account. Add a test asserting `email_login_page.dart`'s provider
buttons don't fire with a hardcoded `true` — mirror whatever pattern
`onboarding_flow_test.dart` already uses to assert the sign-up path's gate
is real.

## Fix 3 (Low) — `sos.go` doc comment claims a DB mirror that no longer exists

**Where:** `backend/internal/modules/auth/sos/sos.go:57-58`'s doc comment
("At least one of PhoneNumber/Email is required — enforced server-side
here, mirroring the DB CHECK constraint") is now false: `sos.go:182-184`
requires phone specifically (a deliberate, well-justified safety change),
but the DB CHECK (`migrations/0001_auth_schema.up.sql:251`,
`CHECK (phone_number IS NOT NULL OR email IS NOT NULL)`) was never
tightened to match. Not currently exploitable — the Go layer is the only
insert path — but the comment is actively misleading about what backstop
exists.

**Fix.** Correct the comment at `sos.go:57-58` to state plainly: the Go
layer requires phone specifically; the DB CHECK is intentionally looser
(legacy, predates the phone-mandatory change) and is not a backstop for
this specific rule. Don't touch the migration/constraint itself in this
pass — tightening it requires checking existing rows for phone-less
contacts first, which is a separate, standalone piece of work if ever
wanted. Note that as an explicit follow-up in the gap tracker (already
done, see Round 6 §Backend #36 below), not in this fix.

## Fix 4 (Medium) — `HomePage` leaks a `listenManual` subscription on every sign-out/sign-in cycle

**Where:** `frontend/lib/features/home/home_page.dart:94` calls
`ref.listenManual(viewerLocationProvider, (_, _) {})` in `initState()` with
no corresponding `.close()` in `dispose()` (`home_page.dart:97-101` only
disposes `_scrollController`). `viewerLocationProvider` is deliberately
`autoDispose` specifically so "a sign-out and sign-in starts clean" — the
missing `.close()` defeats that on every `HomePage` teardown/recreation
(sign-out→sign-in, forced session expiry→re-login).

**Fix.** Hold the `ProviderSubscription` `listenManual` returns in a field
and call `.close()` in `dispose()`, same pattern already used for
`_scrollController`:

```dart
late final ProviderSubscription<void> _locationListener;

@override
void initState() {
  super.initState();
  _locationListener = ref.listenManual(viewerLocationProvider, (_, _) {});
}

@override
void dispose() {
  _locationListener.close();
  _scrollController.dispose();
  super.dispose();
}
```

## Verification

For each fix: `go build ./... && go test ./...` (backend), `flutter analyze
&& flutter test` (frontend). Fix 1 needs an explicit test proving the
startup check actually rejects a bad entry — don't just add the check and
assume it works. Fix 2 needs a test proving the sign-in path's age gate is
real, not decorative (mirror the sign-up path's existing test, if one
checks this).
