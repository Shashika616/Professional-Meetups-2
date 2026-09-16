# ADR-006 - A Turned-Down Request Reads as "Not This Time"

## Status

Accepted (2026-09-17).

## Context

A host can turn down a join request, and a request can also lose out when
the meetup fills up first. Both outcomes reached the requester as a verdict:
a red `REQUEST DECLINED` chip on the card, `DECLINED BY HOST` on their Events
list, a red banner on the meetup page saying "The host did not accept this
request", a red toast, and a push titled "Request declined". The page ended
there. The only thing left to do was back out.

Being turned down by a stranger for a table of three or four is a fit
decision about a small group. The word the requester reads is the word they
carry, and "rejected" is a heavy one to hand somebody for what is, from the
host's side, "not this one". Apps that handle this well (dating apps on a
non-match, marketplaces on a host who cannot accommodate, job boards on a
pass) share three habits: they do not use the word, they explain it as a
matter of fit rather than fault, and they put the next option on the same
screen.

## Decision

### The vocabulary

Where the **requester** reads it, the outcome is `NOT THIS TIME`. A request
that lost to capacity is `FILLED UP BEFORE YOUR TURN`. Neither "rejected" nor
"declined" appears in anything addressed to the requester: not the card chip,
not the Events list, not the meetup page, not the toast, not the push.

The host keeps the plain words. The REJECT button, the REJECTED tab on the
request-management screen and the host's own "Request rejected" toast are
the host's tools, describing the host's own action, and softening them would
make the host's screen less clear without helping anyone.

### The tone

The requester-facing state is muted or calm blue, never red. Red is kept for
things that went wrong (a cancelled meetup, a failed load). The chip icon is
a compass, pointing outward, rather than a cross.

### The explanation

The meetup page's banner says why without apologising for the host and
without blaming the requester: "Hosts keep their groups small, so not every
request can fit. There are more meetups near you."

### The next step, on the same screen

Under that banner, while the meetup is still ahead, the page shows
**OTHERS HAPPENING SOON**: up to three other open meetups near the viewer,
each one tap from its own page, and SEE ALL NEARBY back to Home's list. The
section reuses Home's location and open-meetups providers with the
all-intents key, so it costs no request if the person has been on Home this
session. It filters out the meetup itself, anything the viewer hosts or has
already asked to join, and anything locked for their trust level.

This section never shows a failure. If location is off, the list cannot
load, or nothing else is on, it shows one calm line ("New meetups go up every
day...") and a BROWSE MEETUPS button. An error card under a "not this time"
would be the one thing worse than nothing.

### The push and the toast

The server writes the copy the tray and the in-app toast show, so the
wording lives in one place (`internal/modules/meetup/requests.go`):

- `request_declined`: **Not this time** / "The coffee meetup was not the
  right fit this round. More are happening near you, and new ones every
  day."
- `meetup_full`: **That one filled up fast** / "The coffee meetup filled up
  before your turn. More are happening near you, and new ones every day."

The app shows both as an info toast, not an error toast.

## Consequences

- No wire change. `MeetupRequestStatus.rejected` and the `request_declined`
  / `meetup_full` types keep their names; only copy, colour and the page
  layout changed. Old clients keep working against the new server and see
  the new push copy.
- The requester's Events list and the Home card no longer distinguish "the
  host chose" from "it filled up" by colour, only by label. That is the
  point: neither is a fault.
- Widget tests pin the vocabulary (`meetup_role_chips_test`,
  `events_page_test`, `meetup_detail_page_test`): a future label containing
  REJECTED or DECLINED on a requester-facing surface fails the suite.

## Where to look

- Requester-facing labels: `frontend/lib/core/widgets/meetup_role_chips.dart`,
  `frontend/lib/features/home/widgets/meetup_card.dart`,
  `frontend/lib/features/meetups/events_page.dart` (requester status),
  `frontend/lib/features/meetups/meetup_detail_page.dart` (`_RequestStatusBanner`).
- Suggestions: `frontend/lib/features/meetups/widgets/other_meetups_nearby.dart`.
- Toast tone: `frontend/lib/app_shell.dart` (`_toastTypeFor`).
- Push copy: `backend/internal/modules/meetup/requests.go`.
