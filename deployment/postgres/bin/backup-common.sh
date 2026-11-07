#!/usr/bin/env bash
# deployment/postgres/bin/backup-common.sh -- sourced by backup.sh and check-backup-health.sh; not run.
# Installed next to them under /usr/local/lib/postgres-backup by install-backup.sh.
#
# Environment (systemd reads /etc/postgres-server/backup.env into it):
#   REPO_DIR   the directory holding compose.yml (deployment/postgres in the checkout)
#   HC_*       healthchecks.io ping URLs; the path is the check's credential
#   STATE_DIR  default /srv/postgres; its state/ directory is root-only
# shellcheck shell=bash

STATE_DIR="${STATE_DIR:-/srv/postgres}"
LOG_DIR="$STATE_DIR/state"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-5000000}"

# compose.yml refuses to interpolate without the superuser password, even for `exec`, which never
# uses it. A placeholder keeps root's timer from needing the secret. The two directories only need
# to be the deploy's defaults; `exec` does not look at them.
export POSTGRES_SUPERUSER_PASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-unused-by-exec}"
export POSTGRES_HOST_CONFIG_DIR="${POSTGRES_HOST_CONFIG_DIR:-$STATE_DIR/config}"
export POSTGRES_CERTS_DIR="${POSTGRES_CERTS_DIR:-$STATE_DIR/certs}"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# hc_ping <url> [start|fail] [message]: same behaviour as hc_ping in
# deployment/home-server/guest/lib.sh. A blank url is a no-op, and an undeliverable ping is logged,
# never fatal: an outage of the monitor must not fail the thing it monitors. The URL is never
# logged. The message goes to a third party, so callers send only error classes and exit codes.
hc_ping() {
  local url="${1:-}" suffix="${2:-}" message="${3:-}"
  [ -n "$url" ] || return 0
  if [ -n "$suffix" ]; then url="$url/$suffix"; fi
  curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "$message" "$url" >/dev/null 2>&1 ||
    log "could not ping healthchecks.io (${suffix:-success})"
}

# detail_log DESCRIPTION [FILE...]: full command output goes to a root-only file, rotated by size
# (one old copy kept) so it cannot fill the disk. Nothing from it reaches a ping, stdout or the journal.
detail_log() {
  local desc="$1" f
  shift
  umask 077
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  local file="$LOG_DIR/${DETAIL_LOG_NAME:-backup.log}"
  if [ -f "$file" ] && [ "$(stat -c %s "$file")" -ge "$LOG_MAX_BYTES" ]; then mv -f "$file" "$file.1"; fi
  {
    printf '== %s: %s\n' "$(date -u +%FT%TZ)" "$desc"
    for f in "$@"; do cat "$f"; done
  } >>"$file" 2>/dev/null || true
}

# error_classes FILE...: the bracketed pgBackRest error classes, e.g. [028] or [ProtocolError].
error_classes() {
  cat "$@" 2>/dev/null | grep -oE '\[([0-9]{3}|[A-Za-z]+Error)\]' | sort -u | tr '\n' ' ' | sed 's/ $//' || true
}

# pgb ARGS...: pgBackRest inside the container, as the postgres user. stdin is closed.
# Killing the `docker exec` client (a systemd timeout, a shutdown, a TERM to the script) does NOT stop
# pgBackRest in the container: it keeps running and keeps its lock. The next run's [050] right after
# a "terminated" ping is that leftover run finishing, not a second timer. backup.sh says so in the ping.
pgb() {
  docker compose -f "$REPO_DIR/compose.yml" exec -T postgres pgbackrest --stanza=main "$@" </dev/null
}
