#!/usr/bin/env bash
# deployment/home-server/guest/reboot-if-required.sh
# reboot-if-required.timer, 05:30: reboot for installed updates, unless a data
# build holds the lock. Then it waits for the next night.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
REBOOT_FLAG="${REBOOT_FLAG:-/run/reboot-required}"

[ -f "$REBOOT_FLAG" ] || exit 0
exec 9>"$BUILD_LOCK"
if ! flock -n 9; then log "reboot required, but a build is running; trying tomorrow"; exit 0; fi
log "rebooting for installed updates"
systemctl reboot
