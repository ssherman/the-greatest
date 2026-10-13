#!/usr/bin/env bash
# Unit test for deployment/scripts/verify-opensearch-lockdown.sh; curl is stubbed.
# shellcheck disable=SC2016  # stub bodies and bcrypt strings are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
verify="$OS_DIR/../scripts/verify-opensearch-lockdown.sh"
export SEARCH_IPV4=203.0.113.50 SEARCH_IPV6=2001:db8::50

new_sandbox
stub curl 'printf 000; exit 28'
"$verify" --outside >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then pass "--outside: timeouts everywhere pass"; else fail "--outside: timeouts pass" "rc=$rc"; fi
if called '\[2001:db8::50\]:9200'; then pass "--outside probes IPv6"; else fail "--outside probes IPv6" "$(cat "$CALLS")"; fi

new_sandbox
stub curl 'printf 000; exit 28'
SEARCH_IPV6=2001:db8::50/128 "$verify" --outside >/dev/null 2>&1
if called '\[2001:db8::50\]:9200' && ! called '/128'; then pass "--outside strips a /128 suffix from SEARCH_IPV6"; else fail "--outside strips /128" "$(cat "$CALLS")"; fi

new_sandbox
stub curl 'printf 401; exit 0'
"$verify" --outside >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ]; then pass "--outside: an answer from the server fails"; else fail "--outside: an answer fails" "rc=$rc"; fi

new_sandbox
stub curl 'printf 000; exit 28'
SEARCH_IPV6="" "$verify" --outside >/dev/null 2>&1; rc=$?
if [ "$rc" != 0 ]; then pass "--outside without SEARCH_IPV6 is refused"; else fail "--outside without SEARCH_IPV6" "rc=0"; fi

new_sandbox
# Answers by path: the right code for each inside check.
stub curl 'for a in "$@"; do last="$a"; done
case "$last" in
  */_cluster/health) printf 200 ;;
  */books_books_production/_count) case "$*" in *legacy*) printf 403 ;; *) printf 404 ;; esac ;;
  */books/_count) case "$*" in *legacy*) printf 200 ;; *) printf 403 ;; esac ;;
  */_plugins/_security/api/internalusers) printf 403 ;;
  *) printf 401 ;;
esac'
OPENSEARCH_APP_PASSWORD=apppw OPENSEARCH_LEGACY_PASSWORD=legacypw "$verify" --inside >"$SANDBOX/log/out" 2>&1; rc=$?
if [ "$rc" = 0 ]; then pass "--inside: correct answers pass"; else fail "--inside: correct answers pass" "$(cat "$SANDBOX/log/out")"; fi
if ! called 'apppw|legacypw'; then pass "--inside keeps passwords off the curl command line"; else fail "passwords on the command line" "$(cat "$CALLS")"; fi

if ! "$verify" >/dev/null 2>&1; then pass "no mode is refused"; else fail "no mode is refused" "exit 0"; fi
finish
