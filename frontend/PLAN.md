# Onboarding Rebuild — Execution Plan

Give this whole file to Claude Code as the task brief, same as `backend/PLAN.md` was. Built from [[Feature Build Plan Template]] in the vault, applied to the frontend side of the already-shipped LinkedIn onboarding slice (ADR-011, `backend` commit `b727986`). This is a consolidated rewrite (2026-08-16) folding in decisions made after the first draft — session storage scope, the LinkedIn redirect-URL mechanics, and a small backend correction — rather than a patch on top of it.

**Status (2026-08-17): Steps 0-11 executed, uncommitted.** `auth-bridge/` is deployed (`https://professional-meetups-976d2.web.app`, registered with LinkedIn, matches `backend/.env`'s `LINKEDIN_REDIRECT_URI`). Cowork rechecked the actual diff, not just the file list — solid overall (real PKCE `state` verification, idempotent sign-out, fail-safe session loading). **Step 1's `LaunchMode` recommendation below is superseded — `http_auth_service.dart` uses `LaunchMode.externalApplication`, and that's the confirmed, correct choice, not a deviation.** RFC 8252's actual requirement is narrower than "use an in-app browser tab": don't use an embedded WebView the host app can inspect. Both `externalApplication` (full switch to Safari/Chrome) and `inAppBrowserView` (in-app sheet) satisfy that — the difference between them is UX only (app-switch feel + no cookie-sharing vs. an in-app sheet + possible SSO), not security, and `externalApplication` is both simpler and more predictable across Android OEM browser variants than Custom Tabs support tends to be. Keep it as implemented. **Step 11's trust microcopy and its widget test are implemented in `onboarding_flow.dart`/`onboarding_flow_test.dart`, confirmed against the actual `openid profile email` scope in `http_auth_service.dart` — accurate, not stale.** **Steps 12-14 are new (2026-08-17), not yet built.**

**Correction (2026-08-17), after real-device testing against actual LinkedIn accounts:** PKCE (`code_challenge`/`code_verifier`), referenced throughout this plan (Step 1's `crypto` dependency, Step 5's flow description, Step 9's test list, Step 10's checklist), has been **removed**. LinkedIn's Sign In with LinkedIn / OpenID Connect product rejects the token exchange with `401 invalid_client` when PKCE parameters are present — confirmed by hand-building the full OAuth round trip outside the app and hitting LinkedIn's real token endpoint directly via curl: identical requests succeed with PKCE omitted, fail with it included. See `backend/PLAN.md`'s matching correction note for the full detail and the security tradeoff analysis (still safe: this is a confidential client, secret never leaves the backend). `state` generation/CSRF-verification is unaffected and still required — only the `code_challenge`/`code_verifier` pair is gone. The former `Pkce` class (`lib/core/services/pkce.dart`) is now `OAuthState` (`lib/core/services/oauth_state.dart`), reflecting its narrower remaining purpose.

**Read `backend/ARCHITECTURE.md` and the REST contract in `backend/PLAN.md` Step 5 before starting** — this plan assumes that contract, doesn't repeat it.

**Addendum (2026-08-17): Steps 12-14 below, added after basic onboarding was confirmed working end to end on a real device.** Session-restore-on-launch (`SplashScreen` → `authSessionProvider` → `AppShell`) was already built as part of Steps 0-10 and needs no new work — confirmed reading the actual code, not re-specified here. What's actually missing: a confirmation step before sign-out, `HomePage`/`HomeHeader` hardcoding the user's name and never showing a real profile photo, and `ProfilePage`'s LinkedIn verification row being stale now that real sign-in works. **Company name from LinkedIn is explicitly out of scope, by Shashika's decision (2026-08-17)**: LinkedIn's self-serve "Sign In with LinkedIn using OpenID Connect" product's `userinfo` response has no employer/company field at all — that requires LinkedIn's Partner Program (Marketing Developer Platform), a manual approval process, not a config change. Do not add a company field anywhere in this pass, self-reported or otherwise, unless separately asked.

## Scope boundary — read this first

This replaces `lib/features/onboarding/onboarding_flow.dart`'s current phone → LinkedIn-URL-paste → corporate-email flow (the pre-ADR-006 model, flagged in `CLAUDE.md`'s "Known Gaps") with a real LinkedIn federated (Level 1a) OAuth flow wired to the actual backend at `POST /v1/auth/linkedin/callback` / `/v1/auth/refresh` / `/v1/auth/logout`, plus wiring `ProfilePage`'s already-present "SIGN OUT" stub to actually end the session.

**Do not build**: phone OTP verification, personal email verification, personal details capture (Level 2), corporate email verification (Level 3), KYC (Level 4), or the Level 1b "paste a LinkedIn URL" fallback. None of those have backend support yet (ADR-011 scoped the backend to Level 1a only) — building frontend UI for them now would either dead-end against a nonexistent endpoint or, worse, fake success client-side. If asked to extend into any of these, stop and flag it rather than mocking a response, the same rule `backend/PLAN.md` used.

This does mean the onboarding flow gets *simpler* than what's there today, not more complex: one real verification step (LinkedIn), not four.

**Web is explicitly out of scope for session persistence, confirmed 2026-08-16.** `flutter_secure_storage`'s web implementation wraps browser storage (localStorage/IndexedDB) — readable by any JS on the page, not equivalent to Keychain/Keystore. ADR-009 already decided web should get httpOnly cookies instead, which needs gateway changes (platform-aware token issuance) that don't exist yet, plus a web-compatible OAuth redirect. None of that is this slice. Build for iOS/Android only; the web target simply won't have a persisted session until its own slice does that backend work.

## Step 0 — Prerequisites (human, not Claude Code)

