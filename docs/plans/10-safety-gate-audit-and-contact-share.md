# Safety Gate audit + "tell a trusted contact"

Triggered by a direct review of the meetup screen: *"what does I UNDERSTAND
do? does it keep a record? Does share live location actually work?"*

The audit answered four of those with "yes, properly". The fifth was the
problem, and this document records what was found and what replaced it.

---

## Audit: what already worked

| Control | Persisted? | Where |
|---|---|---|
| **I UNDERSTAND** | yes | `meetup.safety_state.checklist_ack_at`, PK `(meetup_id, user_id)` |
| **Check in** | yes | `checked_in_at` |
| **Decline** | yes | `declined_at` + `decline_reason` |
| **How did it go?** | yes | `meetup.meetup_feedback` (`happened`, `felt_safe`, `profile_accurate`, `would_meet_again`, `notes`) |
| **Rate each other after close** | yes | `ListRatableParticipants` / `SubmitRating`, surfaced by `RatingPrompt` from three screens |

Two of these are stronger than they look:

* **The checklist is enforced, not decorative.** `CheckIn` rejects when
  `checklist_ack_at IS NULL` (`meetup/safety.go`), so a modified client
  cannot skip it.
* **Check-in and decline are mutually exclusive terminal states**, enforced
  server-side, and the UI renders the terminal state on return instead of
  asking again.

So consent to attend *is* taken and *is* preserved, which was the question.

## Audit: what did not work

**"Share live location" shared nothing.** It wrote exactly one boolean —
`meetup.safety_state.live_location_opt_in` — and a repo-wide grep found
nothing that read it. No recipient, no message, no link.

That is worse than not offering the feature. A user who flips a switch
labelled "share live location" before meeting a stranger may rely on it.

---

## What replaced it

### Recipient: the user's own emergency contacts, not the host

