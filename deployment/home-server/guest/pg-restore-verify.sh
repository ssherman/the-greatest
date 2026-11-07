#!/usr/bin/env bash
# deployment/home-server/guest/pg-restore-verify.sh
# pg-restore-verify.timer, daily at 12:00 UTC, `pgverify` VM only: restore the newest production
# Postgres backup, prove it is real, dump both databases, and ping `pg-restore-verified` only when
# every step passed. A backup counts only once this has restored it.
# Spec: docs/superpowers/specs/2026-11-06-postgres-server-design.md §8.2, §8.3, §9.
#
# The pgBackRest key on this VM is read-only, and the restore passes --archive-mode=off, so nothing
# restored here can write to the production repo. Postgres has no TCP listener and no published port.
# Test hooks (never set in the env file): PGVERIFY_NOW (a date -d string standing in for the clock),
# PGVERIFY_POLL_S, PGVERIFY_RECOVERY_TIMEOUT_S, PGVERIFY_UID, PGVERIFY_REPO_TYPE (posix, for a rehearsal).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
load_env

# The databases to restore, check and dump. When the old site shuts down, remove tgb here and nothing
# else (its dumps in daily/ and monthly/ then stop being pruned; delete them by hand).
DATABASES=(the_greatest tgb)
# The core tables of each database: a restore with one of these empty or missing is not a real one.
# shellcheck disable=SC2034 # both are read through indirection (CORE_TABLES_${db}[@])
CORE_TABLES_the_greatest=(users books_books music_albums music_songs games_games user_list_items)
# shellcheck disable=SC2034 # read through indirection too
CORE_TABLES_tgb=(users books authors user_list_books)

KEEP_DAILY=14
KEEP_MONTHLY=12
MAX_REPLAY_AGE_S=$((26 * 3600))
MIN_ROWS=10000    # a table must be over this in either night's count to alert on a move
# Free disk a first night must have for its dumps, before there is a previous set to measure. A set was
# about 7.6 GB in November 2026, with the old server's 55 GB stats table gone.
FIRST_DUMPS_KB=$((8 * 1024 * 1024))
MOVE_PERCENT=5
SOCKET=/var/run/postgresql
POLL_S="${PGVERIFY_POLL_S:-10}"
RECOVERY_TIMEOUT_S="${PGVERIFY_RECOVERY_TIMEOUT_S:-10800}"
PG_UID="${PGVERIFY_UID:-999}"
REPO_TYPE="${PGVERIFY_REPO_TYPE:-s3}"

ROOT="$PGVERIFY_ROOT"
DATA="$ROOT/pgdata"
DUMPS="$ROOT/dumps"
STATE="$ROOT/state"
BASELINE="$STATE/row-counts"
MARKER="$STATE/restore-in-progress"
SENTINEL="$ROOT/.pgverify-data"

hc() { hc_ping "${HC_PGVERIFY:-}" "$@"; }
# Row counts that moved over the threshold tonight. They ride on every failure message, so a night that
# fails for another reason (a pg_dump error, say) does not swallow the alert.
moved=()
reported=0 finished=0 started=0
# The ping message goes to a third party: short reasons only, never a bucket, key or path.
fail() {
  local msg=$1
  if [ "${#moved[@]}" -gt 0 ]; then msg+="; row counts moved over ${MOVE_PERCENT}%: ${moved[*]}"; fi
  reported=1
  log "restore check failed: $msg"; hc fail "$msg"; exit 1
}
now_utc() { if [ -n "${PGVERIFY_NOW:-}" ]; then date -u -d "$PGVERIFY_NOW" "$@"; else date -u "$@"; fi; }

postgres_stopped=1
stop_postgres() {
  if "$COMPOSE" stop postgres >/dev/null 2>&1; then postgres_stopped=1; else log "could not stop postgres"; return 1; fi
}
# Whatever way the run ends, the VM is left idle and the next --delta restore finds Postgres stopped.
# A run that ends without a success ping and without fail() having reported (set -e on a failed install,
# mv or write, or a TERM) pings fail here, once, so silence never hides a half-run. The ping comes before
# the stop: a stop can take its whole grace period, and on a TERM systemd may kill the unit during it.
on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$started" = 1 ] && [ "$finished" = 0 ] && [ "$reported" = 0 ]; then
    local msg="run aborted (exit $rc)"
    if [ "${#moved[@]}" -gt 0 ]; then msg+="; row counts moved over ${MOVE_PERCENT}%: ${moved[*]}"; fi
    log "restore check failed: $msg"; hc fail "$msg"
  fi
  if [ "$postgres_stopped" = 0 ]; then stop_postgres || true; fi
}
trap on_exit EXIT
# systemd stops the unit with TERM: exit, so on_exit runs.
trap 'exit 143' TERM INT HUP

