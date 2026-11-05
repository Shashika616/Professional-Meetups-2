# Review 2026-11-05: legal texts, code since Plan 30, design

Read-only, code at `c2a1aac`. Three reviews: legal texts the app and website publish, code changes since the 2026-11-01 review, design and accessibility. Tracker #122-#140.

## Legal (highest risk)

| # | Sev | Finding | Fix |
|---|---|---|---|
| 122 | Critical | No real Terms or Privacy Policy is live. The website `/terms` and `/privacy` are placeholders with TODOs; the in-app pages load from `ops.legal_documents`, which is probably empty (legaladmin refuses texts containing `[FILL IN`), so the app falls back to the placeholders | Finalise both texts with counsel (privacy: the v2.2 Claude Docs draft), publish with `cmd/legaladmin`, replace the website pages |
| 123 | Critical | No assent is recorded: `legal.acceptance.required` is seeded off, sign-up shows only links, and the server never checks acceptance (app-only gate that lets users in on error) | Turn the flag on after publishing; "By continuing, you agree to the Terms and acknowledge the Privacy Policy" at sign-up; server refuses write routes with `legal_acceptance_required` (SOS, auth, legal, delete exempt); keep acceptance records after deletion under a hashed id |
| 124 | High | Report and block do not exist (only analytics event names), yet the website safety page promises them; Apple Guideline 1.2 requires them for user-generated content and meetups | Build report user/meetup/review and block with a review queue, or remove the claims until then |
| 125 | High | Terms (vault draft) lack: credits terms, assumption of risk, indemnity, severability, entire agreement, assignment, force majeure, forum; liability clause excludes injury caused by ordinary negligence (likely void in many countries); content licence too narrow for reviews kept after deletion; Apple EULA not addressed; subscription auto-renew wording; "continued use = acceptance" contradicts the in-app accept flow; "verified professionals" overclaims | Rewrite the Terms (see the review summary in chat for clauses) |
| 126 | High | Website privacy and safety pages state untrue things: "location quantised, never exact", "below level 1 you cannot see where anything is", contact details shared only on confirmation | Replace with the v2.2 policy |
| 127 | Medium | Premium paywall Terms/Privacy links appear only if `BILLING_TERMS_URL` / `BILLING_PRIVACY_URL` are set (Apple 3.1.2) | Set them and fail the manifest test when empty |
| 128 | Medium | `/delete-account` web page has TODOs; Google Play needs a working no-app deletion request path | Finish the page with an email or form route |
| 129 | Medium | Delete-account dialog does not say remaining credits are forfeited | Add the line; mirror in Terms |
| 130 | Low | Entity and brand names inconsistent ("Professional Meetups", "AshiruLabs Pvt Ltd") | Use "TieHere" and "Ashiru Labs (Pvt) Ltd" everywhere |
| 131 | Low | No iOS app privacy manifest (`PrivacyInfo.xcprivacy`) found | Check required-reason APIs and add it |

## Code (since 2026-11-01)

All of #100-#121 are fixed in code. New:

| # | Sev | Finding | Fix |
|---|---|---|---|
| 132 | Medium (High if real users hold credits) | Credit x15 change (0039) did not scale existing balances or holds; runbook still says 60 welcome credits | Confirm no real balances, or migrate x15 with ledger adjustments |
| 133 | Medium | OTP budget keyed only by target: 5 unauthenticated starts or 10 bogus verifies lock a victim out of email login until midnight Colombo | Count guesses only after a code is claimed; key sends by target plus requester or use escalating cooldowns |
| 134 | Medium | Photo decode cap 4096 px allows ~134 MB decodes from a 300 KB file; no concurrency limit; guests can upload | MaxSide 2048 or less, pixel-budget check, 2 concurrent decodes, trust level 1 to upload |
| 135 | Medium | Legal acceptance enforced only by the app (same as #123) | — |
| 136 | Low | Per-meetup average on profiles reveals a single guest's score | Hide below 3 reviews |
| 137 | Low | Location report endpoint has no per-user limit; radius rules rely on reported location | 30 per day, refuse impossible jumps |
| 138 | Low | Verification guess budget charged to client-sent target before the match | Charge the claimed row's target |
| 139 | Low | `docs/api/billing.md` shows `credits_120` as 1800 (database 1500+300); credits page shows "1000" without grouping; runbook 60 credits | Fix text |

## Design and accessibility (#140)

- White on danger red 3.91:1 in dark (SOS confirm/retry, delete account, danger dialogs): use `AppPalette.sos` (5.29:1).
- Brand green and `verified` as text in light mode 2.0-3.0:1 (credit gains, "You're in", "Completed", Host chip); `cancelled` 3.0-3.5:1: use `verifiedText` and a darker cancelled text.
- Home nearby list is shrink-wrapped in a non-lazy scroll view: move to slivers.
- No text theme: 367 raw font sizes across 32 values; add about 7 named styles.
- 37 GestureDetectors and `Pressable` without button semantics; Premium plan selection not announced; no header semantics; legal checkbox not merged with its label.
- Custom zoom page transition removes iOS swipe-back and ignores reduce motion.
- Legal acceptance, location explanation and force-update pages do not scroll (large text overflows); `PrimaryButton` FittedBox cancels text scaling.
- Tap targets under 44 px: several 40-42 px buttons, `AppChip` 32 px, search clear 32 px.
- Premium selected plan uses green (preference: blue for selected).
- 13 radius values, three section-label widgets, trusted contacts phone field lacks the country picker, Android cropper unthemed, remove photo has no confirmation, iOS icon switch shows a system alert on every theme change.
