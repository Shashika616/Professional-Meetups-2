# Plan 13 — fixes for Round 3 verified bugs (#25, #27, #28, #29)

Four fixes, independent of each other and of Plan 12 (the trust-level race,
still separately in progress). #26 (the lifecycle-sweep N+1) is left out of
this pass — it was reported but not independently re-verified, and it's a
performance item, not a correctness bug; fix it in its own pass once
confirmed.

## Fix 1 (gap #27) — setState after dispose in Add Trusted Contact dialog

`frontend/lib/features/safety/manage_trusted_contacts_page.dart`, `_save()`
(around lines 328-347). The `on AuthException catch` block is missing the
`mounted` guard its own `finally` block already has:

```dart
// Before:
} on AuthException catch (error) {
  setState(() => _error = error.message);
} finally {
  if (mounted) setState(() => _saving = false);
}

// After:
} on AuthException catch (error) {
  if (!mounted) return;
  setState(() => _error = error.message);
} finally {
  if (mounted) setState(() => _saving = false);
}
```

One-line fix. No design decision involved.

## Fix 2 (gap #28) — MeetupSessionExpiredException and SOS's SessionExpiredException never force a sign-out

**Meetup call sites.** Every meetup-service call site catches errors with a
bare `catch (error) { ... error is MeetupException ? error.message : '...' }`
(confirmed this exact shape in `meetup_detail_page.dart`, and it's the
established pattern repo-wide) — `MeetupSessionExpiredException` (a
`MeetupException` subtype, `core/services/meetup_service.dart:250-252`) gets
swallowed into that generic branch and shown as a plain error message
forever, instead of forcing sign-out like `AuthService.SessionExpiredException`
already does at five call sites.

The established idiom for the auth-service equivalent, e.g.
`profile_page.dart:406-425`:

```dart
try {
  await ref.read(authSessionProvider.notifier).completeProfileSetup(...);
  ...
} on SessionExpiredException {
  if (context.mounted) {
    ref.read(authSessionProvider.notifier).forceSignOut();
  }
} catch (error) {
  ...
}
```

Apply the identical shape to every meetup-service call site: add an
`on MeetupSessionExpiredException` clause, calling
`ref.read(authSessionProvider.notifier).forceSignOut()` (guarded by
`mounted`/`context.mounted` as appropriate for that method), placed BEFORE
the existing generic `catch (error)` clause (Dart requires more specific
clauses first). Do not remove or restructure the generic `catch` — it stays
exactly as-is for every other error.

**Correction (2026-09-09, before handoff) — the gap-tracker's original call-site
list was incomplete.** Re-grepped the whole `frontend/lib` tree for
`meetupServiceProvider` usage: 11 files reference it, not 6.
`app_providers.dart` is just the provider definition, not a call site.
Confirmed catch blocks needing the fix in all of these (some files have more
than one):

- `meetup_detail_page.dart`
- `schedule_flow.dart`
- `host_meetup_controls.dart` (two call sites: `catch (error)` around line
  110 in the close-meetup flow, and around line 157 in cancel-meetup)
- `happening_soon_section.dart`
- `events_page.dart`
- `share_with_contacts_sheet.dart`
- `participants_page.dart` (one call site, around line 57)
- `review/meetup_review_page.dart` (two call sites, around lines 87 and 140)

`widgets/participants_strip.dart` was checked and has no try/catch around a
meetup-service call — nothing to change there. Still don't treat this list
as final — grep for `meetupServiceProvider` yourself and check every result,
since a file can be added or a call site missed between this review and
when the fix actually runs.

**SOS confirm dialog** (`frontend/lib/features/safety/safety_page.dart`,
`_SosConfirmDialogState._confirm()`, around lines 203-234) is a related but
separate instance of the same failure *pattern*, on the auth service's own
exception: it calls `AuthService.triggerSos`, and its
`on AuthException catch (error)` is broad enough to swallow a
`SessionExpiredException` without forcing sign-out — it just sets the dialog
to a "failed" phase with `error.message`. Fix the same way, mirroring
`profile_page.dart`'s idiom:

```dart
} on SessionExpiredException {
  if (mounted) {
    ref.read(authSessionProvider.notifier).forceSignOut();
  }
} on AuthException catch (error) {
  if (!mounted) return;
  setState(() {
    _phase = _SosDialogPhase.failed;
    _resultMessage = error.message;
  });
}
```

Add the `on SessionExpiredException` clause before the existing
`on AuthException catch`, same ordering rule as above.

## Fix 3 (gap #29) — schedule flow's OS back gesture bypasses step-back logic

