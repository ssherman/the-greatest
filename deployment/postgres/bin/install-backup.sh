#!/usr/bin/env bash
# deployment/postgres/bin/install-backup.sh ENV_SRC   (as root; deploy.sh runs it on every deploy)
# Installs the backup and health-check scripts OUTSIDE the git checkout -- a `git pull` must not
# change what runs until a deploy installs it -- plus their systemd units, and enables the two
# timers. ENV_SRC holds HC_PG_BACKUP, HC_PG_HEALTH and REPO_DIR (the directory with compose.yml);
# it is installed root-only (0600), because a ping URL is a credential.
#
# It never starts a backup and never restarts anything: `enable --now` on the timers starts only
# the timers, and Persistent=false keeps a late boot from firing one. `daemon-reload` alone moves an
# active timer's next elapse to a changed OnCalendar (tested on real systemd), so no restart is added.
# ROOT prefixes the install paths (tests install into a sandbox); BACKUP_ENV_DEST overrides where
# the env file goes (default /etc/postgres-server/backup.env, the path the units read).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
env_src="${1:?usage: install-backup.sh ENV_SRC}"
ROOT="${ROOT:-}"
lib="$ROOT/usr/local/lib/postgres-backup"
dest="${BACKUP_ENV_DEST:-$ROOT/etc/postgres-server/backup.env}"

install -d "$lib" "$ROOT/etc/systemd/system" "$(dirname "$dest")"
install -m 0755 "$here/backup.sh" "$here/check-backup-health.sh" "$here/backup-common.sh" "$lib/"
install -m 0600 "$env_src" "$dest"
install -m 0644 "$here/../systemd/postgres-backup.service" "$here/../systemd/postgres-backup.timer" \
  "$here/../systemd/postgres-backup-health.service" "$here/../systemd/postgres-backup-health.timer" \
  "$ROOT/etc/systemd/system/"
systemctl daemon-reload
systemctl enable --now postgres-backup.timer postgres-backup-health.timer
