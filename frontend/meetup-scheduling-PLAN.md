# Meetup Scheduling & Join Requests — Execution Plan (Frontend)

Companion to `backend/meetup-scheduling-PLAN.md` — same REST contract, gateway base URL, auth pattern. Read ADR-013 (`04 - Decisions/ADR-013 - Host-Initiated Meetup Scheduling with Join Requests.md`) first for the *why*.

**Sequencing: do not start until the Level 2/3 verification addendum and the session-refresh wiring fix (both in `frontend/PLAN.md`) are merged.** This slice reads `trust_level` off `authSessionProvider`'s session/profile state and depends on `getAccessToken`/`TokenRefresher` being the stable, already-wired mechanism, not something still mid-change.

## Scope boundary

**In scope**: retiring `MatchesPage`/`MockMatchingService`/`MatchProfile` in favor of a real "browse open meetups" list; a Schedule flow (Today / Later) with intent, Google Places location picker, capacity, and a review step; My Meetups (hosted + requested, with host accept/reject UI showing requester name + trust level); wiring `HomePage`'s `UpcomingMeetupCard` and its Check-in/safety-checklist stub taps to real data and real screens; the Safety Gate sub-flow (checklist, live-location opt-in, check-in, post-meetup feedback); FCM push notification registration and foreground/background handling; the `IntentType.requiredTrustLevel` floor change (ADR-013).

**Explicitly not in scope**: any UI for the Phase 3 compatibility-matching engine, real-time in-app socket updates (poll/pull-to-refresh on My Meetups for this slice — swap in real-time once the Realtime Gateway exists), ride-share-specific verification screens, SOS/emergency UI beyond what already exists, in-app chat.

## Prerequisites (human, not Claude Code)

1. **Mapbox access tokens** (switched from Google Maps/Places 2026-08-18, before any build started — see ADR-013 §4 for the full reasoning) — Shashika creates a Mapbox account and generates a public, URL/bundle-restricted access token for the SDK plus a Search-scoped token, and provides them. No GCP project or Google Cloud billing account needed for this piece. Claude Code should NOT hardcode a token anywhere committed — wire through the existing build-time config pattern (`AppConfig`, same mechanism as `linkedInClientId`) with placeholders and a clear README note on where to put the real values locally.
2. **Firebase project for FCM** — Shashika (or whoever holds the Firebase console) downloads `google-services.json` (Android) and `GoogleService-Info.plist` (iOS) once the project exists and provides them; Claude Code wires the `firebase_core`/`firebase_messaging` setup assuming these files land in their standard locations, but should not fabricate placeholder files that look real — use the package's documented "not yet configured" fallback / clearly-marked dummy so a missing file fails loudly in dev, not silently in production.
3. Confirm `backend/meetup-scheduling-PLAN.md`'s service is reachable locally before building the client against it.

## Step 1 — New dependencies

