#!/usr/bin/env bash
# deployment/home-server/guest/install-units.sh
# Installs this role's systemd units from the repo and enables their timers.
# deploy.sh runs it on every deploy, so a merged unit change reaches the VM.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
load_env
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

units=(the-greatest-deploy the-greatest-heartbeat reboot-if-required)
case "$ROLE" in
  ol) units+=(ol-refresh recommender-train) ;;
  fetcher) ;;
  *) echo "install-units: unknown ROLE '$ROLE'" >&2; exit 1 ;;
esac

changed=0
for unit in "${units[@]}"; do
  for kind in service timer; do
    if ! cmp -s "$here/systemd/$unit.$kind" "$SYSTEMD_DIR/$unit.$kind"; then
      install -m 0644 "$here/systemd/$unit.$kind" "$SYSTEMD_DIR/$unit.$kind"
      changed=1
    fi
  done
done
if [ "$changed" = 1 ]; then systemctl daemon-reload; fi
for unit in "${units[@]}"; do systemctl enable --now "$unit.timer"; done
