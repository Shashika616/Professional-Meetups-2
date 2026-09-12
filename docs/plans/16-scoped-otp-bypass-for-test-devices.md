# Plan 16 — Scoped OTP bypass for the two real test devices

## The actual problem

Shashika's two physical test phones are all on Dialog, Etisalat, or
Hutchison — the three Sri Lankan networks Twilio's own guidelines
(`twilio.com/en-us/guidelines/lk/sms`) confirm cannot receive long-code SMS
without an Alphanumeric Sender ID registration that hasn't completed yet
(Twilio error 21612, diagnosed in an earlier session). Real phone OTP will
not arrive on either device today. This blocks device testing entirely,
since phone verification gates Level 2 trust, which gates joining meetups
and Safety Center features (ADR-003).

## What was asked for, and why it wasn't done as asked

The request was to set `ALLOW_TEST_OTP_BYPASS=true` on the deployed Cloud
Run service — the existing flag documented in `TESTING-NOTES.md`. That flag
accepts the fixed code `123456` for **every** OTP purpose (phone, personal
email, corporate email) for **every** account, unconditionally, the moment
it's set. Once `service.yaml` is live, the `*.run.app` URL is a real public
endpoint reachable by anyone who finds it — not sharing the URL doesn't
scope who can reach it, since the flag itself has no concept of "which
user" or "which device." Given that phone OTP gates Level 2 trust, that's a
global authentication bypass sitting on a public URL, not a narrow testing
convenience. Rejected for the deployed environment on that basis (this
reasoning is already recorded in `15-gcp-production-deployment.md` and the
vault's `GCP Deployment Architecture.md`).

The actual need — two specific devices, whose SMS delivery is broken for a
reason that has nothing to do with those devices' owner being untrusted —
doesn't require a global bypass to solve. It requires the bypass to be
scoped down to exactly those two phone numbers.

## The design

Add a **second**, narrower env var: `TEST_OTP_BYPASS_PHONES` — a
comma-separated allowlist of exact phone-number strings. Unlike
`ALLOW_TEST_OTP_BYPASS`, this one is scoped on two axes at once:

1. **Purpose**: only `VerificationPurposePhone`. Personal/corporate email
   OTP still requires the real code always — Resend/Gmail delivery isn't
   broken, there's no reason to weaken that path at all.
2. **Target**: only phone numbers in the allowlist. Every other phone
   number — including ones nobody has used yet — still requires the real
   Twilio-delivered code.

`ALLOW_TEST_OTP_BYPASS` stays exactly as it is today, for local
`docker-compose` development only (never public, so the global-scope
tradeoff is fine there). It stays unset (`false`) in the Cloud Run
deployment, per the existing decision — this plan doesn't reopen that.
`TEST_OTP_BYPASS_PHONES` is the new, separate mechanism used **only** on the
deployed service, **only** for these two numbers.

### Residual risk, stated plainly

This is not risk-free — it's risk reduced to a specific, named, small
shape, which is the point. If someone other than Shashika knows one of the
two allowlisted phone numbers and wants to create or take over an account
tied to that exact number, they could use `123456` to do it. That's a real
account-takeover surface on those two specific numbers. It is categorically
smaller than the global version: today, before this change, nobody can
complete phone verification with either of those two numbers anyway (the
real SMS never arrives), so this doesn't newly expose any account that
currently works — it only affects the two numbers that are already
non-functional for verification. No other user, and no other phone number,
is affected in any way.

### Code changes

**`backend/internal/modules/auth/otp.go`**

Add alongside the existing `allowTestOTPBypass()`:

```go
// testOTPBypassPhones parses TEST_OTP_BYPASS_PHONES — a comma-separated
// allowlist of exact phone-number strings, matched against
// VerificationCode.Target the same way pending.Target is already compared
// in verifyAndConsumeCode (verification.go). Not normalized — the entry
// must match byte-for-byte what the client actually sends. Empty/unset
// means the allowlist is empty, i.e. this mechanism is off.
func testOTPBypassPhones() map[string]bool {
	raw := os.Getenv("TEST_OTP_BYPASS_PHONES")
	if raw == "" {
		return nil
	}
	set := make(map[string]bool)
	for _, p := range strings.Split(raw, ",") {
		p = strings.TrimSpace(p)
		if p != "" {
			set[p] = true
		}
	}
	return set
}
```

Change `otpMatches`'s signature to take the purpose and target it's
checking against — both call sites already have these in scope, so this is
a pure signature widening, no new plumbing:

```go
func otpMatches(hash, code string, purpose repository.VerificationPurpose, target string) bool {
	if allowTestOTPBypass() && code == testOTPBypassCode {
		return true
	}
	if purpose == repository.VerificationPurposePhone &&
		code == testOTPBypassCode &&
		testOTPBypassPhones()[target] {
		return true
	}
	return subtle.ConstantTimeCompare([]byte(hash), []byte(hashOTP(code))) == 1
}
```

Update the doc comment above `otpMatches` to describe both mechanisms and
both scopes — don't just add code, keep the existing "why this shape, not
the source's unconditional version" reasoning intact and extend it.

**Call sites** — both already have `purpose` and `target` in a local
variable at the exact line being changed:

- `backend/internal/modules/auth/verification.go:437`:
  `otpMatches(pending.CodeHash, code)` → `otpMatches(pending.CodeHash, code, purpose, target)`
- `backend/internal/modules/auth/service.go:519`:
  `otpMatches(pending.CodeHash, code)` → `otpMatches(pending.CodeHash, code, purpose, target)`

**`backend/cmd/monolith/main.go`** — extend the existing startup-warning
block (around line 119) to also check `TEST_OTP_BYPASS_PHONES`, logging a
`WARN` naming how many numbers are allowlisted (log the *count*, not the
numbers themselves — no reason to put real phone numbers in log output).
Keep the existing `ALLOW_TEST_OTP_BYPASS` warning as-is; add a second,
separate warning line for this one so either can be identified independently
in `gcloud run services logs read`.

**`backend/.env.example`** — add `TEST_OTP_BYPASS_PHONES=` (empty, commented,
same treatment as `ALLOW_TEST_OTP_BYPASS=false` already gets) with a
one-line comment pointing at `TESTING-NOTES.md`.

**`TESTING-NOTES.md`** — add a new subsection under the existing "Gated OTP
bypass" section (don't replace it — both mechanisms coexist) documenting:
what `TEST_OTP_BYPASS_PHONES` does, that it's the one actually set on the
deployed Cloud Run service (unlike `ALLOW_TEST_OTP_BYPASS`, which stays
local-only), the exact residual risk paragraph above, and how to revert
(remove the env var from `service.yaml`/Secret Manager and redeploy; no code
rollback needed since an empty/unset value is a no-op).

**`backend/service.yaml`** (the Cloud Run spec from Plan 15) — add
`TEST_OTP_BYPASS_PHONES` as a plain env var (not a secret — these are phone
numbers, not credentials) on the `monolith` container only, matching where
`ALLOW_TEST_OTP_BYPASS` would have gone. Value: Shashika's two test device
numbers, exactly as the Flutter app will send them (see below).

**Tests** — add to `backend/internal/modules/auth/otp_test.go`:
- bypass code rejected for a phone target NOT in the allowlist, even with
  `TEST_OTP_BYPASS_PHONES` set to a different number;
- bypass code accepted for a phone target that IS in the allowlist, purpose
  phone;
- bypass code rejected for the *same* allowlisted number when purpose is
  personal/corporate email — proves the purpose scope actually holds;
- existing `ALLOW_TEST_OTP_BYPASS` tests untouched and still passing.

### One thing Shashika needs to confirm before this ships

`validate.go`'s `phonePattern` accepts `+`, digits, spaces, and hyphens, and
the target is compared byte-for-byte (`pending.Target != target` in
`verifyAndConsumeCode`) — there's no server-side normalization. Whatever the
Flutter app actually sends as the phone number (from the two test devices,
typed into the real onboarding UI) is what has to appear in
`TEST_OTP_BYPASS_PHONES`, exact match, including whether it has a leading
`+` or any spaces. Safest path: type the number into the app once with real
Twilio sending (it'll fail at the SMS step, but the request will have
already reached the backend with the exact target string), check
`gcloud run services logs read` for that value, and use that literal string
in the allowlist — don't hand-guess the format.

## Deploy sequencing

This lands as a small addition to Plan 15's Phase 1 (still pre-deploy,
still safe to run anytime) if Phase 2 hasn't gone live yet, or as a
follow-up `gcloud run services replace` if it already has — either way it's
the same code change either way, just different deploy timing depending on
where Plan 15 currently stands.
