# Plan 25 — Create CLAUDE.md for the monolith repo

## Context

Plan 23's completion report caught something I'd gotten wrong: Finding 3
quoted a stale "Design system" section as living in *this* repo's `CLAUDE.md`.
There is no `CLAUDE.md` anywhere in `Professional-Meetups-Monolith` — that
text is real, but it's in the sibling `Professional-Meetups` repo (the
pre-monolith microservices codebase this one was ported from), which I've now
fixed directly (small, precise, low-risk doc edit — verified its
`app_background.dart` still genuinely renders `assets/images/suit.png` before
writing the replacement text, since that repo's photo-removal never happened).

Shashika asked for both: fix the sibling (done), and give this repo — the
actively-developed one — a `CLAUDE.md` of its own. It has none today, which
means Claude Code sessions here start from zero context every time and
re-derive things (repo layout, commands, the module-boundary architecture,
the design system) that are already settled and documented elsewhere in
`docs/`.

**Why this is a Claude Code task and not something I draft myself:** a good
`CLAUDE.md` is a dense, accurate index into a real, current codebase —
commands that actually run, module names that actually exist, test file
counts that are actually current. I've explored large parts of this repo
across this whole engagement, but a complete file needs every claim checked
against the repo *as it stands right now* (`flutter test`/`go test` actually
running, `docker-compose.yml`'s actual service names, the actual current
migration version), which is better done by something that can run the
commands and read the whole tree fresh, not reconstructed from memory of
past conversation turns.

## What the file should cover

Use the sibling repo's `CLAUDE.md` as a **structural template only** — same
kind of sections, not copied content, since this is a different architecture
(modular monolith with two Cloud Run containers, not standalone
microservices). Verify every sentence against this repo's actual current
state before writing it:

1. **Repo layout** — `frontend/` (Flutter), `backend/` (Go modular monolith:
   `cmd/gateway`, `cmd/monolith`, `internal/modules/{auth,meetup,notification}`,
   `internal/platform/`), `docs/` (vault-generated, same convention as the
   sibling — check `docs/00-project/cowork-operating-charter.md` if present),
   `docker-compose.yml`, CI workflows. Cite ADR-001 for the module-boundary
   rationale.
2. **Commands** — actually run `flutter analyze`, `flutter test` (from
   `frontend/`), `go build ./...`, `go test ./...` (from `backend/`), and
   `docker compose up` to confirm they work as documented before writing them
   down; note the two-container (`gateway` + `monolith`, gRPC over
   `localhost:9090`) local dev shape.
3. **Architecture** — the gateway/monolith split, JWT (RS256, 15-min access
   tokens), the trust-level ladder (0–3, not 0–4 — check
   `trustlevel.go`/`computeTrustLevel` for the authoritative ceiling), the
   federated-identity design (ADR-014), the meetup lifecycle module
   boundaries, the notification outbox pattern. Point at `docs/04-decisions/`
   rather than re-explaining every ADR in full.
4. **Design system** — use this section verbatim, it's already accurate as
   of Plan 23 (verified against current `core/widgets/` source in this same
   session):

   ```markdown
   ### Design system

   Dark, flat UI (ADR-032). All colors are tokens in `AppPalette`
   (`frontend/lib/core/theme/app_palette.dart`) — never hardcode colors in
   feature widgets. Shared chrome lives in `frontend/lib/core/widgets/`:
   - `FlatCard` (`flat_card.dart`) — the shared card surface: solid fill,
     hairline border, no blur and no translucency.
   - `PrimaryButton` / `SecondaryButton` — the shared button styles, solid-fill
     and hairline-outlined respectively. Both give tap-scale press feedback and
     shrink an over-long label rather than truncating it.
   - `Pressable` (`pressable.dart`) — the same press feedback for whole-card tap
     targets that are not buttons.
   - `AppBottomBar` — the shared bottom nav: flush, solid, one top hairline.
   - `AppBackground` — a single flat `AppPalette.onyx` fill. It is **not** a
     background photograph; it was one, and that widget's own
     "THIS USED TO BE A PHOTOGRAPH" comment records why it went with the TieHere
     rebrand (a desaturated stock photo fought the saturated blue/green mark) and
     what it bought (no full-screen `saveLayer`, no decoded image per route).
   - `GlassTextField` (`glass_text_field.dart`) — **known stale name**: it renders
     through `FlatCard` and has no glass left in it. Renaming it would touch every
     call site, so it is deliberately left for a separate mechanical pass.
   ```

   Re-verify this against current source before pasting it in — if anything
   has changed since Plan 23 landed, correct it rather than shipping it stale
   on day one.
5. **Trust-level gating** — mirror the sibling's section but confirm the
   actual current `IntentType.requiredTrustLevel` values and whether
   `dating`/`rideShare` are still deferred (ADR-004) in this repo.
6. **Security rules** — pull forward whatever's still live from ADR-003
   (ephemeral work-email verification), the nonce/replay fix, and any other
   security-review-framework rule that's actually enforced in current code —
   check `docs/03-architecture/security-review-framework.md` if it exists
   here, don't invent one.
7. **Pointer to `docs/00-project/action-tracker.md`** (if it exists in this
   repo's `docs/`) and `TESTING-NOTES.md`, the same "check this before
   starting nontrivial work" framing the sibling's `CLAUDE.md` uses.
8. **Git rule** — commit docs and code together where practical, if that's
   still the convention here.

## What this deliberately does not do

- Does not copy the sibling repo's content wholesale — every fact must be
  re-verified against this repo, since the two have diverged (this repo has
  no photo background, has `Pressable`, is a modular monolith rather than
  microservices, uses Supabase rather than Cloud SQL).
- Does not touch the sibling repo further — that fix is done.
- Does not invent a Known Gaps section from guesswork — if nothing in this
  repo's current `docs/` names an open gap analogous to the sibling's, leave
  that section out rather than fabricating one.

## Related

Plan 23 (fluid interaction polish — where this gap was caught), ADR-001
(modular monolith architecture), ADR-032 (flat design system).
