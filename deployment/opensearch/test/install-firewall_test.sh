#!/usr/bin/env bash
# Unit test for deployment/opensearch/bin/install-firewall.sh and the unit file it installs.
# shellcheck disable=SC2016  # stub bodies and bcrypt strings are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
stub systemctl ''
stub iptables-restore 'command -p cat >/dev/null'
stub ip6tables-restore 'command -p cat >/dev/null'
lib="$SANDBOX/root/usr/local/lib/opensearch-firewall"
unit="$SANDBOX/root/etc/systemd/system/opensearch-firewall.service"

ROOT="$SANDBOX/root" ALLOWLIST="$SANDBOX/missing" "$BIN/install-firewall.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then pass "install exits 0"; else fail "install exits 0" "rc=$rc"; fi
if [ -x "$lib/render-firewall.sh" ] && [ -x "$lib/apply-firewall.sh" ] && [ -f "$unit" ]; then
  pass "scripts and unit are installed outside the checkout"; else fail "scripts and unit installed" "$(ls -R "$SANDBOX/root")"; fi
if called '^systemctl daemon-reload$' && called '^systemctl enable opensearch-firewall.service$'; then
  pass "the unit is enabled for the next boot"; else fail "the unit is enabled" "$(cat "$CALLS")"; fi
# docker.service Requires= this unit, and restarting a required unit restarts Docker -- every
# deploy would bounce OpenSearch. Rules are re-applied by running the script directly instead.
if ! called '^systemctl (restart|stop|reload-or-restart|try-restart)'; then
  pass "install never restarts the unit (that would restart Docker)"; else fail "install restarted the unit" "$(cat "$CALLS")"; fi
if called '^iptables-restore --noflush$' && called '^ip6tables-restore --noflush$'; then
  pass "the rules are applied immediately"; else fail "the rules are applied immediately" "$(cat "$CALLS")"; fi

for line in 'Before=docker.service' 'RequiredBy=docker.service' 'Type=oneshot' 'RemainAfterExit=yes' \
  'ExecStart=/usr/local/lib/opensearch-firewall/apply-firewall.sh'; do
  if grep -qxF "$line" "$unit"; then pass "unit: $line"; else fail "unit: $line" "missing"; fi
done
if ! grep -q '^After=docker.service' "$unit"; then pass "unit: not ordered after Docker"; else fail "unit: ordered after Docker" "boot race"; fi
finish
