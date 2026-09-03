# Frontend plan — Trust-gated meetup visibility + guided verification checklist (ADR-028)

Read `docs/04-decisions/adr-028-trust-gated-meetup-visibility-and-guided-verification-checklist.md` first. Depends on the backend plan's `locked_for_viewer` field and the now-optional host/location/time fields on `MeetupResponse`.

## Step 1 — Model + service contract

- `Meetup` model (wherever `MeetupResponse` is parsed): add `lockedForViewer` (bool), make `hostFullName`/`hostProfilePhotoUrl`/`locationLabel`/the time-window fields nullable if they aren't already.
- `MeetupService.listOpenMeetups`: thread nothing new here — `viewer_trust_level` is entirely gateway-sourced, the frontend never sends it.

## Step 2 — `_MeetupCard`'s locked treatment (`matches_page.dart`)

- When `meetup.lockedForViewer`, render a blur/lock visual in place of host avatar, host name, location label, and time — a frosted/blurred placeholder shape with a small lock icon and short caption (e.g. "Verify to see details"), not literally blank space. Keep intent tag, accepted-count/capacity, and status badge rendered normally (these are never redacted server-side, so they're always real data).
- The "REQUEST TO JOIN" button is no longer disabled for a locked meetup — it's a normal enabled button. Tapping it (or tapping anywhere else on the card) does NOT navigate to the meetup detail page; instead: `showSnack(context, ..., type: ToastType.locked)` (reuse the existing wording pattern/mechanism from the intent-picker sites, don't invent new copy) immediately followed by `Navigator.push` to the new `VerificationChecklistPage` (Step 4).
- Unlocked meetups are completely unaffected — normal card, normal navigation to the detail page, normal enabled join button hitting the real RPC.

## Step 3 — `meetup_detail_page.dart`'s join action

- Since a locked card never navigates here (Step 2), this page's `_buildJoinAction` mainly needs updating as a defensive fallback (e.g. reachable via a notification deep link) rather than the primary path — but apply the same fix for consistency: drop the disabled-button pattern, same toast + push-to-checklist behavior as the card.

## Step 4 — New `VerificationChecklistPage`

- New screen: a short header explaining why the user landed here ("Unlock joining meetups — complete these to reach Level 2 trust"), then a list of exactly Level 2's requirements, each as its own row with done/not-done status (read from the same profile fields `ProfilePage`'s existing verification rows already use):
  - "Connect LinkedIn" (if not linked) — reuses whatever existing LinkedIn-connect action/banner logic `ProfilePage`'s `_ConnectLinkedInBanner` already has, don't rebuild the OAuth flow.
  - Phone — tapping pushes the existing `PhoneVerificationPage` (same widget `ProfilePage` already uses, not a new one).
  - Personal email — pushes the existing `PersonalEmailVerificationPage`.
  - Personal details (legal name) — pushes the existing `PersonalDetailsPage`.
  - **Do not include corporate/work email** — that's Level 3, out of scope for this checklist, which is specifically about reaching Level 2.
- After each pushed page pops (any of the four above), re-fetch the profile (same `completeVerification`-style refresh already used elsewhere) so the row's done/not-done status updates immediately, not on next app launch.
- A `Complete` button, disabled until all four rows show done, enabled once they do. On tap: pop back to wherever the user came from (the browse screen or detail page) — do not attempt to automatically retry the join action that got them here; the next tap on REQUEST TO JOIN will simply work since the meetup is no longer locked for them. Keep this simple for now.

## Step 5 — Tests

- Widget test: a locked meetup card shows the blur/lock treatment, tapping it (or its join button) shows the toast and navigates to `VerificationChecklistPage`, never to the detail page.
- Widget test: an unlocked meetup card behaves exactly as before this change (regression guard).
- Widget test: `VerificationChecklistPage` shows all four rows as not-done initially (mock profile with nothing verified), `Complete` disabled; after simulating each verification page returning success, the corresponding row flips to done and `Complete` becomes enabled once all four are done.
- Widget test: `VerificationChecklistPage` never renders a corporate/work-email row.
- Full checklist: `flutter analyze --fatal-infos`, `dart format --set-exit-if-changed`, `flutter test` — report the real total test count.
