# ADR-013: Reactive SOS and unconfirmed trusted contacts

Status: accepted (Shashika, 2026-11-01). Implemented in plan 30C.

## Context

Trusted contacts were invited by SMS and had to confirm through a link before
SOS could reach them (#80). In practice that put a step between a person and
their emergency contact: a contact who ignored a text from an unknown number
would silently never be alerted. It also meant texting a stranger on add, and
it kept a public confirmation page and a table of pending states.

## Decision

- A trusted contact is a **name and a phone number**. At most two.
- **Adding or editing a contact sends nothing.** Contacts do not confirm, and
  have no email.
- **SOS is strictly reactive.** A contact hears from us only when the user
  presses SOS, or chooses to share a meetup with them. There are no invitations,
  no live tracking and no background location. The unused live-location API and
  state are removed.
- SOS goes by SMS only, to the two oldest contacts. An account with three keeps
  them, and the app asks the user to remove one (D5).

## Consequences

Contacts have not opted in (D6). Shashika accepted that, with these limits as
the mitigation:

| Abuse | Limit |
|---|---|
| Texting many strangers | 2 contacts per account |
| Cycling through numbers | 5 contact adds or edits per account per day, shared across instances; fails closed |
| Bad numbers | Normalised and validated as E.164 |
| Repeated alerts | SOS 5 an hour and 10 a day per account, counted with the claim; a retry is not an alert |
| Using SOS as a free message | A fixed template; nothing the client sends reaches it. The name is one line, at most 60 characters, no links |
| Meetup share as a message | 3 shares a day, 2 contacts, live meetups only (D1) |

A contact can receive an alert about someone they did not agree to be a contact
for. A wrongly typed number reaches a stranger, once, with a real name and
location, so the app shows the numbers clearly and the privacy policy says
contacts are told only in an emergency.

## Message

The template, the three location variants and the meetup section are in plan
2.2, pinned by golden files in `backend/internal/modules/auth/sos/testdata`. GSM-7
only, to keep the SMS in the cheaper encoding. A name in a script GSM-7 cannot
carry (Sinhala, Tamil) therefore reads "A TieHere member"; sending those
messages as UCS-2 would need a decision on cost per segment.

A fix stamped in the future, or older than a day, is treated as no fix. The
alert is never refused over its location: a phone with a wrong clock must not
stop an SOS. This is a deliberate reading of plan 2.2's "rejects a future
`captured_at`".
