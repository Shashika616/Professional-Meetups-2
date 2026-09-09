Fix four verified bugs from the Round 3 design review. Full design/reasoning
for each is in `docs/plans/13-round3-bug-fixes.md` — read it first. Summary:

**1. `frontend/lib/features/safety/manage_trusted_contacts_page.dart`**,
`_save()`'s `on AuthException catch (error)` block is missing a `mounted`
guard before `setState` (its own `finally` block right below has one). Add
`if (!mounted) return;` as the first line of that catch block.

**2. `MeetupSessionExpiredException` is thrown on meetup-API 401s
(`core/services/http_meetup_service.dart:344`) but no call site anywhere in
the app catches it specifically — it falls into the generic
`catch (error) { error is MeetupException ? error.message : '...' }` shown
at every meetup call site, and the user just sees an error message forever
instead of being signed out. Fix: grep the whole `frontend/lib` tree for
every `meetupServiceProvider` call wrapped in try/catch, and add an
`on MeetupSessionExpiredException` clause before the existing generic catch
that calls `ref.read(authSessionProvider.notifier).forceSignOut()` (guard
with `mounted`/`context.mounted` first). Mirror the exact idiom already used
for `AuthService.SessionExpiredException` in
`frontend/lib/features/profile/profile_page.dart` around line 412 — same
shape, just for the meetup-service exception type. Don't rely on any
specific file list being exhaustive; find every site yourself.

Same failure pattern, separate exception, exists in
`frontend/lib/features/safety/safety_page.dart`'s `_SosConfirmDialogState._confirm()`
(around lines 203-234): it calls `AuthService.triggerSos` and its
`on AuthException catch (error)` swallows a `SessionExpiredException`
without forcing sign-out. Add an `on SessionExpiredException` clause before
it, same `forceSignOut()` call, guarded by `mounted`.

**3. `frontend/lib/features/meetups/schedule_flow.dart`**'s
`_ScheduleFlowPageState` has working step-back logic (`_goBack()`) wired
only to its custom in-app back button — the OS back gesture bypasses it and
pops the whole 5-step wizard, discarding everything. Wrap the page's
`Scaffold` (around line 124) in a `PopScope`:
`canPop: _sequence.indexOf(_step) == 0`, and on a blocked pop call
`_goBack()` instead. Check the installed Flutter SDK for whether
`PopScope`'s callback is named `onPopInvoked` or
`onPopInvokedWithPopScope` in this version — use whichever one
`flutter analyze` doesn't flag as deprecated. Do not use `WillPopScope`
(fully deprecated). Don't add any new confirmation dialog — this fix is
scoped to making the OS gesture match what the in-app button already does,
nothing more.