- `mapbox_maps_flutter` — official Mapbox SDK, map render + pin-drop for the location step.
- Mapbox Search Box API via direct HTTP calls (`http`, already a dependency) or `mapbox_search` if its current Flutter/iOS support is solid at build time (Claude Code's call) — address search/autocomplete for the location step, resolves a selection to lat/lng + a formatted label.
- `geolocator` — "use my current location" convenience on the location picker; this is also what actually triggers the iOS/Android location-permission prompts, not the map package itself.
- `firebase_core`, `firebase_messaging` — FCM registration and foreground/background notification handling (unrelated to the Mapbox switch — still Firebase, just for push, not maps).

## Step 2 — Platform permission strings (closes a gap `CLAUDE.md` already flagged)

`CLAUDE.md`'s Known Gaps note: `frontend/ios/Runner/Info.plist` has no usage-description keys yet because nothing needed them — this slice is the first feature that does (map "current location" button, optional live-location sharing during an active meetup). Add:
- iOS: `NSLocationWhenInUseUsageDescription` (a real, specific sentence — "Used to show your current location when scheduling or attending a meetup" style, not a placeholder).
- Android: `ACCESS_FINE_LOCATION`/`ACCESS_COARSE_LOCATION` in `AndroidManifest.xml`.

Do this before wiring `geolocator` calls, not after — a permission request with no usage string is a hard crash on iOS, not a soft failure.

## Step 3 — Models

`Meetup` (id, host, intent, `DateTime? scheduledFor` — null means now/today, location lat/lng + label, capacity, acceptedCount, status, `isHostedByMe`/`myRequestStatus` convenience fields for list rendering), `MeetupRequest` (id, meetupId, requester summary — name, trust level, profile photo — status, autoRejected, timestamps). Mirror the backend's enums exactly (`open`/`full`/`cancelled`/`completed`; `pending`/`accepted`/`rejected`/`withdrawn`) — don't invent client-side states that don't exist server-side.

## Step 4 — `MeetupService` contract + `HttpMeetupService`

Same `abstract interface class` + `Mock*`-for-tests pattern as `AuthService`. Methods mapping 1:1 to the backend's RPCs (Step C of the backend plan): `createMeetup`, `listOpenMeetups` (cursor-paginated, intent filter — replaces `MatchingService.fetchMatches`' role), `getMeetup`, `listMyMeetups`, `requestToJoin`, `withdrawRequest`, `respondToRequest`, `cancelMeetup`, `registerDeviceToken`, `acknowledgeSafetyChecklist`, `setLiveLocationOptIn`, `checkIn`, `submitMeetupFeedback`. Wire `meetupServiceProvider` in `app_providers.dart` next to `authServiceProvider`, same `getAccessToken`-via-`TokenRefresher` wiring (reuse the same `TokenRefresher` instance/provider — don't construct a second one).

## Step 5 — Trust gating in `IntentType`

Update `frontend/lib/core/models/intent_type.dart`'s `requiredTrustLevel`:
```dart
int get requiredTrustLevel => switch (this) {
  IntentType.rideShare || IntentType.dating => 4,
  _ => 2, // was 1 — ADR-013: Level 2 is the real floor for stranger meetups
};
```
Anywhere the app currently gates on `isUnlockedFor` should already pick this up automatically. Add a visible, non-punitive prompt (not just a disabled button with no explanation) when a Level 1 user taps something gated at 2 — point at the relevant `ProfilePage` verification screens (phone/personal email/personal details, already built) rather than a dead end.

## Step 6 — Browse open meetups (replaces `MatchesPage`)

Keep the existing `MatchesPage` file/route as the mount point (least navigation churn) but swap its internals: `matchesProvider`/`MatchProfile`/`MockMatchingService` → a new `openMeetupsProvider(IntentType)` backed by `meetupServiceProvider.listOpenMeetups`, `_MatchCard` → a meetup card showing host name/trust level, intent, timing (now vs. scheduled date/time), location label, `accepted/capacity` count, and a real "REQUEST TO JOIN" button calling `requestToJoin` (replacing the current `showSnack('Meetup request sent...')` stub with a real call + real success/error toast). Delete `MockMatchingService`/`MatchProfile`/`matchesProvider` once nothing references them — don't leave dead mock code alongside the real thing.

Add an entry point for hosting: a prominent "Schedule a Meetup" action (FAB or app-bar action on this same page) opening Step 7's flow.

## Step 7 — Schedule flow (Today / Later)

New `frontend/lib/features/meetups/` folder (mirrors `features/verification/`'s shape: a page per step, shared widgets in `widgets/`):
1. **Entry**: two options, "Schedule Today" and "Schedule for Later" — the only difference is whether step 2 shows a date/time picker (Later) or defaults to now (Today). Don't build two parallel flows; one flow with a conditional step.
2. **Intent** — reuse `intent_picker_sheet.dart`, filtered/annotated to show which intents the current user's trust level actually unlocks (Step 5).
3. **Timing** (Later only) — a calendar date picker + time-slot picker. Flutter's built-in `showDatePicker`/`showTimePicker` is enough for v1 — a custom calendar widget is polish, not a functional requirement; don't over-build this.
4. **Location** — `mapbox_maps_flutter` map + Mapbox Search Box search bar (bias results toward POI-category places per ADR-013 § 4) + "use current location" (via `geolocator`) + pin-drop-to-adjust. Show the existing pre-meetup safety copy from Safety UX Flows.md ("Choose a public place...") directly on this screen, not buried elsewhere.
5. **Capacity** — a simple stepper, 1-20 (matches the backend's `CHECK` constraint — keep these in sync).
6. **Review & confirm** — summary of all of the above, calls `createMeetup`, navigates to the new meetup's detail page (Step 9) on success.

## Step 8 — My Meetups + request management

A new section (tab within the browse page, or its own entry from `HomePage` — Claude Code's call on IA, but it must be reachable without more than one tap from Home) listing meetups the user hosts and meetups they've requested to join, each showing status. Tapping a hosted meetup with pending requests shows the requester list: name, trust level (a simple badge, not the raw number — reuse whatever trust-level display component `ProfilePage` already has, don't invent a second one), Accept/Reject buttons per request. Rejecting or accepting calls `respondToRequest` and shows the result; the UI should distinguish a host's explicit rejection from a system auto-reject (`auto_rejected` flag) if a requester views their own resolved request.

## Step 9 — Meetup detail page + Safety Gate

Replaces `UpcomingMeetupCard`'s hardcoded "Coffee with Sachini Fernando" text and its two stub `showSnack` taps with a real detail page bound to real `Meetup` data:
- Header: intent, timing, location, participants.
- **Safety checklist**: shown once at least one request is accepted; must be acknowledged (`acknowledgeSafetyChecklist`) before check-in unlocks — matches Safety UX Flows.md's step order (checklist before check-in, not after).
- **Live-location opt-in**: a clear, optional toggle (`setLiveLocationOptIn`) with the existing verified-badge-style disclaimer tone — optional, not required to proceed, per Safety UX Flows.md.
- **Check-in**: replaces the current "Check-in opens 10 minutes before the meetup" toast stub with the real thing — button disabled with that same message until 10 minutes out, then calls `checkIn`.
- **Post-meetup feedback**: triggered after the scheduled time passes (or manually, "meetup happened early") — the five questions from Safety UX Flows.md (did it happen, felt safe, profile accurate, would meet again, want to report), submitted via `submitMeetupFeedback`. A report answer routes into whatever reporting flow already exists rather than being a dead field.

`HomePage`'s "YOUR NEXT MEETUP" card becomes a real preview of the soonest upcoming confirmed meetup (or hides itself if there isn't one — don't show a stale/fake card when the user has nothing scheduled), tapping through to this detail page.

## Step 10 — Push notifications

`firebase_messaging` setup: request permission (iOS needs an explicit prompt; Android 13+ also needs runtime `POST_NOTIFICATIONS`), get the device token, call `registerDeviceToken` once after login/verification and again whenever the token rotates (`onTokenRefresh` listener). Handle: foreground messages (show an in-app banner/toast, don't rely on the OS tray while the app is open), background/terminated tap-through (deep-link to the relevant meetup's detail page using the notification's `data` payload — needs the meetup ID, nothing else sensitive in the payload).

## Tests

- Unit: `IntentType.requiredTrustLevel`'s new values; capacity-stepper bounds; timing-step conditional logic (Today vs Later).
- Widget: browse list renders real `Meetup` data and calls `requestToJoin` on tap (fake `MeetupService`); host request-management screen renders Accept/Reject and calls the right method with the right request ID; check-in button's enabled/disabled state around the 10-minute boundary; safety checklist gates check-in until acknowledged.
- Manual, noted in the PR same as prior slices: a real end-to-end pass — host schedules today, a second test account requests to join, host accepts, both see updated state, checklist → check-in → feedback, and a push notification actually arrives on a real device (simulators don't reliably deliver FCM — confirm on physical hardware).

## Self-review checklist

- [ ] `MockMatchingService`/`MatchProfile`/the old `matchesProvider` are fully removed, not left as dead code next to the real implementation.
- [ ] No trust-level check is duplicated-and-diverged from `IntentType.requiredTrustLevel` — one source of truth in the client (server still re-checks independently, per the backend plan).
- [ ] `NSLocationWhenInUseUsageDescription`/Android location permissions are in place before any `geolocator` call ships, and the permission-denied path shows a real explanation, not a silent no-op.
- [ ] The Safety Gate step order matches Safety UX Flows.md exactly (checklist before check-in, live-location is optional not required, feedback asks all five questions).
- [ ] No Mapbox access token is committed in source — confirm via a diff scan before merging, same discipline as any other secret.
- [ ] `flutter analyze`/`dart format --set-exit-if-changed .`/`flutter test` all clean.
- [ ] Bring the diff back to Cowork for review before merging.

## Explicitly not in this addendum

Waitlist UI (auto-reject only, ADR-013), in-app chat, ride-share-specific screens, real-time socket-based live updates (poll/refresh only), a custom calendar widget beyond the platform date/time pickers.

## Addendum (2026-08-18): Testing with Stadia Maps — not the production decision

**Status framing, read this first**: ADR-013 §4's second correction explains why — Mapbox's card requirement and its Sri Lanka geocoding coverage couldn't be confirmed, so Shashika created a Stadia Maps key (no card required) purely to get the location step actually running and testable now. **The final vendor is still open between Google Maps and Mapbox.** Build this so swapping later is contained to one widget, not a rewrite — that constraint shapes every decision below.

### Step 1 — Dependency: `maplibre_gl`, not `mapbox_maps_flutter`

Add `maplibre_gl` to `pubspec.yaml` for this testing pass — it renders MapLibre-style vector tiles, which is what Stadia Maps (and MapTiler, if that's ever chosen instead) serve. **Do not also add `mapbox_maps_flutter` right now** — if Mapbox ends up being the final choice, that's a deliberate future swap with its own step, not something to half-wire speculatively today. Note this explicitly in the PR description so it's clear this diverges from ADR-013's original Step 1 dependency list on purpose, not by oversight.

### Step 2 — `AppConfig` addition

Add a Stadia Maps API key field following the exact existing pattern (`String.fromEnvironment`, `--dart-define`, no hardcoded real value):

```dart
static const String stadiaMapsApiKey = String.fromEnvironment(
  'STADIA_MAPS_API_KEY',
  defaultValue: '',
);
```

Empty default, same as every other credential in this file — confirm the real value is passed via `--dart-define=STADIA_MAPS_API_KEY=...` at run time, never written into source. This is a real, working API key (unlike Twilio/Resend's empty-means-fallback pattern) — if it's empty, the location step should show a clear "not configured" state rather than silently failing, same spirit as the manual-entry stopgap's own visible banner.

### Step 3 — Comment out, don't delete, the manual-entry stopgap

In `schedule_flow.dart`, the current `_LocationStep` class (manual lat/lng/label text entry, with the "map search is pending" banner) stays in the file, fully intact, wrapped in a clearly marked comment block explaining it's the fallback if the active map provider ever needs to be temporarily disabled again (e.g., a bad API key, a provider outage during a demo). Rename the *active* one to something provider-neutral in the switch statement's usage — not `_StadiaLocationStep` — so the next swap doesn't require renaming call sites again. `_MapLocationStep` is a reasonable name; Claude Code's call on exact naming, but it should not bake "Stadia" into anything other than the one file/section that actually calls Stadia's API.

### Step 4 — The real location step

New widget (same file or a new one under `features/meetups/widgets/`, Claude Code's call): `maplibre_gl`'s map widget pointed at Stadia's map style URL (`https://tiles.stadiamaps.com/styles/<style>.json?api_key=...` — confirm the exact current style name and URL shape against `docs.stadiamaps.com` directly, don't guess), with:
- A pin that follows either the map's center or a tap-to-place gesture (Claude Code's call on which feels better; center-pin-with-a-fixed-crosshair is the simpler one to implement correctly).
- A search bar calling Stadia's Autocomplete/Search endpoint (`docs.stadiamaps.com`'s Geocoding & Autocomplete Search section — confirm the exact query-parameter names and response shape against their live docs rather than assuming; use the plain `http` package already in this project, same as every other REST call here, not a new SDK just for this one endpoint) — selecting a result recenters the map and fills in the label.
- "Use my current location" via `geolocator` (Step 1/2 of the base plan above still apply — this is when the iOS/Android location-permission strings actually become necessary; add them now if they weren't already).
- The same "Choose a public place..." safety copy from Safety UX Flows.md that the stopgap version already shows — this requirement doesn't change with the provider.
- If `AppConfig.stadiaMapsApiKey` is empty, show a clear "location search isn't configured" message rather than a blank/broken map.

### Step 5 — Update `TESTING-NOTES.md`

Add a new section to `TESTING-NOTES.md` (repo root — read the existing OTP-bypass section first and match its format exactly: what changed, files touched, how this gets superseded, known caveats) documenting: Stadia Maps is a provisional test provider, not a production decision; which files were added/changed; that switching to the eventual real provider means replacing the widget from Step 3/4, not just an env var, unless the final choice turns out to also be MapLibre-compatible. This is a real implementation detail only known after this step is actually built, so write it last, after the code is done — don't speculate ahead of the actual diff.

### Self-review checklist (this addendum)

- [ ] The original `_LocationStep` (manual entry) is still in the file, commented out, not deleted.
- [ ] No Stadia-specific naming leaked into the switch statement or any call site outside the one widget that actually talks to Stadia's API.
- [ ] `stadiaMapsApiKey` is read via `AppConfig`/`--dart-define`, never a literal string in source.
- [ ] The public-place safety copy is present on the real version, not just the stopgap.
- [ ] `TESTING-NOTES.md` has a new, accurate section for this change, written after the code exists.
- [ ] `flutter analyze`/`dart format --set-exit-if-changed .`/`flutter test` all clean.
- [ ] Confirm Stadia's actual current style URL and geocoding query/response shape against `docs.stadiamaps.com` directly rather than trusting this plan's description of them — API details drift and weren't independently re-verified line-by-line here.

## Addendum (2026-08-18): Platform-split picker (Apple MapKit on iOS) + search fix

**Read ADR-013 §4's third correction first** — the reasoning for why this splits by platform, and why iOS is now settled while Android stays on the provisional Stadia Maps choice from the addendum above.

**Also fixes a real bug**: address search in the current Stadia-backed picker isn't working. Diagnose and fix this as part of the same pass, not as a separate follow-up — don't build the new interaction pattern below on top of a search call that's already broken without first confirming why.

### Step 1 — `_MapLocationStep` becomes a platform switch, same external contract

The widget instantiated from `schedule_flow.dart`'s step switch keeps its existing name and its existing `onSubmit(lat, lng, label)` contract — internally it now picks between two implementations based on `Platform.isIOS`/`Platform.isAndroid` (or `defaultTargetPlatform`, whichever this codebase already prefers elsewhere — check for an existing convention before introducing a new one). The two implementations:

- **iOS**: Apple MapKit, via `apple_maps_flutter` or whatever current, well-supported Flutter/MapKit binding exists at build time — confirm the package is actively maintained before committing to it, the Flutter-MapKit ecosystem has had churn. No API key, no `AppConfig` entry needed for this path.
- **Android**: the existing Stadia Maps (`maplibre_gl`) implementation from the addendum above, with its search bug fixed (Step 3 below).

Both still show the same "Choose a public place..." safety copy and both still respect an equivalent "not configured" fallback state if their respective dependency isn't available (though MapKit, being bundled with iOS, should essentially never hit that state the way a missing Stadia key can).

### Step 2 — Shared search interaction contract, both platforms

Match Apple Maps' own established UX rather than inventing a new pattern, since iOS users already know this interaction:

1. Tapping the search field focuses it and shows a suggestions list as the user types, refreshed on a short debounce (roughly 300ms is the usual floor for typeahead — avoid firing a request per keystroke).
2. Tapping a suggestion selects it, recenters the map on it, drops/moves the pin there, and fills in the location label — no separate "confirm" tap needed at that point.
3. **Also** support typing a complete query and pressing the keyboard's search/return action without tapping a suggestion — this should run a direct search/geocode of the typed text and produce the same recenter-and-pin-drop result as picking a suggestion.
4. Either path is equally valid; a user shouldn't be forced through the suggestions list if they already know exactly what they want to type.

**iOS implementation**: MapKit's local search completer (`MKLocalSearchCompleter`) is the native API built for exactly this pattern — debounced, incremental completions as the user types — and a full `MKLocalSearch` resolves either a selected completion or free-typed text into coordinates. Use whichever Flutter binding exposes this if the chosen MapKit package supports it; if the map-rendering package doesn't also expose search, that's a second, smaller package/platform-channel decision — flag it rather than silently downgrading iOS to a weaker search experience than what MapKit natively offers.

**Android implementation**: Stadia's Autocomplete endpoint for the debounced suggestions list, Stadia's Search/Geocoding endpoint for the direct-submit path — both already named in the addendum above; this step is about wiring the *interaction* (debounce timer, suggestion list UI, submit-without-selecting handling), which is what's currently missing/broken, not about discovering new Stadia endpoints.

### Step 3 — Diagnose and fix the current Stadia search bug

Before adding the new interaction pattern, find out why the existing search doesn't work — check, in order: is `AppConfig.stadiaMapsApiKey` actually populated at run time (was `--dart-define=STADIA_MAPS_API_KEY=...` passed to `flutter run`?), does the request actually reach Stadia's endpoint (log or breakpoint the HTTP call), does Stadia return a non-200 (bad param name, wrong auth placement — key as query param vs. header — confirm against `docs.stadiamaps.com` directly), or does the response parse fail (response shape assumption wrong). State which of these it turns out to be in the PR description — that's useful signal for whether this class of bug is likely to recur.

### Tests

- Widget test: typing in the search field with a fake debounced provider triggers exactly one suggestion-fetch per debounce window, not one per keystroke.
- Widget test: selecting a suggestion and, separately, submitting free-typed text via the search action both result in `onSubmit` being called with coordinates — two distinct paths to the same outcome.
- Platform-conditional test coverage for both the iOS and Android branches of `_MapLocationStep` (fakes/mocks for whichever native search API is used on iOS, same fake `MeetupService`-style pattern already used elsewhere for Android/Stadia).

### Self-review checklist (this addendum)

- [ ] The Stadia search bug's root cause is identified and stated, not just papered over by the new debounce logic coincidentally masking it.
- [ ] iOS path requires no `AppConfig` entry, no API key, no billing setup — confirm by running with `STADIA_MAPS_API_KEY` unset and verifying iOS still works fully.
- [ ] Both platforms support both interaction paths (suggestion-tap and type-and-submit), not just one.
- [ ] Debounce actually reduces request volume — verify with the widget test above, don't just eyeball it.
- [ ] `flutter analyze`/`dart format --set-exit-if-changed .`/`flutter test` all clean on both platform configurations if CI or local tooling can exercise both.
- [ ] Bring the diff back to Cowork for review before merging.