1. Confirm the backend stack runs locally (`cd backend && docker compose up --build`) — this plan is worthless to test against without it.
2. **Deploy `auth-bridge/` and register its URL with LinkedIn.** LinkedIn requires an absolute `https://` redirect URL — it will not accept a custom URL scheme (`professionalconnections://...`) directly in the portal. `auth-bridge/index.html` is already built: a branded (matches `AppPalette`), zero-server-logic page that forwards LinkedIn's query string to the app's custom scheme, with a tap-to-continue fallback for browsers that block script-triggered custom-scheme redirects. Deploy it per `auth-bridge/README.md` (Firebase Hosting recommended — free, stays inside the existing GCP project):
   ```bash
   npm install -g firebase-tools
   firebase login
   cd auth-bridge
   firebase init hosting   # public directory: "." (this folder)
   firebase deploy
   ```
   That gives a stable URL like `https://<project-id>.web.app/`. **That's what gets registered as the LinkedIn app's Redirect URL** — go to the LinkedIn Developer Portal → your app → Auth tab → Redirect URLs, add it. It's also the exact `redirect_uri` value the app sends in both the authorization request (Step 5 below) and the `POST /v1/auth/linkedin/callback` call, since OAuth requires the same value at both steps, and it doesn't change between local and production backend environments since this page never talks to the backend at all. The custom scheme itself is only ever registered inside the app (Step 2 below) — LinkedIn never sees it.
