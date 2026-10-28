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
# Outside, the server is expected to DROP 9200 and 9300 (DOCKER-USER, ufw), so a pass is curl exit 28
# with time_connect 0: no TCP connection was ever made. Exit 7 (refused), any HTTP answer, or a timeout
# after connecting all fail. A drop looks the same as an unreachable network, so each address first gets
# a positive control: a TCP connection to port 22 (ufw allows OpenSSH on IPv4 and IPv6). If the control
# cannot connect, the 9200/9300 probes for that address prove nothing and are skipped, with a FAIL.
# Passwords go to curl through a netrc file, never its command line.
set -uo pipefail
mode="${1:-}"
failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1 -- $2"; failures=$((failures + 1)); }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

bad_input() { echo "$1" >&2; echo "usage: verify-opensearch-lockdown.sh --outside|--inside (see the header)" >&2; exit 2; }
valid_ipv4() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
valid_ipv6() { [[ "$1" =~ ^[0-9A-Fa-f:]+$ && "$1" == *:* ]]; }
connected() { [[ "${1##* }" =~ [1-9] ]]; }   # a non-zero time_connect: a TCP connection was made

control() {   # control NAME HOST   (HOST: 1.2.3.4 or [v6]) -> 0 if port 22 accepts a connection
  local tc
  tc="$(curl -s -o /dev/null --connect-timeout 5 --max-time 3 -w '%{time_connect}' "telnet://$2:22")"
  if connected "$tc"; then return 0; fi
  fail "$1 control: port 22 unreachable" "cannot reach the server on $1 from this machine -- the 9200 probe would prove nothing; run --outside from a host that can reach it"
  return 1
}

no_connection() {   # no_connection NAME URL
  local out rc code tc
  out="$(curl -sk -o /dev/null -w '%{http_code} %{time_connect}' --connect-timeout 10 --max-time 15 "$2")"; rc=$?
  code="${out%% *}"; tc="${out##* }"
  if [ "$rc" = 28 ] && ! connected "$tc"; then pass "$1 (dropped: curl exit 28, no TCP connection)"
  elif [ "$rc" = 7 ]; then fail "$1" "curl exit 7 (refused) -- a correct firewall drops, it does not refuse"
  elif connected "$tc"; then fail "$1" "a TCP connection was made (curl exit $rc, http $code) -- the search server answered"
  else fail "$1" "curl exit $rc, http $code, expected a drop (exit 28)"; fi
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
    valid_ipv4 "$SEARCH_IPV4" || bad_input "SEARCH_IPV4 must be a bare IPv4 address, got: $SEARCH_IPV4"
    valid_ipv6 "$SEARCH_IPV6" || bad_input "SEARCH_IPV6 must be a bare IPv6 address, got: $SEARCH_IPV6"
    if control "IPv4" "$SEARCH_IPV4"; then
      no_connection "IPv4 :9200" "https://$SEARCH_IPV4:9200/"
      no_connection "IPv4 :9300 (transport, never published)" "https://$SEARCH_IPV4:9300/"
    fi
    if control "IPv6" "[$SEARCH_IPV6]"; then
      no_connection "IPv6 :9200" "https://[$SEARCH_IPV6]:9200/"
    fi
    ;;
  --inside)
    : "${SEARCH_IPV4:?}" "${OPENSEARCH_APP_PASSWORD:?}" "${OPENSEARCH_LEGACY_PASSWORD:?}"
    valid_ipv4 "$SEARCH_IPV4" || bad_input "SEARCH_IPV4 must be a bare IPv4 address, got: $SEARCH_IPV4"
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
