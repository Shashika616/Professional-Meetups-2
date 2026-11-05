# Google Cloud deployment record and redeploy runbook

> **Status 2026-11-01:** Cloud Run `meetups-backend` against Supabase
> (Mumbai), last deployed as `r38` (2026-10-22). The database moved to
> Supabase on 2026-09-15 and the Cloud SQL instance `meetups-db` was deleted
> (see §6); the Cloud SQL parts of §1–§5 are kept so it can be recreated if
> Supabase is ever left. The service scales to zero with CPU only during
> requests (§7, §10). **The next deploy** goes through the Deploy workflow
> and the order in §3a: migrations 0017-0032 are pending since the last
> recorded version, two need a pre-flight check, and Cloud Scheduler needs
> a second job.

Snapshot of the production deployment as it stood before the move (revision
`meetups-backend-r22`), written so the whole thing can be torn down for a
free-tier host and stood up again on Google Cloud later without rediscovery.
No secret VALUES are in this file; every secret is listed by name with where
its value comes from. The secret-free service manifest is next to this file
as `service.yaml.template` (the real `backend/service.yaml` is gitignored).

## 1. Inventory

| Item | Value |
|---|---|
| GCP project | `project-285b9289-549d-4fef-92c` (project number `740861671089`) |
| Region | `asia-south1` (Mumbai) |
| Cloud Run service | `meetups-backend`, public URL `https://meetups-backend-k7eklebcwq-el.a.run.app` (also `https://meetups-backend-740861671089.asia-south1.run.app`) |
| Last serving revision | `meetups-backend-r38` (2026-10-22); the Cloud SQL era ended at `r22` |
| Containers (sidecars, one Cloud Run service) | `gateway` (HTTP :8080, 1 CPU / 512Mi) and `monolith` (gRPC :9090 on localhost, 1 CPU / 1Gi); `container-dependencies: gateway → monolith` |
| Scaling | maxScale 8, containerConcurrency 80, request timeout 600s (the analytics tick needs up to 480s, §10), minScale **0** with CPU only during requests: the free tier (2026-10-22). Minscale 1 with `cpu-throttling: "false"` was tried on 2026-10-21 (#77) and reverted; Cloud Scheduler drives the background work instead (§10). `deploy_manifest_test.go` refuses either annotation |
| Service account | `740861671089-compute@developer.gserviceaccount.com` (needs Secret Manager accessor on every secret below, and `roles/storage.objectCreator` on the analytics bucket, §14; Cloud SQL client only in the Cloud SQL era) |
| Artifact Registry | `asia-south1-docker.pkg.dev/project-285b9289-549d-4fef-92c/meetups-repo` (Docker), images `gateway:rNN`, `monolith:rNN` |
| Cloud SQL instance (deleted 2026-09-15) | `meetups-db`, PostgreSQL 18, tier `db-g1-small`, zonal, 10 GB PD_SSD, public IPv4 with NO authorized networks (access only via the Cloud SQL connector/proxy), IAM auth flag on, automated backups + PITR (7-day log retention), deletion protection ON |
| Cloud SQL connection name | `project-285b9289-549d-4fef-92c:asia-south1:meetups-db` |
| Databases / users | database `monolith_db`; users `app` (application), `postgres` (admin) |
| Postgres extensions | `pgcrypto`, `postgis` (created by migrations 0001/0002) |
| Schema | golang-migrate, `backend/migrations/`, versions 0001-**0038** in the repository. The monolith refuses to start below the version it was built for (`cmd/monolith/schema_check.go`). Production was last recorded at 16 (r34, 2026-10-01); check the live version before each deploy (§3a) rather than trusting this row. Migrations go over the SESSION connection (port 5432), never the transaction pooler (6543), which breaks golang-migrate's advisory lock |
| Auth bridge page | LinkedIn redirect `https://professional-meetups-976d2.web.app` (Firebase Hosting, project `professional-meetups-976d2`) — separate from this GCP project |

### Secret Manager secrets (names; values live only in Secret Manager and the owner's password manager)

| Secret | Used as |
|---|---|
| `database-url` | `DATABASE_URL` env (monolith). Today the Supabase transaction pooler URL (§6); in the Cloud SQL era `postgres://app:<password>@/monolith_db?host=/cloudsql/<connection name>` |
| `cron-shared-secret` | `CRON_SHARED_SECRET` (gateway): authenticates Cloud Scheduler to both tick routes (§10). Without it neither is mounted and no background work runs |
| `metrics-token` | `METRICS_TOKEN` (gateway): guards `/metrics` and `/metrics/monolith`. The manifest references it, so it must exist; any long random value |
| `internal-grpc-secret` | `MONOLITH_SHARED_SECRET` (gateway) and `INTERNAL_GRPC_SHARED_SECRET` (monolith) |
| `jwt-private-key` / `jwt-public-key` | mounted as files at `/secrets-priv/jwt_private.pem`, `/secrets-pub/jwt_public.pem` (RS256, 15-min access tokens) |
| `work-email-hmac` | mounted at `/secrets-hmac/work_email_hmac.key` |
| `linkedin-client-secret` | `LINKEDIN_CLIENT_SECRET` |
| `firebase-sa` | `FIREBASE_SERVICE_ACCOUNT_JSON` (push notifications) |
| `twilio-auth-token` | `TWILIO_AUTH_TOKEN` (SMS OTP) |
| `gmail-app-password` | `GMAIL_APP_PASSWORD` (email OTP) |
| `apple-app-store-private-key` | `APPLE_APP_STORE_PRIVATE_KEY` (monolith): the App Store Connect API `.p8` key, PEM text. Without it iOS purchases are 503 (§13) |
| `google-play-service-account` | `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` (monolith): the Android Publisher service account key file's contents. Without it Android purchases are 503 (§13) |
| `analytics-user-key-secret` | `ANALYTICS_USER_KEY_SECRET` (monolith): 32+ random bytes keying `user_key = HMAC-SHA256(user id)`. Without it production collects no analytics and sends no report (§14). Rotating it splits every account's history in two; do not rotate casually |

Plain env values (not secrets, but environment-specific; see the template):
`LINKEDIN_CLIENT_ID`, `LINKEDIN_REDIRECT_URI`, `TWILIO_ACCOUNT_SID`,
`TWILIO_PHONE_NUMBER`, `GMAIL_ADDRESS`, `ALLOW_TEST_OTP_BYPASS=false`,
`TEST_OTP_BYPASS_PHONES`, `TEST_OTP_BYPASS_EMAILS`, and for store purchases
(§13) `APPLE_APP_STORE_ISSUER_ID`, `APPLE_APP_STORE_KEY_ID`,
`GOOGLE_PUBSUB_PUSH_AUDIENCE`, `GOOGLE_PUBSUB_PUSH_SERVICE_ACCOUNT`,
`BILLING_TERMS_URL`, `BILLING_PRIVACY_URL`. `BILLING_STORE` must never be set
on Cloud Run (the monolith refuses to start with `BILLING_STORE=fake` there).
For analytics and telemetry (§14): `ANALYTICS_ARCHIVE_BUCKET`,
`ANALYTICS_RAW_RETENTION_DAYS`, `ANALYTICS_REPORT_RECIPIENTS`, `OTEL_EXPORTER`
and the standard `OTEL_*` variables, `DEPLOYMENT_ENVIRONMENT`, and on the
gateway `METRICS_TOKEN` (a secret if set).

## 2. What the backend needs from any host (portability notes)

- Two long-running processes that talk gRPC over localhost (`gateway` →
  `monolith` at `MONOLITH_ADDR=localhost:9090`). They must be co-located.
- Background loops inside the monolith: notification outbox dispatcher,
  meetup lifecycle sweep (auto-close / completion), guest-account sweeper,
  notification retention. These run on tickers, so the process must be
  allowed to stay alive while there is work; on Cloud Run they only run
  while a request keeps an instance warm, which is why lifecycle checks are
  also enforced in the read queries (`window_end > now()`).
- PostgreSQL 14+ with `postgis` and `pgcrypto`. The schema uses PostGIS
  geography (`ST_DWithin`, 50 km radius), GiST indexes, deferrable unique
  constraints, per-table autovacuum settings (migration 0012).
- Outbound HTTPS to LinkedIn, Twilio, Gmail SMTP, Firebase (FCM), Nominatim.

## 3. Redeploy on Google Cloud from zero

```bash
gcloud config set project project-285b9289-549d-4fef-92c
gcloud services enable run.googleapis.com sqladmin.googleapis.com \
  secretmanager.googleapis.com artifactregistry.googleapis.com

# Registry
gcloud artifacts repositories create meetups-repo --repository-format=docker \
  --location=asia-south1

# Cloud SQL (same shape as before; pick a smaller tier if cost matters)
gcloud sql instances create meetups-db --database-version=POSTGRES_18 \
  --tier=db-g1-small --region=asia-south1 --storage-type=SSD --storage-size=10 \
  --backup-start-time=20:00 --enable-point-in-time-recovery \
  --deletion-protection --database-flags=cloudsql.iam_authentication=on
gcloud sql databases create monolith_db --instance=meetups-db
gcloud sql users create app --instance=meetups-db --password='<new app password>'

# Secrets (one per row of the table above)
printf '%s' '<value>' | gcloud secrets create database-url --data-file=-
# ... repeat for internal-grpc-secret, jwt-private-key, jwt-public-key,
#     work-email-hmac, linkedin-client-secret, firebase-sa,
#     twilio-auth-token, gmail-app-password
# Grant the runtime service account access:
for s in database-url internal-grpc-secret jwt-private-key jwt-public-key \
         work-email-hmac linkedin-client-secret firebase-sa twilio-auth-token \
         gmail-app-password; do
  gcloud secrets add-iam-policy-binding $s \
    --member=serviceAccount:740861671089-compute@developer.gserviceaccount.com \
    --role=roles/secretmanager.secretAccessor
done
gcloud projects add-iam-policy-binding project-285b9289-549d-4fef-92c \
  --member=serviceAccount:740861671089-compute@developer.gserviceaccount.com \
  --role=roles/cloudsql.client
```

Schema, in the Cloud SQL era (from `backend/`, with the Cloud SQL Auth
proxy on a local port). On Supabase there is no proxy: migrate over the
session connection instead (§3a, §6).

```bash
cloud-sql-proxy project-285b9289-549d-4fef-92c:asia-south1:meetups-db --port 6543 &
migrate -path migrations \
  -database 'postgres://app:<password>@127.0.0.1:6543/monolith_db?sslmode=disable' up
# To load a dump taken at teardown time (see §4) instead of an empty schema:
psql 'postgres://postgres:<password>@127.0.0.1:6543/monolith_db' < monolith_db.dump.sql
```

Images and service (from `backend/`; `rNN` = next revision number):

```bash
gcloud auth print-access-token | docker login -u oauth2accesstoken \
  --password-stdin https://asia-south1-docker.pkg.dev
REPO=asia-south1-docker.pkg.dev/project-285b9289-549d-4fef-92c/meetups-repo
docker buildx build --platform linux/amd64 -f cmd/gateway/Dockerfile  -t $REPO/gateway:rNN  --push .
docker buildx build --platform linux/amd64 -f cmd/monolith/Dockerfile -t $REPO/monolith:rNN --push .
# Render the manifest from docs/deploy/service.yaml.template: export every
# variable the script lists (it refuses to render with a required one
# empty), then:
REVISION=rNN scripts/render-service-yaml.sh service.yaml
go test ./cmd/monolith -run 'Manifest|Template|Render' -count=1
gcloud run services replace service.yaml --region asia-south1
gcloud run services describe meetups-backend --region asia-south1 \
  --format='value(status.traffic[0].revisionName,status.traffic[0].percent)'
```

Client: the mobile app's production gateway URL is set at build time in
`frontend/build.sh` (`PROD_URL`); update it if the service URL changes.

## 3a. Deploying the next revision (from 2026-11-01)

Normally through the **Deploy** workflow (§11), which does steps 3-5
itself. By hand, the same order:

1. **Check the live schema version** over the session connection:
   `migrate -path migrations -database "$SUPABASE_DIRECT_URL" version`.
   Everything above it up to 0038 is pending.
2. **Pre-flight the two migrations that can fail on real data** (read-only):

   ```sql
   -- 0017: personal e-mails that differ only by case (must be 0; resolve
   -- any by hand first, see ADR-009). Counts only, so no address is shown.
   SELECT count(*) FROM (SELECT 1 FROM auth.users WHERE personal_email IS NOT NULL
    GROUP BY lower(personal_email) HAVING count(*) > 1) d;

   -- 0036 (ADR-013): contacts it will delete, and accounts past the new cap
   -- of 2 (they keep their contacts; SOS alerts the 2 oldest).
   SELECT count(*) FROM auth.trusted_contacts WHERE phone_number IS NULL OR btrim(phone_number) = '';
   SELECT count(*) FROM (SELECT 1 FROM auth.trusted_contacts GROUP BY user_id HAVING count(*) > 2) d;

   -- 0019 (#101): the same person both pending and accepted on one meetup.
   -- 0019 itself now marks the extra pending row 'withdrawn' and keeps the
   -- accepted one; this says how many it will touch.
   SELECT count(*) FROM meetup.meetup_requests p
    WHERE p.status = 'pending' AND EXISTS (
          SELECT 1 FROM meetup.meetup_requests a
           WHERE a.meetup_id = p.meetup_id AND a.requester_id = p.requester_id
             AND a.status = 'accepted');
   ```

3. **Create what the new manifest references** before deploying, or Cloud
   Run refuses the revision: the secrets `cron-shared-secret` (exists since
   r35), `metrics-token`, `analytics-user-key-secret`,
   `apple-app-store-private-key` and `google-play-service-account` (a
   placeholder value is fine until the store is set up: purchases then fail
   closed with 503), each readable by the runtime service account (§1); and
   the `production` environment's values for the render script (§11). No
   analytics bucket is used for now (§14).
4. **Apply migrations** 0017-0037 in one `migrate up`. In order:
   0017-0018 identity (ADR-009); 0019 one live request per person (cleans
   up first); 0020 verification target; 0021 and 0023 SOS location and
   idempotency; 0022 refresh-token index; 0024 contact consent; 0025 feature
   flags; 0026-0029 billing, meetup billing, ledger guard, store purchases;
   0030-0032 analytics, the meetup activity outbox, the report; 0033 OTP
   budgets and shared rate counters, 0034 the company-claim review status,
   0035 the meetup creation request hash (plan 30B); 0036 reshapes trusted
   contacts (plan 30C); 0037 the photos table (plan 30D, additive); 0038 legal acceptances and the force-update flag (additive, both flags off). All are additive except 0017 and 0019, covered by
   step 2, and **0036, which is destructive**: it deletes contact emails,
   email-only contacts, duplicate numbers, pending invitations and the
   live-location flags, and the down migration restores the columns, not the
   data. Take a backup first (§9). Until the new revision serves, the old one
   cannot read contacts, so SOS fails for those minutes: run this and the
   deploy together, in a quiet hour.
5. **Deploy** the revision, then confirm `/readyz` and that traffic is on it.
5a. **Photos, once, after the deploy** (plan 30D). In this order, because the
   second copies the paths the first writes:
   `DATABASE_URL=... go run ./cmd/backfill-photos --dry-run`, then without
   `--dry-run`, then `go run ./cmd/backfill-user-display-cache`. A picture
   that cannot be
   fetched leaves initials. Both are safe to re-run.
6. **Cloud Scheduler** (§10): create the analytics job
   `monolith-cron-analytics` if it does not exist, and make sure both jobs
   are ENABLED with the attempt deadlines in §10. Run each once by hand.

## 4. Teardown checklist (only after the replacement host is verified)

1. Take a full dump and keep it somewhere durable (this is the data the
   user has said must be kept indefinitely):
   `pg_dump 'postgres://postgres:<pw>@127.0.0.1:6543/monolith_db' --no-owner --format=plain > monolith_db.dump.sql`
   (through the proxy as in §3).
2. Export secret values to the password manager
   (`gcloud secrets versions access latest --secret=<name>`).
3. `gcloud run services delete meetups-backend --region asia-south1`
4. `gcloud sql instances patch meetups-db --no-deletion-protection` then
   `gcloud sql instances delete meetups-db` (this is the recurring cost).
5. Optionally delete the Artifact Registry repo and the secrets; both are
   near-free, and keeping them makes §3 shorter.

## 5. Cost notes (as observed)

- Cloud Run at this traffic sits inside the always-free allowance (2M
  requests, 360k vCPU-seconds, 180k GiB-seconds per month); scale-to-zero.
- Cloud SQL `db-g1-small` + 10 GB SSD + PITR is the only meaningful monthly
  charge (on the order of US$25–35/month in asia-south1).

## 6. Current state: Cloud Run + Supabase (from 2026-09-15)

| Item | Value |
|---|---|
| Supabase project | ref `wvsrtbactwawxhcyokep`, region `ap-south-1` (Mumbai), Postgres 17.6, PostGIS 3.3.7, pgcrypto. (A first project in Tokyo, `vglymgqqljzywxownoma`, served for ~30 minutes on 2026-09-15 and was deleted; its data was re-seeded from the Cloud SQL final backup.) |
| Database | a dedicated `monolith_db` inside the project (NOT `postgres`): Supabase's own `auth` schema in `postgres` collides with this app's `auth` schema. Created with `CREATE DATABASE monolith_db` as the `postgres` role; the Supavisor pooler routes to it by database name. |
| App connection (Cloud Run) | transaction pooler, IPv4: `postgresql://postgres.<ref>:<pw>@aws-0-ap-south-1.pooler.supabase.com:6543/monolith_db?sslmode=require&default_query_exec_mode=cache_describe&application_name=monolith-cloudrun` — stored as Secret Manager `database-url` version 3 (v1 = old Cloud SQL URL, v2 = the deleted Tokyo project). `cache_describe` keeps pgx compatible with transaction pooling; the app has no session-level SQL. |
| Admin / migrations | direct connection (IPv6 only on the free tier; works from a Mac on IPv6): `postgresql://postgres:<pw>@db.<ref>.supabase.co:5432/monolith_db`, or the IPv4 session pooler on port 5432 (what CI and the Deploy workflow use, secret `SUPABASE_DIRECT_URL`, §9). `migrate -path migrations -database '<url>' up`. `migrate` over the 6543 transaction pooler does not work: golang-migrate holds a session-scoped advisory lock and the pooler hands each transaction a different server connection. The live schema version and the pending migrations: §3a. The `postgres` password is the same one embedded in the `database-url` secret's pooler URL. |
| Data | full copy of Cloud SQL taken 2026-09-15 (all 20 tables, row counts verified equal). Final Cloud SQL backups kept at `~/Documents/Professional Meetups/backups/` (custom-format `.dump` + plain data `.sql`), outside git. |
| Cloud Run change | `run.googleapis.com/cloudsql-instances` annotation removed from `service.yaml`; `r23`/`r24` reused the `r22` images; `r25` (2026-09-15) adds email-address validation on the unauthenticated start endpoints; `r28`/`r28b` (2026-09-16) carry ADR-005 (one meetup at a time, logout with `fcm_token`) and the Android notification icon/colour on every push; `r29` (2026-09-16) adds the advisory `GET /v1/meetups/schedule-check` and the x/crypto + compress bumps; `r30` (2026-09-17) rewords the `request_declined` and `meetup_full` push copy per ADR-006 ("Not this time"), no wire change; `r31` (2026-09-17) drops the dash from the starting-soon push; `r32` (2026-09-25) carries the five commits that had accumulated since r31 — Plan 22's `full_name_hint`/`suggested_name_update` (proto change, so `auth.pb.go` regenerated), the `FindScheduleConflict` rewrite, the starting-soon push wording and the traits comment — and was briefly deployed with `minScale: "1"` during the 2026-09-25 incident (since set back to `"0"`, see §7); `r32b` (2026-09-25) is the same images rolled again so instances re-read `firebase-sa` version 2; `r32c` (2026-09-25) adds the missing `GOOGLE_CLIENT_ID` and `APPLE_SERVICES_ID` env vars, without which Apple/Google sign-in failed in production (see §7).; `r34` (2026-10-01) carries account deletion end to end (`DELETE /v1/users/me`, the auth-side purge with its transactional outbox and 90-day SOS safety hold, and the meetup-side purge that anonymises ratings and hosted meetups rather than deleting them — ADR-008), the host-sees-every-requester fix in `CanViewMemberProfile` (a host could not open the profile of someone who had asked to join, which is the one decision the host is being asked to make), and the user-facing error rewrite: every message the app shows now goes through `apperror.UserMessage`, and the gateway's own replies (`invalid request body`, `unauthorized`, `rate limited`) are plain sentences. Migrations 0014-0016 were applied FIRST — the new code writes to `auth.user_deleted_outbox` and `auth.safety_holds`, and the hourly guest sweeper would have failed without them. |
| Free-tier caveats | project pauses after 7 idle days (unpause in the dashboard); no PITR and no managed backups on free, so the backup is ours: `.github/workflows/backup-database.yml` runs `backend/scripts/backup-database.sh` daily at 18:00 UTC (and on demand via *Run workflow*), a `pg_dump -Fc` over the direct URL uploaded to the GCS bucket in the `BACKUP_GCS_BUCKET` secret, kept 30 days by the bucket's lifecycle policy (`backend/scripts/backup-lifecycle.json`); a failed run shows as a failed workflow. See ADR-007. Pooler ~15 server connections shared, 200 client connections. |
| Latency note | Cloud Run and Supabase are both in Mumbai now; the earlier Tokyo project cost ~70 ms per DB round trip. |

Restore-from-dump into a fresh database: strip pg_dump's
`set_config('search_path', '', false)` line (the PostGIS trigger resolves
`geography` through the search path) and clear the migration-seeded
`auth.known_companies` before loading data, as was done here.

Restore from an automated backup: the nightly files are custom-format
(`pg_dump -Fc`), so fetch one with `gsutil cp gs://<bucket>/backup-<stamp>.dump .`
and load it with `pg_restore --no-owner --no-privileges -d '<direct url>' backup-<stamp>.dump`
against a database that already has the migrations applied. The same two
gotchas above apply: pass `--no-privileges` and restore data after
migrations so the PostGIS trigger and `auth.known_companies` behave as
described; if `pg_restore` reports the search_path or known_companies
conflicts, use `pg_restore -l`/`-L` to drop those items from the list and
re-run. Test a restore into a scratch database before relying on it.

## 7. The 2026-09-25 outage: billing, cold starts, and `minScale`

A full outage, then a partial one that looked like rate limiting and was not.
Recorded here because the second half is a standing property of the service,
not a one-off.

### What happened

1. **Billing was detached from the project.** Cloud Run refuses to start an
   instance at all in that state; every request returned Google's own 503
   page. The logs say it plainly: `The request failed because billing is
   disabled for this project.` Nothing was wrong with the service, the image
   or the database. Re-attaching a billing account fixed it, and no redeploy
   was needed.
2. **Then onboarding kept failing intermittently with HTTP 429 and the body
   `Rate exceeded.`** This is NOT this app's rate limiter — that one answers
   `{"error":"rate limited"}` with a `Retry-After` header
   (`internal/gateway/middleware/ratelimit.go`). The plain-text 429 is Cloud
   Run shedding a request it could not place, logged as *"The request was
   aborted because there was no available instance."* It hits every client
   equally, so different IPs and mobile data make no difference — a useful
   way to tell the two apart from the outside.

### Why the 429s happened

`minScale` was unset (so 0), which had always been true and had always been
fine. Cold starts normally cost latency, not errors: measured here at
**6.2 s cold vs 0.27 s warm**. Two things turned that into failures:

- hours at zero instances (the billing outage) meant nearly every request was
  a cold start rather than the occasional one, and
- several clients arriving inside the ~6 s startup window (two devices, a
  LinkedIn callback, health probes) were shed rather than queued.

A cold start with one caller usually queues and succeeds; the same cold start
with several callers sheds the extras. That is the whole mechanism.

### What changed, and what was deliberately left alone

`minScale: "1"` was applied during the incident and then set back to `"0"`
the same day, on Shashika's call, after weighing it against cost.

**It is back at `"1"` as of 2026-10-21, together with
`run.googleapis.com/cpu-throttling: "false"`** (tracker #77, review finding
N-C1). The cost reasoning below did not change and is still why this is 1 and
not 2. What it missed is that this service is not only a request handler:

- The notification outbox poller, the lifecycle poller (reminders,
  auto-close), the user-deleted purge and the retention sweeps are
  `time.Ticker` loops inside the monolith container.
- Cloud Run gives an **idle instance no CPU** unless `cpu-throttling` is
  off, and at `minScale: "0"` there is no instance at all between requests.
  So those loops only ran while somebody happened to be using the app.
  Reminders fired late or never, auto-close left meetups open past their
  window, and the account-deletion purge — which has a legal deadline — had
  an unbounded one.
- Both annotations are needed. `minScale: "1"` alone buys a reserved
  instance whose CPU is still throttled to near zero when no request is in
  flight, and a ticker in a throttled container does not tick on any
  schedule you can reason about.

The cost, accepted deliberately:

- At `"0"` you paid only while a request was served. At `"1"` a reserved
  instance bills continuously at the idle rate — roughly US$10-15/mo for this
  2 vCPU / 1.5 GiB pair (gateway 1/512Mi + monolith 1/1Gi) — and
  `cpu-throttling: "false"` bills that instance's CPU at the
  always-allocated rate rather than the per-request one.
- What `"1"` buys back, besides working background jobs: the cold-start shed
  described above stops happening to the first caller after an idle gap.
- The alternative considered and not taken: move every sweep to Cloud
  Scheduler, which removes the need for always-on CPU but adds endpoints,
  authentication and more moving parts than this service's load justifies
  today. Revisit if the idle bill ever matters more than that simplicity.
- A middle option, if the bill goes sour: a Cloud Scheduler ping every ~5
  minutes keeps an instance alive for near-zero cost, but leaves a smaller
  window where a cold start can still land — and does **not** fix CPU
  throttling between pings.

**Whichever value is in force, keep it in the manifest.** The annotation is
now written explicitly in `docs/deploy/service.yaml.template` and
`backend/service.yaml` rather than being left absent. The file previously had
no `minScale` at all, which meant a `gcloud run services replace` would
silently revert whatever `gcloud run services update --min-instances=N` had
set. That trap was hit on 2026-09-25 and is the reason the value is spelled
out even when it is the same as the default.

### Apple and Google sign-in were dead in production (same day)

Separate from the outage, found while investigating a report that Google
sign-in failed: the deployed service had **no `GOOGLE_CLIENT_ID` and no
`APPLE_SERVICES_ID`**. Both were present in `backend/.env`, so both providers
worked against a local backend and failed against production — the worst
shape a config bug can take.

Nothing logs this. `identity.NewGoogleProvider`/`NewAppleProvider` accept an
empty client id on purpose, so the service boots normally and then rejects
every token that arrives ("Verify will then reject every token, never accept
one", their own doc comments). The client sees a generic sign-in failure.

The app side was already correct and was verified rather than assumed:

- Android: the release APK's signing certificate SHA-1
  (`6d38a58ba517b5b88ac0c6fc08ee5164b14777db`, via `apksigner verify
  --print-certs`) matches `certificate_hash` in `android/app/google-services.json`.
- iOS: `Info.plist` carries `GIDClientID` and the reversed-client-id URL
  scheme for the iOS OAuth client.
- `frontend/.env`'s `GOOGLE_SERVER_CLIENT_ID` equals `backend/.env`'s
  `GOOGLE_CLIENT_ID` — the WEB client, which is what makes one audience valid
  for every platform.

Fixed in `r32c`, and both variables are now declared in
`docs/deploy/service.yaml.template` so a manifest rebuilt from it cannot lose
them again. If federated sign-in ever fails everywhere at once while email
still works, check these two env vars on the running revision first:

```bash
gcloud run revisions describe <revision> --region asia-south1 --format=json \
  | python3 -c "import json,sys;print([e for c in json.load(sys.stdin)['spec']['containers'] if c['name']=='monolith' for e in c['env'] if 'CLIENT_ID' in e['name'] or 'SERVICES_ID' in e['name']])"
```

### Also corrected in the same pass

`firebase-sa` held a service account for the OLD Firebase project
(`professional-meetups-976d2`) while the app had migrated to
`project-285b9289-549d-4fef-92c`. FCM tokens are project-scoped, so
production push could not have been delivered; local push was unaffected
because `backend/.env` had already been migrated. Fixed as secret version 2,
and `r32b` exists solely so instances re-read it — secrets are resolved at
instance start, so adding a version does nothing until a new instance boots.
Verify with:

```bash
gcloud logging read 'resource.labels.service_name="meetups-backend" AND jsonPayload.message:"push notification"' \
  --limit 2 --freshness=20m --format="value(jsonPayload.message,jsonPayload.project_id)"
```

## 8. Android release signing (only Shashika can do the first step)

Tracker #55, review finding V-5. Until 2026-10-21 the release build was
signed with the **debug** keystore — the one every Android SDK install
generates, with the password `android`. Play will not accept it, and an
APK signed with it proves nothing about who built it: anybody can produce
a byte-identical signer and ship an "update".

`android/app/build.gradle.kts` now reads the signing config from
`android/key.properties` and **fails the release build** when that file is
missing, rather than falling back to debug. Debug and profile builds are
unaffected (`flutter run` needs nothing).

### Create the keystore — once, by hand, outside the repository

The repository never generates this and must never contain it.

```bash
keytool -genkey -v \
  -keystore ~/keys/tiehere-upload.jks \
  -storetype JKS \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias tiehere-upload
```

Then write `frontend/android/key.properties` (gitignored in two places —
`android/.gitignore:12` and the root `.gitignore:34`):

```properties
storeFile=/Users/<you>/keys/tiehere-upload.jks
storePassword=<store password>
keyAlias=tiehere-upload
keyPassword=<key password>
```

`storeFile` is resolved relative to `frontend/android/`, so an absolute
path outside the tree is the intended shape.

### Keep it, because it cannot be recovered

- Back the `.jks` file and both passwords up somewhere that survives this
  laptop. **There is no recovery.** A lost upload key means a new key,
  which means a new application listing on Play and every existing
  install stranded on the old one.
- Do not paste it into the repository, a ticket, or a chat. For CI, add
  the base64 of the `.jks` and the three secrets to the repository's
  encrypted secrets and have the workflow write `key.properties` at build
  time.
- If Play App Signing is enabled, this is the *upload* key; Google holds
  the app signing key and losing the upload key is recoverable through
  Play support. Confirm which of the two applies before trusting that
  sentence.

### Verify

```bash
# Must FAIL with "Release build needs android/key.properties" when absent:
flutter build apk --release --dart-define-from-file=.env

# With key.properties in place, confirm the signer is not the debug key:
keytool -printcert -jarfile build/app/outputs/flutter-apk/app-release.apk
```

A debug-signed artifact shows `CN=Android Debug, O=Android, C=US`. Any
other subject means the real key was used.

---

## 9. Backups (rebuilt 2026-10-22, after the loss)

### What went wrong

`.github/workflows/backup-database.yml` ran 27 times between 2026-09-25 and
2026-10-22. All 27 failed, every one of them at step 4, "Authenticate to
Google Cloud":

```yaml
credentials_json: ${{ secrets.GCP_BACKUP_SA_KEY }}
```

That secret was never set, and the service account, the bucket and the IAM
it referred to were never created — the project had zero GCS buckets. So
`pg_dump` never ran: there has never been a backup of this database.

Nothing reported the failures. When the Supabase project was paused and its
data was lost, the recovery point was a workflow that had been red for four
weeks in a tab nobody opened.

Three separate things had to be fixed, and only the first is about credentials:

1. **Authentication.** Now Workload Identity Federation, not a JSON key.
   GitHub mints a short-lived OIDC token; Google exchanges it. There is no
   long-lived credential in the repo's secrets to go missing or go stale.
2. **The resources.** The bucket, the service account and the federation
   now exist, created by a script that is in the repo and can be re-run.
3. **The silence.** A failed run now opens a GitHub issue. This is the part
   that actually cost the data; the other two only made the failure
   possible.

### Setting it up

Once, as a project owner:

```sh
gcloud auth login
backend/scripts/setup-backup-infra.sh
```

It is idempotent — re-run it freely, including to finish after a failure.
It creates:

| Resource | Value | Free? |
| --- | --- | --- |
| Bucket | `gs://meetups-db-backups-740861671089`, **asia-south1** | ~4 MB at 30-day retention, about US$0.0001/mo |
| Lifecycle | delete at 30 days (`backup-lifecycle.json`) | keeps it far under 5 GB |
| Service account | `db-backup@…`, `storage.objectAdmin` on that bucket only | IAM is free |
| WIF pool/provider | `github`/`github`, issuer `token.actions.githubusercontent.com` | free |

The bucket is in `asia-south1`, beside the database and Cloud Run. It was
briefly in `us-central1` on 2026-10-22, to stay inside Cloud Storage's
always-free 5 GB (which exists only in us-east1/us-west1/us-central1). That
was the wrong trade at this size: one dump is 128 KB, so 30 days of
retention is about 4 MB, which costs roughly US$0.0001/mo in asia-south1.
Keeping users' data in-region is worth more than that.

### The security boundary

This repository is **public**. The provider's attribute condition is what
stops any repository on the internet from minting a token this project
accepts:

```
assertion.repository == 'Shashika616/Professional-Meetups-2' && assertion.ref == 'refs/heads/main'
```

Pinning `ref` as well as `repository` is deliberate: a pull request from a
fork runs with `ref=refs/pull/N/merge`, so a PR that edits the workflow
cannot use this provider. Do not relax either clause to "make a branch
work" — add a second provider instead.

### The one manual step

Set **one** GitHub Actions secret (Settings → Secrets and variables → Actions):

```
SUPABASE_DIRECT_URL = postgres://postgres.<ref>:<pw>@aws-0-ap-south-1.pooler.supabase.com:5432/monolith_db?sslmode=require
```

That is Supavisor's **session** pooler: the pooler host, port **5432**, the
tenant-qualified user `postgres.<ref>`. Two near misses that both fail:

- the **direct** host `db.<ref>.supabase.co` is IPv6-only on the free tier,
  and GitHub-hosted runners have no IPv6, so the workflow cannot connect
  (verified 2026-10-22: no A record; a dump forced onto IPv4 through the
  session pooler succeeds with all 22 app tables);
- the **6543** transaction pooler hands out a different server connection
  per transaction, which a long `pg_dump` cannot work over (§6).

The script also refuses any URL whose database is not `monolith_db`. The bucket, provider and service account are
identifiers rather than credentials and live in the workflow file, so there
is nothing else to set. **Delete `GCP_BACKUP_SA_KEY`** — it is no longer read.

### Verifying it, which is the point

```sh
gh workflow run backup-database.yml
gh run watch
backend/scripts/restore-drill.sh
```

The drill downloads the newest dump, restores it into a throwaway local
database, and asserts the `auth`, `meetup` and `notification` schemas are
present, that there are at least 15 tables, and that `schema_migrations`
matches `backend/migrations/`. It refuses to run against anything that is
not localhost, because it creates and drops databases.

Run it after any change to the backup path, and at least monthly. A backup
that has never been restored from is a hypothesis.

---

## 10. Scheduled work, and why the service scales to zero

### The cost

The monolith is not only a request handler. The lifecycle sweeps (reminders,
auto-close), three outbox pollers, three retention passes and three auth
sweeps were all `time.Ticker` loops, and a ticker needs an instance that is
alive **and** has CPU. On Cloud Run that means:

```yaml
autoscaling.knative.dev/minScale: "1"
run.googleapis.com/cpu-throttling: "false"
```

Those two were set on 2026-10-21 for tracker #77 and reverted on 2026-10-22.
Together they reserve an instance and bill its CPU for every second of the
month, whether or not anybody uses the app: 2 vCPU × 2.59M seconds against a
free allowance of 180,000 vCPU-seconds, roughly **US$120–130/mo**. (The
comment they replaced estimated "US$10–15/mo" — that is the *throttled* idle
rate, which `cpu-throttling: "false"` specifically opts out of.)

`cmd/monolith/deploy_manifest_test.go` fails if either creeps back.

### What replaced them

Cloud Scheduler (3 jobs always free) runs two jobs every 15 minutes. The
gateway forwards each to the monolith's `OpsService`, which runs that
group's sweeps once and reports each one's row count (tracker #102):

| Job | Route | Sweeps | Total the gateway allows | Scheduler attempt deadline |
| --- | --- | --- | --- | --- |
| `monolith-cron-tick` | `POST /internal/cron/tick` | the 27 core sweeps: lifecycle, outboxes, retention, auth, billing, analytics partitions, and last the analytics flush | 240s | 300s |
| `monolith-cron-analytics` | `POST /internal/cron/tick/analytics` | the 3 analytics sweeps: aggregate, archive and retention, daily report | 480s | 540s |

- **Each sweep has its own budget** (30s by default, 120s for the
  analytics sweeps, whose statements run under a 120s limit) and the
  monolith stops starting sweeps when the total is nearly spent. A sweep it
  had no time for is reported as skipped and counts as a failure, so the
  report always reaches Scheduler before its deadline and names what did
  not run.
- **Each route sets its own write deadline**, past the gateway's 30s
  `WriteTimeout` for ordinary requests; Cloud Run's request timeout is 600s
  (`service.yaml`).
- **Why two jobs:** the analytics sweeps need minutes on a big day and the
  core sweeps must never wait behind them (the account-deletion purge has a
  legal deadline). Two jobs fit the free tier's three.

- **One sweep failing never stops the others.** They are unrelated, and the
  account-deletion purge has a legal deadline.
- **A tick with any failure returns 500**, so Scheduler records it and
  retries. Every sweep is a claim (`FOR UPDATE SKIP LOCKED`), so a retry
  re-does nothing that already succeeded.
- **The tickers are still there.** When an instance happens to be alive they
  do the work sooner. Running both paths is harmless, for the same reason.

### Why 15 minutes

At minScale 0 every tick is a cold start (measured 6.2s) plus the work, on
2 vCPU:

| Cadence | vCPU-seconds/month | Inside the 180,000 free allowance? |
| --- | --- | --- |
| 1 minute | ~600,000 | no — billed |
| 5 minutes | ~124,000 | yes, but little room for real traffic |
| **15 minutes** | **~40,000** | **yes, with room** |

The cost is latency, and only for two things: reminders and auto-close land
within 15 minutes of their threshold instead of within 1 minute. Push
notifications are **not** affected — the outbox is woken in-process by the
write that created the notification, so delivery is immediate while an
instance is up; the scheduled drain is the retry path.

### The route's own secret

Everything else under `/internal` is unreachable from outside the container
pair. This route is not: Cloud Scheduler reaches it over the public URL. It
cannot use the bearer-token middleware, because the caller is a scheduler
rather than a user with a session, so it checks `X-Cron-Secret` in constant
time against `CRON_SHARED_SECRET` (Secret Manager: `cron-shared-secret`).

**If that variable is unset the route is not mounted at all.** An
unauthenticated endpoint that runs database writes is worse than no
endpoint, and local and test stacks genuinely do not need it — there the
in-process tickers do the work. The gateway logs a warning at startup when
it is missing.

The worst an attacker holding the secret achieves is making idempotent,
claim-based sweeps run more often than scheduled, which is what they are
built to tolerate. No user data is returned.

### The jobs

`monolith-cron-tick` was created on 2026-10-22 and PAUSED until a revision
with the route was deployed (r35). Check its state, and that the attempt
deadline is 300s (it was created with the old 180s):

```sh
gcloud scheduler jobs describe monolith-cron-tick --location=asia-south1 \
  --format='value(state,attemptDeadline,schedule)'
gcloud scheduler jobs update http monolith-cron-tick --location=asia-south1 \
  --attempt-deadline=300s
gcloud scheduler jobs resume monolith-cron-tick --location=asia-south1   # if PAUSED
```

The analytics job, created with the next deploy (§3a step 6). The secret
goes in a header, never the URL:

```sh
URL="$(gcloud run services describe meetups-backend --region asia-south1 --format='value(status.url)')"
gcloud scheduler jobs create http monolith-cron-analytics --location=asia-south1 \
  --schedule='*/15 * * * *' --time-zone=Etc/UTC \
  --uri="$URL/internal/cron/tick/analytics" --http-method=POST \
  --headers="X-Cron-Secret=$(gcloud secrets versions access latest --secret=cron-shared-secret)" \
  --attempt-deadline=540s --max-retry-attempts=1
gcloud scheduler jobs run monolith-cron-analytics --location=asia-south1   # verify once by hand
```

If either job is paused or missing, that group's work does not run: the
core job's absence stops reminders, auto-close, outbox retries and
retention; the analytics job's absence stops aggregation, the archive and
the report, and raw events then grow without being dropped.

---

## 11. The Deploy workflow (manual, Workload Identity)

`.github/workflows/deploy.yml` does what §3 does by hand — build and push
both images, apply migrations, render and check the manifest, deploy the
revision, confirm `/readyz` — from a clean checkout. It runs only when
someone presses **Run workflow** and types a new revision name such as
`r39`. Nothing deploys on push.

Two gates before anything is built (#95, #100):

- **A green Backend CI run on the same commit.** The workflow asks the
  Actions API and stops if there is none (CI runs on every push to main).
- **The protected `production` environment.** The job waits for an
  approver there. Create it once in *Settings → Environments*: required
  reviewer Shashika, deployment branches `main` only.

`backend/service.yaml` is not in git. The workflow renders it from
`docs/deploy/service.yaml.template` with `backend/scripts/render-service-yaml.sh`,
which refuses to run with a required value empty and refuses values that
would break the YAML, then runs the manifest tests on the result. Its
values are the `production` environment's secrets (identifiers and test
allowlists rather than credentials, but the repository is public):
required `GOOGLE_CLIENT_ID`, `APPLE_SERVICES_ID`,
`LINKEDIN_CLIENT_ID`, `TWILIO_ACCOUNT_SID`, `TWILIO_PHONE_NUMBER`,
`GMAIL_ADDRESS`, `MIN_CREDITS_APP_VERSION` (`1.1.0`), `OTEL_EXPORTER`
(`none`); optional, with a warning when empty, `ANALYTICS_ARCHIVE_BUCKET`
(leave it empty for now, §14), `ANALYTICS_REPORT_RECIPIENTS`, `MIN_SUPPORTED_APP_VERSION`,
`APPLE_APP_STORE_ISSUER_ID`, `APPLE_APP_STORE_KEY_ID`,
`GOOGLE_PUBSUB_PUSH_AUDIENCE`, `GOOGLE_PUBSUB_PUSH_SERVICE_ACCOUNT`,
`TEST_OTP_BYPASS_PHONES`, `TEST_OTP_BYPASS_EMAILS`. Copy the values of the
last two exactly from the r38 manifest: the sign-in test codes depend on
them (`TESTING-NOTES.md`).

Migrations run before the deploy on purpose: the monolith refuses to start
against a schema older than it was built for (`cmd/monolith/schema_check.go`),
so a revision deployed without its migrations never becomes ready and Cloud
Run keeps serving the previous one.

### One-time setup (project owner)

It authenticates through the same Workload Identity pool as the backup (§9),
whose condition admits only this repository's `main` branch. It needs its own
service account, with the narrowest roles that can deploy:

```sh
P=project-285b9289-549d-4fef-92c
SA=deployer@$P.iam.gserviceaccount.com

gcloud iam service-accounts create deployer \
  --display-name="GitHub Actions deploy" \
  --description="Builds, pushes and deploys meetups-backend from the manual Deploy workflow."

# Deploy revisions; NOT run.admin, so it cannot change who may invoke the service.
gcloud projects add-iam-policy-binding $P \
  --member="serviceAccount:$SA" --role="roles/run.developer" --condition=None

# Push images to this one repository only.
gcloud artifacts repositories add-iam-policy-binding meetups-repo \
  --location=asia-south1 --member="serviceAccount:$SA" --role="roles/artifactregistry.writer"

# Deploy a service that runs as the runtime account.
gcloud iam service-accounts add-iam-policy-binding \
  740861671089-compute@developer.gserviceaccount.com \
  --member="serviceAccount:$SA" --role="roles/iam.serviceAccountUser"

# Let this repository's main branch act as it.
gcloud iam service-accounts add-iam-policy-binding $SA \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/740861671089/locations/global/workloadIdentityPools/github/attribute.repository/Shashika616/Professional-Meetups-2"
```

It reads the `SUPABASE_DIRECT_URL` Actions secret the backup already uses
(the session-pooler URL, §9) to run migrations.

Not created automatically on 2026-10-22: granting project-level roles to a
new identity was left to the project owner.

## 12. Credits, feature flags and the billing sweeps (plan 29A)

Migrations 0025-0028 add the `ops` schema (feature flags), the `billing` schema,
the meetup columns `creation_key` and `charge_hold_id`, and (0028) a trigger that
refuses TRUNCATE on the ledger. They are backward
compatible with the revision already serving (sqlc lists columns explicitly), so
the usual order holds: run migrations, then deploy. The monolith refuses to start
below the latest migration it ships (29 after plan 29B, §13).

### Credits are live on deploy

Credits have **no flag**. From the moment this revision serves, creating a
meetup costs credits (or plan quota), a hosting-level user's first billing call
grants the 1000 welcome credits, and the free limits are 20 people and 14 days
ahead. Only subscription plans are switched, by `billing.plans.visible`
(off, on for the seeded `@meetups.test` accounts).

**Deploy this with the 29C app release, not before.** Every app build older than
`MIN_CREDITS_APP_VERSION` gets 426 "Update TieHere to host a meetup." when it
tries to create a meetup (everything else keeps working). The builds on phones
today are 1.0.0, so deploying ahead of 29C stops everyone hosting until they
update.

### Environment

All optional; the defaults are safe.

| Variable | Default | Meaning |
|---|---|---|
| `MIN_CREDITS_APP_VERSION` | `1.1.0` | An older app build gets 426 "Update TieHere to host a meetup." on create. Set it to the first released build with the credits UI (29C). |
| `MIN_SUPPORTED_APP_VERSION` | `1.0.0` | Reported by `/v1/app-config`; the app may prompt below it. The server refuses nothing because of it. |
| `BILLING_CATALOG_VERSION` | `1` | Reported by `/v1/app-config` so the app knows when to refetch the catalog (29B). |

### Admin: `cmd/billingadmin`

The only way to change credits, plans or flags by hand. It needs `DATABASE_URL`
pointing at the **session pooler** (port 5432, §9), never the transaction pooler.
Every changing command needs `--operator` and `--reason`, and is written to the
ledger, `billing.admin_audit` or `ops.feature_flag_audit`.

```bash
cd backend
export DATABASE_URL='<session pooler URL for monolith_db>'
go run ./cmd/billingadmin flags show
go run ./cmd/billingadmin flags set --flag billing.plans.visible --enabled true \
  --operator shashika --reason "launch plans"
go run ./cmd/billingadmin show-wallet --user <uuid>
go run ./cmd/billingadmin grant --user <uuid> --amount 20 --operator shashika --reason "support #12"
go run ./cmd/billingadmin adjust --user <uuid> --delta -5 --operator shashika --reason "correction"
go run ./cmd/billingadmin set-plan --user <uuid> --plan enterprise --until 2027-06-30 \
  --operator shashika --reason "contract"
```

`grant` and `adjust` are idempotent: the identical command run twice applies
once. Pass `--key <new value>` to repeat a grant on purpose. A flag change is live
on every instance within 30 seconds.

There is no switch that makes creation free again; that would take a deploy.
Hiding plans (`flags set --flag billing.plans.visible --enabled false`) does not
affect subscriptions already active.

### New sweeps on the scheduled tick (§10)

The billing sweeps have no ticker of their own, so the tick is what runs them
(`TestScheduledTickRunsEveryBillingSweep` pins the list):

| Sweep name in the logs | What it does |
|---|---|
| `outbox: meetup billing events` | Captures holds for created meetups; applies the refund policy to cancelled and closed ones |
| `billing: expired holds` | Releases holds older than their TTL (2 hours) |
| `billing: decay and expiry` | Materialises weekly welcome-credit decay and expiries for idle wallets |
| `outbox: billing` | Drains billing's outbox: Google finishes, the meetup subscription cache, and (29D) credits, purchase and subscription events for analytics |
| `billing: reconciliation` | Once per UTC day: checks every wallet against its lots, open holds and ledger; records the run in `billing.reconciliation_runs` |
| `retention: meetup billing events`, `retention: billing outbox` | Keep the two outboxes bounded |

### Checking the books

A reconciliation mismatch is logged at error level as
`billing: reconciliation mismatch` and should never happen. To look directly:

```sql
SELECT run_date, checked, mismatches, detail FROM billing.reconciliation_runs ORDER BY run_date DESC LIMIT 7;
SELECT * FROM billing.refund_log ORDER BY created_at DESC LIMIT 20;
-- Debt (a capture that arrived after its hold lapsed and could not be covered):
SELECT user_id, debt FROM billing.wallets WHERE debt > 0;
```

`billing.ledger_entries` rejects UPDATE, DELETE and TRUNCATE by trigger; corrections are new
entries made with `billingadmin adjust`.

## 13. Store purchases, subscriptions and the catalog (plan 29B)

Migration 0029 adds `billing.store_products` (the catalog: three credit packs and
the two Pro products), `billing.store_purchases`, `billing.processed_store_notifications`,
plan titles and perks, and two subscription columns. Additive and backward
compatible: run it, then deploy. The monolith then refuses to start below
schema 29.

The console steps (products, API keys, notification URLs, testers, review
notes) are in `docs/deploy/store-setup.md`. Until they are done:

| Missing | Effect |
|---|---|
| `APPLE_APP_STORE_ISSUER_ID`, `_KEY_ID` or `_PRIVATE_KEY` | iOS purchases answer 503 and the monolith logs `billing: store verification is not configured; refusing the purchase (fail closed)`. Nothing is granted. |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | The same for Android, and purchases already granted are not consumed (the `store.finish` outbox job retries them until the key is set; Google refunds what is not acknowledged within three days) |
| `GOOGLE_PUBSUB_PUSH_AUDIENCE` | `POST /v1/billing/webhooks/google` answers 503; Pub/Sub retries |
| `GOOGLE_PUBSUB_PUSH_SERVICE_ACCOUNT` (production) | The same 503. The audience alone does not prove a push came from our subscription, so production requires the subscription's service account too (security review 2026-11-01, S-1) |

Apple notifications need no secret: they are verified against Apple's root
certificate, which is embedded in the code.

`APPLE_BUNDLE_ID` and `GOOGLE_PLAY_PACKAGE_NAME` default to the app's real ids
(`com.profconn.professionalConnectionsPlatform`,
`com.profconn.professional_connections_platform`); set them only if those
change. Sandbox purchases are accepted in production only from the test
accounts on the `billing.plans.visible` allowlist (App Review uses the sandbox).

### Things to watch

- Log lines `billing: verified purchase refused` (a real store purchase that
  failed a check: wrong app, wrong account, sandbox) and `billing: granted a
  subscription to an account the plans are hidden from` (a paid purchase is
  always granted; this says how it was bought).
- Dead-lettered `store.finish` rows in `billing.billing_outbox`: a Google
  purchase that could not be consumed. Consume it in the Play Console before
  the three days are up.

## 14. Analytics, the daily report and telemetry (plans 29D-29F)

> **Decision (Shashika, 2026-11-04): no analytics bucket for now.** Leave
> `ANALYTICS_ARCHIVE_BUCKET` empty. Raw events are dropped after the
> retention with no archive copy, the daily aggregates stay in Postgres, and
> the report is only emailed, so set `ANALYTICS_REPORT_RECIPIENTS` or it goes
> nowhere. The bucket, IAM and lifecycle notes below apply only if a bucket is
> added later.

Migrations 0030-0032 add the `analytics` schema (day-partitioned raw events,
daily aggregates, opt-outs, report runs, per-day active accounts) and
`meetup.activity_outbox`. Additive: run them, then deploy. The monolith then
refuses to start below schema 32.

### Environment and secrets

| Variable | Default | Effect when missing |
|---|---|---|
| `ANALYTICS_USER_KEY_SECRET` (secret) | none | **Production collects nothing** and logs `analytics disabled: collecting nothing` at start-up. Locally a fixed development key is used |
| `ANALYTICS_ARCHIVE_BUCKET` | none | Raw days are still dropped after the retention, without an archive copy (logged at start-up and per day). The daily report is not stored. Give the Cloud Run service account `roles/storage.objectCreator` on the bucket, and nothing more: every upload is create-only (below) |
| `ANALYTICS_RAW_RETENTION_DAYS` | `14` | Raw events stay this many days (1-90) |
| `ANALYTICS_REPORT_RECIPIENTS` | none | Comma-separated plain addresses (at most 20). Empty: the report is built and stored, not emailed. It goes out through the configured sender (Gmail, then Resend, then the logging sender) |
| `OTEL_EXPORTER` | `none` | `stdout` or `otlp` (with `OTEL_EXPORTER_OTLP_ENDPOINT`). See `docs/observability.md` |
| `METRICS_TOKEN` (gateway) | none | `/metrics` and `/metrics/monolith` are not served on Cloud Run |

### Flags

| Flag | Default | Meaning |
|---|---|---|
| `analytics.enabled` | on | The kill switch: off drops every event, app and server, at once (no release needed) |
| `analytics.sample_rate` | 100 | The share of installs that send events (the app reads it from `/v1/app-config`) |

```bash
go run ./cmd/billingadmin flags set --flag analytics.enabled --enabled false --operator shashika --reason "incident"
```

### Sweeps on the scheduled tick (§10)

| Sweep name in the logs | What it does |
|---|---|
| `outbox: meetup activity`, `retention: meetup activity` | Join requests and accepts into analytics; keeps the outbox bounded |
| `analytics: partitions` | Creates today's raw partition and the next three |
| `analytics: aggregate` | Aggregates each complete Asia/Colombo day once (`analytics.aggregate_runs`) |
| `analytics: archive and retention` | Archives raw days past the retention to `gs://$ANALYTICS_ARCHIVE_BUCKET/analytics/raw/YYYY/MM/DD.ndjson.gz`, then drops them; keeps 120 days of active-account rows |
| `analytics: daily report` | After 06:00 Asia/Colombo, once: yesterday's report, emailed and stored at `analytics/reports/YYYY-MM-DD.xlsx`. A failed email or upload is retried on the next tick (only the part that failed), up to 24 attempts |
| `auth: otp budgets`, `ops: rate counters` | Plan 30B: trim the daily OTP budgets (today and yesterday kept) and finished shared-limit windows |
| `auth: location retention` | Plan 30B: forgets last known locations older than 30 days, deletes SOS events older than 90 |
| `meetup: stale locations`, `meetup: old meetup coordinates` | Plan 30B: deletes cached locations older than 30 days; coarsens the coordinates of meetups that ended more than 180 days ago to 2 decimals (D4) |
| `analytics: flush` | Last in the core tick (#117): writes the server events the outbox drains just handed to the in-memory buffer, so an instance that idles after the tick loses none |

Partitions and the flush run on the core job; aggregate, archive and
retention, and the report on the analytics job (§10), every 15 minutes. The
report lands between 06:00 and 06:15 Colombo.

**Bucket permissions (#116).** Every object is written create-only
(`ifGenerationMatch=0`), so `roles/storage.objectCreator` is enough and
nothing the service runs can replace or delete a stored file. A retry after
an upload that landed but was not recorded gets 412, which counts as done.
A regenerated report is stored beside the daily one, never over it. Keep
raw archives no longer than the privacy policy says.

**Archive lifecycle (#110).** Raw archives are deleted after 90 days by a
bucket lifecycle rule, set once:

```sh
cat > /tmp/lifecycle.json <<'JSON'
{"rule": [{"action": {"type": "Delete"},
           "condition": {"age": 90, "matchesPrefix": ["analytics/raw/"]}}]}
JSON
gcloud storage buckets update gs://$ANALYTICS_ARCHIVE_BUCKET --lifecycle-file=/tmp/lifecycle.json
```

Since plan 30B an archived line carries no `user_key` or `install_id`:
account deletion and opt-out erase what is in Postgres, and cannot reach a
file in a bucket, so the file holds nothing that links an event to a person
or a device. Sessions, screens, flows and attributes stay. Reports are kept
(aggregates only). The upload is streamed in 8 MiB chunks (resumable
upload), so a busy day is never held in memory.

### Regenerating a report

```bash
cd backend
export DATABASE_URL='<session pooler URL for monolith_db>'
go run ./cmd/analyticsreport --date=2026-10-31 --out=report.xlsx      # just the file
go run ./cmd/analyticsreport --date=2026-10-31 --deliver              # email it and store a regenerated copy
```

It re-aggregates the day from its raw events, so it works while they are still
in Postgres (the retention window). `--deliver` stores the workbook as
`analytics/reports/YYYY-MM-DD.regenerated-<UTC time>.xlsx` beside the daily
copy. The upload authenticates through the metadata server, so it works only
on Google Cloud (for example as a Cloud Run job running as the service
account); from a laptop the email goes out and the upload fails with
`metadata token`, which changes nothing in the bucket.

### Checking

```sql
SELECT day, status, attempts, emailed_at, uploaded_at, detail FROM analytics.report_runs ORDER BY day DESC LIMIT 7;
SELECT day, aggregated_at, events FROM analytics.aggregate_runs ORDER BY day DESC LIMIT 7;
SELECT day, archived_at, dropped_at FROM analytics.partitions ORDER BY day DESC LIMIT 20;
```

Metrics (behind `METRICS_TOKEN`): `analytics_events_dropped_total{reason}`,
`analytics_flush_failures_total`, `analytics_reports_total{part,outcome}`.
Locally, `backend/scripts/seed-analytics.sh` seeds a realistic fortnight and
builds a report from it.

## 15. Switching on credit packs and subscription plans in production

Credits and credit packs need no switch: they are live with the backend and the
1.1.0 app. Packs appear in the app as soon as the store products exist (the
catalog lists them; the app shows those the store returns).

Plans are hidden behind `billing.plans.visible` until you choose. In order:

1. The store side is done (`docs/deploy/store-setup.md`): both Pro products
   approved in App Store Connect and Play Console, notifications pointed at
   `/v1/billing/webhooks/{apple,google}`, the four Apple values and the Google
   service account in Secret Manager, `GOOGLE_PUBSUB_PUSH_AUDIENCE` and
   `GOOGLE_PUBSUB_PUSH_SERVICE_ACCOUNT` set.
2. `BILLING_TERMS_URL` and `BILLING_PRIVACY_URL` are set (App Review requires
   them on the subscription screen).
3. Test with a sandbox tester (iOS) and a license tester (Android) on an
   allowlisted `@meetups.test` account: buy, restore, cancel in the store, and
   check `billing.subscriptions` and the app (`TESTING-NOTES.md`).
4. Turn plans on for everyone:

   ```bash
   go run ./cmd/billingadmin flags set --flag billing.plans.visible --enabled true \
     --operator shashika --reason "launch plans"
   ```

   Live within 30 seconds; no release. The app shows Premium from its next
   app-config read (on open or resume).
5. Watch the next daily report's Credits and revenue sheet, and the log line
   `billing: verified purchase refused`.

To hide plans again, set the flag to false. Subscriptions already bought stay
active and keep their perks.