3. Update `backend/.env`'s `LINKEDIN_REDIRECT_URI` to match the deployed bridge URL, for consistency.
4. Decide the gateway base URL per run target now, not later: `http://localhost:8080` for iOS simulator, `http://10.0.2.2:8080` for Android emulator (`backend/README.md`'s documented gotcha — get this wrong and requests just hang). Step 4 below wires this as a build-time config, not a hardcoded constant.

Claude Code should confirm the backend is actually reachable (`curl localhost:8080` or similar) before writing the client that talks to it — don't build blind against a contract nobody's confirmed is live.

## Step 1 — New dependencies

Add to `frontend/pubspec.yaml`:
- `flutter_secure_storage` — Keychain/Keystore-backed storage for the access/refresh token pair (ADR-009: mobile clients use OS secure storage, never `SharedPreferences`, never cookies).
- `http` — REST calls to the gateway. Matches the backend's own "standard library first, no framework" preference; no need for `dio`'s extra surface at this API size.
- `app_links` — receives the custom-URL-scheme redirect from LinkedIn's browser flow back into the app.
- `url_launcher` (^6.3.2+) — opens LinkedIn's authorization URL via `LaunchMode.externalApplication` — **not** `LaunchMode.inAppWebView`, and this is a deliberate, confirmed choice (see Status note above), not an oversight. The security line RFC 8252 (OAuth for native apps) actually draws is: never an embedded WebView the host app can inspect — `externalApplication` (full switch to the system browser) satisfies that just as well as an in-app browser tab does, and LinkedIn (or any OAuth provider) may detect and block an embedded-WebView-originated auth request outright regardless of which side of that line you're on. `inAppBrowserView` (`SFSafariViewController`/Chrome Custom Tabs) was considered for its smoother in-app feel and cookie-sharing SSO benefit, but `externalApplication` is simpler and more predictable across Android OEM browser variants, and is the more common pattern in practice — kept as the implementation.
- `crypto` — SHA-256 for the PKCE `code_challenge` (`BASE64URL(SHA256(code_verifier))`, per `backend/PLAN.md` Step 4).

## Step 2 — Platform config for the redirect deep link

Register the custom URL scheme on **both** platforms — this is separate from the usage-description-keys gap already flagged in `CLAUDE.md` (that's for camera/location; this is for the OAuth redirect to reach the app at all):
- **iOS** (`frontend/ios/Runner/Info.plist`): add a `CFBundleURLTypes` entry for the `professionalconnections` scheme.
- **Android** (`frontend/android/app/src/main/AndroidManifest.xml`): add an `intent-filter` on the launch activity for the same scheme.

## Step 3 — Small backend addition: return `full_name`/`profile_photo_url`

**This step touches `backend/`, not `frontend/` — flag it as such in the PR.** `services/auth`'s `CompleteLinkedInOnboarding` already fetches `info.Name`/`info.Picture` from LinkedIn and stores them on the `users` row, but `SessionResponse` (`.proto`) and the gateway's `sessionResponse` struct/`sessionFromClient` mapping never surface them to the client — confirmed against the actual code, not assumed. There is no `GET /v1/users/me` and no other way for the app to ever learn a user's name or photo without this.

Add `full_name` and `profile_photo_url` as top-level fields to `SessionResponse` in `backend/proto/auth/v1/auth.proto`, regenerate via `buf` (same as `backend/PLAN.md` Step 2), thread the values through `services/auth/internal/service/service.go`'s `issueSession`/`CompleteLinkedInOnboarding`, and add the corresponding fields to `services/gateway/internal/handlers/handlers.go`'s `sessionResponse` struct and `sessionFromClient` mapping. Small, contained: no new data collection (both values are already fetched and stored), no schema change, no new security surface.

**Deliberately not the JWT.** `trustLevel` belongs in the token (Step 5 below explains why); a name and a photo URL don't — they'd bloat every single authenticated request for data that's only ever needed once, at session establishment. `SessionResponse` is exactly the right scope for that.

Update `backend/ARCHITECTURE.md`'s REST contract description and add a test asserting the new fields round-trip, same rigor as the rest of that slice's test suite.

## Step 4 — `lib/core/config/` — environment-aware backend URL

New: a small `AppConfig` (or extend if something equivalent already exists) exposing the gateway base URL, switched via `--dart-define=GATEWAY_BASE_URL=...` at build/run time — **not** a hardcoded `localhost:8080` in the service implementation. This is what Step 0.4's per-platform URL actually gets wired through; a hardcoded value here is the single most likely thing to make this "work on my simulator, silently time out on my Android emulator."

## Step 5 — `lib/core/services/` — the real auth service

`AuthService`'s current interface (`requestPhoneOtp`, `verifyPhoneOtp`, `connectLinkedIn(profileUrl)`, `verifyCorporateEmail`) doesn't match what the backend actually does — it was written against the pre-ADR-006 model. Replace it with an interface scoped to what Level 1a actually supports:

```dart
abstract interface class AuthService {
  Future<AuthSession> signInWithLinkedIn();
  Future<AuthSession> refreshSession(String refreshToken);
  Future<void> logout(String refreshToken);
}
```

Don't leave the old phone/corporate-email methods on the interface returning "not implemented" — that's worse than not having them. They come back when the Level 2/3 backend slices exist and get their own frontend plan then, per this project's established scope discipline.

- **New `AuthSession` model** (`lib/core/models/auth_session.dart`): `userId`, `accessToken`, `refreshToken`, `fullName`, `profilePhotoUrl`, `isNewUser`, `accessTokenExpiresAt` (computed from `expires_in`) — `fullName`/`profilePhotoUrl` assume Step 3 has landed.
- **`trustLevel` is not a top-level field in `SessionResponse`** — it only exists inside the signed JWT access token's claims (`shared/jwt.Claims`). Decode it client-side from the access token's payload (plain base64url JSON — no signature verification needed or wanted here, the backend is the actual enforcement point on every real request) in exactly one small, clearly-named function, and treat the result as display-only state, never a client-side gating decision. This naturally stays current too: every token refresh re-reads `trustLevel` from the DB, so the decoded value updates on its own roughly every 15 minutes.
- **`UserProfile` needs a look too**: its current shape (`isPhoneVerified`, `isWorkEmailVerified`, etc.) assumes the old model. For this slice, a user is either Level 1a-onboarded or not — simplify to what the backend actually gives you (`id`, `fullName`, `profilePhotoUrl`, `headline`, `trustLevel`), noting in a comment that phone/work-email fields return when those slices exist server-side.
- **`signInWithLinkedIn()` implementation** (e.g. `lib/core/services/http_auth_service.dart`) orchestrates the full sequence from `backend/PLAN.md` Step 4's client side: generate `code_verifier` (cryptographically random, 43-128 chars) + `state`, compute `code_challenge`, build LinkedIn's authorization URL (with `redirect_uri` set to the deployed HTTPS bridge from Step 0.2, not the custom scheme), open it via `launchUrl(..., mode: LaunchMode.externalApplication)` (Step 1), listen for the `app_links` redirect. The browser visits the HTTPS bridge page first, which immediately forwards to the custom scheme — `app_links` only ever sees that final `professionalconnections://...` URL. **Verify the returned `state` matches what was generated before doing anything else** (this is the CSRF protection PKCE's `state` param exists for — skipping this check defeats the point of having it), then POST to `/v1/auth/linkedin/callback` with the code/verifier/**the same HTTPS bridge `redirect_uri`** (OAuth requires the identical value used in the authorization request), parse the response into `AuthSession`.
- **`refreshSession`/`logout`** are thin — POST to their respective endpoints, parse/discard the response.
- Map the gateway's error responses (400 invalid/expired code or PKCE mismatch, 429 rate limited) to a typed exception the UI can show a real message for — not a generic "something went wrong" for a 429 specifically, the user should know to wait.

## Step 6 — `lib/core/storage/` — secure session storage

A small wrapper around `flutter_secure_storage` — `saveSession`, `loadSession`, `clearSession`. Stores the token pair and the cached `fullName`/`profilePhotoUrl` — never anything else. This is the one place tokens ever touch disk — no service or widget should call `flutter_secure_storage` directly.

## Step 7 — Session state — Riverpod provider

New provider (e.g. `authSessionProvider`, an `AsyncNotifier`) that on first read checks secure storage for an existing session and exposes whether the app is "logged in." This is genuinely new — nothing today tracks a logged-in user across app restarts at all (`app_providers.dart` has no session/current-user provider currently, and `SplashScreen` unconditionally goes to `LandingPage`). Without this, every app relaunch would force a fresh LinkedIn login, which defeats the entire point of a 30-day refresh token.

## Step 8 — Wire it into navigation

- **`SplashScreen`**: after its existing minimum display duration, check `authSessionProvider` instead of unconditionally routing to `LandingPage`. Valid/refreshable session → `AppShell` directly. No session → existing `LandingPage` flow.
- **`OnboardingFlow`**: collapses from the current 4-step wizard (welcome → phone → LinkedIn → email) to two states — a welcome/intro screen (keep the existing one, it's fine) and a single "Continue with LinkedIn" action that calls `authService.signInWithLinkedIn()`, shows a loading state for the out-of-app browser round trip, saves the resulting session (Step 6), and navigates to `AppShell` on success. On failure, show the mapped error (Step 5) and let them retry — don't silently fall back to anything.
- Update `app_providers.dart`: `authServiceProvider` now provides the real `HttpAuthService`, not `MockAuthService`, once this is wired and tested. Keep `MockAuthService` in the codebase for widget tests (Step 9) rather than deleting it.
- **`ProfilePage`'s "SIGN OUT" button** (`lib/features/profile/profile_page.dart`) is currently a stub — its `onTap` just shows a snackbar saying sign-out "will be wired to the auth service." Wire it for real: call `authService.logout(refreshToken)`, then `clearSession()` (Step 6) regardless of whether the network call succeeds (a failed logout call to the backend shouldn't leave the user stuck signed in locally — clear the local session either way, per the same idempotent-logout spirit as the backend's `/v1/auth/logout`), then navigate back to `LandingPage`, clearing the nav stack so back-button can't return to `AppShell`. This is what makes the whole flow testable end-to-end: sign in with LinkedIn → land in `AppShell` → tap Sign Out → confirm you're actually back at the start with no session left in secure storage.

## Step 9 — Tests

- **Unit**: ~~PKCE `code_challenge` generation against a known verifier/expected-output pair~~ superseded — PKCE removed 2026-08-17, see the correction note at the top of this file; `oauth_state_test.dart` covers `state` freshness instead. Secure-storage wrapper round-trip. `AuthSession`/`UserProfile` parsing from a sample JSON response, including the error-response shapes (400/429). JWT-claims-decode function against a known token.
- **Widget**: `OnboardingFlow` against a fake `AuthService` (mirrors the backend's own fakes-in-tests pattern) — success path navigates to `AppShell`, failure path shows the error and stays put, loading state disables the button so a slow tap can't double-fire the flow. `ProfilePage`'s sign-out path similarly.
- **Backend (Step 3)**: a test asserting `full_name`/`profile_photo_url` actually round-trip through `SessionResponse`.
- **Manual, not automatable here**: the actual out-of-app browser round trip and deep-link redirect — note in the PR description that this was exercised manually against the local `docker compose` stack, since it can't run headless in `flutter test`.

## Step 10 — Self-review checklist (do this before calling it done)

- [ ] Access/refresh tokens only ever touch `flutter_secure_storage` — grep for any `SharedPreferences`/plain-file/log usage of either.
- [ ] `state` is actually verified before the authorization code is used for anything — not just generated and ignored.
- [ ] LinkedIn's authorization URL opens via a real external user-agent (`LaunchMode.externalApplication`, as implemented) — grep for `inAppWebView` specifically and confirm it never snuck in; that's the one mode that's actually disallowed (an embedded, host-app-inspectable WebView), not a style preference between the other two.
- [ ] ~~`code_verifier` is freshly random per attempt, never reused across sign-in attempts.~~ Superseded 2026-08-17 — PKCE removed entirely (LinkedIn's Sign In with LinkedIn / OpenID Connect product rejects the exchange with it present; see `backend/PLAN.md`'s correction note). `state` freshness/CSRF-verification still applies and is unaffected.
- [ ] Gateway base URL is never hardcoded — confirm both the iOS-simulator and Android-emulator values actually work by running on both, not just reading the code.
- [ ] A 429 from the gateway shows a distinct "you're being rate limited, try again shortly" message, not a generic error.
- [ ] `trustLevel` decode is display-only — grep for anywhere it might be used to gate a client-side decision instead of just showing a badge/label.
- [ ] `full_name`/`profile_photo_url` genuinely round-trip end to end — sign in for real and confirm they show up in `ProfilePage`, not just that the backend test passes in isolation.
- [ ] Full loop actually exercised on both a real/simulated iOS and Android target: sign in with LinkedIn → land in `AppShell` → tap Sign Out in `ProfilePage` → confirm you're back at `LandingPage` with no session left in secure storage (inspect via the device's Keychain/Keystore tooling, not just "the UI looks logged out").
- [ ] `flutter analyze` and `dart format --set-exit-if-changed .` both clean from `frontend/`; `go vet`/`golangci-lint`/`go test` clean for the Step 3 backend change.
- [ ] `flutter test` and `go test` both pass, including the new tests above.
- [ ] Bring the diff back to Cowork for review before merging — same discipline as the backend slice.

## Step 11 — Trust microcopy above the LinkedIn button

Right now `OnboardingFlow._welcomeStep()` goes straight from the headline/subtext into the "CONTINUE WITH LINKEDIN" button with no explanation of *why* LinkedIn specifically, or what it does and doesn't access — the pattern professional/verification-focused apps use here (and this app's own [[Trust Levels]]/[[Vision]] positioning calls for) is a short reassurance line directly above the auth button, not buried in a settings page or omitted entirely.

Add a small `Text` block between the subtext and the `GradientButton`, in `AppPalette.textSecondary`, smaller/lighter than the body copy above it, center-aligned to match. Content should do two things concretely, not just gesture at "trust": state the actual reason (confirms real professional identity, which is what makes the network safe to meet strangers from), and pre-empt the most common LinkedIn-OAuth worry (that it'll post on your behalf or spam your connections) — **this claim must stay accurate to the actual requested scope**, which is `openid profile email` only (confirmed in `http_auth_service.dart`) — no posting or connections access is requested at all, so it's a true statement, not marketing copy.

Suggested copy (adjust tone freely, keep the two claims):

> We verify your LinkedIn to confirm you're a real, working professional — the foundation of a safer community. We never post on your behalf or access your connections.

Test: a widget test asserting this text renders on `OnboardingFlow`'s welcome step. Self-review addition: if the requested OAuth scope in `http_auth_service.dart` ever changes, this copy must be revisited in the same PR — don't let it silently go stale and become an inaccurate claim.

## Step 12 — Logout confirmation dialog

`ProfilePage._signOut` (Step 8 above) currently signs out immediately on tap — no confirmation, so a mis-tap ends the session. Add a confirmation step before calling `authSessionProvider.notifier.signOut()`: a standard `showDialog`/`AlertDialog` (or the app's existing `Glass`-styled modal pattern if one already exists elsewhere in `core/widgets` — check before introducing a second dialog style) with a short message ("Sign out of Professional Connections?") and two actions, Cancel and Sign Out (destructive-styled, `AppPalette.danger` to match the existing SIGN OUT button's tint). Only proceed with the existing sign-out logic (clear session, navigate to `LandingPage`, clear nav stack) if the user confirms. Cancel just dismisses — no state change.

Test: a widget test confirming tapping SIGN OUT shows the dialog without clearing the session, tapping Cancel leaves the session intact, and tapping the confirm action actually signs out (reuse the existing sign-out widget test's fake `AuthService`/session setup, just gate it behind the extra tap).

## Step 13 — Homepage personalization

`HomePage` (`lib/features/home/home_page.dart`) hardcodes `const HomeHeader(userName: 'Shashika Fernando')` — a literal string, not read from any session state. `HomeHeader` (`lib/features/home/widgets/home_header.dart`) also never passes an `imageUrl` to its `ProfessionalAvatar`, even though `ProfessionalAvatar` already supports one (confirmed — `ProfilePage`'s own avatar block already uses it via `profile.profilePhotoUrl`).

Fix both, mirroring the pattern `ProfilePage` already uses:
- In `HomePage`, read `final profile = ref.watch(authSessionProvider).value?.profile;` (same call `ProfilePage` makes) and pass `profile?.fullName` (with the same "Member" fallback `ProfilePage._avatarBlock` uses for null/empty) into `HomeHeader` instead of the hardcoded string.
- Add an `imageUrl` parameter to `HomeHeader`, threaded from `HomePage`, passed through to its `ProfessionalAvatar(size: 44, name: userName, imageUrl: imageUrl)`. `ProfessionalAvatar` already handles a null/empty URL by falling back to initials — no new fallback logic needed there.
- Leave `HomeHeader`'s `_greeting()` time-of-day logic and layout untouched — this is a data-wiring fix, not a redesign.

Test: a widget test that pumps `HomeHeader` with a non-null `imageUrl` and asserts an `Image.network` (or `ProfessionalAvatar`) with that URL is present, and a `HomePage` test (with a fake session provider override) asserting the real name from the fake session appears instead of any hardcoded string.

## Step 14 — Fix stale "LinkedIn: Not connected" row in ProfilePage

`ProfilePage`'s VERIFICATION section (`lib/features/profile/profile_page.dart`) hardcodes the LinkedIn row as `subtitle: 'Not connected'` with a tappable "VERIFY" chip — left over from before real LinkedIn sign-in existed. This is now actively wrong: every user on this screen signed in with LinkedIn to get here, by definition. Change the LinkedIn row to reflect actual state: `subtitle: 'Connected'` (or similar) with no "VERIFY" chip — replace the chip with a static checkmark/connected indicator (there's no re-verification action to offer, since sign-in already happened). Leave the Phone and Work Email rows exactly as they are (still genuinely "Not verified" — those slices don't exist server-side yet, per this plan's scope boundary).

Test: a widget test asserting the LinkedIn row shows "Connected" with no tappable "VERIFY" chip, while Phone/Work Email rows are unchanged.

## Step 15 — Self-review checklist for Steps 12-14

- [ ] Sign-out cannot happen without an explicit confirm tap — verify Cancel actually leaves the session in secure storage untouched (inspect via device Keychain/Keystore tooling, not just the UI).
- [ ] `HomePage`/`HomeHeader` show the real signed-in user's name and photo on a real device — not just that a fake-provider widget test passes.
- [ ] No hardcoded name/photo strings remain anywhere in `features/home/` — grep for `'Shashika Fernando'` specifically to confirm it's gone.
- [ ] The LinkedIn row's new "Connected" state is genuinely conditional on `authSessionProvider` reflecting a real session, not just a permanently-flipped hardcoded string (i.e., it's not literally the same class of bug it's replacing).
- [ ] No company-name field or UI was added anywhere in this pass — this was explicitly deferred, not built.
- [ ] `flutter analyze` and `dart format --set-exit-if-changed .` clean; `flutter test` passes including the three new widget tests above.
- [ ] Bring the diff back to Cowork for review before merging.

## Explicitly not in this slice

Level 1b (pasted-URL LinkedIn), phone/personal-email/personal-details
(Level 2) UI, corporate email (Level 3) UI — **superseded by the addendum
below, now in scope** — KYC (Level 4) UI, general profile editing, any
matching/chat/safety-gate UI, and company/employer name anywhere in the UI
(not available without LinkedIn Partner Program access; deferred
2026-08-17, don't self-report it either without being asked). Flag rather
than build if asked to extend into any of these without an explicit
go-ahead.

---

# Addendum (2026-08-17): Level 2/3 Verification Slice

Companion to `backend/PLAN.md`'s matching addendum — **read that first**,
this assumes its REST contract (`/v1/verification/*`, `GET /v1/users/me`)
exists. Builds phone/personal-email/personal-details (Level 2) and
corporate email (Level 3) UI, all skippable, all reachable again later from
`ProfilePage`, per ADR-012 (already Accepted).

**Sequencing note**: build this only after Steps 12-15 above are merged —
both touch `app_providers.dart` and `ProfilePage`, and two Claude Code
sessions editing the same files concurrently is asking for a bad merge.

## Scope boundary for this addendum

Build: a 4-step post-LinkedIn flow (phone → personal email → personal
details → corporate email), each step individually skippable via a visible
"Skip for now" action plus a short trust-benefit line, not a hard gate; the
same four flows reachable independently from `ProfilePage` for a user who
skipped and wants to finish later; a real `UserProfile` sourced from `GET
/v1/users/me` instead of only the one-time LinkedIn callback fields.

**Do not build**: KYC/Level 4 UI, profile *editing* (changing an
already-verified phone/email/name — first-time capture only), any
alternate login path via phone or email (LinkedIn stays the only sign-in
method — these screens verify trust attributes on an already-authenticated
session, they never authenticate on their own), a company-name field
(still deferred, see above), the meetup feature (separate plan, later).

## Step 1 — No new platform-auth dependency needed

**Superseded by ADR-012's 2026-08-17 correction** — phone verification no
longer goes through Firebase. It's a plain gateway call, identical in
shape to personal/corporate email verification (Step 4 below). No
`firebase_core`/`firebase_auth`, no Firebase project config in the app —
every screen in this addendum talks only to this app's own gateway, no
exception.

## Step 2 — `AuthService`: new methods

Extend the interface from Step 5 of the original plan:

```dart
abstract interface class AuthService {
  // existing: signInWithLinkedIn, refreshSession, logout

  Future<int> startPhoneVerification(String phoneNumber);      // returns resend_after_seconds
  Future<AuthSession> verifyPhoneCode(String phoneNumber, String code);
  Future<int> startPersonalEmailVerification(String email);   // returns resend_after_seconds
  Future<AuthSession> verifyPersonalEmailCode(String email, String code);
  Future<AuthSession> submitPersonalDetails(String legalName, String address);
  Future<int> startCorporateEmailVerification(String email);
  Future<AuthSession> verifyCorporateEmailCode(String email, String code);
  Future<UserProfile> getProfile();
}
```

Every verification-completing call returns a fresh `AuthSession` (backend
reissues the access token with the updated `trust_level` — see backend
addendum Step E) — **save it via `SecureSessionStorage` and update
`authSessionProvider`'s state immediately**, the same way a token refresh
already does, so the UI reflects the new trust level without waiting for
the next natural refresh.

**Gap worth catching now rather than at review time**: `AuthSession`
(token pair + `trust_level`) and `UserProfile` (the per-field booleans —
`phoneVerified`, etc., Step 3) are two different response shapes from two
different calls. Updating `AuthSession` alone after a successful verify
leaves `UserProfile`'s booleans stale until the next full `getProfile()`
fetch — meaning `ProfilePage`'s Phone row could still show "Not verified"
immediately after phone verification actually succeeded, right after the
trust-level badge elsewhere already updated. Fix: call `getProfile()`
again immediately after any verification-completing call succeeds (in
addition to saving the fresh `AuthSession`), so both pieces of state
move together. Don't try to hand-patch just the one boolean that changed
locally — a real re-fetch is simpler and can't drift from the server.

Map the gateway's "please wait, resend cooldown active" error (backend
Step F) to a distinct exception the UI uses to keep the countdown timer
in sync with the server's actual value rather than trusting the client's
own clock alone. Separately, map `StartCorporateEmailVerification`'s
domain-rejection error (backend Step F — a free/role-based email domain)
to its own distinct exception too, so `corporate_email_verification_page`
can show "please use your work email, not a personal address" instead of
a generic failure message.

## Step 3 — `UserProfile`: extend for real verification state

Add: `bool phoneVerified`, `bool personalEmailVerified`, `bool
personalDetailsComplete`, `String? companyDomain`, `bool
workEmailVerified`. Sourced from `getProfile()` (Step 2) — **never** the
raw phone number or email address, matching the backend's deliberate
choice not to send them over the wire (Verification Model § 1's "never
reveal a user's full phone number" rule). `authSessionProvider` should
call `getProfile()` once on session load (alongside its existing
secure-storage read) so `ProfilePage`/onboarding both see real state
immediately, not just after a user manually triggers a fetch.

## Step 4 — New screens: `lib/features/verification/`

One new feature folder, four screens plus a shared OTP-entry widget (don't
duplicate the OTP-input-plus-timer UI four times):

- `phone_verification_page.dart` — phone number entry (with a country-code
  picker defaulting to `+94`, per the Sri Lanka launch market — see
  `docs/00-project/vision.md`) → the shared OTP widget below, identical
  shape to the email screens: calls `startPhoneVerification`, shows the
  "we sent a code" toast, then `verifyPhoneCode`.
- `personal_email_verification_page.dart` — email entry → shared OTP
  widget. Calls `startPersonalEmailVerification` (show the toast: "We sent
  a code to <email>" via the existing `showSnack`/`toast` utilities,
  already used elsewhere in the app — don't introduce a second toast
  mechanism), then `verifyPersonalEmailCode`.
- `personal_details_page.dart` — legal name + address text fields, no
  OTP (self-reported, Verification Model § 4). Calls `submitPersonalDetails`.
- `corporate_email_verification_page.dart` — same shape as personal email,
  against the corporate-email endpoints. Client-side hint (not
  enforcement — the backend is the real check, per Verification Model §
  5's free/role-based rejection): a small inline note if the entered
  address looks like a free-mail domain, before they even submit.
  **Copy requirement, not optional polish** (ADR-012's 2026-08-17 note,
  [[Verification Model]] § 5): this MVP only proves the user controls a
  mailbox on the domain they entered — it does not check the domain
  belongs to a real employer, so a fresh lookalike domain
  (`acme-hr.com` for real company `acme.com`) passes cleanly. The success
  state and trust-benefit line must not imply company legitimacy was
  checked — say something like "Email ownership confirmed" or "Work email
  verified," never "Company verified" or anything implying the employer
  itself was validated.
- **Shared `lib/features/verification/widgets/otp_entry.dart`** — 6-digit
  code input, a countdown timer seeded from the server's
  `resend_after_seconds` (Step 2), a disabled "Resend" action until the
  timer hits zero, an error state for a wrong/expired code that doesn't
  reset the timer (a wrong guess shouldn't give a free timer reset).

Each screen has a **"Skip for now"** action (top-right or bottom, following
whatever pattern reads clearest — not hidden) and a short trust-benefit
line matching Step 11's precedent (accurate to what the step actually
does, not generic marketing copy) — e.g. phone: "Verifying your number
unlocks messaging other members and helps keep the community
scam-resistant." Reuse `AppPalette`/`Glass`/`GradientButton` throughout —
no new visual language for these four screens.

## Step 5 — Flow orchestration after LinkedIn success

`OnboardingFlow._continueWithLinkedIn` currently navigates straight to
`AppShell` on LinkedIn success. Change it to navigate into a small
sequential flow instead — phone → personal email → personal details →
corporate email, in that order, each screen's Skip **or** Continue both
advance to the next step (skip just doesn't call the verify RPC first) —
landing in `AppShell` after the fourth step either way. Keep this
navigation logic simple (a `PageView` or a plain step-index `Navigator`
push chain, whichever is less code) — this is not a wizard with
back-navigation or progress-saving mid-flow; if the app is killed
mid-sequence, the user lands back in `AppShell` next launch (session
already exists post-LinkedIn) and finishes any skipped steps from
`ProfilePage` instead (Step 6).

## Step 6 — Wire `ProfilePage`'s VERIFICATION section to the real flows

`ProfilePage`'s VERIFICATION section (already restructured by Step 14
above to show LinkedIn as "Connected") needs, for Phone and Work Email:
replace the `_verifyChip`'s current stub (`showSnack('$name verification
flow will be built next.')`) with real navigation to the corresponding
Step 4 screen, and swap the row's subtitle/chip to a "Verified" state
(matching Step 14's LinkedIn-row treatment) once `UserProfile` (Step 3)
reports it as done. **Add two new rows** that don't exist in `ProfilePage`
today: **Personal Email** and **Personal Details** — same `_Row` pattern,
same VERIFY-chip-until-done treatment. All four rows should independently
open exactly the same screen Step 5's onboarding sequence uses — no
second implementation of any of these screens for the "reached from
Profile" case.

**Work Email row's "Verified" subtitle is subject to the same copy
requirement as Step 4's corporate-email screen** — "Email verified" or
similar, not "Company verified" or any phrasing implying the employer
itself was checked. This one's easy to get wrong by copy-pasting the
LinkedIn/Phone rows' pattern without thinking about it — don't.

## Tests

- Unit: `UserProfile` parsing including the four new booleans; OTP-widget
  countdown-timer logic (seeded value counts down, hits zero, enables
  resend); session-update-on-verification-success (a fake `AuthService`
  returning a new `AuthSession`, assert `authSessionProvider`'s state and
  secure storage both reflect it immediately).
- Widget: each of the four verification screens — Skip advances without
  calling verify; a wrong code shows an error and doesn't advance; a
  successful verify advances and (for the onboarding sequence) lands on
  the next step or `AppShell` after the last one. `ProfilePage`'s four
  VERIFICATION rows open the correct screen and reflect "Verified" once
  `UserProfile` says so.
- Manual: a real end-to-end pass through all four screens against the
  local backend stack (with `LoggingSmsSender`/`LoggingEmailSender`, per
  the backend addendum — read the logged code from the backend's console
  output to complete each step) — note this in the PR same as the
  LinkedIn OAuth round trip was noted.

## Self-review checklist

- [ ] No raw phone number or email address is ever displayed back to the
      user from `UserProfile` state — only booleans/derived text ("Phone
      ending in •••1234" is fine if you want that touch, the full number
      pulled from local input state during entry is fine, but nothing
      round-tripped from the backend should include the raw value, since
      the backend deliberately never sends it back (backend addendum Step
      E) — confirm the frontend doesn't invent a workaround, e.g. caching
      the number locally after entry and treating that as "backend-
      confirmed."
- [ ] Skip genuinely skips — no verify RPC fires when Skip is tapped.
- [ ] The resend timer is seeded from the server's `resend_after_seconds`
      on every start, not hardcoded to 60 client-side — confirm by
      checking what happens if the backend ever returns a different value.
- [ ] A verification success immediately updates `authSessionProvider`'s
      state (fresh token, new trust level reflected) — don't rely on the
      next natural token refresh.
- [ ] A verification success also triggers a fresh `getProfile()` call —
      confirm by checking `ProfilePage` right after completing phone
      verification, without navigating away and back: the Phone row
      should already say "Verified," not require an app restart to catch
      up.
- [ ] Submitting a rejected (free/role-based) domain to the corporate
      email screen shows the specific rejection message, not a generic
      error.
- [ ] All four `ProfilePage` VERIFICATION rows are wired to real
      navigation, none still show the old "will be built next" stub.
- [ ] `flutter analyze`/`dart format --set-exit-if-changed .`/`flutter
      test` all clean.
- [ ] All four screens (phone included) were exercised end to end against
      the real local backend stack, not just unit-tested around the edges
      — phone is no longer a special case, hold it to the same bar as the
      email screens.
- [ ] Bring the diff back to Cowork for review before merging.

## Explicitly not in this addendum

KYC (Level 4) UI, profile editing for already-verified fields, phone/email
as an alternate login method, a company-name field, and the meetup feature
— scoped as its own separate plan once this lands, not bundled in here.

## Addendum (2026-08-17): Session refresh wiring fix

**Sequencing: do not start this until the Level 2/3 verification addendum above (Steps 1-6) is merged.** Both touch `http_auth_service.dart` and `app_providers.dart`; stacking a second in-flight diff on the same files invites a messy rebase. This section is written now so it's ready the moment that diff lands — confirm it's merged before starting.

**Bug being fixed, confirmed by reading the actual code (not assumed):** `HttpAuthService.refreshSession()` (`POST /v1/auth/refresh`) is fully implemented and correct, and `AuthSession.accessTokenExpiresAt`/`SecureSessionStorage` already persist everything needed to know when a token is stale. But nothing calls `refreshSession()` — `AuthSessionNotifier.build()` loads the stored session and uses it as-is with no expiry check, and the `getAccessToken` callback wired into `HttpAuthService` (`app_providers.dart`) reads the stored access token directly, also with no expiry check. `SessionExpiredException` is thrown on a 401 in two places (`_parseSessionResponse`, `_mapVerificationError`) but caught nowhere. Net effect: the access token silently goes stale after 15 minutes and every authenticated call from that point starts failing, even though the refresh token is still good for 30 days — exactly the "have to log in again constantly" bug Shashika flagged.

**Design principle carried over from the existing code's own doc comments**: `HttpAuthService` holds no session state of its own — it only reads it via the `getAccessToken` callback. This fix keeps that principle; it doesn't turn `HttpAuthService` into a second place that owns session state.

**The `AuthSessionNotifier.build()`-cannot-self-reference constraint** (see the existing comment above `authServiceProvider` in `app_providers.dart`) still applies: nothing this addendum adds may call `ref.read(authSessionProvider)` or `ref.read(authSessionProvider.notifier)` from inside `AuthSessionNotifier.build()`. The design below only ever touches `sessionStorageProvider` and `authServiceProvider` from that context, same as today.

### Step 1 — `TokenRefresher`

New file `frontend/lib/core/services/token_refresher.dart`. A small, storage-backed helper — not a Riverpod notifier, not session state, just proactive-refresh-with-persistence:

```dart
class TokenRefresher {
  TokenRefresher({
    required SecureSessionStorage storage,
    required Future<AuthSession> Function(String refreshToken) refreshSession,
    Duration expiryBuffer = const Duration(seconds: 30),
  });

  /// Full session, refreshed and persisted first if the stored access
  /// token is expired or within [expiryBuffer] of expiring. Null if no
  /// session is stored at all. Rethrows whatever refreshSession() throws
  /// (SessionExpiredException on a rejected/rotated-away refresh token,
  /// AuthNetworkException on a transient failure) after clearing the
  /// stored session — a rejected refresh token really does mean the
  /// session is gone; a network blip clearing storage is an acceptable
  /// simplification here since the caller has no good way to distinguish
  /// the two from a single failed HTTP call, and re-login is always a
  /// safe fallback even for the network-blip case.
  Future<AuthSession?> getValidSession();

  /// Convenience wrapper for the getAccessToken callback shape
  /// HttpAuthService already expects.
  Future<String?> getValidAccessToken() async =>
      (await getValidSession())?.accessToken;
}
```

Internals:
- `getValidSession()`: `storage.loadSession()`; if null return null; if `accessTokenExpiresAt` is after `now + expiryBuffer`, return it as-is (no network call — this is the common case, keep it cheap); otherwise call the private refresh path below and return its result.
- Refresh path: **single-flight** — cache the in-flight `Future<AuthSession>` and hand the same one to every concurrent caller rather than firing a second `refreshSession()` call. This isn't a nice-to-have: the backend rotates refresh tokens on every use with reuse/replay detection (`refresh_tokens.replaced_by`, per the theft-detection design discussed earlier this project) — two concurrent calls both reading the same now-stale refresh token and both POSTing it to `/v1/auth/refresh` would have the second one rejected as a replay, which would incorrectly kill a perfectly good session. A `Future<AuthSession>?` field holding the in-flight attempt, cleared in a `whenComplete`, is enough.
- On success: `storage.saveSession(refreshed)`, return it.
- On failure: `storage.clearSession()`, rethrow the original error.

### Step 2 — Wire it into `authServiceProvider`

In `app_providers.dart`, replace the current direct-storage-read `getAccessToken` with `TokenRefresher.getValidAccessToken`. `TokenRefresher` needs `authServiceProvider`'s own `refreshSession()` method, which creates a naive circular dependency if built as two separate providers (`tokenRefresherProvider` needing `authServiceProvider`, `authServiceProvider` needing `tokenRefresherProvider`) — avoid that by constructing both inside one provider body, same pattern already used for other tightly-coupled construction in this file:

```dart
final authServiceProvider = Provider<AuthService>((ref) {
  final storage = ref.read(sessionStorageProvider);
  late final HttpAuthService service;
  final refresher = TokenRefresher(
    storage: storage,
    refreshSession: (token) => service.refreshSession(token),
  );
  service = HttpAuthService(getAccessToken: refresher.getValidAccessToken);
  return service;
});
```

Also expose `tokenRefresherProvider` (built the same way, or split out) so `AuthSessionNotifier.build()` can reach it in Step 3 without duplicating the construction — simplest is to keep one private `_TokenRefresherBundle`-style provider both `authServiceProvider` and the new provider read, or just expose the `refresher` instance via its own `Provider<TokenRefresher>` and have `authServiceProvider` depend on *that* (one-directional: `authServiceProvider` → `tokenRefresherProvider` → `authServiceProvider`'s `refreshSession` via the same `late final` trick isn't needed if `TokenRefresher` is built first with a placeholder and `HttpAuthService` built second reading it — pick whichever ordering avoids the cycle; the `late final service` pattern above is the simplest one that works in a single provider body). Use judgment on the exact split, but the two hard constraints are: (1) no provider-level circular dependency, (2) exactly one `HttpAuthService` and one `TokenRefresher` instance for the app's lifetime (a `Provider`, not `.autoDispose`, same as today).

### Step 3 — Wire it into `AuthSessionNotifier.build()`

Replace `ref.watch(sessionStorageProvider).loadSession()` with `ref.read(tokenRefresherProvider).getValidSession()` (or however Step 2 exposed it). Everything downstream (`_fetchProfileOrFallback`, the existing `catch (_) { return const AuthSessionState(); }`) needs no change — a refresh failure during launch already correctly resolves to a logged-out `AuthSessionState` through the existing catch block.

### Step 4 — `forceSignOut()` for a mid-session refresh failure

The gap Step 3 doesn't cover: a refresh failure happening *after* launch, triggered by some other authenticated call (a verification screen, a profile refetch) going through the `getAccessToken` callback rather than through `build()`. `TokenRefresher` clears storage in that case, but `authSessionProvider`'s in-memory `state.session` doesn't know that on its own — Riverpod won't notice a storage write it wasn't watching for.

Add to `AuthSessionNotifier`:

```dart
/// Called when a caller catches SessionExpiredException from an
/// authenticated call made mid-session (not during build()/launch,
/// which already handles this itself) — TokenRefresher has already
/// cleared storage by the time this runs, so this only needs to bring
/// in-memory state into agreement with it. Unlike signOut(), this must
/// NOT call authService.logout() — the refresh token that call would
/// send is already dead server-side (that's why we're here), and
/// storage no longer has it to send anyway.
void forceSignOut() {
  state = const AsyncData(AuthSessionState());
}
```

### Step 5 — Catch `SessionExpiredException` where it surfaces, and auto-navigate as a safety net

Two layers, both needed:

1. Wherever a screen already catches `AuthException` from an `AuthService`/`authSessionProvider` call to show an error (verification screens, `ProfilePage`'s verification-status refetch), add a `SessionExpiredException` case that calls `ref.read(authSessionProvider.notifier).forceSignOut()` before showing/dismissing, rather than showing it as a generic "something went wrong" — the user needs to know sign-in is required again, not that a request failed.
2. In `AppShell`, add a `ref.listen(authSessionProvider, ...)` that navigates to `LandingPage` (clearing the nav stack, same as `ProfilePage`'s existing sign-out navigation) whenever `isLoggedIn` transitions from `true` to `false` while `AppShell` is mounted. This is the safety net for any authenticated call site that doesn't have its own explicit catch — without it, a forgotten catch block would leave the user stranded on a dead session with every action silently failing.

**UX distinction to get right**: this is an *involuntary* sign-out (session actually expired/was revoked), not the user tapping "Sign Out." Do not show the existing sign-out confirmation dialog (Step 12 above) on this path — that dialog is for confirming intent before a voluntary action, not for something that already happened. Show a brief, low-friction explanation instead (a `SnackBar` on `LandingPage` after the navigation, e.g. "Your session expired — please sign in again," is enough) so it doesn't read as an unexplained kick-out.

### Tests

- `TokenRefresher` unit tests (fake `SecureSessionStorage`/fake `refreshSession`): returns the cached session unchanged when not expiring soon (asserts `refreshSession` was never called); refreshes and persists when expired; two concurrent `getValidSession()` calls against an expired session result in exactly one `refreshSession()` call (the single-flight case — this is the one worth actually testing, not just reasoning about); clears storage and rethrows when `refreshSession()` throws; returns null when no session is stored.
- `AuthSessionNotifier.build()` test: stored session with an already-past `accessTokenExpiresAt` + a fake `refreshSession` that succeeds → resolves to a logged-in state carrying the *refreshed* session, not the stale one.
- `AuthSessionNotifier.forceSignOut()` test: state goes from logged-in to `const AuthSessionState()`.
- Widget test on `AppShell`: forcing `authSessionProvider` to emit a logged-out state while `AppShell` is showing results in navigation to `LandingPage`.

### Self-review checklist

- [ ] No code path calls `ref.read`/`ref.watch` on `authSessionProvider` or its notifier from inside `AuthSessionNotifier.build()` — only `sessionStorageProvider`/`authServiceProvider`/`tokenRefresherProvider`, matching the existing constraint comment in `app_providers.dart`.
- [ ] Exactly one `refreshSession()` HTTP call happens when two authenticated requests race against the same expired token (test this, don't just eyeball it) — this is the concrete failure mode of skipping single-flighting, and it would look like an intermittent, hard-to-reproduce forced logout in practice.
- [ ] `forceSignOut()` does not call `authService.logout()`.
- [ ] The involuntary-session-expiry path does not show the voluntary sign-out confirmation dialog.
- [ ] A session that's been idle (app backgrounded, not force-quit) for longer than 15 minutes but less than 30 days comes back to a logged-in state on next foreground/relaunch, not a forced re-login — this is the actual bug being fixed; confirm it by hand against the local backend with a shortened access-token TTL if that's faster than waiting 15 real minutes.
- [ ] `flutter analyze`/`dart format --set-exit-if-changed .`/`flutter test` all clean.
- [ ] Bring the diff back to Cowork for review before merging.

### Explicitly not in this addendum

Biometric/PIN re-auth, a "remember me" opt-out, silently retrying a request that got a 401 for a reason *other* than expiry (e.g. a genuinely revoked account) — those cases should still surface as a real session-expired state, not an infinite retry loop.