Telling the person you are meeting where you are is not a safety feature.
Telling someone *outside* the meetup is. (Reviewer's call, and correct.)

### What is actually sent

A text and/or email naming the meetup's **window and place**, with a map pin
at its coordinates:

> Ada Lovelace is meeting Mon 3:00 PM–4:00 PM at Colombo Fort Cafe.
> Location: https://maps.google.com/?q=6.927100,79.861200

**Not tracking.** True live location would need background-location
entitlement on both platforms, an App Store review justification, and a
public tokenized web page to view it — none of which exist here. The copy in
the app and the message body both say what actually happens, and
`TestMeetupShareMessage_StatesAWindowAndPlaceNotLiveTracking` fails if the
wording ever drifts back toward implying tracking.

### The security shape

The client supplies **only which of its own contacts to tell**:

* the message body is built server-side from the meetup row — window, label
  and coordinates are read inside `ShareWithContacts`, never accepted from
  the caller;
* the auth module intersects the requested contact ids against the caller's
  own list, so a guessed uuid cannot text a stranger;
* `requireParticipant` gates the whole call, so a non-participant cannot read
  a meetup's place and time out through a share.

The worst a modified client can do is tell its own emergency contacts about a
meetup it genuinely participates in.

### Module boundary

The meetup module owns the meetup; auth owns trusted contacts, phone numbers
and the SMS/email senders. Neither reads the other's schema (ADR-001 §3), so
the meetup module declares a narrow `TrustedContactNotifier` interface and
`cmd/monolith` supplies an adapter over `auth.Service` — the same place every
other cross-module wire is made. `NotifyMeetupShare` reuses SOS's existing
per-channel circuit breakers rather than adding a second send path.

### Confirmation is the point

`meetup.safety_share` (migration 0007) records one row per
`(meetup, sharer, contact)`, and `GetSafetyState` returns the ids on every
read. Reopening the meetup shows *"Told 2 trusted contacts"* rather than
offering to share again as if nothing had happened — a safety action you
cannot verify afterwards is one you cannot rely on.

`ON CONFLICT DO NOTHING` makes it idempotent per contact, and the picker
shows an already-told contact as **Already told** and refuses to re-select
them, so "select all" is safe to press twice and nobody gets texted twice.

### No contacts yet

The sheet routes straight to `ManageTrustedContactsPage` instead of being a
dead end. Contacts remain capped at `MaxTrustedContactsPerUser = 3`
(reviewer's call — multiple were already supported).

---

## Also fixed

The **cancel-meetup** and **decline** dialogs required a reason and disabled
their confirm button correctly (`onPressed: null`), but hardcoded the label
to `AppPalette.danger`, which overrides `TextButton`'s own disabled colour —
so the button looked fully active while doing nothing. Both now grey out
until the field is filled.

## Files

**Backend** — `migrations/0007_meetup_safety_share.{up,down}.sql`;
`meetup/repository/queries/safety_state.sql`; `meetup/safety.go`
(`ShareWithContacts`); `meetup/service.go` (`TrustedContactNotifier`,
`ContactShare`); `auth/sos/sos.go` (`NotifyMeetupShare`,
`MeetupShareMessage`); `cmd/monolith/main.go` (adapter);
`proto/meetup/v1/meetup.proto`; gateway route
`POST /v1/meetups/{id}/safety/share`.

**Frontend** — `features/meetups/widgets/share_with_contacts_sheet.dart`
(new); `meetup_detail_page.dart` (card + handler);
`core/models/meetup.dart` (`sharedWithContactIds`);
`core/services/{meetup_service,http_meetup_service}.dart`;
`widgets/host_meetup_controls.dart` (disabled-button fix).

## Tests

Backend: 5 meetup integration tests (facts come from the meetup row;
idempotent per contact; rejects contacts that are not yours; requires
participation; rejects an empty selection) and 4 auth tests (only picked
contacts are texted; foreign ids rejected; empty/NaN rejected; message wording
states a window and place, not tracking).

Frontend: 6 widget tests (the old switch is gone; picking sends exactly those
ids and the screen then shows it; SELECT ALL; an already-told contact cannot
be re-picked; no contacts routes to the add page; a failed share claims
nothing) plus 1 for the greyed cancel button.

## Gates

```
flutter analyze / dart format / flutter test    +388 passed
go build / vet / golangci-lint (0 issues)
go test ./... -race                             21 packages, 0 failures
```

## Correction (found in independent review, not self-reported)

`SafetyState.fromJson` never read `shared_with_contact_ids`, so
`sharedWithContactIds` fell back to its `const []` default on every real HTTP
response — including the response of `shareWithContacts` itself. The
confirmation mechanism this feature is built around ("Told N trusted
contacts", and the picker's per-contact "Already told") could therefore never
fire in production, which is exactly the failure the feature exists to
prevent.

Every other layer was correct: the Go struct, the JSON tag, the model field,
the constructor, the UI. Only the decode was missing.

**How it shipped.** `SafetyState` had no `fromJson` coverage at all, and
every widget test builds model objects directly through
`ScriptedMeetupService`, so the decode path from a real body was never
exercised. The backend integration tests were correct and unaffected — they
assert on the Go struct, never on the frontend's parsing.

Fixed at `frontend/lib/core/models/meetup.dart:417-422`, with two layers of
new coverage:

* `test/meetup_model_test.dart` — a `SafetyState.fromJson` group (5 tests),
  which this type had none of;
* `test/http_meetup_service_test.dart` (new file) — round-trips realistic
  gateway bodies through the real `HttpMeetupService` for both
  `getSafetyState` and `shareWithContacts`. A model-only test would not catch
  a mismatch between the model and a differently-shaped service wrapper.

Control run: with the fix removed, **4 of these fail** — two at the model
layer and two at the service layer, so either would have caught it. Restored:
`+396 All tests passed!`

## Known follow-up

Migration 0007 needs `docker compose up` to apply. `live_location_opt_in` and
its RPC are left in place but no longer surfaced — dead once this ships, and
worth removing in a separate pass rather than churning the proto here.
