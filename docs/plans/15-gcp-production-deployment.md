# Plan 15 — GCP production deployment (Cloud Run sidecar + Cloud SQL)

**Status (2026-09-10):** Cloud SQL instance and schema are live and verified.
Cloud Run deploy is designed below, not yet executed against real traffic —
this doc is what Claude Code should follow to finish it, and what the next
person should read before touching this deployment again.

**Purpose, explicitly**: this is a device-validation deployment — testing
the real end-to-end flow on two physical devices (Android + iPhone), not a
public launch. That distinction doesn't loosen anything security-wise
below: once deployed with `--allow-unauthenticated`, the service's URL is
reachable by anyone who finds it, testing intent or not, so it's held to
the same bar as a real launch (see the `ALLOW_TEST_OTP_BYPASS` section
below, which was specifically challenged and kept `false` for exactly this
reason). What the "testing, not launch" framing does affect: no custom
domain, no HA, no budget for real production traffic — this is meant to be
reachable and correct, not meant to scale or stay up indefinitely.

## What's already done, verified directly (not just assumed)

- **GCP project**: `project-285b9289-549d-4fef-92c` ("My First Project"),
  owned by the `saiprojectautumn@gmail.com` account.
- **Cloud SQL instance**: `meetups-db`, Postgres 18, `db-custom-1-3840`
  (1 vCPU / 3.75GB dedicated-core, ~$58/month — chosen over the cheaper
  shared-core `db-f1-micro` deliberately, since this app stores real
  trusted-contact/SOS data and shared-core has no SLA), region
  `asia-south1` (Mumbai — closest Tier-1 GCP region to Sri Lanka), single
  zone (no HA yet).
- **Database**: `monolith_db`, all 9 migrations applied successfully
  (confirmed via `migrate up` output and `psql \dn` showing `auth`,
  `meetup`, `notification` schemas). PostGIS installed automatically via
  migration `0002`'s own `CREATE EXTENSION IF NOT EXISTS postgis;`.
- **DB user**: `app`, password rotated at least once during setup — current
  value known to the user, not repeated here. Whoever runs the Cloud Run
  deploy needs this value to build the `database-url` secret below.
- **Secrets already created** in Secret Manager: `jwt-private-key`,
  `jwt-public-key`, `work-email-hmac`, `internal-grpc-secret`.
- **Firebase**: push notifications use project `professional-meetups-976d2`,
  which belongs to a **different Google account** than the one running this
  GCP project. Confirmed this is not a problem — the FCM service-account
  JSON key is a portable API credential, unrelated to which project/account
  runs the caller. Still needs the actual key downloaded and stored as the
  `firebase-sa` secret (not done yet as of this doc).
- **Twilio**: works locally (`TwilioSmsSender`, confirmed via docker-compose
  logs showing real send attempts), but delivery to Sri Lankan numbers on
  Dialog/Etisalat/Hutchison networks is blocked by Twilio's own platform
  limits (long codes unsupported to those three networks; Alphanumeric
  Sender ID registration required and not yet done) — see
  `docs/gap-tracker.md` if this needs tracking as a launch blocker. Does not
  block *this* deploy; OTP delivery to Mobitel numbers should work today.

## Why a Cloud Run sidecar, not two separate services

This backend is genuinely two processes — `gateway` (public HTTP,
port 8080) and `monolith` (internal gRPC, port 9090, never exposed
publicly) — authenticated to each other via `INTERNAL_GRPC_SHARED_SECRET`.
Cloud Run's multi-container (sidecar) feature runs both inside one service
instance, sharing a network namespace, so `gateway` reaches `monolith` via
plain `localhost:9090` — the closest match to how `docker-compose.yml`
already runs them (`monolith:9090` over the compose network). The
alternative (two separate Cloud Run services, IAM-authenticated
service-to-service calls) was considered and rejected for now: it would
mean re-doing the trust model this app already has working
(`INTERNAL_GRPC_SHARED_SECRET`) as a second, redundant IAM layer, for no
benefit at this scale. Revisit if `monolith` ever needs to scale
independently of `gateway`.

## Env var → container mapping (verified against `docker-compose.yml` directly — do not guess this again)

**`gateway`** (port 8080, the ingress container):
`PORT`, `MONOLITH_ADDR` (`localhost:9090` in Cloud Run, was `monolith:9090`
in compose), `JWT_PRIVATE_KEY_PATH`, `JWT_PUBLIC_KEY_PATH`,
`MONOLITH_SHARED_SECRET`, `JWT_PREVIOUS_PUBLIC_KEY_PATHS` (leave unset
outside a key rotation).

