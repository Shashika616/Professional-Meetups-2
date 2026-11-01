# Claude Code prompt 30E: anonymous host reviews, client fixes, structure, docs

Read first: `docs/plans/30-review-fixes-photos-sos-reviews.md` (sections 1, 2.3, 3.3 app side, 3.4), `docs/full-review-2026-11-01.md` (N1-D1 to N1-D8), the 30A-30D completion reports, `backend/internal/modules/meetup/{member.go,review.go}`, `queries/member.sql`, `frontend/lib/features/profile/{public_profile_body.dart,profile_page.dart}`, `frontend/lib/features/premium/*`, `frontend/lib/features/credits/*`, `frontend/lib/home/viewer_location_provider.dart`, `frontend/lib/features/meetups/widgets/other_meetups_nearby.dart`, `frontend/lib/features/privacy/privacy_controls_page.dart`, `frontend/ios/Runner/Info.plist`.

Hard rules: plan section 1.

## Host reviews (2.3)

1. Backend: the member endpoint returns, for hosts, recent completed hosted meetups (intent, date only, area label, participant count, average rating) and reviews from participants with score, text and month only. No author name, photo, id or "viewer was there" flag reaches the client for any viewer. Remove the old name-reveal logic. Review text plain, at most 500 characters. Members who only joined: completed count and rating, no meetup list.
2. App: show the host's recent meetups and the anonymous reviews ("A participant", score, text, month) in the existing profile style; empty states for no meetups and no reviews.
Tests: no author fields in any response for any viewer (scan), upcoming meetups never listed, Level 0 rules, app rendering.

## Client fixes

3. N1-D1 and location (3.3): round the last-known upload to 3 decimals; `OtherMeetupsNearby` uses an already-known location only and never starts a read; a short explanation screen before the first permission request; iOS `NSLocationWhenInUseUsageDescription` describes browsing nearby meetups and nearby notifications; remove `NSLocationAlwaysAndWhenInUseUsageDescription`; privacy page copy matches what the app does (approximate stored location, read when Home is open, SOS); map picker starts at the user's rounded location when known.
4. N1-D2: one app-level purchase listener (started after sign-in) that routes by product id against the cached catalog, waits for the catalog before routing, and keeps unrouted transactions pending.
5. N1-D3 enforce `minSupportedAppVersion` with a blocking update screen at start and on resume; N1-D4 credit client 426 maps to the same update prompt; N1-D5 rotate the analytics install id on sign-out and account deletion; N1-D6 treat a rate-limited refresh at launch like a network error (stay signed in); N1-D8 stop a flush in progress when the user opts out.
6. Anything else you find in the touched code: fix with a test or add a tracker row.

## Structure (3.4)

7. Split without behaviour changes, one file per step with the full suite green before and after: `meetups_postgres.go`, `meetup/service.go`, `auth/service.go`, `gateway/handlers/meetups.go`, `profile_page.dart`, `schedule_flow.dart`, `events_page.dart`, `meetup_detail_page.dart`. Target under 600 lines each; list any exception with a reason.

## Docs and final review

8. Update `docs/api/*` for every changed route, `TESTING-NOTES.md` (test codes unchanged; how to test photos and SOS variants), the runbook, ADR-008 (photo deletion), ADR-009 if identity flows changed, `docs/gap-tracker.md` statuses for #100-#121 and the earlier items, and the vault notes (`03 - Architecture/Full Review 2026-11-01.md` status, `08 - Legal/Privacy Policy.md` callout items now resolved) if the vault is reachable.
9. Final read-only review of everything Plan 30 changed against OWASP API Top 10 and MASVS; write `docs/plans/30-final-report.md` with what changed, open items, migrations in deploy order, and the steps only Shashika can do.

Finish with the gates.
