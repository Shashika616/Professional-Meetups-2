You are working in the Professional-Meetups-Monolith repo. Follow
`docs/plans/22-federated-name-hint.md` in full before writing any code — it
explains why this is scoped the way it is (Apple's name is a one-time,
out-of-band value the app currently reads and discards; Google already works
correctly and must not change; LinkedIn linking already correctly never
touches an existing user's name, and that guarantee must not regress).

## Part A — Backend

1. `backend/internal/modules/auth/types.go` (or wherever
   `CompleteFederatedSignupRequest` is defined): add a new field
   `FullNameHint string`. Also add `SuggestedNameUpdate string` to whatever
   result type `LinkIdentity` returns (`SessionResult` or similar) — check
   the actual type name in `service.go` rather than assuming.

2. `service.go`'s `CompleteFederatedSignup`: right before the existing call
   to `s.ResolveOrCreateIdentity(ctx, req.Provider, verified.Subject,
   verified.Email, verified.Name, "", req.AgeConfirmedOver18)`, compute
   `name := verified.Name; if name == "" { name = req.FullNameHint }` and
   pass `name` instead of `verified.Name`. Trim it and apply whatever
   length/character validation the profile self-edit name field already
   uses — find that validation (likely near `UpdateFullName` or wherever
   profile-editing validates input) and reuse it, don't invent a new rule.
   Do not change `ResolveOrCreateIdentity`'s signature.

3. The gateway HTTP handler for the federated-signup route: accept an
   optional `full_name_hint` string field in the request JSON, default `""`
   if absent, thread it into `CompleteFederatedSignupRequest.FullNameHint`.

4. `service.go`'s `LinkIdentity`, LinkedIn branch: it already fetches
   `info.Name` before calling `s.LinkIdentityToUser`. After a successful
   link, fetch the user's current `FullName` (you already have `user` from
   the `s.users.GetByID` call a few lines later — reorder if needed) and
   compare to `info.Name`. If they differ and `info.Name` is non-empty, set
   the new `SuggestedNameUpdate` field on the result to `info.Name`;
   otherwise leave it empty. This must be purely additive — do not change
   what `LinkIdentityToUser` itself does.

5. `identity_resolution.go`'s `LinkIdentityToUser`, LinkedIn branch (around
   line 135-143): add an explicit comment stating that this deliberately
   never writes `FullName` — connecting LinkedIn to an existing account
   must never silently change a name the user already has. Do not add any
   FullName-writing logic here.

6. Tests (extend existing suites, e.g. `identity_resolution_test.go`,
   `service_test.go` — follow whatever pattern they already use):
   - New Apple signup, JWT name empty, `FullNameHint` set → created user's
     `FullName` equals the hint.
   - New Apple signup, JWT name empty, `FullNameHint` also empty → `FullName`
     stays empty (unchanged existing behavior — client still shows "Member").
   - New Google signup with both a JWT name AND a hint present → the JWT
     name wins, hint is ignored (verified.Name is authoritative when
     non-empty).
   - **Regression test enshrining the constraint that matters most**: an
     existing user with a `FullName` already set links LinkedIn, and
     LinkedIn's own name is different — assert `FullName` is unchanged after
     `LinkIdentityToUser` runs, regardless of what `SuggestedNameUpdate` on
     the `LinkIdentity` result contains.
   - `LinkIdentity` LinkedIn branch: names differ → `SuggestedNameUpdate` is
     set to LinkedIn's name; names already match, or LinkedIn has no name →
     `SuggestedNameUpdate` is empty.

## Part B — Frontend

1. `frontend/lib/core/services/http_auth_service.dart`'s `signInWithApple`:
   right after obtaining `credential`, read `credential.givenName` and
   `credential.familyName` (both nullable). Join non-null/non-blank parts
   with a space into a single trimmed string; empty string if both are
   absent (this will be the common case after a user's first authorization
   — that's expected, not a bug). Pass it to `_completeFederatedSignup` as
   a new parameter.

2. `_completeFederatedSignup`: add a `required String fullNameHint`
   parameter, include it in the POST body as `'full_name_hint': fullNameHint`
   (always present, empty string when unavailable). Update `signInWithGoogle`'s
   call site to pass `''` (Google never needs this — its JWT already carries
   a name).

3. Update the class doc comment on `signInWithApple` — it currently states
   the JWT-has-no-name limitation as the end of the story; add a note that
   the one-time out-of-band name is now captured and sent, so a brand-new
   Apple signup does get a real name when Apple provides one (the "falls
   back to Member" comment should now say "only when Apple provides no name
   at all, e.g. not the user's very first authorization" rather than always).

4. Find the Profile page's "Connect LinkedIn" success handling (grep for
   wherever `LinkIdentity`'s LinkedIn case is called from the UI). After a
   successful link, if the response's `suggested_name_update` (adjust to
   whatever the actual decoded field name is) is present and non-empty, show
   a one-time dialog: "LinkedIn shows your name as {name} — update your
   profile to match?" with Yes/No. Yes calls whatever existing method
   updates the profile's display name (find the existing self-edit
   update-name call — ADR-023 already built this, do not add a new backend
   call). No or dismiss does nothing further. Do not show this dialog more
   than once per link event, and do not poll or re-check later.

5. Widget test: the suggested-name-update dialog appears only when the
   field is present and non-empty, and tapping "No"/dismiss never triggers
   the update call.

## Explicitly do not touch

- `ResolveOrCreateIdentity`'s or `LinkIdentityToUser`'s function signatures.
- Anything about trust-level computation.
- Google's sign-in path beyond passing `''` for the new hint parameter — its
  behavior must be identical to today.

## Before you report done

Run the full backend (`go test ./...` from `backend/`) and frontend
(`flutter analyze` and `flutter test` from `frontend/`) test suites and
paste the real pass/fail output — especially the new regression test for
the LinkedIn-link-must-not-overwrite-name guarantee, since that's the one
this whole plan exists to protect.