**4. `backend/internal/modules/meetup/rating.go`** (`ListRatableParticipants`)
doesn't apply the same trust-level-based redaction
`ListMeetupParticipants` (`participants.go`) applies to `TrustLevel`,
`FullName`, and `ProfilePhotoURL`. This is a deliberate PARTIAL fix, not
full parity — read the "Fix 4" section of the plan doc for why full parity
would break the rating feature (the viewer here is always an actual
participant who already met these people in person, and the rating UI
identifies who to rate by name/photo — there's no way to rate someone you
can't see the name of). Only redact `TrustLevel`.

This one crosses a real gRPC boundary (gateway → monolith's internal gRPC
server via `buf`-generated stubs), so it needs a proto field, not just a Go
struct field. Full chain, in order — the plan doc's "Correction" note under
Fix 4 has the exact file:line for each of these, follow it precisely rather
than guessing the shape from `ListMeetupParticipants` alone:

1. Add `viewer_trust_level` to `ListRatableParticipantsRequest` in
   `backend/proto/meetup/v1/meetup.proto`.
2. Regenerate the proto/gRPC Go stubs using this repo's existing `buf
   generate` setup (`buf.gen.yaml`) — do not hand-edit the generated
   `.pb.go` files.
3. Add the `viewerTrustLevel int32` parameter to
   `monolithclient.MonolithClient.ListRatableParticipants`'s interface
   signature and its `grpcClient` implementation
   (`monolithclient.go:151`, `monolithclient/meetup.go:493-496`).
4. Source and pass the trust level in the gateway handler
   `listRatableParticipants` (`handlers/meetups.go:606-608`), the same way
   `listMeetupParticipants` right above it already does
   (`int32(middleware.TrustLevelFromContext(ctx))`).
5. Read `req.GetViewerTrustLevel()` in `grpcapi/meetup.go`'s
   `ListRatableParticipants` handler and pass it into the service-layer
   request, mirroring its `ListMeetupParticipants` handler.
6. Add `ViewerTrustLevel int` to `ListRatableParticipantsRequest` in
   `backend/internal/modules/meetup/types.go`.
7. In `rating.go`'s `ListRatableParticipants`, zero `TrustLevel` on each
   `RatableParticipant` when `req.ViewerTrustLevel < participantIdentityFloor`
   (the existing constant in `participants.go` — import/reuse it, don't
   redefine). Add a doc comment explaining this is intentionally a partial
   redaction and why.
8. Update `fakeMonolith.ListRatableParticipants` in
   `handlers/meetups_test.go:136-139` to match the new interface signature
   (mirror how `fakeMonolith.ListMeetupParticipants` right above it already
   records the trust level it received).
9. Run `go build ./...` and fix every other call site it flags — don't
   assume the list above is exhaustive; the build error list is the source
   of truth for what else needs updating (other tests, etc.).
10. On the frontend, confirm wherever `RatableParticipant.trustLevel` feeds
    a trust badge (`rating_prompt.dart`, via `ProfessionalAvatar`) already
    treats `0` as "no badge shown" rather than rendering a Level-0 badge —
    fix the rendering if it doesn't. No other frontend change needed.

**Fix 2 — verified call-site list (not exhaustive, but confirmed real):**
`meetup_detail_page.dart`, `schedule_flow.dart`, `host_meetup_controls.dart`
(two sites — close-meetup around line 110, cancel-meetup around line 157),
`happening_soon_section.dart`, `events_page.dart`,
`share_with_contacts_sheet.dart`, `participants_page.dart` (around line
57), `review/meetup_review_page.dart` (two sites — around lines 87 and
140). `widgets/participants_strip.dart` was checked and has no
try/catch around a meetup-service call, nothing to do there. Grep
`meetupServiceProvider` yourself to catch anything added or missed since.

**Fix 4 — redact after conversion, not before:** the plan doc originally
said "zero `TrustLevel` after fetching `eligible`" — that was wrong,
`eligible` is the repo-layer type (`repository.RatableParticipant`), not
the service-layer type actually returned. Redact on the slice
`ratableParticipantsFromRepo(eligible)` returns, per the exact code shape
in the plan doc's "Fix 4" step 8. Checked `integration_test.go`'s ~15
existing `ListRatableParticipants` tests — none set `ViewerTrustLevel` or
assert on `TrustLevel`, so adding the field and the redaction shouldn't
break them, but run them and confirm.

**Plan 12 note (separate, already-in-progress fix, not part of this
prompt):** if you're doing Plan 12 (the trust-level race) in the same
session, three test call sites — `identity_resolution_test.go:268`,
`identity_resolution_test.go:291`, `service_test.go:543` — pass a bare int
literal to `UpdatePersonalEmail` and need updating to
`func(repository.User) int { return <literal> }` once that signature
changes. Not relevant if Plan 12 is being done separately.

**When done:** run `dart format --set-exit-if-changed .`,
`flutter analyze --fatal-infos`, `flutter test` (from `frontend/`), and
`go build ./...`, `go test ./internal/modules/meetup/...` (from `backend/`).
Report the actual command output, and list every file you changed with a
one-line description of the change — not a prose summary of "fixed the
bugs."
