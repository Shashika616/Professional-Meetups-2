# Claude Code prompt 29E: analytics in the Flutter app

Read first: `docs/plans/29-credits-billing-analytics.md` (sections 4.1 to 4.3), `docs/api/analytics.md`, `frontend/lib/core/analytics/event_names.g.dart` (generated in 29D), `frontend/lib/main.dart`, `frontend/lib/app_shell.dart`, `frontend/lib/core/providers/app_providers.dart`, `frontend/lib/features/privacy/privacy_controls_page.dart`, and every page class listed in the screen catalogue below.

## Goal

The app records sessions, screens with time on screen, catalogued actions, funnels, and friction signals, privately and without affecting performance, so the daily report can show the whole picture.

## Hard rules

1. Never send names, emails, phones, free text, meetup labels, coordinates, receipts or raw user ids; the server builds `user_key`. Attributes only from the generated registry; adding an event means editing `events.yaml` in the backend and regenerating.
2. No new third-party analytics SDK (no Firebase Analytics); one small in-house client.
3. Analytics must never block the UI or a user action: events are queued in memory, persisted in a bounded local queue (500 events, oldest dropped), flushed every 30 seconds, at 20 events, and when the app goes to the background; retries with backoff; nothing sent while offline or opted out.
4. Opt-out toggle in Privacy Controls, stored locally and sent to `PUT /v1/analytics/consent`; when off, the queue is cleared and nothing is recorded.
5. Behaviour of existing screens must not change. Tests stay green.

## Work, in order

1. `lib/core/analytics/`: `AnalyticsClient` (envelope with UUIDv7 `event_id`, session id, install id, app and OS version, coarse device class, locale), `AnalyticsQueue` (bounded, persisted with `shared_preferences` or a small file), `HttpAnalyticsTransport` (wraps `DeadlineHttpClient`, gzip, honours 429 and `analytics.sample_rate` from app config), provider wiring, and a no-op implementation for tests.
2. **Sessions**: lifecycle observer in `AppShell`; new session after 30 minutes in the background; `app_opened`, `session_started`, `session_ended` with duration.
3. **Screens**: give every route a stable name with `RouteSettings(name:)` from a single `ScreenNames` catalogue (all 51 routes and the four tabs, which change through `currentTabIndexProvider`); a `NavigatorObserver` plus tab listener emits `screen_viewed` and `screen_left` with `duration_ms` (paused while the app is in the background). Bottom sheets and dialogs named too (schedule conflict, join confirmation, share with contacts, participant review, account claim, SOS confirm).
4. **Actions**: a `track(Cta.x)` helper called from the catalogued controls only: host your own meetup, I'm interested, view location, accept and reject request, withdraw, cancel and close meetup, filter chips, verify buttons, add trusted contact, trigger SOS, buy credits, subscribe, restore, edit name, sign out, delete account, theme switch.
5. **Flows**: `FlowTracker` with `flow_started`, `flow_step_viewed`, `flow_step_completed`, `flow_completed`, `flow_abandoned` (on leaving the flow or backgrounding for more than 30 minutes) for onboarding, verification checklist, hosting unlock, schedule a meetup (5 steps), join a meetup, review, buy credits, subscribe, SOS.
6. **Friction**: `error_shown` from `LoadFailedState`, error snack bars and failure states (kind only, no message text); `api_error` from the HTTP services (route template and status class, not the URL); timeouts; `rage_tap` from a global pointer listener (3 or more taps within one second inside a 24 px radius with no route change); `long_dwell` when a form step stays open over 60 seconds without input.
7. **Privacy Controls**: replace the "Controls are coming" notice with the real analytics toggle and one line on what is collected; keep the rest of the page unchanged.

## Tests that must exist

- Envelope never contains forbidden fields (scan the serialised JSON of every event type).
- Queue bound, persistence across restart, flush triggers, offline hold, backoff, opt-out clears and stops.
- Every named route emits `screen_viewed` and `screen_left`; tab swipes and taps both counted; background time excluded from duration.
- Schedule flow funnel: steps in order, completion, abandonment on back and on backgrounding.
- Rage tap and long dwell detection with `fake_async`.
- Existing test suite still green.

## Finish

`flutter analyze --fatal-infos`, `dart format --set-exit-if-changed`, `flutter test`. Report at `docs/plans/29E-completion-report.md` with the final screen and event catalogue. Do not start 29F.