**`monolith`** (port 9090, sidecar, no public ingress):
`MONOLITH_PORT`, `DATABASE_URL`, `LINKEDIN_CLIENT_ID`/`_SECRET`/`_REDIRECT_URI`,
`APPLE_SERVICES_ID`, `GOOGLE_CLIENT_ID`, `TWILIO_ACCOUNT_SID`/`_AUTH_TOKEN`/`_PHONE_NUMBER`,
`GMAIL_ADDRESS`/`_APP_PASSWORD`, `RESEND_API_KEY`/`_FROM_EMAIL`,
`WORK_EMAIL_HMAC_KEY_PATH`, `ALLOW_TEST_OTP_BYPASS` (**must be `"false"`**),
`INTERNAL_GRPC_SHARED_SECRET`, `FIREBASE_SERVICE_ACCOUNT_JSON`.

Getting this split wrong (e.g. putting `DATABASE_URL` on `gateway`) fails
silently in confusing ways rather than erroring clearly — verify against
`docker-compose.yml` again if this doc and the actual compose file ever
disagree; the compose file is the source of truth, not this doc.

## Secret volume mounts — one Secret Manager secret per mount path

Confirmed against Google's own Cloud Run docs (a `secret` volume maps to
exactly ONE Secret Manager secret; you cannot combine two different
secrets' files into one mounted directory). Consequence: `jwt_private.pem`
and `jwt_public.pem` cannot both land in the same `/secrets` directory the
way `docker-compose.yml`'s single bind-mount does it — they need two
separate mount paths (`/secrets-priv`, `/secrets-pub`), with
`JWT_PRIVATE_KEY_PATH`/`JWT_PUBLIC_KEY_PATH` updated to match. This is a
real, deliberate divergence from the local dev layout, not a mistake to
"fix" later.

## `service.yaml`

