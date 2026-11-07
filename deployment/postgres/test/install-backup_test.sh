#!/usr/bin/env bash
# Unit test for deployment/postgres/bin/install-backup.sh and the units it installs.
# shellcheck disable=SC2016  # stub bodies are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
stub systemctl ''
lib="$SANDBOX/root/usr/local/lib/postgres-backup"
sysd="$SANDBOX/root/etc/systemd/system"
dest="$SANDBOX/etc/backup.env"
printf 'HC_PG_BACKUP=http://hc.test/one\nHC_PG_HEALTH=http://hc.test/two\nREPO_DIR=/opt/checkout/deployment/postgres\n' >"$SANDBOX/env.in"

ROOT="$SANDBOX/root" BACKUP_ENV_DEST="$dest" "$BIN/install-backup.sh" "$SANDBOX/env.in" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then pass "install exits 0"; else fail "install exits 0" "rc=$rc"; fi
if [ -x "$lib/backup.sh" ] && [ -x "$lib/check-backup-health.sh" ] && [ -f "$lib/backup-common.sh" ]; then
  pass "scripts are installed outside the checkout"; else fail "scripts installed" "$(ls -R "$SANDBOX/root" 2>&1)"; fi
for u in postgres-backup.service postgres-backup.timer postgres-backup-health.service postgres-backup-health.timer; do
  if [ -f "$sysd/$u" ]; then pass "unit installed: $u"; else fail "unit $u" "$(ls "$sysd" 2>&1)"; fi
done
if [ "$(stat -c '%a' "$dest")" = 600 ] && cmp -s "$dest" "$SANDBOX/env.in"; then
  pass "backup.env is 0600 and holds the URLs and the compose directory"; else fail "backup.env" "$(stat -c '%a' "$dest" 2>&1)"; fi
if called '^systemctl daemon-reload$' && called '^systemctl enable --now postgres-backup.timer postgres-backup-health.timer$'; then
  pass "both timers are enabled"; else fail "timers enabled" "$(cat "$CALLS")"; fi
if ! called 'systemctl (start|restart|try-restart|reload-or-restart|stop) .*\.service' && ! called 'systemctl (start|restart) postgres-backup'; then
  pass "t_install_starts_no_backup: no service is started or restarted"; else fail "install started something" "$(cat "$CALLS")"; fi
# A git pull must not change what runs: the units must name the installed copies, not the checkout.
if ! grep -hv '^#' "$sysd"/postgres-backup* | grep -q '/opt/checkout\|deployment/postgres'; then pass "units reference only installed paths"; else fail "unit paths" "$(grep -r 'deployment' "$sysd")"; fi
for f in postgres-backup.service postgres-backup-health.service; do
  if grep -qx 'EnvironmentFile=/etc/postgres-server/backup.env' "$sysd/$f" && grep -qx 'Type=oneshot' "$sysd/$f"; then
    pass "$f: oneshot, reads backup.env"; else fail "$f basics" "$(cat "$sysd/$f")"; fi
done
if grep -qx 'ExecStart=/usr/local/lib/postgres-backup/backup.sh' "$sysd/postgres-backup.service" \
   && grep -qx 'ExecStart=/usr/local/lib/postgres-backup/check-backup-health.sh' "$sysd/postgres-backup-health.service"; then
  pass "ExecStart points at the installed scripts"; else fail "ExecStart" "$(grep ExecStart "$sysd"/*)"; fi
timeout_line="$(grep '^TimeoutStartSec=' "$sysd/postgres-backup.service" | cut -d= -f2)"
if [ "$timeout_line" = 6h ]; then pass "the backup service has a long start timeout (6h)"; else fail "TimeoutStartSec" "'$timeout_line'"; fi
if grep -qxF 'OnCalendar=*-*-* 09:00:00 UTC' "$sysd/postgres-backup.timer" && grep -qx 'Persistent=false' "$sysd/postgres-backup.timer"; then
  pass "backup timer: 09:00 UTC, not persistent"; else fail "backup timer" "$(cat "$sysd/postgres-backup.timer")"; fi
ht="$sysd/postgres-backup-health.timer"
if grep -q '^OnBootSec=' "$ht" && grep -qx 'OnUnitActiveSec=15min' "$ht" && ! grep -q '^OnActiveSec=' "$ht"; then
  pass "health timer: OnBootSec and OnUnitActiveSec every 15 min, no redundant OnActiveSec"; else fail "health timer" "$(cat "$ht")"; fi
if ! grep -q '^Wants=' "$sysd/postgres-backup.service" "$sysd/postgres-backup-health.service" \
   && grep -qx 'After=docker.service' "$sysd/postgres-backup.service" && grep -qx 'After=docker.service' "$sysd/postgres-backup-health.service"; then
  pass "t_units_order_after_docker_without_pulling_it_in: After= only, no Wants="; else fail "docker ordering" "$(grep -E 'After|Wants' "$sysd"/*.service)"; fi
if ! grep -q '^Nice=' "$sysd/postgres-backup.service"; then pass "no Nice= on the backup service (it only reaches the compose client)"; else fail "Nice" "present"; fi
for t in postgres-backup.timer postgres-backup-health.timer; do
  if grep -qx 'WantedBy=timers.target' "$sysd/$t"; then pass "$t is wanted by timers.target"; else fail "$t install" "$(cat "$sysd/$t")"; fi
done

# --- a second run is harmless and refreshes the files ---------------------------------------------------------------------
printf 'HC_PG_BACKUP=http://hc.test/new\nHC_PG_HEALTH=http://hc.test/two\nREPO_DIR=/opt/checkout/deployment/postgres\n' >"$SANDBOX/env.in"
: >"$CALLS"
ROOT="$SANDBOX/root" BACKUP_ENV_DEST="$dest" "$BIN/install-backup.sh" "$SANDBOX/env.in" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -q '/new' "$dest" && ! called 'systemctl (start|restart)'; then pass "re-running replaces the env file and restarts nothing"; else fail "rerun" "rc=$rc $(cat "$CALLS")"; fi
if ! "$BIN/install-backup.sh" >/dev/null 2>&1; then pass "no env file argument is refused"; else fail "no argument" "exit 0"; fi
finish
