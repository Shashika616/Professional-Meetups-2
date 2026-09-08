# Secrets (not committed)

`docker-compose.yml` mounts this folder read-only into both `gateway` and
`monolith`. None of the actual key files belong in git — `.gitignore` at the
repo root excludes `*.pem`/`*.key` under this folder; this README and
`.gitkeep` are the only tracked files here.

**Generate a fresh keypair/key for this project — don't copy the ones from
`../../Professional-Meetups/backend/secrets/`.** These are two independently
running systems; sharing a signing key between them means a token minted by
one would validate against the other, which is exactly the kind of coupling
this whole project exists to avoid.

## `jwt_private.pem` / `jwt_public.pem`

RSA keypair, RS256. Per ADR-001 §6, **both** live with the gateway now (the
monolith never holds the private key):

```bash
openssl genrsa -out jwt_private.pem 2048
openssl rsa -in jwt_private.pem -pubout -out jwt_public.pem
```

## `work_email_hmac.key`

Raw HMAC key bytes for the corporate-email verification hash (ADR-003 in the
sibling repo — ported here as auth-module business logic). Any sufficiently
random secret works:

```bash
openssl rand -out work_email_hmac.key 32
```

## Rotation procedures

Both of the secrets below can now be rotated with ordinary, independently
rollback-able deploys and **no coordinated restart and no window where valid
callers are rejected** (`docs/plans/03-hardening-pass.md` §A2/§A3). Before
this, rotating either one meant restarting both processes with the new value
at effectively the same instant.

### `INTERNAL_GRPC_SHARED_SECRET` (gateway → monolith)

The monolith accepts a **comma-separated list**; the gateway sends exactly
one value (`MONOLITH_SHARED_SECRET`). The overlap lives on the accepting
side, deliberately — a client holding two secrets would have to guess which
one a given server honours.

```bash
NEW=$(openssl rand -base64 32)
```

1. **Monolith accepts both.** Deploy with
   `INTERNAL_GRPC_SHARED_SECRET="<old>,<new>"`. The gateway is untouched and
   still sends `<old>`.
2. **Gateway switches.** Deploy with `MONOLITH_SHARED_SECRET="<new>"`. The
   monolith already accepts it.
3. **Monolith drops the old one.** Deploy with
   `INTERNAL_GRPC_SHARED_SECRET="<new>"`. `<old>` is now dead.

Wait for step *n* to be fully rolled out before starting step *n+1*. Each
step is safe to roll back on its own.

**Watch for**: a trailing comma (`"<old>,"`) is rejected at startup rather
than silently adding the empty string to the accepted set — an empty accepted
secret would authenticate every caller. So is a duplicate entry, which always
means the rotation didn't actually change anything.

### `jwt_private.pem` / `jwt_public.pem` (access-token signing)

Every access token carries a `kid` header derived from the signing key's own
bytes (`internal/platform/jwt/kid.go`), so the verifier can hold the previous
public key alongside the current one and route each token to the key that
actually signed it. Key ids are **derived, never configured** — there is no
name to keep in sync.

```bash
openssl genrsa -out jwt_private.new.pem 2048
openssl rsa -in jwt_private.new.pem -pubout -out jwt_public.new.pem
```

1. **Sign with the new key, still verify the old one.** Put the new pair in
   place as `JWT_PRIVATE_KEY_PATH`/`JWT_PUBLIC_KEY_PATH`, keep the old public
   key on disk, and set
   `JWT_PREVIOUS_PUBLIC_KEY_PATHS=/run/secrets/jwt_public.old.pem`. New
   tokens are signed with the new key; tokens already in users' hands still
   verify.
2. **Wait out `AccessTokenTTL` + margin** — 15 minutes, so ~30 to be safe.
   Every token signed by the old key has expired on its own by then.
3. **Retire the old key.** Deploy with `JWT_PREVIOUS_PUBLIC_KEY_PATHS`
   removed and delete the old public key file.

Only the **access token** is affected by any of this. Refresh tokens were
never JWTs (ADR-001's §6 correction) — they are opaque, DB-backed, and carry
no signature, so a signing-key rotation cannot invalidate a session as long
as step 2's wait is observed.

**Watch for**: pointing `JWT_PREVIOUS_PUBLIC_KEY_PATHS` at the *current*
public key. The gateway refuses to start rather than accept it, because a
"previous" key identical to the current one means the rotation never
happened while looking like it did.
