#!/usr/bin/env bash
# deployment/postgres/bin/check-backup-health.sh   (as root, every 15 minutes from postgres-backup-health.timer)
# Pings healthchecks.io success only if every check passes; otherwise fail with one short reason per
# failed check. Spec §8.3. The failure this replaces was silence, so no check may pass by default:
# a Postgres, Docker or df that does not answer is a failure.
#
#  1. no finished WAL file has waited over 15 minutes to be archived. archive_timeout is 300 s, so a
#     healthy server may hold one for a few minutes;
#  2. pg_stat_archiver.failed_count has not risen since the last run. The first run stores a value
#     and passes (failures logged before stanza-create on a first deploy are normal). The state file
#     holds "count|stats_reset". When stats_reset has changed (a restore or crash restarts the
#     counter) the baseline is 0, so any failure since the reset alerts: comparing against the old
#     count once let 3 real failures pass as "3 is lower than 9". A NULL stats_reset is stored as
#     "never". A file holding only a count (the old format) passes once without a reset comparison
#     and is rewritten with both values;
#  3. the filesystem holding Docker's data is under 80% full.
#
# Test hook: DF_PATH overrides /var/lib/docker.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=backup-common.sh
. "$here/backup-common.sh"
# url first: every failure below, including a missing REPO_DIR, must be able to ping.
url="${HC_PG_HEALTH:-}"
if [ -z "$url" ]; then log "HC_PG_HEALTH is not set; checking without pings"; fi
DETAIL_LOG_NAME=health.log
count_file="$LOG_DIR/archive-failed-count"
reasons=()

# A timeout or shutdown mid-check must not be silent.
# shellcheck disable=SC2329  # invoked by the trap
on_term() {
  hc_ping "$url" fail "terminated before finishing"
  log "health check terminated"
  exit 143
}
trap on_term TERM INT HUP

# The archive settings this server must run with. Must equal config/postgresql.conf; a test checks.
EXPECTED_ARCHIVE_COMMAND='pgbackrest --stanza=main archive-push %p'

dexec() { timeout 120 docker compose -f "$REPO_DIR/compose.yml" exec -T postgres "$@" </dev/null; }

# Postgres, the failure counter and the archive settings, in one query. Anything but a number
# first means it did not answer. Settings are read from the running server, not from the file: an
# `ALTER SYSTEM`, a reload or a different config_file would show here and nowhere else.
failed_count="" stats_reset="" archive_mode="" archive_command=""
if [ -z "${REPO_DIR:-}" ]; then
  reasons+=("REPO_DIR is not set")
elif answer="$(dexec psql -U postgres -At -F '|' -c "SELECT failed_count, coalesce(extract(epoch from stats_reset)::text, 'never'), current_setting('archive_mode'), current_setting('archive_command') FROM pg_stat_archiver" 2>/dev/null)" \
  && IFS='|' read -r failed_count stats_reset archive_mode archive_command <<<"$answer" && [[ "$failed_count" =~ ^[0-9]+$ ]]; then
  :
else
  failed_count=""
  reasons+=("postgres not answering")
fi

if [ -n "$failed_count" ]; then
  # 0. Archiving must be switched on and pointed at pgBackRest. With archive_mode off, or a command
  # that succeeds without pushing, no .ready file appears and failed_count stays flat, so nothing
  # below would notice. last_archived_time is not used: an idle server legitimately archives nothing.
  if [ "$archive_mode" != on ]; then
    reasons+=("archive_mode is $archive_mode, not on")
  elif [ "$archive_command" != "$EXPECTED_ARCHIVE_COMMAND" ]; then
    reasons+=("archive_command is not the expected pgbackrest command")
  fi

  # 1. The oldest .ready file, under the image's data path. -mmin +15 is "older than 15 minutes".
  # shellcheck disable=SC2016  # expands inside the container
  if stuck="$(dexec sh -c 'find "$PGDATA/pg_wal/archive_status" -name "*.ready" -mmin +15' 2>/dev/null)"; then
    if [ -n "$stuck" ]; then reasons+=("WAL archive stuck over 15 min"); fi
  else
    reasons+=("could not check the WAL archive queue")
  fi

  # 2. Compare, then store: always, so one burst of failures alerts once and a reset starts over.
  stored="" stored_reset=""
  if [ -f "$count_file" ]; then stored="$(cat "$count_file" 2>/dev/null || true)"; fi
  if [[ "$stored" == *"|"* ]]; then stored_reset="${stored#*|}"; stored="${stored%%|*}"; fi
  if ! [[ "$stored" =~ ^[0-9]+$ ]]; then
    :  # first run, or an unreadable file: nothing to compare with
  elif [ -n "$stored_reset" ] && [ "$stored_reset" != "$stats_reset" ]; then
    # The counter restarted: its baseline is 0, whatever was stored.
    if [ "$failed_count" -gt 0 ]; then reasons+=("archive failures rose 0 to $failed_count"); fi
  elif [ "$failed_count" -gt "$stored" ]; then
    # Same reset time, or an old-format file with no reset time to compare.
    reasons+=("archive failures rose $stored to $failed_count")
  fi
  umask 077
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  if ! { printf '%s|%s\n' "$failed_count" "$stats_reset" >"$count_file.tmp" && mv -f "$count_file.tmp" "$count_file"; } 2>/dev/null; then
    # A failure, not a log line: without a stored value every run is a "first run" and an
    # increase in failures could never be seen.
    reasons+=("could not store the archive failure count")
  fi
fi

# 3. Disk.
used="$(df --output=pcent "${DF_PATH:-/var/lib/docker}" 2>/dev/null | tail -n 1 | tr -dc '0-9')"
if [ -z "$used" ]; then
  reasons+=("could not read disk usage")
elif [ "$used" -ge 80 ]; then
  reasons+=("disk ${used}% full")
fi

if [ "${#reasons[@]}" = 0 ]; then
  hc_ping "$url" "" "ok"
  log "health ok"
  exit 0
fi
msg="$(IFS=';'; echo "${reasons[*]}")"
msg="${msg//;/; }"
detail_log "health failed: $msg"
hc_ping "$url" fail "$msg"
log "health failed: $msg"
exit 1
