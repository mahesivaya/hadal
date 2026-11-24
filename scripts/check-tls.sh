#!/usr/bin/env bash
# Checks transport security of a running stack (CASA 4.1.1, 4.1.2).
# CI runs it against the compose stack. Before an assessment, run it against
# the production host too, and attach an SSL Labs report.
#
#   scripts/check-tls.sh [host] [https_port] [http_port]   (default localhost 8000 8000)
#   scripts/check-tls.sh hadalspace.com 443 80              (production, on the server)
#
# Env: CHECK_DB=0 skips the Postgres checks (when the DB isn't in compose).
set -uo pipefail

HOST="${1:-localhost}"
HTTPS_PORT="${2:-8000}"
HTTP_PORT="${3:-$HTTPS_PORT}"   # locally the same port: nginx redirects plain HTTP sent to it
cd "$(dirname "$0")/.."

fails=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

handshake() { # handshake <openssl s_client args...>: 0 if a session was set up
  openssl s_client -connect "$HOST:$HTTPS_PORT" -servername "$HOST" "$@" </dev/null 2>/dev/null \
    | grep -q 'Cipher is [A-Z0-9]'   # a failed handshake prints "Cipher is (NONE)"
}

echo "TLS on https://$HOST:$HTTPS_PORT"
handshake -tls1_3 && pass "TLS 1.3 accepted" || fail "TLS 1.3 not accepted"
handshake -tls1_2 && pass "TLS 1.2 accepted" || fail "TLS 1.2 not accepted"
for v in tls1_1 tls1; do
  if handshake "-$v" -cipher 'DEFAULT:@SECLEVEL=0'; then fail "$v accepted"; else pass "$v refused"; fi
done
# Non-forward-secret and CBC suites must be refused on TLS 1.2.
for c in AES128-SHA AES256-GCM-SHA384 ECDHE-RSA-AES128-SHA ECDHE-ECDSA-AES128-SHA DES-CBC3-SHA; do
  if handshake -tls1_2 -cipher "$c:@SECLEVEL=0"; then fail "weak suite $c accepted"; else pass "weak suite $c refused"; fi
done

echo "HTTP -> HTTPS"
out="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "http://$HOST:$HTTP_PORT/some/path?q=1")"
authority="$HOST"; [[ "$HTTPS_PORT" == 443 ]] || authority="$HOST:$HTTPS_PORT"
if [[ "$out" == "301 https://$authority/some/path?q=1" ]]; then
  pass "plain HTTP redirects to HTTPS"
else
  fail "plain HTTP answered '$out'"
fi
body="$(curl -s "http://$HOST:$HTTP_PORT/api/health")"
[[ "$body" != *'"status"'* ]] && pass "API not served over plain HTTP" || fail "API served over plain HTTP"

echo "HSTS"
for path in / /api/health /assets/missing.js; do
  n="$(curl -sk -D - -o /dev/null "https://$HOST:$HTTPS_PORT$path" | grep -ci '^strict-transport-security: max-age=[1-9]')"
  [[ "$n" == 1 ]] && pass "HSTS once on $path" || fail "HSTS header count $n on $path"
done

if [[ "${CHECK_DB:-1}" == 1 ]]; then
  echo "Postgres"
  db="$(docker compose ps -q db 2>/dev/null)"
  if [[ -z "$db" ]]; then
    fail "db container not running (CHECK_DB=0 to skip)"
  else
    # Every network client (the backend) must be on TLS.
    counts="$(docker exec "$db" sh -c 'psql -tAq -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
      "SELECT count(*) FILTER (WHERE NOT s.ssl), count(*) FROM pg_stat_ssl s
       JOIN pg_stat_activity a USING (pid) WHERE a.client_addr IS NOT NULL"')"
    plain="${counts%%|*}"; total="${counts##*|}"
    if [[ "$plain" == 0 && "${total:-0}" -gt 0 ]]; then
      pass "all $total network connections use TLS"
    else
      fail "network connections without TLS: '${counts}'"
    fi
    # A plaintext connection must be refused before authentication.
    err="$(docker exec "$db" sh -c 'psql "host=127.0.0.1 sslmode=disable user=$POSTGRES_USER dbname=$POSTGRES_DB" -c "SELECT 1" 2>&1')"
    [[ "$err" == *"no encryption"* || "$err" == *"rejects"* ]] \
      && pass "plaintext connection refused" || fail "plaintext connection not refused: $err"
    v="$(docker exec "$db" sh -c 'psql -tAq -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SHOW ssl_min_protocol_version"')"
    [[ "$v" == TLSv1.2 || "$v" == TLSv1.3 ]] && pass "Postgres minimum protocol $v" || fail "Postgres minimum protocol '$v'"
  fi
fi

echo
if ((fails)); then echo "check-tls: $fails failure(s)"; exit 1; fi
echo "check-tls: all checks passed"
