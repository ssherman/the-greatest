#!/usr/bin/env bash
# deployment/postgres/bin/install-firewall.sh   (as root)
# Installs postgres-firewall.service and its scripts OUTSIDE the git checkout -- a `git pull`
# must not change what runs at boot until a deploy installs it -- enables the unit for the next
# boot, and applies the rules now. Cloud-init runs this before Docker is installed; deploy.sh runs
# it on every deploy. It never restarts the unit: docker.service Requires= it, and restarting a
# required unit restarts Docker, which would bounce Postgres on every deploy. ROOT prefixes
# every path (tests install into a sandbox).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ROOT="${ROOT:-}"
lib="$ROOT/usr/local/lib/postgres-firewall"

install -d "$lib" "$ROOT/etc/systemd/system"
install -m 0755 "$here/render-firewall.sh" "$here/apply-firewall.sh" "$lib/"
install -m 0644 "$here/../systemd/postgres-firewall.service" "$ROOT/etc/systemd/system/"
systemctl daemon-reload
systemctl enable postgres-firewall.service
"$lib/apply-firewall.sh"
