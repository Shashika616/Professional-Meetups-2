# 29E completion report: analytics in the Flutter app

This is the working tree only. Nothing is committed, built for a store or
deployed. Test users, seeded emails and the OTP bypass are unchanged. 29F has
not started.

## Gates

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | No issues |
| `dart format --set-exit-if-changed lib test` | Clean |
| `flutter test` | 877 pass (843 existing, all still green, plus 34 new) |
| Backend (registry and generator changes) | Registry, analytics module and command tests pass; `gofmt`, `go vet` and `golangci-lint` clean |
| On the emulator, against the local backend at schema 31 | Events reach `analytics.events` (see "Device test") |

## What was built

| # | Item | Where |
|---|---|---|
| 1 | **The client.** `Analytics` (interface, with a no-op default that every test and every widget built outside `main()` gets) and `AnalyticsClient`. The envelope: a UUIDv7 `event_id`, the session id, the install id, the app version, OS, coarse device class and locale. `AnalyticsQueue`: bounded at 500, oldest dropped, persisted with `shared_preferences`. `HttpAnalyticsTransport`: gzip, through `DeadlineHttpClient` and `ClientInfoHttpClient`, the access token when there is one; it honours 429 `Retry-After` and backs off on 5xx and offline. It flushes every 30 seconds, at 20 events, and when the app goes to the background. The server's `analytics.enabled` and `analytics.sample_rate` (parsed from `values` in app config) are applied once the signed-in shell has the config. Wired in `main()` through an explicit `ProviderContainer`, so the transport can read the session | `lib/core/analytics/{analytics,analytics_client,analytics_queue,analytics_transport}.dart`, `lib/main.dart`, `core/services/app_config_service.dart`, `core/utils/uuid.dart` (`uuidV7`) |
| 2 | **Sessions.** `app_opened`, `session_started`; `app_backgrounded` and `app_foregrounded`; after 30 minutes in the background, `session_ended` (with the length up to the moment it went away), the open flows abandoned as `backgrounded`, and a new session | `AnalyticsScope` in MaterialApp's builder (`analytics_scope.dart`) |
| 3 | **Screens.** One catalogue, `ScreenNames` (35 screens, all from the registry). Every route the app pushes now carries `RouteSettings(name:)`: 50 `MaterialPageRoute`s plus 4 through `screenRoute`. The six sheets and dialogs that count as screens are named too: schedule conflict, join confirmation, share with contacts, participant review, account claim, SOS confirm. `ScreenTracker` emits `screen_viewed` and `screen_left` with `duration_ms`, with the clock paused in the background. The shell reports its tab (tap or swipe, both through `currentTabIndexProvider`). One forwarding observer per navigator, because the theme switch builds a second navigator before the first is gone | `screen_names.dart`, `screen_tracker.dart`, `app_shell.dart`, `core/widgets/{app_sheet,app_dialog}.dart`, every page that pushes |
| 4 | **Actions.** `track(Cta.x)` on the catalogued controls only: host your own meetup (Home, Events), I'm interested, view location, accept and reject, withdraw, cancel and close meetup, the verify rows (checklist and Profile), work email on hosting unlock, add trusted contact, SOS, buy credits (Credits page and the schedule flow), subscribe, restore purchases, edit name, sign out, delete account, theme switch. Home's intent chips are `filter_changed` (`intent_<name>`, active) | The pages listed |
| 5 | **Flows.** `FlowTracker` for all nine funnels (table below) | `flow_tracker.dart`, `tracked_flow.dart`, the pages |
| 6 | **Friction.**<br>• `error_shown`: from `LoadFailedState`, once per appearance (kind `load_failed_<offline\|server\|permission\|location>`), and from every error toast (kind `error_toast`). Never the text.<br>• `api_error`: from `ClientInfoHttpClient`, the one client every service shares (status class and route template; never the URL, ids or query).<br>• `request_timeout`: when a request has no answer within 15 seconds.<br>• `rage_tap`: an app-wide pointer listener, three taps within a second inside 24 px with no screen change.<br>• `long_dwell`: a form step left 60 seconds without a tap, scroll or key press, on the schedule flow's steps, email sign-in and sign-up, profile setup and the four verification screens | `friction.dart`, `core/services/client_info_http_client.dart`, `core/utils/toast.dart`, `core/widgets/load_failed_state.dart`, `verification_scaffold.dart` |
| 7 | **Privacy Controls.** The "Controls are coming" banner is replaced by a real switch, "Share usage analytics", with one line on what is collected. Off clears the queue, stops recording and sending at once, and (when signed in) sends `PUT /v1/analytics/consent`. The rest of the page is unchanged | `features/privacy/privacy_controls_page.dart` |

