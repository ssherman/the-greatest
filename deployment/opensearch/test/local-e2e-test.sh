#!/usr/bin/env bash
# End-to-end test of the search server's security on this machine (spec §8.2): the real compose
# file, real generated certificates, the rendered security directory, securityadmin.sh, then the
# logins. No firewall here -- that is proven on the real server (verify-opensearch-lockdown.sh).
# Needs docker, curl, openssl, python3; port 19200 free. About 2 minutes (longer on first pull).
# Usage (from anywhere): deployment/opensearch/test/local-e2e-test.sh
set -uo pipefail
os="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
export COMPOSE_PROJECT_NAME=tg-opensearch-e2e OPENSEARCH_PORT=19200 OPENSEARCH_HEAP=1g OPENSEARCH_MEM_LIMIT=2g
export OPENSEARCH_CERTS_DIR="$work/certs" OPENSEARCH_SECURITY_DIR="$work/security"
compose=(docker compose -f "$os/compose.yml")
cleanup() { "${compose[@]}" down -v >/dev/null 2>&1; rm -rf "$work"; }
trap cleanup EXIT

failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1 -- $2"; failures=$((failures + 1)); }

admin_pw="$(openssl rand -hex 32)" app_pw="$(openssl rand -hex 32)" legacy_pw="$(openssl rand -hex 32)"
"$os/bin/generate-certs.sh" "$work/certs" >/dev/null
OPENSEARCH_ADMIN_PASSWORD="$admin_pw" OPENSEARCH_APP_PASSWORD="$app_pw" OPENSEARCH_LEGACY_PASSWORD="$legacy_pw" \
  "$os/bin/render-security.sh" "$work/security" || { echo "render-security failed (hash-password.sh?)"; exit 1; }
# The container runs as uid 1000; this throwaway copy just needs to be readable by it.
chmod -R a+rX "$work/certs" "$work/security"

"${compose[@]}" up -d >/dev/null 2>&1 || { echo "compose up failed"; "${compose[@]}" logs; exit 1; }
if "$os/bin/apply-security.sh" >"$work/securityadmin.log" 2>&1; then pass "securityadmin.sh applied the config"
else fail "securityadmin.sh applied the config" "$(tail -20 "$work/securityadmin.log")"; fi

base="https://localhost:19200"
req() {   # req USER PASSWORD METHOD PATH [BODY] -> prints the HTTP status
  local body=() cfg=''
  # The credentials go to curl on stdin (-K -), so they are never in a process listing. A
  # process substitution in an array does not work here: bash closes it before curl reads it.
  if [ -n "$1" ]; then cfg="$(printf 'user = "%s:%s"\n' "$1" "$2")"; fi
  if [ -n "${5:-}" ]; then body=(-H 'Content-Type: application/json' -d "$5"); fi
  printf '%s\n' "$cfg" | curl -sk -K - -o /dev/null -w '%{http_code}' --max-time 20 -X "$3" "${body[@]}" "$base$4"
}
expect() {   # expect NAME WANT USER PASSWORD METHOD PATH [BODY]
  local name="$1" want="$2" got
  shift 2
  got="$(req "$@")"
  if [ "$got" = "$want" ]; then pass "$name ($got)"; else fail "$name" "http $got, wanted $want"; fi
}
expect "no login is refused" 401 "" "" GET /
expect "admin works" 200 admin "$admin_pw" GET /_cluster/health
expect "app: cluster health" 200 the_greatest_app "$app_pw" GET /_cluster/health
expect "app: creates its own index" 200 the_greatest_app "$app_pw" PUT /books_books_production
expect "app: writes to it" 201 the_greatest_app "$app_pw" POST '/books_books_production/_doc?refresh=true' '{"title":"x"}'
expect "app: searches it" 200 the_greatest_app "$app_pw" GET /books_books_production/_search
expect "app: bulk to its own index" 200 the_greatest_app "$app_pw" POST /_bulk $'{"index":{"_index":"music_albums_production"}}\n{"t":1}\n'
expect "app: refused on the old site's index" 403 the_greatest_app "$app_pw" PUT /books
expect "app: refused on the security API" 403 the_greatest_app "$app_pw" GET /_plugins/_security/api/internalusers
expect "app: cannot change its own password" 403 the_greatest_app "$app_pw" PUT /_plugins/_security/api/account "{\"current_password\":\"$app_pw\",\"password\":\"$(openssl rand -hex 32)\"}"
expect "app: refused on cluster settings" 403 the_greatest_app "$app_pw" PUT /_cluster/settings '{"persistent":{"cluster.routing.allocation.enable":"all"}}'
expect "legacy: creates its own index" 200 tgb_legacy "$legacy_pw" PUT /books
expect "legacy: refused on the new app's index" 403 tgb_legacy "$legacy_pw" GET /books_books_production/_search
expect "legacy: refused on cluster settings" 403 tgb_legacy "$legacy_pw" PUT /_cluster/settings '{"persistent":{"cluster.routing.allocation.enable":"all"}}'
expect "wrong password is refused" 401 the_greatest_app "$legacy_pw" GET /_cluster/health

if [ "$failures" = 0 ]; then echo "all passed"; else echo "$failures failed"; exit 1; fi