Save this in `backend/service.yaml` (gitignored — it will contain no
secrets values, only secret *references*, but keep it out of git anyway
since it's environment-specific):

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: meetups-backend
spec:
  template:
    metadata:
      annotations:
        run.googleapis.com/cloudsql-instances: project-285b9289-549d-4fef-92c:asia-south1:meetups-db
        run.googleapis.com/container-dependencies: '{"gateway":["monolith"]}'
    spec:
      containers:
      - name: gateway
        image: asia-south1-docker.pkg.dev/project-285b9289-549d-4fef-92c/meetups-repo/gateway:latest
        ports:
        - containerPort: 8080
        env:
        - name: PORT
          value: "8080"
        - name: MONOLITH_ADDR
          value: "localhost:9090"
        - name: JWT_PRIVATE_KEY_PATH
          value: /secrets-priv/jwt_private.pem
        - name: JWT_PUBLIC_KEY_PATH
          value: /secrets-pub/jwt_public.pem
        - name: MONOLITH_SHARED_SECRET
          valueFrom:
            secretKeyRef: { name: internal-grpc-secret, key: latest }
        resources:
          limits: { memory: 512Mi, cpu: "1" }
        volumeMounts:
        - { name: jwt-priv, mountPath: /secrets-priv }
        - { name: jwt-pub, mountPath: /secrets-pub }
        startupProbe:
          exec: { command: ["/gateway", "-healthcheck"] }
          periodSeconds: 3
          failureThreshold: 10
      - name: monolith
        image: asia-south1-docker.pkg.dev/project-285b9289-549d-4fef-92c/meetups-repo/monolith:latest
        env:
        - name: MONOLITH_PORT
          value: "9090"
        - name: DATABASE_URL
          valueFrom: { secretKeyRef: { name: database-url, key: latest } }
        - name: INTERNAL_GRPC_SHARED_SECRET
          valueFrom: { secretKeyRef: { name: internal-grpc-secret, key: latest } }
        - name: FIREBASE_SERVICE_ACCOUNT_JSON
          valueFrom: { secretKeyRef: { name: firebase-sa, key: latest } }
        - name: TWILIO_ACCOUNT_SID
          value: "REPLACE_ME"
        - name: TWILIO_PHONE_NUMBER
          value: "REPLACE_ME"
        - name: TWILIO_AUTH_TOKEN
          valueFrom: { secretKeyRef: { name: twilio-auth-token, key: latest } }
        - name: WORK_EMAIL_HMAC_KEY_PATH
          value: /secrets-hmac/work_email_hmac.key
        - name: ALLOW_TEST_OTP_BYPASS
          value: "false"
        resources:
          limits: { memory: 1Gi, cpu: "1" }
        volumeMounts:
        - { name: work-hmac, mountPath: /secrets-hmac }
        startupProbe:
          exec: { command: ["/monolith", "-healthcheck"] }
          periodSeconds: 3
          failureThreshold: 20
      volumes:
      - name: jwt-priv
        secret: { secretName: jwt-private-key, items: [{ key: latest, path: jwt_private.pem }] }
      - name: jwt-pub
        secret: { secretName: jwt-public-key, items: [{ key: latest, path: jwt_public.pem }] }
      - name: work-hmac
        secret: { secretName: work-email-hmac, items: [{ key: latest, path: work_email_hmac.key }] }
```

`LINKEDIN_*`, `APPLE_SERVICES_ID`, `GOOGLE_CLIENT_ID`, `GMAIL_*`,
`RESEND_*` are deliberately omitted from the YAML above — same
empty-means-fallback behavior as local dev (LinkedIn/Apple/Google fail
closed rather than blocking startup; Gmail/Resend fall back to a logging
sender). Add them as plain env vars or secrets later, the same way Twilio
was added here, once each is actually ready to go live — don't wire a
credential-shaped env var with a placeholder value "just in case."

## Deploy steps (in order)

1. Confirm these secrets exist before deploying — `gcloud secrets list` —
   and create any missing ones: `database-url`, `firebase-sa`,
   `twilio-auth-token`. (`jwt-private-key`, `jwt-public-key`,
   `work-email-hmac`, `internal-grpc-secret` should already exist from
   earlier setup — verify, don't recreate blindly, since recreating a
   secret with the same name errors rather than silently overwriting.)
2. `gcloud artifacts repositories create meetups-repo --repository-format=docker --location=asia-south1` (skip if it already exists — check with `gcloud artifacts repositories list` first).
3. Build and push both images (`docker build` + `docker push`, both
   Dockerfiles, context is `backend/`).
4. Fill in the real `TWILIO_ACCOUNT_SID`/`TWILIO_PHONE_NUMBER` values in
   `service.yaml` (replace `REPLACE_ME`).
5. `gcloud run services replace service.yaml --region=asia-south1`.
6. **Required, easy to miss**: `gcloud run services replace` does NOT make
   the service publicly callable the way `gcloud run deploy
   --allow-unauthenticated` does — that flag doesn't exist for `services
   replace`. Without this step the mobile app gets a 403 from an
   apparently-successful deploy:
   ```
   gcloud run services add-iam-policy-binding meetups-backend \
     --region=asia-south1 --member=allUsers --role=roles/run.invoker
   ```
7. Verify: `gcloud run services describe meetups-backend --region=asia-south1`
   for the service URL, then `curl https://<url>/healthz` — expect `200`.
   If it fails, `gcloud run services logs read meetups-backend --region=asia-south1`
   is the first place to look — the `container-dependencies` annotation
   means a `monolith` startup failure surfaces as "gateway never became
   ready," not as an obviously-monolith-shaped error.

## `ALLOW_TEST_OTP_BYPASS` stays `false` here — considered and rejected, not an oversight

Raised during this deploy: since Twilio can't yet deliver OTP SMS to
Sri Lanka's Dialog/Etisalat/Hutchison networks (see the gap noted above),
should the deployed service accept the `123456` test bypass so real users
on those networks aren't blocked? **No** — that flag accepts `123456` as a
valid code for every phone and email verification, for every user, and the
exact code is sitting in this repo's own `.env.example`/`TESTING-NOTES.md`.
Phone verification gates Level 2 trust, which gates joining meetups and
using SOS/trusted contacts (ADR-003) — a global, publicly-guessable bypass
on the live service would let anyone skip real verification entirely for
the one thing this app's safety design depends on. Mobitel delivery already
works today per Twilio's own network table, so this isn't even blocking
every user, only those on the three unregistered networks. If broader live
testing is needed before the Sender ID registration completes, the safe
fix is a small explicit allowlist of test phone numbers accepting a fixed
code — scoped, not global — not this flag. Not built as part of this plan;
flag it explicitly if it's wanted.

## Known gaps, deliberately not fixed in this pass

- No custom domain mapped yet — service is reachable only at its default
  `*.run.app` URL until that's done.
- No budget alert configured yet on this project — set one before leaving
  this running unattended (Billing → Budgets & alerts).
- Twilio SMS to Sri Lanka's three largest networks (Dialog/Etisalat/
  Hutchison) needs Alphanumeric Sender ID registration before it'll work
  for most real users — tracked separately, not a blocker for getting the
  service itself deployed and reachable.
