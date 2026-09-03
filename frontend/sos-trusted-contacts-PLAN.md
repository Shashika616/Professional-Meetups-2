# Frontend plan — Minimal real SOS + trusted contacts (ADR-026, Slice H)

Read `docs/04-decisions/adr-026-minimal-real-sos-and-trusted-contacts.md` first. This replaces `SafetyPage`'s existing fake SOS confirm action (`lib/features/safety/safety_page.dart:100-107`) — read that file in full before changing it, the checklist section above the SOS button stays as-is, only the SOS action itself changes.

## Step 1 — Service contract

- New `SafetyService` (or add to an existing relevant service): `addTrustedContact`, `listTrustedContacts`, `removeTrustedContact`, `triggerSos(contextMessage, lat, lng)`. Mock + Http implementations, wired through `app_providers.dart` same as every other service.

## Step 2 — "Manage trusted contacts" screen

- New screen under Safety Center: list current contacts (name + phone/email), add (name + phone and/or email, at least one required — mirror this against `Validators` per the hardening plan's fix rather than duplicating a fresh ad hoc check), remove with confirmation.

## Step 3 — `SafetyPage`'s SOS action, made real

- Tapping "TRIGGER SOS" first checks whether the caller has any trusted contacts (fetch via `listTrustedContacts`). Zero contacts → route to the new screen from Step 2 with an explanatory prompt instead of showing the confirm dialog at all.
- One or more contacts → show the existing confirm dialog (copy can stay close to current), but CONFIRM now: requests a fresh on-demand location read (reuse the map picker's existing permission-request plumbing, don't build a second location-permission flow), calls `triggerSos` with that coordinate and an optional context message, and shows a **real** result — success names which contacts were alerted (from the RPC's returned count), failure shows a real error.
- Add a "Call emergency services" action in the same dialog that opens a `tel:` intent directly (via `url_launcher`) — works even if `triggerSos` fails, no backend dependency.

## Step 4 — Tests

- Widget test: zero contacts routes to the manage-contacts screen instead of showing the confirm dialog.
- Widget test: successful trigger shows the real contacts-alerted count, not a canned message.
- Widget test: failed trigger shows a real error state.
- Widget test: "Call emergency services" opens the dialer intent independent of trigger success/failure.
- Full checklist: `flutter analyze`, `dart format --set-exit-if-changed`, `flutter test`.
