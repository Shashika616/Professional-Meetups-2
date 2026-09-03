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
