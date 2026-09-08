# Gap tracker

Living record of known gaps, opened 2026-09-08 from a full UX + backend
architecture review. Not vault-synced — hand-maintained here, like
`docs/decisions/` and `docs/plans/`. Update status inline as items close;
don't delete closed rows, mark them `DONE (date)` so the history stays
legible.

Columns: **Gap** — **Where** — **Why not fixed yet** — **Status**.

## Frontend / UX

1. **Privacy Controls row is a silent dead tap** — `frontend/lib/features/profile/profile_page.dart:156-165`, no `onTap` handler despite looking tappable (chevron + subtitle). — Never audited before; no prior round did a full dead-tap sweep of Profile. — **OPEN**.

2. **Accessibility near-absent** — one `Semantics` usage in the whole app (`events_page.dart:499`), several tap targets under 44/48dp, a `TextButton` minimum size deliberately dropped in `onboarding_flow.dart:381-384` for layout convenience. — Accessibility was never the stated lens of any prior review round. — **OPEN**.

3. **`dating`/`rideShare` shown as live, unlocked chips to signed-out users** — `frontend/lib/features/landing/widgets/orbiting_intents.dart:21-28`. — The underlying Play Store age-verification policy question is legitimately blocked on a business decision (see `docs/07-research/app-store-and-play-store-compliance.md` in the source repo), but the narrower fix — not showing these as live/unlocked pre-auth — doesn't depend on that decision and was never split out. — **OPEN, partially actionable now**.

4. **Stale design tokens** — `glassTint`/`glassBorder` still defined in `core/theme/app_palette.dart:48-50` after ADR-032 moved the app off glassmorphism; a second unofficial `Colors.white.withValues(...)` convention living alongside the real token system (e.g. `profile_page.dart:781`, `intent_filter_bar.dart:123`, `schedule_flow.dart:792`). — ADR-032's implementation was verified for functional correctness only, not audited for leftover dead tokens afterward. — **OPEN**.

5. **130 lines of commented-out fallback `_LocationStep`** — `frontend/lib/features/meetups/schedule_flow.dart:578-709`. — Never flagged; minor. — **OPEN**.

6. **`_EditNameDialog` has no input validation** — `frontend/lib/features/profile/profile_page.dart:848-899`, SAVE always enabled even for empty/whitespace input. — Never spot-checked; past form-UX checks focused on OTP/onboarding/scheduling only. — **OPEN**.

7. **CORRECTED (2026-09-08) — this was wrong, not a real gap.** Originally logged as "push notifications fully scaffolded but inert (NoOp)." Re-checked directly: `frontend/lib/core/providers/app_providers.dart:114-122` binds `pushNotificationServiceProvider` to the real `FirebasePushNotificationService` (real Firebase project `professional-meetups-976d2`, real `google-services.json`, token refresh wired to `registerDeviceToken`) — push is genuinely live, done in round-10, in this repo. The actual (much smaller) gap: `frontend/lib/app_shell.dart:58-64,89-90`'s doc comments still say "NoOpPushNotificationService.messages never emits," left over from round-9 scaffolding and never updated when the binding was swapped to real Firebase. Misleading stale comments, not a missing feature. — **OPEN — doc-comment cleanup only**.

15. **"Told N trusted contacts" confirmation never displays** — `frontend/lib/core/models/meetup.dart:410-419`, `SafetyState.fromJson` never reads `shared_with_contact_ids` from the server response, so it silently defaults to empty on every real HTTP call. Found 2026-09-08 verifying the trusted-contact-share feature (`docs/plans/10-safety-gate-audit-and-contact-share.md`) — backend fully correct, this one frontend field mapping was missed, and no test caught it because all widget tests construct `SafetyState` directly rather than through `fromJson`. Fix handed off: `docs/plans/11-safety-share-confirmation-parsing-fix.md`. **OPEN — fix ready to run.**
16. **`live_location_opt_in` field/RPC now dead, left in place on purpose** — `gateway/handlers/meetups.go:434-446`, `grpcapi/meetup.go:318-319`. Superseded by the trusted-contact-share feature; self-flagged in the completion report as a deliberate deferral (avoid churning the proto in the same pass), not an oversight. **DEFERRED, tracked — remove in a dedicated cleanup pass.**

## Backend

8. **No billing/subscription module in the monolith** — ADR-031 + Slice B billing service were designed, built, and verified in the original microservices repo; no equivalent module exists under `backend/internal/modules/` in this repo. — Same root cause as #7: phased port never scheduled a billing phase. — **OPEN — porting gap**.

9. **Stadia Maps API key committed in plaintext** — `frontend/.env:37`. — Already tracked in `TESTING-NOTES.md` as a "must not ship" item, but only the vendor-choice question was tracked as open; the independent, cheap fix (rotate + stop committing) was never separated out and actioned. — **OPEN — fix this independently of the vendor decision**.

10. **Hardcoded OTP bypass (`123456`)** — `backend/.../otp.go:88-93`, gated by `ALLOW_TEST_OTP_BYPASS`, absent from `.env.example`, loud `WARN` on boot when active. — Correctly gated as a testing aid, tracked in `TESTING-NOTES.md`. Recommended hardening never built: refuse to boot if the flag is true in a production environment, rather than relying on a log line being noticed. — **OPEN — hardening, not a leak**.

11. **Validation is hand-rolled per-field regex, no shared schema/DTO layer** — e.g. `backend/internal/modules/auth/validate.go:29-56`. — New recommendation; past reviews confirmed validation existed per-route, never audited the pattern's structural consistency as module count grows. — **OPEN**.

12. **No distributed tracing** — no OpenTelemetry/trace spans anywhere in `backend/internal/`. — New observation; past operational-readiness audits covered logging/metrics/shutdown/migrations, not tracing. — **OPEN**.

13. **OTP verify endpoints lack a target-keyed rate limit** (send-side has one; verify relies on blanket IP+path limiting plus the 5-attempt code lockout) — `backend/internal/platform/ratelimit/`, `backend/.../otp.go:20-25`. — Past rate-limit audit checked send-side limits existed; never drilled into send/verify asymmetry. Also unconfirmed: whether the 5-attempt lockout can be reset by requesting a fresh code, which would weaken the bound. — **OPEN — needs one explicit check**.

14. **No tamper-evident audit log for admin/moderation actions.** — No admin surface exists yet, so correctly deferred — but must be a hard gate before any admin/moderation tooling ships. — **DEFERRED, not forgotten**.

## Process note

Most review rounds to date were reactive — triggered by a specific bug report
or a named ask ("check vulnerabilities," "check scalability") — rather than a
recurring full-surface sweep. That's why #1, #2, #4, #5, #6, #11, #12, #13
were never caught earlier: nobody's stated lens ever pointed at them. #7 and
#8 are a different failure mode — real porting gaps from the microservices →
monolith rewrite, which happened phase-by-phase with no parity checklist
against the old repo. Worth considering: a standing periodic full-sweep
(UX + security + parity-vs-old-repo) rather than only reviewing what's asked
about directly.