# The tools container: pgbackrest, psql, pg_amcheck, pg_dump, pg_restore.
tool() { "$COMPOSE" run --rm --no-deps -T tools "$@"; }
sql() { tool psql -X -At -v ON_ERROR_STOP=1 -h "$SOCKET" -U postgres -d "$1" -c "$2"; }

exec 9>"$PGVERIFY_LOCK"
if ! flock -n 9; then
  # The next run reports; pinging here would hide a stuck run behind a "deferred".
  log "a run or deploy holds $PGVERIFY_LOCK; trying next run"
  finished=1
  exit 0
fi

# --- Configuration, checked before two hours of restore --------------------------------------
missing=()
required=(PGVERIFY_CIPHER_PASS PGVERIFY_REPO_PATH)
if [ "$REPO_TYPE" = s3 ]; then
  required=(PGVERIFY_REPO_BUCKET PGVERIFY_REPO_ENDPOINT PGVERIFY_REPO_REGION PGVERIFY_REPO_PATH
    PGVERIFY_REPO_KEY PGVERIFY_REPO_KEY_SECRET PGVERIFY_CIPHER_PASS)
fi
upload=0
if [ "${PGVERIFY_UPLOAD_ENABLED:-0}" = 1 ]; then
  upload=1
  required+=(PGVERIFY_DUMP_BUCKET PGVERIFY_DUMP_REGION PGVERIFY_DUMP_ENDPOINT PGVERIFY_DUMP_KEY PGVERIFY_DUMP_KEY_SECRET)
fi
for name in "${required[@]}"; do
  if [ -z "${!name:-}" ]; then missing+=("$name"); fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  hc start; started=1
  fail "missing settings: ${missing[*]}"
fi

# --- The data disk, and the guards around emptying it ----------------------------------------
# The data disk mounts with nofail so a missing disk cannot hang boot; without this check the
# restore would fill the OS disk instead.
root_is_sane() {
  case "$ROOT" in /*) ;; *) return 1 ;; esac
  case "$ROOT" in *..*) return 1 ;; esac
  # Two path components at least: not / and not /mnt.
  [[ "${ROOT#/}" == */* ]]
}
hc start; started=1
root_is_sane || fail "the data directory setting is not a safe path"
mountpoint -q "$ROOT" || fail "the data disk is not mounted"
# Only a pristine disk (empty, or just lost+found) or one this job already owns is used. A wrong
# PGVERIFY_ROOT that happens to be a mount point holds other files, so it is never adopted, and
# nothing under it is ever deleted.
if [ ! -f "$SENTINEL" ]; then
  if [ -n "$(find "$ROOT" -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit)" ]; then
    fail "the data disk holds files this job did not create; not using it"
  fi
  echo pgverify >"$SENTINEL"
fi
for d in pgdata run state; do
  [ ! -L "$ROOT/$d" ] || fail "a data directory is a symlink; refusing to use it"
