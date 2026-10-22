# Claude Code prompt — build the TieHere design prototype

You're working in `/Users/as/Documents/Professional Meetups/Professional-Meetups-Monolith`. Build static HTML, CSS and JS only. Do not change any Flutter, Go or SQL code. Do not commit or push.

## Read first

1. `docs/plans/27-ui-redesign-clickable-prototype.md`. It is the plan, including the colour tokens and the table mapping every UI review item (R1 to R32) to a design response. Follow it.
2. `frontend/lib/core/theme/app_palette.dart`, then the screens under `frontend/lib/features/` and the widgets under `frontend/lib/core/widgets/`. Copy their real labels, states and controls.
3. `TESTING-NOTES.md`. Never show test credentials or OTP bypass values.

## Build

A clickable prototype in `docs/design/prototype/` covering every existing screen and state, each in dark and light, with a Dark/Light switch on every page. Show the four tabs in both a view-only account and a verified account. Real relative links between screens. Tabs, sheets, dialogs and the theme switch work in JS. Opens from `file://`, no build step.

## Rules

- Brand green is the only primary button colour. Blue is the only selected and active colour.
- Sentence case everywhere except small section labels. The tab is "Meetups".
- Keep every control and state that exists today.
- Use the real images from `frontend/assets/images/`, resized to 520px max into `assets/img/`. Do not use `l13.jpg` or any image with a third-party brand mark; use a placeholder and list it in the report.
- Use the real copy from the Dart files, except where the review changes it. Placeholder names and times should be plausible for Colombo.
- All colours come from CSS variables in `assets/theme.css`.
- Light mode is its own design, not an inversion.
- Text 4.5:1, large text and icons 3:1, visible focus, 44px tap targets, respect `prefers-reduced-motion`.
- Items marked in the plan as needing a decision (nearby alerts, radius, early trusted contact, live location, non-LinkedIn verification, phone first) are drawn but labelled "Proposed" in `SCREEN-MAP.md`.

## Interaction and polish

Follow the "Interaction, motion and materials" section of the plan. In the prototype, build the sheets and dialogs with a small spring (no external library): pointer-capture drag that tracks 1:1, release velocity handed to the spring, snap to the projected position, rubber-band at the edges, and interruptible mid-motion. Use `backdrop-filter` on the nav and sheets, with solid fallbacks under `prefers-reduced-transparency`. Honour `prefers-reduced-motion` and `prefers-contrast`. Press state on pointer-down.

## Process

1. Write `SCREEN-MAP.md` first and use it as the checklist.
2. Build `theme.css`, `proto.js` and the shared components.
3. Build the four tabs, then everything else.
4. Build `index.html` and wire the links.
5. Verify with a script (broken links, missing images, any ALL-CAPS text outside section labels), screenshots at 390px and 1280px in both themes using Playwright Chromium (`executablePath: '/opt/pw-browsers/chromium'`), and a contrast check.
6. Write `README.md` and a coverage table against `SCREEN-MAP.md` and R1 to R32.

## Report

What was built, the coverage tables, any control you could not place, and any design choice Shashika should confirm.
