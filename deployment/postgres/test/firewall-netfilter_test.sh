#!/usr/bin/env bash
# Real netfilter test of deployment/postgres/bin/render-firewall.sh's rules: they are loaded with iptables-restore
# in a throwaway privileged container, shaped like Docker's published port. It exists because a guard on the
# original destination port alone also dropped the Postgres container's own outbound connection to a remote port
# 6543 (CREATE SUBSCRIPTION to the old server), which comparing the rules as text cannot see.
# Needs Docker. Touches only its own network namespaces. This proves netfilter's behaviour, not the Docker daemon's:
# the runbook's checks on the real server prove that.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=docker-helpers.sh
. "$OS_DIR/test/docker-helpers.sh"
# Pinned by digest, as in docker-helpers.sh. The packages it installs come from this release's apk index.
ALPINE_IMAGE="${ALPINE_IMAGE:-alpine:3@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6}"

if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then
  echo "firewall-netfilter_test: Docker is required and is not available" >&2
  exit 1
fi
dk_init
rules="$TMP/rules"
mkdir -p "$rules"
cp "$OS_DIR/test/firewall-netfilter-harness.sh" "$rules/harness.sh"
printf '203.0.113.50\n2001:db8:1::50\n' >"$TMP/allowlist"
for family in v4 v6; do
  "$BIN/render-firewall.sh" --family "$family" --allowlist "$TMP/allowlist" >"$rules/$family.allow" || { echo "render failed" >&2; exit 1; }
  "$BIN/render-firewall.sh" --family "$family" --deny-all >"$rules/$family.deny" || { echo "render failed" >&2; exit 1; }
done
chmod -R a+rX "$rules"

out="$(timeout 240 docker run --rm --privileged --label "pgmig=$PROJ" -v "$rules:/rules:ro" "$ALPINE_IMAGE" sh /rules/harness.sh /rules 2>&1)"
rc=$?
if [ "$rc" != 0 ]; then echo "$out" >&2; fail "the harness ran" "exit $rc"; finish; fi

expect() {   # expect FAMILY SCENARIO PROBE RESULT
  if grep -qxF "$1 $2 $3 $4" <<<"$out"; then pass "$1 $2: $3 is $4"
  else fail "$1 $2: $3 should be $4" "$(grep -F "$1 $2 $3" <<<"$out" || echo 'no such line')"; fi
}
families=(v4 v6)
if grep -q '^v6 SKIP' <<<"$out"; then echo "SKIP  $(grep '^v6 SKIP' <<<"$out")"; families=(v4); fi
for f in "${families[@]}"; do
  # Control: with an empty chain everything connects, so a BLOCKED below is the rules and not the test's network.
  expect "$f" no-rules container-outbound-to-remote-6543 CONNECTED
  expect "$f" no-rules allowlisted-client-to-published-6543 CONNECTED
  expect "$f" no-rules other-client-to-published-6543 CONNECTED
  expect "$f" allowlist container-outbound-to-remote-6543 CONNECTED
  expect "$f" allowlist allowlisted-client-to-published-6543 CONNECTED
  expect "$f" allowlist other-client-to-published-6543 BLOCKED
  # What the first boot renders, before any deploy wrote an allowlist (apply-firewall.sh).
  expect "$f" deny-all container-outbound-to-remote-6543 CONNECTED
  expect "$f" deny-all allowlisted-client-to-published-6543 BLOCKED
  expect "$f" deny-all other-client-to-published-6543 BLOCKED
done
finish
