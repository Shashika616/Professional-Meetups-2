# Plan 27 — UI redesign: clickable HTML prototype

Goal: a clickable HTML prototype of every existing screen, in dark and light, for review before the Flutter app is redesigned. It applies the 32-point UI review (`TieHere_UI_Review.xlsx`, items R1 to R32 in row order). No Flutter, Go or SQL changes. No feature, control or image is removed.

## Design

- Deep-navy tonal surfaces. Depth from tone, not borders: background, surface, card, raised. Dark cards get a 1px top highlight; light cards get a soft shadow.
- Radius 22 to 24 on cards and tiles, pill buttons and chips, floating pill nav (28). This replaces the 10 to 12px radii of ADR-032; record it in a new ADR when the Flutter work starts.
- **One primary colour: brand green** for every main button (R1). **One selected colour: blue** for active tabs, segmented controls, nav item, chips and links (R2). Green also marks verified and "You're in". Never two colours for the same job.
- **Sentence case** for screen titles, buttons, tabs and nav labels. Letter-spaced caps only for small section labels (R3). Support Dynamic Type.
- **One word: "Meetups"** for the tab and every label (R6). Tabs: Home, Meetups, Safety, Profile.
- Keep all imagery, in one consistent illustration style (R7). Remove the Apple logo from the laptop illustration, which is in `l13.jpg` (R18); regenerate or replace it, and check the other illustrations for brand marks.

| Token | Dark | Light |
|---|---|---|
| Background | `#070D15` | `#F3F6F9` |
| Card | `#0F1824` | `#FFFFFF` |
| Raised | `#172536` | `#E8EEF5` |
| Text | `#F1F5F9` | `#131A23` |
| Secondary text | `#A9B6C4` | `#4F5C6B` |
| Tertiary text and nav | `#8F9EAF` | `#5A6677` |
| Primary action fill | `#34C24C`, dark text | `#17803D`, white text |
| Selected | `#8EC5EE` text, `#5FA8DC` fill | `#1F6FA8` |
| SOS | `#C8323A`, white text | `#C8323A`, white text |

## UI review mapping

| Review items | Design response |
|---|---|
| R4, R23 | Contrast raised on secondary text, nav labels, locked tabs; SOS is white on solid red. Every pair checked at 4.5:1. |
| R5 | Slim persistent banner on every tab: "View-only. Verify to unlock meetups", opens the verification flow. |
| R8 | Empty areas filled: how-it-works steps, nearby alerts, tips. |
| R9 | Greeting "Good afternoon" and an "Add your name" tap target; no auto-generated name. |
| R10 | Locked category chips show a lock; tapping explains how to unlock; fade edge on the chip row. |
| R11, R12 | "Negombo · 10 km" with Change; "Notify me about new meetups nearby" toggle and "Browse other areas". |
| R13, R19 | Host button in a locked style, "Verify to host", routes to verification. |
| R14 | Unread badge on the bell, empty message inside the list. |
| R15 | Safety tip is a neutral, dismissible card. |
| R16, R17 | One segmented control: Hosting, Joined, Past; empty copy per tab with a "Find meetups" button. |
| R20 | Safety tips use neutral bullets, not green ticks. |
| R21 | Locked trusted contacts have "Verify now" and "Add one". |
| R22 | SOS has a one-line description, hold to send, and "Call 119". |
| R24 | "Share live location" toggle in Safety. |
| R25 | No online dot on your own profile. |
| R26, R27 | "Level 0", tappable, "How to level up"; "No ratings yet". |
| R28, R29 | Corrected LinkedIn copy with data-use reassurance, "1 of 3 verified" progress, phone verification not blocked, alternative path link. |
| R30 | Bottom scroll padding so the last row clears the nav. |
| R31, R32 | "Edit profile" label; camera badge and "Add a photo". |

## Interaction, motion and materials

Principles from Apple's fluid-interface guidance and common mobile UX rules, to be shown in the prototype and later built in Flutter.

- **Respond on press.** Pressed state on touch-down: scale 0.97 over 100ms. Feedback within 100ms.
- **Springs, not fixed durations, for anything touchable.** Default critically damped (no overshoot), response 0.3 to 0.4s. Bounce (damping about 0.8) only after a flick or throw, such as a sheet released with speed.
- **Interruptible.** A sheet, card or tab change can be grabbed mid-motion and reversed. Never lock input during a transition.
- **Drag is 1:1** with the finger, keeping the grab offset. Sheet release hands the finger's velocity to the spring and snaps to the position projected from that velocity, not the release point. Rubber-band at edges.
- **Spatial consistency.** Sheets and dialogs open from their trigger and close along the same path. Forward navigation moves left or up, back moves right or down.
- **Materials.** The floating nav and sheets are translucent (blur 20, saturate 180%) with a bright top edge. Content scrolls under them. A soft fade replaces hard dividers where content meets the nav.
- **Typography.** System font. Tighter tracking on large headings (about -0.02em), none on body, positive tracking only on small section labels. Scale with the user's text size; spacing in relative units.
- **One primary action per screen.** Secondary actions are visually quieter.
- **Wayfinding.** Every screen answers where am I, where can I go, how do I leave. Back is always visible.
- **Accessibility signals.** `prefers-reduced-motion`: replace slides and springs with a short cross-fade. `prefers-reduced-transparency`: solid surfaces. `prefers-contrast: more`: visible borders. Targets at least 44px, 8px between targets. Do not rely on colour alone.
- **Loading.** Skeletons after 300ms, not spinners. Toasts 3 to 5 seconds, not focus-stealing.

## Needs a product or backend decision (design them, flag them)

R11 radius change, R12 nearby alerts, R21 a trusted contact before verification (today SOS needs Level 2, ADR-003), R24 live location sharing, R28 verification without LinkedIn, R29 phone before LinkedIn. The prototype shows them; the Flutter plan will not build them until each is confirmed.

## Screens

- **Entry:** Splash, Landing, Onboarding (age, email sign-up, profile setup, account claim), Email login.
- **Tabs:** Home, Meetups, Safety, Profile.
- **Meetups:** Detail (host, pending, accepted, rejected, withdrawn, cancelled, locked), Requests, Participants, Location, Schedule flow, Review flow, join, conflict, withdraw and cancel dialogs.
- **Safety:** Safety center, Trusted contacts, SOS.
- **Profile:** Profile, Public profile, Privacy controls, edit name, delete account, sign out.
- **Verification:** Checklist, Phone, Personal email, Personal details, Work email, Hosting unlock.
- **Other:** Notifications, Premium, Chats.
- **States:** view-only account, verified account, loading, empty, error, locked, toast.

Copy comes from the current Dart files, except where the review changes it.

## Deliverable: `docs/design/prototype/`

- `index.html` (gallery, theme switch) and the screen pages, all with real relative links.
- `assets/theme.css` (tokens and components), `assets/proto.js` (theme switch, sheets, tabs), `assets/img/` (images, 520px max).
- `SCREEN-MAP.md` and `README.md`.
- Plain HTML, CSS and JS. Opens from `file://`. Both themes complete on every screen.

## Steps

1. Write `SCREEN-MAP.md` from the Dart screens: sections, strings, controls, states, images, navigation.
2. Build `theme.css` and the shared components.
3. Build the four tabs in both account states (view-only and verified), then every other screen and state.
4. Build `index.html` and wire the links.
5. Check: no broken link or image, both themes at 390px and 1280px, contrast, no ALL-CAPS outside section labels.
6. Report coverage against `SCREEN-MAP.md` and against R1 to R32.

After sign-off, a separate plan ports the design to Flutter.
