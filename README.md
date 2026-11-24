# Hadal

Full-stack web app: **Rust (actix-web) + SolidJS + PostgreSQL**, served by **nginx**, run with **Docker Compose**.

```
browser ──► nginx :8000 ─┬─ /        → SolidJS static build (SPA fallback)
                         └─ /api/*   → backend:8080 (actix-web) ──► db:5432 (Postgres)
```

## Layout

| Path | What |
|------|------|
| `backend/` | actix-web API. sqlx (Postgres), migrations in `backend/migrations/` run automatically on startup |
| `frontend/` | SolidJS + Vite + TypeScript |
| `nginx/` | nginx config + Dockerfile that builds the frontend and serves it |
| `docker-compose.yml` | `db`, `backend`, `nginx` services |

## Run everything with Docker

```sh
cp .env.example .env      # then set POSTGRES_PASSWORD (openssl rand -hex 24)
                          # and the Google OAuth client (below)
scripts/dev-certs.sh      # TLS certificates for nginx and Postgres (certs/, git-ignored)
docker compose up -d --build
open https://localhost:8000
```

HTTPS only, on port 8000: `http://localhost:8000` just redirects to `https://localhost:8000`,
and Postgres refuses connections without TLS. `scripts/dev-certs.sh` uses
[mkcert](https://github.com/FiloSottile/mkcert) when it is installed (run
`mkcert -install` once so the browser trusts it); otherwise the certificate is
self-signed and the browser warns. `scripts/check-tls.sh` checks the running
stack: TLS versions and suites, the redirect, HSTS, and TLS to Postgres.

### Google sign-in setup

1. In Google Cloud Console → APIs & Services → Credentials, create an
   **OAuth client ID** of type **Web application**.
2. Add the authorized redirect URI `https://localhost:8000/api/auth/callback`
   (for Vite dev on :5173, also add `http://localhost:5173/api/auth/callback` and set
   `OAUTH_REDIRECT_URI` to it). Outside localhost it must be `https://`.
3. Put the client ID and secret in `.env` as `GOOGLE_CLIENT_ID` and
   `GOOGLE_CLIENT_SECRET`. The backend refuses to start without them.

Session cookies are `Secure` and `__Host-` prefixed. For Vite dev on
`http://localhost:5173` browsers still accept them, because localhost counts
as a secure context. Everywhere else you need HTTPS.

## Production (hadalspace.com, Let's Encrypt)

`docker-compose.prod.yml` serves `https://hadalspace.com` (and `www.`) on ports
80/443 with a Let's Encrypt certificate, renewed by a `certbot` service; nginx
reloads every 6 hours to pick renewals up. Postgres isn't published.

```sh
# On the server, with DNS for hadalspace.com and www.hadalspace.com pointing at it
cp production.env.example .env     # fill in; production secrets come from a secrets manager
scripts/dev-certs.sh                # Postgres TLS (private CA for backend -> db)
scripts/letsencrypt-init.sh you@example.com --staging   # dry run against LE staging
scripts/letsencrypt-init.sh you@example.com             # real certificate, starts the stack
scripts/check-tls.sh hadalspace.com 443 80
```

Register `https://hadalspace.com/api/auth/callback` as a redirect URI on the
Google OAuth client. Then run an [SSL Labs](https://www.ssllabs.com/ssltest/)
test for the CASA 4.1.1 evidence.

## Local development (hot reload)

```sh
docker compose up -d db                 # Postgres only, on 127.0.0.1:5432
cd backend && cargo run                 # API on :8080 (reads ../.env via DATABASE_URL)
cd frontend && npm install && npm run dev   # Vite on :5173, proxies /api → :8080
```

`cargo run` loads a `.env` from the current directory, so either `cp ../.env .env` inside `backend/` or export `DATABASE_URL`.

## API

| Method | Path | |
|--------|------|-|
| GET | `/api/health` | liveness + DB check (public) |
| GET | `/api/auth/login` | start Google sign-in (public, redirects) |
| GET | `/api/auth/callback` | Google redirect target (public) |
| POST | `/api/auth/register` | `{first_name, last_name, email, password}`; creates an email account and signs in (public) |
| POST | `/api/auth/password` | signed in: `{current_password, new_password}`; signs out every other session |
| POST | `/api/auth/password-login` | `{email, password}`; signs in (public) |
| GET | `/api/auth/me` | `{ "email": "..." }` of the signed-in user |
| POST | `/api/auth/logout` | body `{}`; ends the session |
| GET | `/api/notes` | your notes (latest 100) |
| POST | `/api/notes` | `{ "title": "...", "body": "..." }` |
| GET | `/api/notes/{id}` | fetch one |
| DELETE | `/api/notes/{id}` | delete |

Everything except health and sign-in needs a session, and notes are visible only to their owner.

## Adding a migration

Add `backend/migrations/<timestamp>_<name>.sql`. It is embedded at compile time and applied on the next backend start.

## Tests

```sh
eval "$(scripts/test-db.sh start)"   # throwaway Postgres for auth/IDOR tests
cd backend && cargo test
cd frontend && npm run build   # type-check + build
```

`scripts/verify.sh` starts the test database by itself.

## CASA verification

Hadal must pass the App Defense Alliance CASA v2.1.1 assessment, and every change is checked against it.

```sh
scripts/install-hooks.sh        # once per clone
scripts/verify.sh quick         # CASA rules + register, fmt, clippy, tests, typecheck, secrets
scripts/verify.sh full          # + cargo-deny, cargo-audit, npm audit, build, semgrep, git-history secrets
python3 scripts/casa_check.py list-rules
```

- Requirement status for all 55 CASA items: [docs/casa/controls.md](docs/casa/controls.md), generated from [docs/casa/requirements.json](docs/casa/requirements.json).
- **pre-commit** runs the quick gate, then a Claude review of the staged diff. **pre-push** runs the full gate. **CI** runs the full gate plus an OWASP ZAP baseline. Release tags fail while any requirement is still `pending`.
- Exceptions and accepted risks: [docs/casa/exceptions.md](docs/casa/exceptions.md).