### Flows

| Flow | Steps, and where each is recorded |
|---|---|
| `onboarding` | `age_confirmation`, `choose_method` (OnboardingFlow); `email`, `otp` (EmailSignupStep); `profile_setup`; completed on reaching the app |
| `verify_level_2` | `phone`, `personal_email`, `personal_details`: viewed when a checklist row opens its screen, completed when the profile says so; completed at Level 2 |
| `hosting_unlock` | `checklist` (passed straight through when already done), `corporate_email`, `unlock`; completed at Level 3 |
| `schedule_meetup` | `intent`, `timing`, `location`, `capacity`, `review`, in order, with back steps re-viewed; completed when the meetup is created; abandoned (back) when the page closes unfinished |
| `join_meetup` | `detail` (done on "I'm interested"), `request` (done when the server takes it); completed on the request. Closing the sheet is `closed`; a refusal is `error`. `accepted` is the server's own `request_accepted` |
| `review_meetup` | `experience`, `rating`, `submit` |
| `buy_credits` | `choose_pack`, `store_sheet`, `confirmed` (by the server) |
| `subscribe` | `choose_plan`, `store_sheet`, `confirmed`. Restores do not complete it |
| `sos` | `confirm`, `sending`, `sent`; closed without sending is `closed`; a failure is `error` |

## Final screen catalogue

`splash`, `landing`, `onboarding`, `email_sign_in`, `email_signup`, `profile_setup`,
`home`, `events`, `meetup_detail`, `location_view`, `participants`, `request_management`,
`schedule_meetup`, `meetup_review`, `notifications`, `profile`, `public_profile`,
`privacy_controls`, `safety`, `trusted_contacts`, `verification_checklist`,
`personal_details`, `phone_verification`, `personal_email_verification`,
`corporate_email_verification`, `hosting_unlock`, `credits`, `buy_credits`, `premium`.
Sheets and dialogs: `schedule_conflict`, `join_confirmation`, `share_with_contacts`,
`participant_review`, `account_claim`, `sos_confirm`.

The four tabs report as `home`, `events`, `safety`, `profile`. The registry also keeps
`chats` for the switched-off tab; nothing routes to it.

## Final event catalogue (app)

| Family | Events |
|---|---|
| session | `app_opened`, `app_foregrounded`, `app_backgrounded`, `session_started`, `session_ended` |
| screen | `screen_viewed`, `screen_left` |
| action | `cta_tapped` (34 controls in the registry; 19 wired, listed in item 4), `filter_changed`; `search_performed` and `toggle_changed` are in the registry, unused so far |
| flow | `flow_started`, `flow_step_viewed`, `flow_step_completed`, `flow_completed`, `flow_abandoned` |
| friction | `error_shown`, `api_error`, `request_timeout`, `rage_tap`, `long_dwell`; `credits_insufficient_shown` is in the registry, unused so far |

The generated Dart file has no constant for a server event, and the server refuses one
from the app.

## The required tests

| Required | Test |
|---|---|
| The envelope never contains forbidden fields | `envelope_privacy_test.dart`: records every app event type with every attribute, plus HTTP failures from URLs carrying a UUID, an email, coordinates and a query. Then it scans every serialised batch: only the documented keys, UUIDv7 ids, identifier-only strings, and no `@`, email, name, coordinates, URL, receipt or token. `route templates never carry ids, emails or queries` |
| Queue bound, persistence, flush triggers, offline hold, backoff, opt-out | `analytics_client_test.dart`: 500 and oldest dropped; survives a restart; a corrupt entry skipped; flushes at 20, every 30 s and on background (fake time); batches of 50 with the context; offline holds everything and waits 30 s, then 60 s; 429 waits for `Retry-After`; refused batches dropped; opt-out clears, stops, survives a restart and tells the server; the server switch and the sample rate; sessions |
| Every named route emits viewed and left; tabs by swipe and tap; background excluded | `screen_tracking_test.dart`: every one of the 35 screens; a named sheet is a screen and an unnamed dialog is not; the shell reports only its tab; an hour in the background adds nothing (7 s = 5 + 2); a new navigator starts clean; and a source audit that fails if any `MaterialPageRoute` in `lib/` has no name. `app_shell_test.dart`: `tab swipes and taps are both counted as screen views`, on the real AppShell |
| Schedule funnel: order, completion, abandonment on back and on backgrounding | `schedule_flow_test.dart` "funnel analytics": the exact 12-event sequence to completion; back out from the timing step (abandoned at `intent`, reason `back`); 31 minutes in the background (abandoned at `timing`, reason `backgrounded`, once) |
| Rage tap and long dwell with `fake_async` | `friction_test.dart`: three taps in a second reported once; slow, spread out or navigation in between is not rage; the app-wide listener does not stop the tap; a minute without input reported once; input restarts it; a new step restarts it |
| Also | `api_activity_test.dart` (the shared HTTP client reports statuses, lost connections and 15-second timeouts, and starts no timer under the no-op analytics); `privacy_controls_page_test.dart` (the switch is real both ways) |

