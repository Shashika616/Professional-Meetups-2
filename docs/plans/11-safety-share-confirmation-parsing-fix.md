# Fix — "Told N trusted contacts" never shows (JSON parsing bug)

Found during independent verification of `docs/plans/10-safety-gate-audit-and-contact-share.md`'s completion report — not self-reported. Everything else in that report checked out against source (backend: all 9 checkable claims confirmed; frontend: 9 of 10). This is the one real discrepancy.

## The bug

`frontend/lib/core/models/meetup.dart`, `SafetyState.fromJson` (lines 410-419):

```dart
factory SafetyState.fromJson(Map<String, dynamic> json) {
  return SafetyState(
    meetupId: json['meetup_id'] as String,
    checklistAckAt: _secondsToDateTime(json['checklist_ack_at_unix_seconds']),
    liveLocationOptIn: json['live_location_opt_in'] as bool? ?? false,
    checkedInAt: _secondsToDateTime(json['checked_in_at_unix_seconds']),
    declinedAt: _secondsToDateTime(json['declined_at_unix_seconds']),
    declineReason: json['decline_reason'] as String?,
  );
}
```

It never reads `shared_with_contact_ids` — confirmed as the real wire key from
`backend/internal/gateway/handlers/meetups.go:139`
(`SharedWithContactIDs []string \`json:"shared_with_contact_ids"\``). So
`SafetyState.sharedWithContactIds` silently falls back to its constructor
default (`const []`, `meetup.dart:383`) on every real HTTP response —
including the response of `shareWithContacts` itself and every
`getSafetyState` call.

**Effect**: the entire "confirmation is the point" mechanism the feature was
built around — `meetup_detail_page.dart:762-767`'s "Told N trusted contacts"
text, and the picker's "Already told" per-contact disable — never fires in
production. A user can share with the same contacts repeatedly across app
sessions with no visible record it ever worked, which is exactly the failure
mode ("a safety action you cannot verify afterwards is one you cannot rely
on") the plan doc says this feature exists to prevent.

**Why the test suite didn't catch it**: every frontend widget test constructs
`SafetyState` objects directly (via `ScriptedMeetupService`), never through
`fromJson` — so the parsing path itself has zero test coverage. The backend
integration tests are correct and unaffected (they check the Go struct field,
never the frontend's JSON decoding).

## The fix

Add the missing field to `fromJson`:

```dart
sharedWithContactIds:
    (json['shared_with_contact_ids'] as List<dynamic>?)
        ?.cast<String>() ??
    const [],
```

## Test to add

A `SafetyState.fromJson` unit test that decodes a JSON map containing
`shared_with_contact_ids` and asserts the parsed object's
`sharedWithContactIds` matches — this is the missing coverage that let the
bug ship; add it regardless of whether other fromJson fields already have
similar tests, since this specific field had none.

Also worth one integration-style check: an `http_meetup_service_test.dart`
(or wherever `HttpMeetupService`'s response parsing is tested) call that
round-trips a realistic `getSafetyState`/`shareWithContacts` response through
the real HTTP service layer, not just the bare model — the model-only test
above would not have caught a mismatch between the constructor field name and
a differently-shaped service-layer wrapper, if one existed.

## Bar for "done"

Cite file:line. Prove the fix with the new `fromJson` test, not by reading
the diff. Confirm `flutter analyze`/`dart format --set-exit-if-changed`/
`flutter test` all pass. Don't touch anything else in this file — every other
field mapping was independently verified correct.
