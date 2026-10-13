#!/usr/bin/env bash
# Checks that the search server is locked down (spec §8.3). Run both modes after every build or rebuild.
#
#   --outside   from a machine that is NOT an app server (a laptop): nothing may even connect.
#                 SEARCH_IPV4=... SEARCH_IPV6=... deployment/scripts/verify-opensearch-lockdown.sh --outside
#   --inside    from the new app server: both logins work over HTTPS, each is refused on the other
#               site's indexes and on the security API, and a request without a login is refused.
#                 SEARCH_IPV4=... OPENSEARCH_APP_PASSWORD=... OPENSEARCH_LEGACY_PASSWORD=... \
#                   deployment/scripts/verify-opensearch-lockdown.sh --inside
#
# Outside, a pass is curl exit 7 (refused) or 28 (timed out: the DOCKER-USER drop). Any HTTP answer
# at all, even 401, is a failure: it means the firewall let the connection through. Passwords go to
# curl through a netrc file, never its command line.
set -uo pipefail
mode="${1:-}"
failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1 -- $2"; failures=$((failures + 1)); }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

no_connection() {   # no_connection NAME URL
  local code rc
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$2")"; rc=$?
  case "$rc" in
    7|28) pass "$1 (curl exit $rc: no connection)" ;;
    *) fail "$1" "curl exit $rc, http $code -- the search server answered" ;;
  esac
}

status() {   # status NAME WANT_REGEX LOGIN(app|legacy|none) PATH
  local name="$1" want="$2" login="$3" path="$4" auth=() code
  case "$login" in
    app) auth=(--netrc-file "$work/netrc-app") ;;
    legacy) auth=(--netrc-file "$work/netrc-legacy") ;;
  esac
  # shellcheck disable=SC2153  # SEARCH_IPV4 is the env var, checked in --inside before status runs
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "${auth[@]}" "https://$SEARCH_IPV4:9200$path")"
  if [[ "$code" =~ ^($want)$ ]]; then pass "$name (http $code)"; else fail "$name" "http $code, wanted $want"; fi
}

case "$mode" in
  --outside)
    : "${SEARCH_IPV4:?set SEARCH_IPV4}" "${SEARCH_IPV6:?set SEARCH_IPV6 -- the server has one, and it must be probed}"
    SEARCH_IPV6="${SEARCH_IPV6%%/*}"   # Terraform reports it with a /128 suffix
    no_connection "IPv4 :9200" "https://$SEARCH_IPV4:9200/"
    no_connection "IPv6 :9200" "https://[$SEARCH_IPV6]:9200/"
    no_connection "IPv4 :9300 (transport, never published)" "https://$SEARCH_IPV4:9300/"
    ;;
  --inside)
    : "${SEARCH_IPV4:?}" "${OPENSEARCH_APP_PASSWORD:?}" "${OPENSEARCH_LEGACY_PASSWORD:?}"
    (umask 077
      printf 'machine %s login the_greatest_app password %s\n' "$SEARCH_IPV4" "$OPENSEARCH_APP_PASSWORD" >"$work/netrc-app"
      printf 'machine %s login tgb_legacy password %s\n' "$SEARCH_IPV4" "$OPENSEARCH_LEGACY_PASSWORD" >"$work/netrc-legacy")
    status "no login is refused" 401 none /
    status "app: cluster health" 200 app /_cluster/health
    status "app: its own index (404 until the first reindex)" '200|404' app /books_books_production/_count
    status "app: refused on the old site's index" 403 app /books/_count
    status "app: refused on the security API" 403 app /_plugins/_security/api/internalusers
    status "legacy: its own index (404 until the first reindex)" '200|404' legacy /books/_count
    status "legacy: refused on the new app's index" 403 legacy /books_books_production/_count
    ;;
  *) echo "usage: verify-opensearch-lockdown.sh --outside|--inside (see the header)" >&2; exit 2 ;;
esac
if [ "$failures" = 0 ]; then echo "all passed"; else echo "$failures failed"; exit 1; fi
