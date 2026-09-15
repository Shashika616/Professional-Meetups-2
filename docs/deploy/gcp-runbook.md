# Google Cloud deployment record and redeploy runbook

> **Status 2026-09-15:** the database moved to Supabase and the Cloud SQL
> instance `meetups-db` was deleted (see §6). Cloud Run `meetups-backend`
> stays, serving revision `r28b` against Supabase (Mumbai). §1–§5 below describe the
> Cloud SQL era as it was, so it can be recreated if Supabase is ever left.

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
| Scaling | maxScale 8, containerConcurrency 80, timeout 300s, no minScale (scales to zero) |
| Service account | `740861671089-compute@developer.gserviceaccount.com` (needs Secret Manager accessor + Cloud SQL client) |
| Artifact Registry | `asia-south1-docker.pkg.dev/project-285b9289-549d-4fef-92c/meetups-repo` (Docker), images `gateway:rNN`, `monolith:rNN` |
| Cloud SQL instance | `meetups-db`, PostgreSQL 18, tier `db-g1-small`, zonal, 10 GB PD_SSD, public IPv4 with NO authorized networks (access only via the Cloud SQL connector/proxy), IAM auth flag on, automated backups + PITR (7-day log retention), deletion protection ON |
| Cloud SQL connection name | `project-285b9289-549d-4fef-92c:asia-south1:meetups-db` |
| Databases / users | database `monolith_db`; users `app` (application), `postgres` (admin) |
| Postgres extensions | `pgcrypto`, `postgis` (created by migrations 0001/0002) |
| Schema | golang-migrate, `backend/migrations/`, 24 files = versions 0001–0012, current version **12** |
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
| Admin / migrations | direct connection (IPv6 only on the free tier; works from a Mac on IPv6): `postgresql://postgres:<pw>@db.<ref>.supabase.co:5432/monolith_db`. `migrate -path migrations -database '<direct url>' up`. Schema version 12. |
| Data | full copy of Cloud SQL taken 2026-09-15 (all 20 tables, row counts verified equal). Final Cloud SQL backups kept at `~/Documents/Professional Meetups/backups/` (custom-format `.dump` + plain data `.sql`), outside git. |
| Cloud Run change | `run.googleapis.com/cloudsql-instances` annotation removed from `service.yaml`; `r23`/`r24` reused the `r22` images; `r25` (2026-09-15) adds email-address validation on the unauthenticated start endpoints; `r28`/`r28b` (2026-09-16) carry ADR-005 (one meetup at a time, logout with `fcm_token`) and the Android notification icon/colour on every push. |
| Free-tier caveats | project pauses after 7 idle days (unpause in the dashboard); no PITR/backups on free (take `pg_dump` via the direct URL periodically); pooler ~15 server connections shared, 200 client connections. |
| Latency note | Cloud Run and Supabase are both in Mumbai now; the earlier Tokyo project cost ~70 ms per DB round trip. |

Restore-from-dump into a fresh database: strip pg_dump's
`set_config('search_path', '', false)` line (the PostGIS trigger resolves
`geography` through the search path) and clear the migration-seeded
`auth.known_companies` before loading data, as was done here.
