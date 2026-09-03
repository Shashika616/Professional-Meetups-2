# Frontend plan — 40km geo-visibility + nearby-meetup notifications (ADR-021)

Read `docs/04-decisions/adr-021-geo-visibility-radius-and-nearby-meetup-notifications.md` first. Backend contract is defined in `backend/geo-visibility-and-nearby-notifications-PLAN.md` (Step 2 for the `ListOpenMeetups` lat/lng params, Step 3 for `UpdateLastKnownLocation`) — the backend team's landed RPC names/shapes are the source of truth if this plan and the backend plan ever disagree once both are implemented.

**What exists today**: `matches_page.dart` (the real browse-open-meetups surface, ADR-013) calls `MeetupService.listOpenMeetups` with no location parameters at all. No location-permission code exists anywhere in the app yet — `Info.plist` has no usage-description keys (per CLAUDE.md's iOS notes) and neither does the Android manifest.

## Step 1 — Platform permission plumbing (prerequisite, do this first)

- Add `NSLocationWhenInUseUsageDescription` to `ios/Runner/Info.plist` and the matching `ACCESS_FINE_LOCATION`/`ACCESS_COARSE_LOCATION` (coarse is sufficient per ADR-021 § 4's "city-block-ish precision is enough" — request coarse only if the platform allows requesting coarse alone; if the plugin doesn't distinguish, fine is acceptable but only fine-precision it actually needs is what gets displayed/stored) to the Android manifest. CLAUDE.md's existing iOS note already anticipated this exact moment ("before implementing anything that touches live location... add the corresponding usage-description key").
- Pick a location plugin (check `pubspec.yaml` for one already present before adding a new dependency — none currently exists per the "no plugin needs them yet" note in CLAUDE.md).

## Step 2 — On-demand location read on the browse screen

- On `matches_page.dart` open (or pull-to-refresh), request current location **once**, on demand — no `Stream`/continuous listener, matching the on-demand-only decision.
- **Permission denied or location services off**: render the screen blurred (reuse `Glass`/existing blur patterns from `core/widgets/`, don't invent a new blur mechanism) with a prompt: "Turn on location to see meetups near you" and a button that opens system location settings. Do not silently fall back to an unfiltered list and do not show an empty list without explanation — ADR-021 § 3 is explicit that this must be a visible block, not silent.
- On successful read: pass `lat`/`lng` into `MeetupService.listOpenMeetups(...)` (interface gains these as required parameters, mirrored in `MockMeetupService` and `HttpMeetupService` per the service-contract pattern in CLAUDE.md's Architecture section).
- In the same success path, fire-and-forget call `MeetupService.updateLastKnownLocation(lat, lng)` — same coordinate, same moment, no separate trigger, no periodic timer. This is the only call site for this method anywhere in the app (mirrors the backend plan's Step 3 constraint — grep for it during review to confirm exactly one call site).

## Step 3 — Service contract additions

- `MeetupService` (interface in `core/services/`): add `lat`/`lng` params to `listOpenMeetups`, add `Future<void> updateLastKnownLocation(double lat, double lng)`.
- `MockMeetupService`: ignore lat/lng for filtering (mock data is small/static) but accept the parameters so call sites compile identically to the real implementation; `updateLastKnownLocation` can just be a no-op or log.
- `HttpMeetupService`: wire both through to the new backend endpoints.

## Step 4 — Push notification receipt (client side of "nearby meetup" notifications)

- This app already has FCM wiring from the existing notification infrastructure (meetup-request accept/reject/cancel notifications, ADR-020) — confirm the existing notification-tap-routing code (wherever that's handled today) gains a case for the new "nearby meetup created" notification type, routing to that meetup's detail page. Don't build a second, parallel FCM handling path.

## Step 5 — Tests

- Widget test: browse screen shows the blur+prompt state when location permission is denied (mock the location plugin's permission-denied response).
- Widget test: browse screen calls `listOpenMeetups` with the coordinates returned by a successful location read.
- Unit test confirming `updateLastKnownLocation` is called exactly once per successful location read, not on every rebuild.
- Full checklist: `flutter analyze`, `dart format --set-exit-if-changed`, `flutter test` all clean, consistent with every prior slice.

## Note on scope

Do not add a settings toggle for "share my location for nearby notifications" as part of this slice — ADR-021 treats this as an implicit, unavoidable consequence of using the browse screen at all (§ 4), not a separately consented feature. If this feels like it deserves its own opt-out, flag it rather than silently adding one; that would be a scope change to ADR-021 itself, not an implementation detail.