`frontend/lib/features/meetups/schedule_flow.dart`, `_ScheduleFlowPageState`.
Current fields: `_step` (current `_Step`), a `_sequence` getter returning the
ordered step list, `_goBack()` (steps back one, or does nothing at the first
step), and the `Scaffold(...)` built around line 124.

Wrap that `Scaffold` in a `PopScope` so the system back gesture goes through
`_goBack()` instead of popping the route outright:

```dart
return PopScope(
  canPop: _sequence.indexOf(_step) == 0,
  onPopInvokedWithPopScope: (didPop, result) {
    if (didPop) return;
    _goBack();
  },
  child: Scaffold(
    // ...unchanged
  ),
);
```

Check the installed Flutter SDK version before writing this: `PopScope`'s
callback was renamed from `onPopInvoked` to `onPopInvokedWithPopScope` at
some point and the old name is deprecated in newer SDKs — use whichever one
`flutter analyze` doesn't flag as deprecated, don't guess. `WillPopScope` is
not an acceptable substitute (fully deprecated) — use `PopScope` regardless
of which callback name applies.

This makes the first step poppable normally (leaving the flow entirely,
same as today) and every later step route back through the existing
one-step-at-a-time `_goBack()` logic instead of discarding the whole draft.
No confirmation dialog is being added here — that's a separate, larger UX
decision (warn before discarding a partially-filled draft at all, including
via the in-app back button) or existing intent; keep this fix scoped to
"the OS gesture does what the in-app button already does," nothing more.

## Fix 4 (gap #25) — ListRatableParticipants identity-redaction inconsistency

This one is a judgment call, not a mechanical copy of
`ListMeetupParticipants`'s redaction — full mechanical parity would break
the feature. `ListMeetupParticipants`'s redaction exists to stop a
non-participant from scraping a guest list they have no legitimate reason
to see (`participants.go:7-20`'s own stated rationale). `ListRatableParticipants`
is different in a way that matters: the viewer is already a confirmed
participant on this specific meetup (`IsParticipant` gate,
`rating.go:22-29`) — they already met these people in person. Fully
redacting `FullName`/`ProfilePhotoURL` the same way would make the rating
UI unusable for exactly the (small, shrinking) population this affects —
`rating_prompt.dart:108,155-156,200-209` renders `fullName`/`profilePhotoUrl`
directly to let the viewer pick who they're rating; there is no way to
rate someone you cannot identify by name.

**Fix: redact only `TrustLevel`, not `FullName`/`ProfilePhotoURL`/`UserID`,
for a viewer below `participantIdentityFloor`.** `TrustLevel` is the one
field here with a real, avoidable disclosure: it tells the viewer another
specific person's current trust level, which is exactly the kind of
per-person reputation signal `ListMeetupParticipants` also withholds from
sub-floor viewers, and nothing about the rating flow needs it —
`rating_prompt.dart:157` only threads it into `ProfessionalAvatar` as a
small badge, which degrading gracefully to "no badge" doesn't break
anything.

**Correction (2026-09-09, before handoff):** the first draft of this fix
understated the plumbing. `ListMeetupParticipants` and `ListRatableParticipants`
both cross a real gRPC boundary in this monolith (gateway process → the
monolith's internal gRPC server, via `buf`-generated stubs under
`backend/internal/proto/meetup/v1/`) — `ViewerTrustLevel` isn't just a Go
struct field, it's a proto message field that has to exist on the wire.
Checked directly: `ListMeetupParticipantsRequest` already carries
`viewer_trust_level` (`meetup.proto`, field 3) precisely so the gateway can
supply it; `ListRatableParticipantsRequest` has no such field today, and the
whole chain down to it is missing the parameter — confirmed at every layer:
`monolithclient.MonolithClient.ListRatableParticipants(ctx, meetupID, viewerID)`
(no trust level param, `monolithclient.go:151`), its `grpcClient` implementation
(`monolithclient/meetup.go:493-496`, doesn't set `ViewerTrustLevel` on the
request it builds), the gateway handler `listRatableParticipants`
(`handlers/meetups.go:606-608`, doesn't read a trust level from context at
all), and `grpcapi/meetup.go`'s `ListRatableParticipants` handler (doesn't
read `req.GetViewerTrustLevel()`). This needs a real (if small) proto
change, not just a Go-side interface change. Full chain to update, in order:

1. **`backend/proto/meetup/v1/meetup.proto`** — add `int32 viewer_trust_level = 3;`
   to the `ListRatableParticipantsRequest` message (mirror
   `ListMeetupParticipantsRequest`'s existing field name/number convention —
   use the next free field number in that message, not necessarily 3).
