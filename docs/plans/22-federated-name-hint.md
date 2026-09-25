# Plan 22 — Use the provider's name on Apple/Google signup (like LinkedIn), without ever letting a later LinkedIn connection silently overwrite it

## Context

ADR-014's federated signup design already treats Apple/Google/LinkedIn as symmetric on paper: `CompleteFederatedSignup` and `CompleteLinkedInOnboarding` both call the one shared `ResolveOrCreateIdentity`, and both already pass a `name` through to `repository.NewUser.FullName` at account creation (`service.go:67`, `service.go:106`). For Google this already works end-to-end — Google's id_token carries a standard OIDC `name` claim, which `identity.jwksProvider.Verify` parses into `VerifiedIdentity.Name` (`identity.go:64,105,223`) and which flows straight into the new user's `FullName`.

**Apple is the one place this silently does nothing**, and it's a real, fixable gap, not a platform limitation dressed up as one. Apple's `id_token` never carries a name claim at all (Apple's own privacy design) — `http_auth_service.dart:194-206` already documents this correctly. But Apple's native SDK *does* hand the app `AuthorizationCredentialAppleID.givenName`/`.familyName` out-of-band, on the credential object itself, on the user's very first authorization only. The current code reads `credential.identityToken` and throws everything else away — so a real name Apple did offer is being discarded, not genuinely unavailable. That's the bug this plan fixes.

Separately, Shashika raised a real regression risk while this was being designed: **connecting LinkedIn later (Profile → Connect LinkedIn) must never silently overwrite a name a user already has** (e.g., one that came from this new Apple hint, or one the user typed in by hand via profile self-editing, ADR-023). I checked this against source before writing anything: `LinkIdentityToUser`'s LinkedIn branch (`identity_resolution.go:135-143`) only ever calls `UpdateLinkedInSub` — it does not touch `FullName` today. **This is not a live bug** — but it's exactly the kind of guarantee that's easy to break by accident in a future change (e.g., someone "helpfully" wiring LinkedIn's name into the link path the same way signup does it), so this plan makes it explicit and tested, and adds the better version of what Shashika suggested: ask, never auto-overwrite.

## Decision

### 1. Apple's one-time name, captured and sent as a fallback hint only

- `frontend/lib/core/services/http_auth_service.dart`'s `signInWithApple`: read `credential.givenName`/`credential.familyName` right after obtaining the credential (they're already being requested via `AppleIDAuthorizationScopes.fullName` — just never read). Join into a single trimmed string (empty if both are null/blank).
- Pass this to `_completeFederatedSignup` as a new optional parameter, sent in the POST body as `full_name_hint` (empty string when unavailable — simple, always-present field, no null-handling needed on either side).
- Backend (`service.go`'s `CompleteFederatedSignup`, around line 268-274): compute `name := verified.Name; if name == "" { name = req.FullNameHint }` and pass `name` to `ResolveOrCreateIdentity` in place of `verified.Name`. **`ResolveOrCreateIdentity`'s own signature does not change** — this is a call-site-only change.
- This hint is never trusted for anything security-sensitive (identity, trust level, email) — only ever a display-name fallback for a *brand-new* account, at the exact moment of creation. It's no more sensitive than what a user could type into the profile-editing screen thirty seconds later (ADR-023 already lets them do that), so accepting client-supplied text here doesn't cross any trust boundary this app doesn't already cross elsewhere.
- Reuse whatever length/character validation the profile self-edit name field already applies — don't invent a new rule for this one.

### 2. LinkedIn linking never silently overwrites the name — made explicit, tested, and given a real "ask" path

- Add an explicit code comment on `LinkIdentityToUser`'s LinkedIn branch stating this guarantee in words, so it can't be "fixed" away by accident later.
- Add a regression test: link LinkedIn to an existing user who already has a `FullName` set (from an Apple hint or hand-typed edit) with a *different* name on the LinkedIn side — assert `FullName` is unchanged after linking.
- Add the better version of Shashika's suggestion — offer, never impose: `LinkIdentity`'s LinkedIn branch already fetches LinkedIn's `info.Name` before calling `LinkIdentityToUser`. After a successful link, compare it to the user's current `FullName`; if they differ (and LinkedIn's isn't empty), include a new, purely additive field on the response — `SuggestedNameUpdate` (empty when there's nothing to suggest, i.e. names already match or LinkedIn had none). Existing API consumers that ignore an unknown field see no behavior change.
- Frontend: the Profile page's "Connect LinkedIn" success handling shows a one-time dialog when `suggested_name_update` is present and non-empty: *"LinkedIn shows your name as {X} — update your profile to match?"* Yes calls the **existing** profile self-edit update-name endpoint (no new write path — ADR-023 already built this); No/dismiss does nothing and never asks again for that same link event. This is the "ask" option Shashika floated, built on infrastructure that already exists rather than a new mutation path.

## What this deliberately does not do

- Does not change Google's behavior at all — Google's JWT already carries a name, so `verified.Name` is always used when present; the hint is Apple-only in practice (the fallback logic only engages when the JWT name is empty, which today only happens for Apple).
- Does not add any new database column — `FullName` already exists and is already writable via the existing self-edit path; this plan only adds one new *optional, additive* response field.
- Does not touch trust-level computation, identity resolution's cross-user collision handling, or anything else ADR-014 already got right.

## Related

ADR-014 (federated identity), ADR-023 (profile self-view editing) — [[Trust Levels]] governs none of this (name is display-only, never a trust signal).
