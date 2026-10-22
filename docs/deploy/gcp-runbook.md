# Google Cloud deployment record and redeploy runbook

> **Status 2026-09-25:** Cloud Run `meetups-backend` serves revision
> `r32b` against Supabase (Mumbai). The database moved to Supabase on
> 2026-09-15 and the Cloud SQL instance `meetups-db` was deleted (see §6);
> §1–§5 below describe the Cloud SQL era as it was, so it can be recreated
> if Supabase is ever left. See §7 for the 2026-09-25 outage and what it
> changed about scaling.

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
| Last serving revision | `meetups-backend-r22`, images tagged `r22` |
| Containers (sidecars, one Cloud Run service) | `gateway` (HTTP :8080, 1 CPU / 512Mi) and `monolith` (gRPC :9090 on localhost, 1 CPU / 1Gi); `container-dependencies: gateway → monolith` |
| Scaling | maxScale 8, containerConcurrency 80, timeout 300s, minScale **1** with `cpu-throttling: "false"` (2026-10-21, #77 — the background pollers need CPU Cloud Run does not give an idle instance; §7) |
| Service account | `740861671089-compute@developer.gserviceaccount.com` (needs Secret Manager accessor + Cloud SQL client) |
| Artifact Registry | `asia-south1-docker.pkg.dev/project-285b9289-549d-4fef-92c/meetups-repo` (Docker), images `gateway:rNN`, `monolith:rNN` |
| Cloud SQL instance | `meetups-db`, PostgreSQL 18, tier `db-g1-small`, zonal, 10 GB PD_SSD, public IPv4 with NO authorized networks (access only via the Cloud SQL connector/proxy), IAM auth flag on, automated backups + PITR (7-day log retention), deletion protection ON |
| Cloud SQL connection name | `project-285b9289-549d-4fef-92c:asia-south1:meetups-db` |
| Databases / users | database `monolith_db`; users `app` (application), `postgres` (admin) |
| Postgres extensions | `pgcrypto`, `postgis` (created by migrations 0001/0002) |
| Schema | golang-migrate, `backend/migrations/`, 32 files = versions 0001-0016, current version **16** (`0014_account_deletion_indexes`, `0015_user_deleted_outbox` and `0016_safety_holds` applied 2026-10-01 over the SESSION connection, not the transaction pooler the app uses: port 6543 is transaction-pooled and breaks the advisory lock golang-migrate takes, so migrations go to port 5432. All three are additive, so they were applied while r33 was still serving. 0014 adds the six user-id indexes the account purge needs, including `meetup.idx_meetup_user_ratings_rater` — `rater_user_id` previously existed only as the second column of a composite unique and could not be seeked on, measured at cost 4773 (seq scan) versus 8.44 (index scan) over 200k rows.) |
| Auth bridge page | LinkedIn redirect `https://professional-meetups-976d2.web.app` (Firebase Hosting, project `professional-meetups-976d2`) — separate from this GCP project |

### Secret Manager secrets (names; values live only in Secret Manager and the owner's password manager)

| Secret | Used as |
|---|---|
| `database-url` | `DATABASE_URL` env (monolith). Shape: `postgres://app:<password>@/monolith_db?host=/cloudsql/<connection name>` |
| `internal-grpc-secret` | `MONOLITH_SHARED_SECRET` (gateway) and `INTERNAL_GRPC_SHARED_SECRET` (monolith) |
| `jwt-private-key` / `jwt-public-key` | mounted as files at `/secrets-priv/jwt_private.pem`, `/secrets-pub/jwt_public.pem` (RS256, 15-min access tokens) |
| `work-email-hmac` | mounted at `/secrets-hmac/work_email_hmac.key` |
| `linkedin-client-secret` | `LINKEDIN_CLIENT_SECRET` |
| `firebase-sa` | `FIREBASE_SERVICE_ACCOUNT_JSON` (push notifications) |
| `twilio-auth-token` | `TWILIO_AUTH_TOKEN` (SMS OTP) |
| `gmail-app-password` | `GMAIL_APP_PASSWORD` (email OTP) |

Plain env values (not secrets, but environment-specific; see the template):
`LINKEDIN_CLIENT_ID`, `LINKEDIN_REDIRECT_URI`, `TWILIO_ACCOUNT_SID`,
`TWILIO_PHONE_NUMBER`, `GMAIL_ADDRESS`, `ALLOW_TEST_OTP_BYPASS=false`,
`TEST_OTP_BYPASS_PHONES`, `TEST_OTP_BYPASS_EMAILS`.

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

Schema (from `backend/`, with the proxy on a local port):

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
# Copy docs/deploy/service.yaml.template to backend/service.yaml, fill the
# <PLACEHOLDERS>, set the revision name and both image tags to rNN, then:
gcloud run services replace service.yaml --region asia-south1
gcloud run services describe meetups-backend --region asia-south1 \
  --format='value(status.traffic[0].revisionName,status.traffic[0].percent)'
```

Client: the mobile app's production gateway URL is set at build time in
`frontend/build.sh` (`PROD_URL`); update it if the service URL changes.

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
| Admin / migrations | direct connection (IPv6 only on the free tier; works from a Mac on IPv6): `postgresql://postgres:<pw>@db.<ref>.supabase.co:5432/monolith_db`. `migrate -path migrations -database '<direct url>' up`. Applied schema version is 16 (as of r34, 2026-10-01). Migrations `0017_email_is_the_identity_anchor` and `0018_account_claim_verification_purpose` are pending (ADR-009): apply both over this session connection (port 5432) BEFORE deploying code that uses them; 0017 can fail if existing rows differ only by email case, so check for duplicates first. The direct host is IPv6-only on the free tier and resolves to `db.wvsrtbactwawxhcyokep.supabase.co`; `migrate` over the POOLER does not work, since golang-migrate holds a session-scoped advisory lock and the pooler hands each transaction a different server connection. The `postgres` password is the same one embedded in the `database-url` secret's pooler URL. |
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

Cloud Scheduler (3 jobs always free) calls `POST /internal/cron/tick` every
15 minutes. The gateway forwards it to the monolith's `OpsService`, which
runs all eleven sweeps once and reports each one's row count.

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

### State as of 2026-10-22

The job was created and then **PAUSED**, because `/internal/cron/tick` does
not exist on the deployed revision (r34) — only on r35 and later. Leaving it
running would have been 96 false failures a day.

Resume it in the same step that deploys r35:

```sh
gcloud scheduler jobs resume monolith-cron-tick --location=asia-south1
gcloud scheduler jobs run    monolith-cron-tick --location=asia-south1   # verify once by hand
```

If it is still paused, no periodic work is running at all. `gcloud scheduler
jobs describe monolith-cron-tick --location=asia-south1` reports the state.

---

## 11. The Deploy workflow (manual, Workload Identity)

`.github/workflows/deploy.yml` does what §3 does by hand — build and push
both images, apply migrations, deploy the revision, confirm `/readyz` — from
a clean checkout. It runs only when someone presses **Run workflow** and
types a new revision name such as `r38`. Nothing deploys on push.

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
