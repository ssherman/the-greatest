#!/usr/bin/env bash
# Unit test for deployment/opensearch/bin/apply-firewall.sh. iptables is stubbed.
# shellcheck disable=SC2016  # stub bodies and bcrypt strings are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
setup() {
  new_sandbox
  stub iptables-restore 'command -p cat >"$SANDBOX/log/v4.rules"'
  stub ip6tables-restore 'command -p cat >"$SANDBOX/log/v6.rules"'
}

setup
ALLOWLIST="$SANDBOX/missing" "$BIN/apply-firewall.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -q -- '-j DROP' "$SANDBOX/log/v4.rules" && grep -q -- '-j DROP' "$SANDBOX/log/v6.rules" \
  && ! grep -q -- ' -s ' "$SANDBOX/log/v4.rules" "$SANDBOX/log/v6.rules"; then
  pass "no allowlist file: both families drop everyone"; else fail "no allowlist file: both families drop everyone" "rc=$rc"; fi
if called '^iptables-restore --noflush$' && called '^ip6tables-restore --noflush$'; then
  pass "rules go in with --noflush, leaving Docker's chains alone"; else fail "rules go in with --noflush" "$(cat "$CALLS")"; fi

setup
: >"$SANDBOX/allowlist"
ALLOWLIST="$SANDBOX/allowlist" "$BIN/apply-firewall.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && ! grep -q -- ' -s ' "$SANDBOX/log/v4.rules"; then
  pass "an empty allowlist file drops everyone"; else fail "an empty allowlist file drops everyone" "rc=$rc"; fi

setup
printf '203.0.113.10\n' >"$SANDBOX/allowlist"
ALLOWLIST="$SANDBOX/allowlist" "$BIN/apply-firewall.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -q -- '-s 203.0.113.10/32 -j RETURN' "$SANDBOX/log/v4.rules"; then
  pass "an allowlist is applied"; else fail "an allowlist is applied" "rc=$rc"; fi

setup
printf 'nope\n' >"$SANDBOX/allowlist"
ALLOWLIST="$SANDBOX/allowlist" "$BIN/apply-firewall.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" != 0 ] && ! called 'restore'; then
  pass "an invalid allowlist applies nothing and fails"; else fail "an invalid allowlist applies nothing and fails" "rc=$rc $(cat "$CALLS")"; fi
finish
