#!/usr/bin/env bash
# Creates the TLS certificates the docker stack needs (CASA 4.1.1, 4.1.2).
# Output goes to certs/ (git-ignored). Safe to re-run: existing files are kept
# unless they expire within 30 days, or --force is given.
#
#   certs/nginx/{cert,key}.pem          HTTPS for https://localhost:8000
#       mkcert is used when installed, so browsers trust it (run
#       `mkcert -install` once); otherwise a self-signed certificate.
#   certs/db/{ca.crt,server.crt,server.key}
#       A private CA just for Postgres. The backend checks the server
#       certificate against ca.crt and the host name `db` (sslmode=verify-full).
#
# Production: use certificates from your CA / load balancer instead, and keep
# private keys in the secrets manager (CASA 6.7.1).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/certs"
FORCE="${1:-}"
DAYS=825

fresh() { # true if every file exists and is valid for 30 more days
  for f in "$@"; do [[ -s "$f" ]] || return 1; done
  [[ "$FORCE" == "--force" ]] && return 1
  openssl x509 -checkend $((30 * 86400)) -noout -in "$1" >/dev/null 2>&1
}

umask 077
mkdir -p "$OUT/nginx" "$OUT/db"

# ---- nginx (browser-facing) ----------------------------------------------
if fresh "$OUT/nginx/cert.pem" "$OUT/nginx/key.pem"; then
  echo "certs/nginx: up to date"
elif command -v mkcert >/dev/null 2>&1; then
  mkcert -cert-file "$OUT/nginx/cert.pem" -key-file "$OUT/nginx/key.pem" \
    localhost 127.0.0.1 ::1 >/dev/null 2>&1
  echo "certs/nginx: issued by mkcert (trusted after 'mkcert -install')"
else
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days "$DAYS" \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=serverAuth" \
    -keyout "$OUT/nginx/key.pem" -out "$OUT/nginx/cert.pem" 2>/dev/null
  echo "certs/nginx: self-signed (install mkcert for a browser-trusted one)"
fi

# ---- Postgres (backend -> db) ----------------------------------------------
if fresh "$OUT/db/server.crt" "$OUT/db/server.key" "$OUT/db/ca.crt"; then
  echo "certs/db: up to date"
else
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days "$DAYS" \
    -subj "/CN=Hadal dev database CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$tmp/ca.key" -out "$OUT/db/ca.crt" 2>/dev/null
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj "/CN=db" -keyout "$OUT/db/server.key" -out "$tmp/server.csr" 2>/dev/null
  printf '%s\n' \
    "basicConstraints=critical,CA:FALSE" \
    "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=serverAuth" \
    "subjectAltName=DNS:db,DNS:localhost,IP:127.0.0.1" > "$tmp/ext.cnf"
  openssl x509 -req -in "$tmp/server.csr" -CA "$OUT/db/ca.crt" -CAkey "$tmp/ca.key" \
    -set_serial "0x$(openssl rand -hex 16)" -days "$DAYS" -extfile "$tmp/ext.cnf" -out "$OUT/db/server.crt" 2>/dev/null
  # The CA key is thrown away: nothing else can ever be signed by this CA.
  echo "certs/db: new private CA and server certificate for host 'db'"
fi

# Certificates are public; containers running as non-root must read them.
# Private keys stay owner-only (containers copy them in as root).
chmod 0755 "$OUT" "$OUT/nginx" "$OUT/db"
chmod 0644 "$OUT/nginx/cert.pem" "$OUT/db/ca.crt" "$OUT/db/server.crt"
chmod 0600 "$OUT/nginx/key.pem" "$OUT/db/server.key"
