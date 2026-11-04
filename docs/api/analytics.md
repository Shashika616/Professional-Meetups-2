# Analytics API (plan 29D)

How the app sends usage events, and how a signed-in user turns collection off.
The design is in plan 29 §4 and ADR-011. The event list is the registry,
`backend/internal/modules/analytics/registry/events.yaml`. The app's constants are
generated from it into `frontend/lib/core/analytics/event_names.g.dart`. Run
`go generate ./internal/modules/analytics/registry` after changing the registry;
a backend test fails if the Dart file is out of date.

Analytics is best effort. Nothing here should ever block or slow the app: send
batches in the background, drop them on failure after a retry or two, and never
show an analytics error to the user.

## `POST /v1/analytics/events`

Signed in **or not**. Send the access token when there is one, and the events are
keyed to the account. Without one, they are keyed only to the install.

| Limit | Value | Response when over |
|---|---|---|
| Events per batch | 50 | 413 |
| Body size, after gzip is decoded | 64 KB | 413 |
| Batches per minute, per account (signed in) or per `install_id` (signed out) | 30 | 429 with `Retry-After` |
| Batches per minute from one IP address | 300 | 429 |

Send `Content-Encoding: gzip` to compress the body (recommended). No other
encoding is accepted. Unknown top-level or per-event fields are refused with 400:
the shape below is the whole contract.

```json
{
  "install_id": "4b0c8a1e-3f2d-4c5b-9a8e-7d6c5b4a3f21",
  "app_version": "1.1.0+7",
  "os_name": "android",
  "os_version": "15",
  "device_class": "phone",
  "locale": "en-LK",
  "events": [
    {
      "event_id": "0192f0a4-7b1c-7d3e-8f00-0123456789ab",
      "event_name": "screen_left",
      "schema_version": 1,
      "occurred_at": "2026-10-25T10:00:03.120Z",
      "session_id": "a1d2c3e4-0000-4000-8000-000000000001",
      "screen": "home",
      "flow_id": "",
      "flow_step": "",
      "attributes": {"duration_ms": 3120}
    }
  ]
}
```

### The envelope

| Field | Rule | If it does not match |
|---|---|---|
| `install_id` | A random UUID made on first launch and kept on the device, in the 36-character form. Never a device identifier (no IDFA, no Android ID). Checked at the gateway before anything else, since it keys the signed-out rate limit (plan 30B) | 400: the whole batch is refused |
| `app_version` | `1.2.3` or `1.2.3+45` | Not stored |
| `os_name` | `ios`, `android` or `other` | Not stored |
| `os_version` | Digits and dots, for example `17.4` | Not stored |
| `device_class` | `phone`, `tablet` or `other` | Not stored |
| `locale` | For example `en`, `en-LK`, `si_LK` | Not stored |
| `event_id` | A UUID, v7 recommended, made on the device. It is the deduplication key: send the same id again on a retry and it is stored once | Event dropped |
| `event_name` | A registry event whose source is `app` | Event dropped |
| `schema_version` | From 1 up to the registry's version for that event (`analyticsEventVersions`) | Event dropped |
| `occurred_at` | RFC 3339, device time, within 7 days of the server clock | Event dropped |
| `session_id` | A UUID, or empty. Start a new session after 30 minutes in the background | Event dropped |
| `screen` | Empty, or one of `AnalyticsScreen` | Event dropped |
| `flow_id`, `flow_step` | Empty, or a flow from `AnalyticsFlow` with one of its own steps (`analyticsFlowSteps`) | Event dropped |
| `attributes` | An object of at most 20 keys | More than 20 keys drops the event; see below for single attributes |

**Attributes** are checked one by one against the event's registry entry. An
attribute the event does not list, of the wrong type, out of range, a string
over 100 characters, or a string that is not an identifier (lowercase letters,
digits and `_ . : -`) is removed, and so is an `id` attribute shaped like a
UUID (plan 30B): an `id` names a thing in the app, such as a filter, never a
user, meetup or contact. The rest of the event is kept. Free text cannot
get through as an attribute, so never try to send any.

### The response

`202 Accepted`, as soon as the events are queued, before anything is written:

```json
{"accepted": 9, "dropped": 1}
```