done
install -d -m 0700 -o "$PG_UID" -g "$PG_UID" "$DATA" "$ROOT/run" "$ROOT/config" || fail "could not prepare the data disk"
install -d -m 0700 "$STATE" || fail "could not prepare the data disk"
install -d -m 0755 -o "$PG_UID" -g "$PG_UID" "$DUMPS" "$DUMPS/daily" "$DUMPS/monthly" || fail "could not prepare the data disk"
rm -f "$DUMPS"/daily/*.partial "$DUMPS"/monthly/*.partial

# empty_data_directory: the only deletion this script does, and it re-checks every guard itself.
empty_data_directory() {
  root_is_sane && [ -f "$SENTINEL" ] && [ ! -L "$DATA" ] && [ "$DATA" = "$ROOT/pgdata" ] &&
    [ "$(cd "$DATA" && pwd -P)" = "$(cd "$ROOT" && pwd -P)/pgdata" ] || return 1
  find "$DATA" -mindepth 1 -delete
}

# --- pgBackRest config: read-only key, never archives ----------------------------------------
render_pgbackrest_conf() {
  local conf="$ROOT/config/pgbackrest.conf"
  (
    umask 077
    {
      echo "[global]"
      if [ "$REPO_TYPE" = s3 ]; then
        echo "repo1-type=s3"
        echo "repo1-s3-bucket=$PGVERIFY_REPO_BUCKET"
        echo "repo1-s3-endpoint=$PGVERIFY_REPO_ENDPOINT"
        echo "repo1-s3-region=$PGVERIFY_REPO_REGION"
        echo "repo1-s3-key=$PGVERIFY_REPO_KEY"
        echo "repo1-s3-key-secret=$PGVERIFY_REPO_KEY_SECRET"
      else
        echo "repo1-type=posix"
      fi
      echo "repo1-path=$PGVERIFY_REPO_PATH"
      echo "repo1-cipher-type=aes-256-cbc"
      echo "repo1-cipher-pass=$PGVERIFY_CIPHER_PASS"
      echo "process-max=2"
      echo "log-level-console=warn"
      # The containers are throwaway, so a log file inside one is lost anyway.
      echo "log-level-file=off"
      echo
      echo "[main]"
      echo "pg1-path=/var/lib/postgresql/18/docker"
    } >"$conf.new"
  )
  chown "$PG_UID:$PG_UID" "$conf.new"
  mv "$conf.new" "$conf"
}
render_pgbackrest_conf

# --- 1. Restore --------------------------------------------------------------------------------
# The newest WAL segment in the archive, read before restoring. Recovery that stops short of it (a WAL
# fetch that failed or an object that is missing) would otherwise finish on a new timeline and pass every
# later check with the last hours of data gone. A segment archived after this read is not required.
info_json="$(tool pgbackrest --stanza=main info --output=json)" || fail "could not read the backup repository"
archive_max="$(jq -r '[.[] | select(.name == "main") | .archive[]?.max] | last // empty' <<<"$info_json")" ||
  fail "could not read the archive from the backup repository"
archive_max="${archive_max^^}"
[[ "$archive_max" =~ ^[0-9A-F]{24}$ ]] || fail "the backup repository has no archived WAL"

# Stop whatever an earlier killed run left running before touching its data directory. A hard kill leaves
# postmaster.pid, which makes pgBackRest refuse the restore (exit 38); with the server stopped it is stale.
stop_postgres || fail "could not stop postgres"
if [ -n "$("$COMPOSE" ps -q --status running postgres)" ]; then fail "postgres is still running"; fi
rm -f "$DATA/postmaster.pid"
rm -f "$ROOT"/run/.s.PGSQL* "$ROOT"/run/*.lock 2>/dev/null || true

# From empty on Sundays, on a first run, and after a restore that never finished (a leftover marker:
# the VM rebooted or the unit was killed mid-restore). Otherwise --delta, which keeps the download small.
from_empty=0
if [ "$(now_utc +%u)" = 7 ] || [ -f "$MARKER" ] || [ ! -f "$DATA/PG_VERSION" ]; then from_empty=1; fi

touch "$MARKER"
restore=(pgbackrest --stanza=main restore)
if [ "$from_empty" = 1 ]; then
  log "restoring from an empty data directory"
  empty_data_directory || fail "refused to empty the data directory"
else
  log "restoring over the existing data directory (--delta)"
  restore+=(--delta)
fi
# Never archive from a restored cluster; restore writes this into postgresql.auto.conf.
tool "${restore[@]}" --archive-mode=off || fail "restore failed (exit $?)"
rm -f "$MARKER"

# --- 2. Start Postgres and let it finish recovery ---------------------------------------------
"$COMPOSE" up -d --no-build postgres || fail "could not start postgres"
postgres_stopped=0
deadline=$((SECONDS + RECOVERY_TIMEOUT_S))
until tool pg_isready -q -h "$SOCKET" -U postgres; do
  if [ -z "$("$COMPOSE" ps -q --status running postgres)" ]; then fail "postgres exited during recovery"; fi
  [ "$SECONDS" -lt "$deadline" ] || fail "recovery did not finish in time"
  sleep "$POLL_S"
done
[ "$(sql postgres "select pg_is_in_recovery()")" = f ] || fail "postgres is still in recovery"

# Its settings are what the restore must never override: the command line forces them, this proves it.
settings="$(sql postgres "select concat_ws(',', current_setting('archive_mode'), current_setting('max_logical_replication_workers'), current_setting('listen_addresses'))")" ||
  fail "could not read the server's settings"
[ "$settings" = "off,0," ] || fail "unsafe server settings (archive, replication workers or listener)"

# --- 3. Is it real? ---------------------------------------------------------------------------
# On an idle production cluster this can be old or null although the restore is fine. Production writes
# constantly, so this is a real signal there; a deliberate heartbeat write is out of scope.
age="$(sql postgres "select coalesce(extract(epoch from now() - pg_last_xact_replay_timestamp())::bigint::text, 'null')")" ||
  fail "could not read the last replayed transaction"
if [ "$age" = null ]; then fail "no replayed transaction recorded (an idle backup, or no WAL replayed)"; fi
[[ "$age" =~ ^-?[0-9]+$ ]] || fail "unreadable replay age"
if [ "$age" -gt "$MAX_REPLAY_AGE_S" ]; then fail "latest replayed transaction is $((age / 3600)) hours old"; fi

# Did replay reach the archive's newest segment? Compared as log and segment only (the last 16 hex digits),
# because recovery ends on a new timeline. The last byte replayed (LSN - 1) is used, not the LSN: replay that
# stops at the end of segment N-1 has an LSN that pg_walfile_name puts in segment N, which would pass a
# restore that never read N.
replayed="$(sql postgres "select coalesce(substr(pg_walfile_name(pg_last_wal_replay_lsn() - 1), 9), 'null')")" ||
  fail "could not read the last replayed WAL position"
replayed="${replayed^^}"
[[ "$replayed" =~ ^[0-9A-F]{16}$ ]] || fail "no replayed WAL position recorded"
if [[ "$replayed" < "${archive_max:8}" ]]; then fail "recovery stopped short of the archived WAL"; fi

declare -A counts=()
for db in "${DATABASES[@]}"; do
  [ "$(sql postgres "select count(*) from pg_database where datname = '$db'")" = 1 ] || fail "database $db is missing"
  ref="CORE_TABLES_${db}[@]"
  tables=("${!ref}")
  for t in "${tables[@]}"; do
    [ "$(sql "$db" "select to_regclass('public.$t') is not null")" = t ] || fail "core table $db.$t is missing"
    n="$(sql "$db" "select count(*) from public.$t")" || fail "could not count $db.$t"
    [[ "$n" =~ ^[0-9]+$ ]] || fail "unreadable row count for $db.$t"
    [ "$n" -gt 0 ] || fail "core table $db.$t is empty"
    counts["$db.$t"]=$n
  done
done

# Row counts alert but do not stop the run: bulk changes in books data are normal, so the night's
# dumps still complete. The baseline is always the previous night and is replaced every night, even
# after an alert, so one real change causes one alert and clears itself. It is replaced at the very end
# (below): a night that fails earlier keeps the old baseline, and every failure message carries `moved`.
if [ -f "$BASELINE" ]; then
  while read -r key old; do
    new="${counts[$key]:-}"
    [ -n "$new" ] && [[ "$old" =~ ^[0-9]+$ ]] || continue
    # A table that was big and is now tiny is the move to catch, so one side over the floor is enough.
    if [ "$old" -gt "$MIN_ROWS" ] || [ "$new" -gt "$MIN_ROWS" ]; then
      diff=$((new > old ? new - old : old - new))
      if [ $((diff * 100)) -gt $((old * MOVE_PERCENT)) ]; then moved+=("$key"); fi
    fi
  done <"$BASELINE"
fi

# amcheck: the tables above and their indexes. --install-missing creates the extension where it is
# absent; it is dropped again before any dump so it never reaches one.
for db in "${DATABASES[@]}"; do
  ref="CORE_TABLES_${db}[@]"
  tables=("${!ref}")
  args=()
  for t in "${tables[@]}"; do args+=("--table=public.$t"); done
  tool pg_amcheck -h "$SOCKET" -U postgres -d "$db" --install-missing "${args[@]}" || fail "amcheck failed in $db"
done
for db in "${DATABASES[@]}"; do
  sql "$db" "drop extension if exists amcheck" >/dev/null || fail "could not remove amcheck from $db"
done

# --- 4. Dump, and prove each dump can be read ---------------------------------------------------
# Room for tonight's first: the disk also holds the restored cluster, and a dump that fills it fails
# confusingly. One night's dumps is the newest set on disk, or the floor before there is one.
free_kb="$(df -Pk "$ROOT" 2>/dev/null | awk 'NR == 2 { print $4 }')" || free_kb=""
[[ "$free_kb" =~ ^[0-9]+$ ]] || fail "could not read the free disk"
need_kb=0
for db in "${DATABASES[@]}"; do
  newest="$(find "$DUMPS/daily" -maxdepth 1 -type f -name "postgres_${db}_backup_*.sql.gz" -printf '%f\n' | LC_ALL=C sort | tail -n 1)"
  if [ -n "$newest" ]; then need_kb=$((need_kb + $(stat -c %s "$DUMPS/daily/$newest") / 1024)); fi
done
if [ "$need_kb" = 0 ]; then need_kb=$FIRST_DUMPS_KB; fi
if [ "$free_kb" -lt "$need_kb" ]; then
  fail "not enough free disk for tonight's dumps: $((free_kb / 1048576)) GB free, $((need_kb / 1048576)) GB needed"
fi
log "free disk before the dumps: $((free_kb / 1048576)) GB, one night's dumps: $((need_kb / 1048576)) GB"

ts="$(now_utc +%Y%m%dT%H%M%SZ)"
names=()
for db in "${DATABASES[@]}"; do
  name="postgres_${db}_backup_${ts}.sql.gz"
  partial="$name.partial"
  tool pg_dump -Fc --no-subscriptions -h "$SOCKET" -U postgres -f "/dumps/daily/$partial" "$db" || fail "pg_dump failed for $db"
  [ -s "$DUMPS/daily/$partial" ] || fail "the dump of $db is empty"
  list="$(tool pg_restore --list "/dumps/daily/$partial")" || fail "the dump of $db is unreadable"
  grep -qv '^;' <<<"$list" || fail "the dump of $db has no contents"
  mv "$DUMPS/daily/$partial" "$DUMPS/daily/$name" || fail "could not keep the dump of $db"
  names+=("$name")
done

# --- 5/6. Keep them, then upload ----------------------------------------------------------------
# One copy per database per calendar month, made on the first successful run of the month (not only on the
# 1st: a failed 1st must not cost a month).
month="$(now_utc +%Y%m)"
for name in "${names[@]}"; do
  prefix="${name%%_backup_*}_backup_"
  if [ -z "$(find "$DUMPS/monthly" -maxdepth 1 -type f -name "${prefix}${month}[0-9][0-9]T*.sql.gz" -print -quit)" ]; then
    cp -- "$DUMPS/daily/$name" "$DUMPS/monthly/$name.partial" || fail "could not copy a dump to monthly"
    mv "$DUMPS/monthly/$name.partial" "$DUMPS/monthly/$name" || fail "could not copy a dump to monthly"
  fi
done

# prune <dir> <keep>: the newest <keep> dumps of each database stay, by name (the UTC timestamp sorts
# as text). Only names this script makes are considered; anything else in the directory is left alone.
prune() {
  local dir=$1 keep=$2 db i
  local -a files
  for db in "${DATABASES[@]}"; do
    mapfile -t files < <(find "$dir" -maxdepth 1 -type f -printf '%f\n' |
      grep -E "^postgres_${db}_backup_[0-9]{8}T[0-9]{6}Z\.sql\.gz$" | LC_ALL=C sort)
    for ((i = 0; i < ${#files[@]} - keep; i++)); do rm -f -- "$dir/${files[$i]}"; done
  done
}
prune "$DUMPS/daily" "$KEEP_DAILY"
prune "$DUMPS/monthly" "$KEEP_MONTHLY"

# The dump bucket is on R2: the endpoint (https://<account id>.r2.cloudflarestorage.com) and region `auto`
# come from the env, and the key is an R2 token scoped to that bucket alone.
if [ "$upload" = 1 ]; then
  for name in "${names[@]}"; do
    AWS_ACCESS_KEY_ID="$PGVERIFY_DUMP_KEY" AWS_SECRET_ACCESS_KEY="$PGVERIFY_DUMP_KEY_SECRET" AWS_DEFAULT_REGION="$PGVERIFY_DUMP_REGION" \
      AWS_ENDPOINT_URL="$PGVERIFY_DUMP_ENDPOINT" "$COMPOSE" run --rm --no-deps -T aws s3 cp --only-show-errors "/dumps/daily/$name" "s3://$PGVERIFY_DUMP_BUCKET/$name" ||
      fail "upload failed"
  done
else
  log "upload is off (PGVERIFY_UPLOAD_ENABLED is not 1)"
fi

# --- 7. Report ------------------------------------------------------------------------------------
stop_postgres || log "postgres did not stop cleanly"
# The baseline is tonight's counts from here on, alert or not. The write goes through a temp file so a
# full disk leaves the previous baseline in place, and a failed write is reported.
for key in "${!counts[@]}"; do echo "$key ${counts[$key]}"; done | LC_ALL=C sort >"$BASELINE.new" ||
  fail "could not write the row-count baseline"
mv "$BASELINE.new" "$BASELINE" || fail "could not write the row-count baseline"
if [ "${#moved[@]}" -gt 0 ]; then fail "dumps completed"; fi
finished=1
hc "" "restored, checked and dumped; replay ${age}s old; $((free_kb / 1048576)) GB free before the dumps"
