# Frontend plan — Round 8: stop hardcoding the placeholder label, null-safety for now-optional coordinates, new View Location + Directions feature (ADR-029)

See `docs/04-decisions/adr-029-location-reverse-geocoding-coordinate-redaction-and-in-app-location-view.md` and `docs/00-project/action-tracker.md` § 4b-21 for full context. Depends on the backend plan's proto change (coordinates become nullable) landing first or alongside — coordinate with that before starting the null-safety pass below.

## Step 1 — Stop hardcoding the "Current location" placeholder

In both `stadia_map_location_step.dart` and `ios_map_location_step.dart`'s `_useCurrentLocation()`: remove the `setState(() => _searchController.text = 'Current location')` line (or whatever the exact current string/line is — confirm before editing). Leave the search field empty when the user taps "use current location" without having typed a query — the server now handles turning an empty label into a real one (backend plan, Step 2). `_submit()` should send whatever's actually in the field (empty string is fine now, not a bug).

Consider (use your judgment, note the choice in your report): should the UI show a brief "resolving location..." affordance between tapping "use current location" and the meetup being created, given the server-side geocoding call adds a small amount of latency to `CreateMeetup`? This isn't required by the plan, but flag it if the existing submit-button loading state already covers this or if it looks like a genuinely bad UX gap.

## Step 2 — Null-safety pass on `locationLat`/`locationLng`

Once the backend makes these fields nullable (proto3 `optional`), grep the whole frontend for every place that reads `meetup.locationLat`/`meetup.locationLng` (or whatever the generated Dart field names are) and confirm none of them force-unwrap or assume non-null. This is the same class of fix Rounds 5-6 already did for `hostFullName`/`locationLabel`/the window fields — apply the same defensive pattern (check `lockedForViewer` first, or null-check the specific field directly), not a new pattern.

## Step 3 — New "View Location" entry point

- Add a "View Location" action to both `matches_page.dart`'s meetup card and `meetup_detail_page.dart` — reuse whichever composition pattern the existing REQUEST TO JOIN button/card-tap gating already uses (ADR-028/Round 7): if `meetup.lockedForViewer` is true, tapping shows the same `ToastType.locked` toast and redirects to `VerificationChecklistPage`, exactly like every other gated site — no new gating logic, this is the same check reused a sixth time.
- If unlocked, navigate to a new read-only location-view page/bottom-sheet. Build this by reusing each platform's existing map-rendering widget (`StadiaMapLocationStep`'s underlying `MapLibreMap` usage on Android, `IosMapLocationStep`'s underlying `AppleMap` usage on iOS) in a stripped-down **preview mode**: no search bar, no draggable crosshair pin, just a static camera centered on the meetup's `(locationLat, locationLng)` with a marker, and the resolved `locationLabel` displayed as text. Do not duplicate the full picker widget — factor out just the map-rendering piece if it's cleanly separable, or wrap the existing widget with picker-only UI (search bar, submit button, crosshair) hidden/disabled if factoring out isn't clean; use your judgment on which is less invasive and say which you chose.
- A meetup that's `lockedForViewer` should never reach this view at all (the redirect above prevents it) — but as defense-in-depth (same reasoning as Rounds 5-6's stale-force-unwrap fixes), the location-view page itself should also handle `locationLat`/`locationLng`/`locationLabel` being null gracefully rather than crashing, in case it's ever reached some other way in the future.

## Step 4 — "Get Directions" button

On the same location-view page: a button that builds `https://www.google.com/maps/dir/?api=1&destination={lat},{lng}` (URL-encode as needed) and opens it via `url_launcher`'s `launchUrl` — same package already used for the SOS page's `tel:` scheme (`safety_page.dart`), no new dependency. Use `LaunchMode.externalApplication` so it hands off to an installed maps app rather than trying to render inside the app's own webview.

## Tests

- A widget test for the placeholder-removal (Step 1): tap "use current location," assert the search field/submitted label is empty, not the old hardcoded string.
- A widget test for the new View Location gating (Step 3): locked meetup → tap "View Location" → toast + redirect to `VerificationChecklistPage`, no map page pushed. Unlocked meetup → tap → map preview page pushed, marker/label rendered from the meetup's actual coordinates/label.
- A widget test for "Get Directions" (Step 4): tapping it triggers a `launchUrl` call with the expected URL shape (mock/intercept `url_launcher`'s platform channel the same way any existing `url_launcher` test in this codebase already does, if one exists — check `safety_page_test.dart` for the pattern).

## Do not

- Do not build a second, independent map-rendering implementation for the preview — reuse the existing per-platform widgets' map-rendering code, only stripped of interactive picker chrome.
- Do not add any gating logic beyond the existing `lockedForViewer` check — this feature uses the same lock as everything else, per ADR-029's decision.
- Do not implement in-app routing/directions — deep-link only, per ADR-029's decision.

## Full checklist

`flutter analyze --fatal-infos`, `dart format --set-exit-if-changed`, `flutter test` — report the real total from the test runner's own summary line.
