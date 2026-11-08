#!/usr/bin/env bash
# Unit test for deployment/scripts/verify-opensearch-lockdown.sh; curl is stubbed.
# shellcheck disable=SC2016  # stub bodies and bcrypt strings are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
verify="$OS_DIR/../scripts/verify-opensearch-lockdown.sh"
export SEARCH_IPV4=203.0.113.50 SEARCH_IPV6=2001:db8::50

# One curl stub for --outside, answering by URL. Knobs (env): CTRL4/CTRL6 = time_connect the port 22
# control reports; P_RC/P_CODE/P_TC = exit code, http code and time_connect of every 9200/9300 probe.
OUTSIDE_STUB='last=""; for a in "$@"; do last="$a"; done
case "$last" in
  telnet://\[*) printf "%s" "$CTRL6"; exit 28 ;;
  telnet://*) printf "%s" "$CTRL4"; exit 28 ;;
  *) printf "%s %s" "$P_CODE" "$P_TC"; exit "$P_RC" ;;
esac'
export CTRL4=0.012 CTRL6=0.015 P_RC=28 P_CODE=000 P_TC=0.000000
outside() { new_sandbox; stub curl "$OUTSIDE_STUB"; "$verify" --outside >"$SANDBOX/log/out" 2>&1; rc=$?; }

outside
if [ "$rc" = 0 ]; then pass "--outside: controls connect, 9200/9300 dropped"; else fail "--outside: drops pass" "rc=$rc $(cat "$SANDBOX/log/out")"; fi
if called '\[2001:db8::50\]:9200'; then pass "--outside probes IPv6"; else fail "--outside probes IPv6" "$(cat "$CALLS")"; fi

CTRL6=0.000000 outside
if [ "$rc" = 1 ] && grep -q 'IPv6 control' "$SANDBOX/log/out" && ! grep -q 'PASS  IPv6 :9200' "$SANDBOX/log/out" \
  && ! called '\[2001:db8::50\]:9200'; then pass "--outside: unreachable control fails and skips that family's probes"; else fail "--outside: control unreachable" "rc=$rc $(cat "$SANDBOX/log/out")"; fi

P_RC=7 outside
if [ "$rc" = 1 ]; then pass "--outside: connection refused (exit 7) fails"; else fail "--outside: exit 7" "rc=$rc"; fi

P_TC=0.031 outside
if [ "$rc" = 1 ]; then pass "--outside: timeout after connecting fails"; else fail "--outside: slow after connect" "rc=$rc"; fi

P_RC=0 P_CODE=401 P_TC=0.020 outside
if [ "$rc" = 1 ]; then pass "--outside: an answer from the server fails"; else fail "--outside: an answer fails" "rc=$rc"; fi

new_sandbox
stub curl "$OUTSIDE_STUB"
SEARCH_IPV4=203.0.113.50/32 "$verify" --outside >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ] && [ ! -s "$CALLS" ]; then pass "--outside: SEARCH_IPV4 with a /32 is refused, curl never called"; else fail "--outside: /32" "rc=$rc $(cat "$CALLS")"; fi
SEARCH_IPV6=nope "$verify" --outside >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ] && [ ! -s "$CALLS" ]; then pass "--outside: a malformed SEARCH_IPV6 is refused"; else fail "--outside: SEARCH_IPV6=nope" "rc=$rc"; fi

SEARCH_IPV6=2001:db8::50/128 outside
if [ "$rc" = 0 ] && called '\[2001:db8::50\]:9200' && ! called '/128'; then pass "--outside strips a /128 suffix from SEARCH_IPV6"; else fail "--outside strips /128" "rc=$rc $(cat "$CALLS")"; fi

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