For the key tests, I broke the code they guard and confirmed each one fails. The
16 breaks were:
- **Queue:** no queue bound.
- **Flushing:** no flush at 20; dropping on offline; ignoring the backoff.
- **Opt-out:** not clearing on opt-out; still recording while opted out.
- **Screens:** the clock running in the background; no tab report.
- **Schedule funnel:** no abandon on close; no completion.
- **Friction:** no navigation check on rage taps; input not restarting the dwell watch.
- **Privacy:** lower-casing path segments instead of templating them; reporting the analytics endpoint about itself; the switch not doing anything.
- **Timers:** the no-op guard removed.

The last one at first survived. Its test used a request that answered at once, so the
timer was gone before the check. I strengthened the test with a request that never
answers, and it now catches it.

## Device test (Pixel 8 emulator, 2026-10-26)

I rebuilt the local Docker stack with this registry and ran the app signed in as
`l3.a@meetups.test`. A short session (Coffee filter, Events, Profile, Home, then the
app to the background) arrived through the gateway, gzipped and keyed to the account
by the server:

```
screen_viewed splash · session_started · app_opened · screen_left splash (2159 ms)
screen_viewed home · filter_changed {intent_coffee, active}
screen_left home (18564 ms) · screen_viewed events · screen_left events (2007 ms)
screen_viewed profile · screen_left profile (2051 ms) · screen_viewed home
app_backgrounded (flush)
```

**Bug found on the device and fixed:** the splash screen's `screen_viewed` was
recorded while `start()` was still loading the stored queue, before the session
existed, so it was stored with no `session_id`. The session is now created before
anything is awaited. The test `an event recorded while start() is still loading has
the session` failed before the fix. A second run on the emulator showed every event
carrying the session.

## Decisions and findings

1. **The lifecycle observer sits at the app root (`AnalyticsScope`), not in
   `AppShell`.** The shell only exists once signed in. Sessions, and the time on the
   landing and onboarding screens, need to be counted before that.
2. **Privacy bug found and fixed (test first):** a mixed-case token in a path (the
   contact-confirm link `/c/<token>`) was lower-cased and reported as a path word. A
   segment is now kept only if it is a plain lowercase word or a version (`v1`),
   checked before any lowercasing. Anything else is `:value`; ids are `:id`.
3. **Registry changes (backend, regenerated):**
   - eight screens (`request_management`, `email_signup` and the six sheets and
     dialogs);
   - four controls (`withdraw_request`, `close_meetup`, `edit_name`,
     `switch_theme`);
   - `review_meetup` reordered to the app's real order (`experience`, `rating`,
     `submit`);
   - the generator now also emits `AnalyticsFlowStep` constants, so no page writes a
     step name by hand.
4. **A view is a visible stint.** Returning to a screen (closing a page or a sheet
   over it) counts as another `screen_viewed`. The 29F glossary must say so.
5. **Android's OS version is not sent.** Dart sees the kernel version there, not the
   Android release. iOS sends its version.
6. **`analytics.enabled` and the sample rate are applied when the signed-in shell
   reads app config.** Signed-out screens run on the defaults (on, 100%). A failed
   config fetch never switches analytics off.
7. **A request counts as timed out at 15 seconds** (the shortest deadline any service
   sets), whichever layer gives up on it. The meetup service's own deadline is 20 s,
   so a meetup call answering between 15 and 20 s is counted as a timeout.
8. **Dwell input is a tap, scroll or hardware key.** Typing on the soft keyboard
   needs a tap on the field first, but a single field typed into for over a minute
   without another tap would read as a dwell.
9. **A signed-out user's choice stays on the device.** It is not sent again after
   sign-in (the app sends nothing anyway while it is off).
10. **No new third-party SDK.** `clock` is declared for testable time; it was already
    in the lock file through `flutter_test`.

## Still open (29F or later)

- `search_performed`, `toggle_changed` and `credits_insufficient_shown` are in the
  registry but not wired (no search box in the app today; the one toggle that matters
  is the analytics switch itself).
- Re-sending a signed-out opt-out after sign-in (decision 9).