`dropped` counts events refused by the checks above, or because the server's
queue was full or analytics is switched off (`analytics.enabled`, or the server
has no user-key secret). Do not resend dropped events; they will be refused
again. On 429, wait for `Retry-After`. On 5xx, retry the batch later with the
same event ids.

## `PUT /v1/analytics/consent`

Signed in. Stores the user's choice from Privacy Controls on the server.

```json
{"opted_out": true}
```

At most 10 calls a minute per account (429 with `Retry-After` beyond).

Response `200 {"opted_out": true}`. Opting out deletes the analytics events
already stored for the account, and the server drops any later event carrying
the account's key, including the server's own events about the account. The app
must also stop sending once the toggle is off. Opting back in (`false`) starts
collecting again from then on. A signed-out device's choice stays on the device.

## Events

From the registry. Every app event can also carry `screen`, `flow_id` and
`flow_step`. Durations are milliseconds; ints are 0 or more.

| Event | Family | Attributes |
|---|---|---|
| `app_opened` | session | `cold_start` bool |
| `app_foregrounded`, `app_backgrounded`, `session_started` | session | none |
| `session_ended` | session | `duration_ms` int |
| `screen_viewed` | screen | none (`screen` is required in practice) |
| `screen_left` | screen | `duration_ms` int |
| `cta_tapped` | action | `cta`, one of `AnalyticsCta` |
| `search_performed` | action | `result_count` int ≤ 10000, `filter_count` int ≤ 50 |
| `filter_changed` | action | `filter` id, `active` bool |
| `toggle_changed` | action | `toggle` id, `value` bool |
| `flow_started`, `flow_step_viewed` | flow | none |
| `flow_step_completed`, `flow_completed` | flow | `duration_ms` int |
| `flow_abandoned` | flow | `reason`: `back`, `closed`, `backgrounded`, `error`, `timeout` |
| `error_shown` | friction | `kind` id, for example `network`, `validation` |
| `api_error` | friction | `route` id (for example `meetups.create`), `status_class`: `4xx`, `5xx`, `network`, `timeout` |
| `request_timeout` | friction | `route` id |
| `rage_tap` | friction | `taps` int ≤ 100 (3 or more taps within a second on one spot, without navigation) |
| `long_dwell` | friction | `duration_ms` int (long time on a form step without acting) |
| `credits_insufficient_shown` | friction | `required_credits` int |

Server events, recorded by the monolith from its outboxes. The app cannot send
them; they are refused if it tries:

| Event | From | Attributes |
|---|---|---|
| `meetup_created` | meetup billing outbox (a charged meetup) | none; the cost is the matching `credits_spent` |
| `join_requested`, `request_accepted` | meetup activity outbox, written with the request or the accept | none; the requester's (it is their join funnel) |
| `meetup_completed` | meetups-completed outbox | none; one per meetup |
| `credits_granted` | `credits.changed` (grant, positive admin adjustment) | `reason`, `credits` |
| `credits_spent` | `credits.changed` (capture) | `reason`, `credits` |
| `credits_refunded` | `credits.changed` (refund) | `reason`, `credits` |
| `credits_expired` | `credits.changed` (decay, expire) | `reason`, `credits` |
| `credits_revoked` | `credits.changed` (store reversal, negative admin adjustment) | `reason`, `credits` |
| `purchase_verified` | `purchase.verified` | `platform`, `kind`, `product_id` |
| `subscription_changed` | `subscription.activated` / `.deactivated` | `status`, `plan_code` |

## Flows and steps

| Flow | Steps |
|---|---|
| `onboarding` | `age_confirmation`, `choose_method`, `email`, `otp`, `profile_setup` |
| `verify_level_2` | `personal_details`, `phone`, `personal_email` |
| `hosting_unlock` | `checklist`, `corporate_email`, `unlock` |
| `schedule_meetup` | `intent`, `timing`, `location`, `capacity`, `review` |
| `join_meetup` | `detail`, `request`, `accepted` |
| `review_meetup` | `experience`, `rating`, `submit` |
| `buy_credits` | `choose_pack`, `store_sheet`, `confirmed` |
| `subscribe` | `choose_plan`, `store_sheet`, `confirmed` |
| `sos` | `confirm`, `sending`, `sent` |

The screens and controls are listed in the registry and in the generated Dart
file.
