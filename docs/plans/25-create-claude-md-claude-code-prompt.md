You are working in the Professional-Meetups-Monolith repo. Follow
`docs/plans/25-create-claude-md.md` in full — it explains why this repo has
no `CLAUDE.md` yet (it never got one; the sibling `Professional-Meetups`
repo's stale one was a separate, already-fixed issue) and exactly what each
section needs to cover.

## Task

Create `CLAUDE.md` at this repo's root. Before writing anything, verify each
claim against the actual current repo rather than assuming from the sibling
repo's structure or from general knowledge of what a modular monolith looks
like:

1. Actually run `flutter analyze` and `flutter test` from `frontend/`, and
   `go build ./...` and `go test ./...` from `backend/`, and `docker compose
   up` (or at least `docker compose config`) from `backend/` — confirm each
   command in the doc actually works as written, don't transcribe it from
   memory of similar repos.
2. Read `docs/04-decisions/adr-001*.md` (modular monolith architecture) for
   the Architecture section, `docs/04-decisions/adr-032*.md` for the Design
   system section (though that section's text is already given to you
   verbatim in Plan 25 §4 — just re-verify it's still accurate against
   current `frontend/lib/core/widgets/` source before pasting it in), and
   whatever else is under `docs/04-decisions/` and `docs/00-project/` that a
   future session would need pointed at rather than re-explained.
3. Check `backend/internal/modules/auth/trustlevel.go` (or wherever
   `computeTrustLevel` lives) for the actual current trust-level ceiling (0–3
   per this engagement's prior work, but verify — don't assume it hasn't
   changed) and `frontend/lib/core/models/intent_type.dart` for the current
   `requiredTrustLevel` values and whether `dating`/`rideShare` are still
   gated off per ADR-004.
4. Check whether `docs/00-project/action-tracker.md` and a
   `TESTING-NOTES.md`-equivalent exist in this repo (the monolith already has
   its own `TESTING-NOTES.md` at the repo root — confirm and cite it) and
   point at them the way the sibling repo's `CLAUDE.md` does.
5. Write the file with these sections, each grounded in what you actually
   found in steps 1–4: Repository layout, Commands, Architecture (module
   boundaries, gateway/monolith gRPC split, JWT scheme, trust-level ladder,
   federated identity), Design system (Plan 25 §4's text, re-verified),
   Security rules (only what's actually enforced in current code — don't
   invent), a pointer section to the action tracker / testing notes, and a
   Git rule if this repo has an established convention for it (check recent
   commit messages/CONTRIBUTING if one exists; don't assume the sibling's
   convention carries over without checking).

## Explicitly do not do

- Do not copy the sibling repo's `CLAUDE.md` content and adapt it in place —
  re-derive each fact from this repo's actual current state. The two repos
  have real differences (no photo background here, `Pressable` exists here
  and not there, this is Cloud Run + Supabase not the sibling's own hosting,
  this is a modular monolith not microservices).
- Do not touch anything in the sibling `Professional-Meetups` repo — already
  fixed, out of scope here.
- Do not fabricate a "Known Gaps" section if nothing in this repo's current
  docs supports one — an accurate short file beats a padded inaccurate one.

## Before you report done

Paste the actual output of the commands you ran to verify the Commands
section (not just "I confirmed it works"), and list which of Plan 25's
sections you had to adjust from what it specified because current source
disagreed with the plan's assumptions — that's exactly the kind of
discrepancy this task exists to catch, so surface it rather than silently
reconciling it.
