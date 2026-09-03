# Frontend plan — Safety Gate per-participant state, decline-with-reason (ADR-024)

Read `docs/04-decisions/adr-024-safety-gate-per-participant-state-and-decline-with-reason.md` first. Depends on the backend plan's Step 5 (new `user_id` param on `GetSafetyState`, new `DeclineCheckIn` RPC/response fields).

## Step 1 — Service contract

- `MeetupService` (interface in `core/services/`): `getSafetyState`, `acknowledgeSafetyChecklist`, `setLiveLocationOptIn`, `checkIn` — check whether these already take the current user's ID (the backend's proto did for three of the four already; confirm the frontend call sites already pass it, since if they don't, the backend change in Step 3 below needs a source for it — likely the same signed-in-user ID already available via `authSessionProvider`, same as every other authenticated call in this app).
- Add `declineCheckIn(meetupId, reason)` to the interface, mirrored in `MockMeetupService` and `HttpMeetupService`.
- `SafetyState` model (wherever the current one lives, likely alongside `meetup_detail_page.dart` or a dedicated model file): add `declinedAt`/`declineReason` fields, parsed from the two new response fields.

## Step 2 — `meetup_detail_page.dart`'s Safety Gate sub-flow

- Read the existing checklist → live-location-opt-in → check-in UI in full before changing anything — this plan doesn't have its exact current widget structure in front of it, so match the existing visual/interaction pattern rather than guessing a new one.
- Add a "Decline" action alongside the check-in action, at the same point in the flow (after the checklist is shown, before check-in is the only path forward). Tapping it opens a required-reason text entry (mirror `host_meetup_controls.dart`'s `_CancelReasonDialog` — the same required-reason pattern ADR-020 already built for `CancelMeetup`, don't invent a second one).
- Once declined, the screen should reflect that terminal state clearly (not still offer check-in) — same spirit as how a cancelled/withdrawn state is already shown elsewhere in this app, not a new visual language.
- If the safety-state fetch (`GetSafetyState`) comes back `403`/Forbidden (the caller isn't a participant — shouldn't normally be reachable through this app's own navigation, but the backend now enforces it), handle it as a clear "you're not part of this meetup" state rather than letting it surface as a raw error.

## Step 3 — Notification handling

- The existing FCM notification-tap-routing code (used for accept/reject/cancel notifications) gains a case for the new "review your safety checklist" notification (fired at meetup creation for the host, and at accept-time for a newly-accepted requester, per the backend plan's Step 4) — routes to `meetup_detail_page.dart`'s Safety Gate section. Don't build a second, parallel notification-handling path.
- Host also receives a "participant declined: <reason>" notification — same routing.

## Step 4 — Host visibility into accepted participants' check-in status (ADR-024 § 6)

- `MeetupRequest`/`MeetupRequestResponse` model (wherever `withdrawal_note` is already parsed from the `ListMeetupRequests` response — likely the same model class `my_meetups_page.dart` already consumes): add the three new optional fields (`checkedInAt`, `declinedAt`, `declineReason`), parsed the same way `withdrawalNote` already is (null/absent for anything that isn't an accepted-and-safety-state-touched request).
- `my_meetups_page.dart`'s ACCEPTED tab (`_buildRequestList(accepted, 'No accepted requests yet.')`, the request-card widget it builds): add a small status line/badge per accepted request — "Checked in" (with timestamp) if `checkedInAt` is set, "Declined: <reason>" if `declinedAt`/`declineReason` is set, or "Not checked in yet" otherwise. Match the existing card's visual language (same badge/label style already used for status elsewhere on this page) rather than introducing a new component.
- This is host-only surfacing of data the host already receives via push notification (§ 4 of the backend plan) — no new permission/auth flow on the frontend, since `ListMeetupRequests` is already a host-only call the host-side UI already makes.

## Step 5 — Tests

- Widget test: decline action opens the required-reason dialog, submitting with an empty reason is disabled/rejected (mirror the existing cancel-reason dialog test's shape).
- Widget test: after a successful decline, the screen no longer offers check-in.
- Widget test: an accepted-request card in `my_meetups_page.dart` shows "Checked in", "Declined: <reason>", or "Not checked in yet" correctly based on the three new fields.
- Full checklist: `flutter analyze`, `dart format --set-exit-if-changed`, `flutter test`.
