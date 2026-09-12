Read `docs/plans/15-gcp-production-deployment.md` in full before doing
anything — it has the exact env-var-to-container mapping (verified against
`docker-compose.yml` directly, don't re-derive it from scratch), the reasons
behind the sidecar architecture choice, and a security decision
(`ALLOW_TEST_OTP_BYPASS` stays `false`) that was deliberately argued through
and is not open for reconsideration as part of this task.

This is a two-phase task with a hard stop in between. **Do Phase 1
completely, then stop and report back — do not run anything in Phase 2
without the user explicitly telling you to proceed.** The user wants
everything staged and ready, but the actual go-live command run only on
their explicit go-ahead.

## Phase 1 — prepare everything, safe to run now

1. Run `gcloud secrets list` and compare against what's needed:
   `jwt-private-key`, `jwt-public-key`, `work-email-hmac`,
   `internal-grpc-secret` should already exist — verify, don't recreate
   (recreating an existing secret errors, it doesn't silently overwrite).
   Create whichever of `database-url`, `firebase-sa`, `twilio-auth-token`
   don't exist yet, per the plan doc's exact commands. You'll need the
   Cloud SQL `app` user's password and a downloaded Firebase
   service-account JSON from the user for this — ask for them if not
   already available in the conversation; do not guess or invent
   placeholder values for real credentials.
2. Check `gcloud artifacts repositories list` — create `meetups-repo` in
   `asia-south1` if it doesn't exist yet.
3. Build and push both images (`cmd/gateway/Dockerfile` and
   `cmd/monolith/Dockerfile`, build context is `backend/` for both — see
   each Dockerfile's own header comment). Tag both `:latest`.
4. Write `backend/service.yaml` exactly as specified in the plan doc — copy
   it verbatim, then fill in the real `TWILIO_ACCOUNT_SID` and
   `TWILIO_PHONE_NUMBER` values (ask the user for these if not already
   available; they're not secrets, but they are real values, not
   placeholders).
5. Confirm the Cloud SQL connection name, project ID, and instance name in
   the YAML actually match what `gcloud sql instances list` reports — the
   plan doc's values were correct as of when it was written, but don't
   trust them blindly; verify against the live project.

**Stop here.** Report exactly what you did, what's staged and ready
(`service.yaml` written, both images pushed, all required secrets present),
and explicitly ask the user to confirm before you proceed to Phase 2 — do
not run any command in Phase 2 in the same session unless they've said so
after seeing this report.

## Phase 2 — only after the user explicitly says to deploy

6. `gcloud run services replace service.yaml --region=asia-south1`.
7. `gcloud run services add-iam-policy-binding meetups-backend --region=asia-south1 --member=allUsers --role=roles/run.invoker` —
   required for the mobile app to be able to call it at all; easy to miss
   since `services replace` has no `--allow-unauthenticated` flag the way
   `gcloud run deploy` does.
8. Verify: `gcloud run services describe meetups-backend --region=asia-south1`
   for the URL, then `curl <url>/healthz` — expect `200`. If it fails,
   `gcloud run services logs read meetups-backend --region=asia-south1`
   first — the `container-dependencies` annotation means a `monolith`
   startup failure surfaces as "gateway never became ready," not as an
   obviously-monolith-shaped error.
9. Give the user the working `*.run.app` URL so they can point the Flutter
   app's API base URL at it and install the build on both test devices.

## When done (either phase)

Report actual command output, not a prose summary of "it worked." If
anything in Phase 1 required a value you don't have (Twilio credentials,
the DB password, the Firebase key), stop and ask rather than substituting a
placeholder that would silently break the deploy or leak into a committed
file.