2. Regenerate the Go proto/gRPC stubs the way this repo already does it —
   check `backend/buf.gen.yaml` and whatever script/Makefile target invokes
   `buf generate`, run that, don't hand-edit `meetup.pb.go`/`meetup_grpc.pb.go`.
3. **`backend/internal/gateway/monolithclient/monolithclient.go:151`** —
   change the `MonolithClient` interface method to
   `ListRatableParticipants(ctx context.Context, meetupID, viewerID string, viewerTrustLevel int32) (RatableParticipants, error)`,
   matching `ListMeetupParticipants`'s exact parameter shape on the line above it.
4. **`backend/internal/gateway/monolithclient/meetup.go:493-496`** — accept
   the new parameter and set `ViewerTrustLevel: viewerTrustLevel` on the
   request it builds (same pattern as the `ListMeetupParticipants` client
   method just above it in the same file).
5. **`backend/internal/gateway/handlers/meetups.go:606-608`** (`listRatableParticipants`) —
   source the trust level the same way `listMeetupParticipants` does right
   above it (`handlers/meetups.go:560-570`): `int32(middleware.TrustLevelFromContext(ctx))`
   from the verified JWT, and pass it through.
6. **`backend/internal/grpcapi/meetup.go`**'s `ListRatableParticipants` handler —
   read `req.GetViewerTrustLevel()` and set it on the
   `meetup.ListRatableParticipantsRequest` passed to the service layer,
   mirroring its `ListMeetupParticipants` handler right above it.
7. **`backend/internal/modules/meetup/types.go:286-289`** — add
   `ViewerTrustLevel int` to `ListRatableParticipantsRequest`.
8. **`backend/internal/modules/meetup/rating.go`**'s `ListRatableParticipants` —
   **correction: redact after `ratableParticipantsFromRepo`, not on `eligible`.**
   `eligible` is `[]repository.RatableParticipant` (the repo-layer type;
   `convert.go:174-182`'s `ratableParticipantsFromRepo` converts it to the
   service-layer `[]RatableParticipant` that's actually returned) — the
   redaction has to happen on that converted slice, not on `eligible`.
   Exact shape:
   ```go
   out := ratableParticipantsFromRepo(eligible)
   if req.ViewerTrustLevel < participantIdentityFloor {
   	for i := range out {
   		out[i].TrustLevel = 0
   	}
   }
   return out, nil
   ```
   (reuse the existing `participantIdentityFloor` constant from
   `participants.go`, don't redefine it). Add a doc comment explaining this
   is a deliberate *partial* redaction and why (see above). Checked
   `integration_test.go`'s ~15 existing `ListRatableParticipants` call
   sites (e.g. lines 1282, 1298, 1314, 1324, 1359, 1401, 1422): none set
   `ViewerTrustLevel` on the request (defaults to Go zero value, 0) and
   none assert on `TrustLevel` in the response — only on
   `len(got)`/`got[i].UserID`. Adding the field is additive (no existing
   struct literal breaks) and the default-redacted behavior it triggers is
   the safe direction, so none of those tests should need changes — but
   run them and confirm rather than assuming.
9. **`backend/internal/gateway/handlers/meetups_test.go:136-139`** —
   `fakeMonolith.ListRatableParticipants` needs the new parameter added to
   match the interface change (mirror how `fakeMonolith.ListMeetupParticipants`
   just above it already records `viewerTrustLevel` into
   `f.meetup.gotTrustLevel`), plus any test asserting the old signature.
10. Search the rest of the backend for any other caller of
    `ListRatableParticipants` at any layer (service tests, integration
    tests) and update them to pass a trust level — `go build ./...` will
    surface every call site that needs updating; don't rely on this list
    being complete.

Frontend: `RatableParticipant`'s trust level will come back as `0` for a
redacted entry — confirm `ProfessionalAvatar`/whatever renders the badge
already treats `trustLevel: 0` as "no badge" gracefully (it should, since
that's a legitimate value for an unverified account already); if it
doesn't, fix the rendering to treat `0` as no-badge rather than a real
Level 0 badge in this specific context. No other frontend change needed —
`fullName`/`profilePhotoUrl`/`userId` are unaffected.

## Verification

Run `dart format --set-exit-if-changed .`, `flutter analyze --fatal-infos`,
and `flutter test` from `frontend/`, and `go build ./...` /
`go test ./internal/modules/meetup/...` from `backend/`, after all four
fixes. Report actual output.
