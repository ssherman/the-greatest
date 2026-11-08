#!/usr/bin/env bash
# deployment/postgres/bin/backup.sh   (as root, from postgres-backup.service)
# One pgBackRest backup: full on Sunday (UTC), differential otherwise, full if the repo holds no
# backup at all. Pings healthchecks.io: start before, success only after `info` lists a label that
# was not there before, fail otherwise. Spec §8.
#
# Pings carry the error class ([028], [ProtocolError]) and the exit code only; pgBackRest's own text
# can name the bucket, so it goes to $STATE_DIR/state/backup.log (0600, rotated by size) and
# nowhere else. A second copy cannot overlap: pgBackRest takes its own lock and refuses [050].
#
# Test hook: BACKUP_DOW overrides the ISO day of week (7 = Sunday).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"
# url first: every failure below, including a missing REPO_DIR, must be able to ping.
url="${HC_PG_BACKUP:-}"
if [ -z "$url" ]; then log "HC_PG_BACKUP is not set; running without pings"; fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {   # fail MESSAGE : ping fail, say it on stdout, exit 1
  hc_ping "$url" fail "$1"
  log "backup failed: $1 (details: $LOG_DIR/backup.log)"
  exit 1
}

# A timeout or shutdown mid-backup must not be silent. Killing this script kills the `docker exec`
# client, NOT the pgBackRest process in the container, which keeps running and holds its lock; so
# a [050] on the next run, right after a "terminated" ping, means that leftover run.
# shellcheck disable=SC2329  # invoked by the trap
on_term() {
  hc_ping "$url" fail "terminated before finishing; pgBackRest may still be running in the container and holding its lock (a [050] on the next run means that)"
  log "backup terminated"
  exit 143
}
trap on_term TERM INT HUP

if [ -z "${REPO_DIR:-}" ]; then fail "REPO_DIR is not set"; fi

# labels_now FILE : the labels of stanza main, one per line, into FILE. Returns 1 when info fails
# or cannot be read, which is never to be read as "no backups".
labels_now() {
  local rc=0
  pgb info --output=json >"$work/info.out" 2>"$work/info.err" || rc=$?
  detail_log "pgbackrest info (exit $rc)" "$work/info.out" "$work/info.err"
  if [ "$rc" != 0 ]; then
    INFO_ERR="info failed (exit $rc) $(error_classes "$work/info.out" "$work/info.err")"
    INFO_ERR="${INFO_ERR% }"
    return 1
  fi
  # Labels to stdout. Labels whose entry has "error": true (pgBackRest's mark for a backup that
  # found page checksum errors, even though the command exited 0) go to $1.err.
  python3 -I -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
    assert isinstance(data, list)
except Exception:
    sys.exit(1)
bad = open(sys.argv[1], "w")
for stanza in data:
    if isinstance(stanza, dict) and stanza.get("name") == "main":
        for b in stanza.get("backup") or []:
            print(b["label"])
            if b.get("error") is True:
                bad.write(b["label"] + "\n")
' "$1.err" <"$work/info.out" | LC_ALL=C sort >"$1" || { INFO_ERR="info output was not understood"; return 1; }
}

hc_ping "$url" start
INFO_ERR=""
labels_now "$work/before" || fail "$INFO_ERR"

if [ ! -s "$work/before" ] || [ "${BACKUP_DOW:-$(date -u +%u)}" = 7 ]; then type="full"; else type="diff"; fi

rc=0
pgb backup --type="$type" >"$work/backup.out" 2>"$work/backup.err" || rc=$?
detail_log "pgbackrest backup --type=$type (exit $rc)" "$work/backup.out" "$work/backup.err"
if [ "$rc" != 0 ]; then
  classes="$(error_classes "$work/backup.out" "$work/backup.err")"
  msg="$type backup failed (exit $rc) ${classes}"
  case "$classes" in
    *"[050]"*) msg="$msg: another pgbackrest operation holds the lock (a backup is running, or one a killed earlier run left behind in the container)" ;;
  esac
  fail "$msg"
fi

# Exit 0 is not enough: the backup must be listed.
labels_now "$work/after" || fail "backup exited 0 but could not be confirmed: $INFO_ERR"
new="$(LC_ALL=C comm -13 "$work/before" "$work/after" | tail -n 1)"
if [ -z "$new" ]; then fail "$type backup exited 0 but info shows no new backup"; fi

if grep -qxF "$new" "$work/after.err"; then fail "$type backup $new exited 0 but pgBackRest marks it as having errors (page checksum errors)"; fi

hc_ping "$url" "" "$type backup $new"
log "backup ok: $type $new"
