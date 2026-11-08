#!/usr/bin/env bash
# shellcheck disable=SC2016  # stub bodies are single-quoted: they expand when the stub runs
# deployment/home-server/test/pg_restore_verify_test.sh
# guest/pg-restore-verify.sh against a stubbed compose (which runs the command it is
# given, so the pgbackrest, psql, pg_amcheck, pg_dump, pg_restore and aws stubs see the
# calls), a stubbed curl (healthchecks.io) and a sandbox standing in for /mnt/pgverify.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"

# A Wednesday, so the weekday (--delta) path is the default; SUNDAY is the next Sunday.
WEEKDAY=2026-11-04T12:00:00Z
SUNDAY=2026-11-08T12:00:00Z

setup() {
  new_sandbox
  export PGVERIFY_ROOT="$SANDBOX/pgv" PGVERIFY_LOCK="$SANDBOX/run/pgverify.lock"
  export PGVERIFY_UID PGVERIFY_NOW="$WEEKDAY" PGVERIFY_POLL_S=0 COUNTS="$SANDBOX/counts"
  PGVERIFY_UID="$(id -u)"
  unset FREE_KB COMPOSE_STOP_EXIT INFO_EXIT ARCHIVE_MAX REPLAY_SEG RESTORE_EXIT REPLAY_AGE AMCHECK_EXIT DUMP_MODE LIST_EXIT AWS_EXIT AWS_FAIL_TIMES SETTINGS MISSING_TABLE PG_EXITED \
    NOT_MOUNTED ISREADY_EXIT PGVERIFY_RECOVERY_TIMEOUT_S PGVERIFY_UPLOAD_ENABLED
  : >"$COUNTS"
  # The data disk as first-boot leaves it: mounted and empty.
  mkdir -p "$PGVERIFY_ROOT"
  write_env ROLE=pgverify REPO_REF=main TUNNELS_ENABLED=0 HC_PGVERIFY=https://hc.test/pgv \
    PGVERIFY_REPO_BUCKET=repo-bucket PGVERIFY_REPO_ENDPOINT=s3.repo.test PGVERIFY_REPO_REGION=us-test-1 \
    PGVERIFY_REPO_PATH=/repo-path PGVERIFY_REPO_KEY=repo-key-id PGVERIFY_REPO_KEY_SECRET=repo-key-secret \
    PGVERIFY_CIPHER_PASS=cipher-pass-xyz PGVERIFY_DUMP_BUCKET=dump-bucket PGVERIFY_DUMP_KEY=dump-key-id \
    PGVERIFY_DUMP_KEY_SECRET=dump-key-secret PGVERIFY_DUMP_REGION=dump-region-1 \
    PGVERIFY_DUMP_ENDPOINT=https://dump.r2.test PGVERIFY_UPLOAD_ENABLED=0
  stub curl ''
  stub df 'printf "Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 400000000 1000 %s 1%% /mnt\n" "${FREE_KB:-300000000}"'
  stub mountpoint '[ -z "${NOT_MOUNTED:-}" ]'
  stub compose "$(cat <<'EOF'
case "$1" in
  run)
    shift
    while [ "${1:-}" = --rm ] || [ "${1:-}" = --no-deps ] || [ "${1:-}" = -T ]; do shift; done
    svc=$1; shift
    case "$svc" in aws) exec aws "$@" ;; tools) exec "$@" ;; esac ;;
  up) touch "$SANDBOX/log/pg-up" ;;
  stop) rm -f "$SANDBOX/log/pg-up"; exit "${COMPOSE_STOP_EXIT:-0}" ;;
  ps) { [ -f "$SANDBOX/log/pg-up" ] && [ -z "${PG_EXITED:-}" ]; } && echo abc123 ;;
esac
EOF
)"
  export COMPOSE="$SANDBOX/bin/compose"
  stub pgbackrest "$(cat <<'EOF'
case "$*" in
  *" info"*)
    [ "${INFO_EXIT:-0}" = 0 ] || exit "$INFO_EXIT"
    printf '[{"name":"main","archive":[{"id":"18-1","min":"000000010000000000000001","max":"%s"}]}]\n' "${ARCHIVE_MAX-000000010000000000000010}" ;;
  *" restore"*)
    [ "${RESTORE_EXIT:-0}" = 0 ] || exit "$RESTORE_EXIT"
    [ ! -e "$PGVERIFY_ROOT/pgdata/postmaster.pid" ] || echo "pid-present-at-restore" >>"$SANDBOX/log/pid-seen"
    mkdir -p "$PGVERIFY_ROOT/pgdata"; touch "$PGVERIFY_ROOT/pgdata/PG_VERSION" ;;
esac
EOF
)"
  stub pg_isready 'exit "${ISREADY_EXIT:-0}"'
  stub psql "$(cat <<'EOF'
sql="" db=""
while [ $# -gt 0 ]; do
  case "$1" in -c) sql=$2; shift ;; -d) db=$2; shift ;; esac
  shift
done
table="$(grep -o 'public\.[a-z_]*' <<<"$sql" | head -1 | cut -d. -f2)"
case "$sql" in
  *pg_is_in_recovery*) echo f ;;
  *current_setting*) echo "${SETTINGS-off,0,}" ;;
  *pg_last_xact_replay_timestamp*) echo "${REPLAY_AGE-3600}" ;;
  *pg_walfile_name*) echo "${REPLAY_SEG-0000000000000010}" ;;
  *pg_database*) echo 1 ;;
  *to_regclass*) if [ "$table" = "${MISSING_TABLE:-}" ]; then echo f; else echo t; fi ;;
  *"count(*) from public."*)
    n="$(grep -h "^$db $table " "$COUNTS" | tail -1 | cut -d' ' -f3)"
    echo "${n:-50000}" ;;
esac
EOF
)"
  stub pg_amcheck 'exit "${AMCHECK_EXIT:-0}"'
  stub pg_dump "$(cat <<'EOF'
f=""
while [ $# -gt 0 ]; do case "$1" in -f) f=$2; shift ;; esac; shift; done
case "${DUMP_MODE:-ok}" in
  fail) exit 1 ;;
  empty) : >"$PGVERIFY_ROOT$f" ;;
  *) echo PGDMP >"$PGVERIFY_ROOT$f" ;;
esac
EOF
)"
  stub pg_restore 'case "$*" in --list*) printf "; Archive created\n1; 2615 2200 SCHEMA - public owner\n"; exit "${LIST_EXIT:-0}" ;; esac'
  stub aws 'echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" >>"$SANDBOX/log/aws-env"; echo "${AWS_DEFAULT_REGION:-unset}" >>"$SANDBOX/log/aws-region"; echo "${AWS_ENDPOINT_URL:-unset}" >>"$SANDBOX/log/aws-endpoint"; n=$(( $(cat "$SANDBOX/log/aws-calls" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$SANDBOX/log/aws-calls"; [ "$n" -gt "${AWS_FAIL_TIMES:-0}" ] || exit 1; exit "${AWS_EXIT:-0}"'
}

# adopted: the data disk after the job has run once (the sentinel it writes on a pristine disk).
adopted() { echo pgverify >"$PGVERIFY_ROOT/.pgverify-data"; }
# upload_on: the env file with the upload enabled and the dump bucket's settings.
upload_on() {
  write_env ROLE=pgverify HC_PGVERIFY=https://hc.test/pgv PGVERIFY_REPO_BUCKET=repo-bucket \
    PGVERIFY_REPO_ENDPOINT=s3.repo.test PGVERIFY_REPO_REGION=us-test-1 PGVERIFY_REPO_PATH=/repo-path \
    PGVERIFY_REPO_KEY=repo-key-id PGVERIFY_REPO_KEY_SECRET=repo-key-secret PGVERIFY_CIPHER_PASS=cipher-pass-xyz \
    PGVERIFY_DUMP_BUCKET=dump-bucket PGVERIFY_DUMP_KEY=dump-key-id PGVERIFY_DUMP_KEY_SECRET=dump-key-secret \
    PGVERIFY_DUMP_REGION=dump-region-1 PGVERIFY_DUMP_ENDPOINT=https://dump.r2.test PGVERIFY_UPLOAD_ENABLED=1
}
set_count() { echo "$1 $2 $3" >>"$COUNTS"; }
run() { "$GUEST/pg-restore-verify.sh" >"$SANDBOX/log/out" 2>&1; }
# The calls that matter, in order, one word each.
sequence() {
  awk '
    /^curl .*hc\.test\/pgv\/start$/ { print "start" }
    /^pgbackrest .* info/ { print "info" }
    /^pgbackrest .* restore/ { print "restore" }
    /^compose up/ { print "up" }
    /^psql .*pg_last_xact_replay_timestamp/ { print "replay" }
    /^psql .*pg_walfile_name/ { print "lsn" }
    /^pg_amcheck/ { print "amcheck" }
    /^psql .*drop extension/ { print "dropext" }
    /^pg_dump/ { print "dump" }
    /^pg_restore --list/ { print "list" }
    /^aws / { print "upload" }
    /^compose stop/ { print "stop" }
    /^curl .*hc\.test\/pgv$/ { print "ok" }
    /^curl .*hc\.test\/pgv\/fail$/ { print "fail" }
  ' "$CALLS" | tr '\n' ' '
}
fail_message() { sed -n 's/^curl .*--data-raw \(.*\) https:\/\/hc\.test\/pgv\/fail$/\1/p' "$CALLS"; }
dumps_in() { find "$PGVERIFY_ROOT/dumps/$1" -maxdepth 1 -name '*.sql.gz' -printf '%f\n' 2>/dev/null | sort; }

t_happy_path_sequence() {
  setup
  run && [ "$(sequence)" = "start info stop restore up replay lsn amcheck amcheck dropext dropext dump list dump list stop ok " ] &&
    ! called 'pgv/fail' && called '^curl .*--data-raw .* https://hc\.test/pgv$'
}
t_restore_fail_pings_fail() {
  setup; export RESTORE_EXIT=1
  ! run && [ "$(sequence)" = "start info stop restore fail " ] && ! called '^psql' && ! called '^pg_dump' &&
    [ -f "$PGVERIFY_ROOT/state/restore-in-progress" ] && [[ "$(fail_message)" == *restore* ]]
}
t_replay_over_26h_old_pings_fail() {
  setup; export REPLAY_AGE=93601
  { ! run && called 'hc\.test/pgv/fail$' && [[ "$(fail_message)" == *"hours old"* ]] &&
    ! called '^pg_amcheck' && ! called '^pg_dump' && ! called 'hc\.test/pgv$'; } || return 1
  setup; export REPLAY_AGE=93600
  run && called 'hc\.test/pgv$'
}
t_replay_null_pings_fail() {
  setup; export REPLAY_AGE=null
  ! run && [[ "$(fail_message)" == *"no replayed transaction"* ]] && ! called '^pg_dump'
}
t_core_table_empty_stops_before_dumps() {
  setup; set_count tgb authors 0
  ! run && [[ "$(fail_message)" == *"tgb.authors is empty"* ]] && ! called '^pg_amcheck' && ! called '^pg_dump' &&
    ! called 'hc\.test/pgv$'
}
t_core_table_missing_fails() {
  setup; export MISSING_TABLE=music_songs
  ! run && [[ "$(fail_message)" == *"music_songs"*"missing"* ]] && ! called '^pg_dump'
}
t_database_missing_fails() {
  setup
  stub psql 'case "$*" in *pg_database*) echo 0 ;; *pg_last_xact*) echo 10 ;; *pg_walfile_name*) echo 0000000000000010 ;; *current_setting*) echo "off,0," ;; *pg_is_in_recovery*) echo f ;; esac'
  ! run && [[ "$(fail_message)" == *"the_greatest"*"missing"* ]] && ! called '^pg_dump'
}
t_amcheck_fail_pings_fail() {
  setup; export AMCHECK_EXIT=2
  ! run && [[ "$(fail_message)" == *amcheck* ]] && ! called '^pg_dump' && ! called 'hc\.test/pgv$'
}
t_amcheck_scoped_and_installed() {
  setup
  run && called '^pg_amcheck .*--install-missing .*--table=public\.users .*--table=public\.books_books .*--table=public\.user_list_items' &&
    called '^pg_amcheck .*-d tgb .*--table=public\.authors'
}
t_amcheck_removed_before_dump() {
  setup
  run || return 1
  local drop dump
  drop="$(grep -n '^psql .*drop extension if exists amcheck' "$CALLS" | tail -1 | cut -d: -f1)"
  dump="$(grep -n '^pg_dump' "$CALLS" | head -1 | cut -d: -f1)"
  [ -n "$drop" ] && [ -n "$dump" ] && [ "$drop" -lt "$dump" ] && [ "$(grep -c '^psql .*drop extension' "$CALLS")" = 2 ]
}
t_row_count_move_finishes_dumps_then_pings_fail_naming_table() {
  setup; PGVERIFY_NOW=2026-11-03T12:00:00Z run || return 1
  : >"$CALLS"; set_count the_greatest books_books 60000
  ! run && [ "$(sequence)" = "start info stop restore up replay lsn amcheck amcheck dropext dropext dump list dump list stop fail " ] &&
    [[ "$(fail_message)" == *"the_greatest.books_books"* ]] && [[ "$(fail_message)" != *"the_greatest.users"* ]] &&
    [ "$(dumps_in daily | wc -l)" = 4 ]
}
t_small_table_move_ignored() {
  setup; set_count tgb user_list_books 5000; set_count tgb books 20000
  PGVERIFY_NOW=2026-11-02T12:00:00Z run || return 1
  # 5000 -> 9000 is under the 10,000-row floor on the new side; 20000 -> 21000 is exactly 5%.
  : >"$CALLS"; set_count tgb user_list_books 9000; set_count tgb books 21000
  PGVERIFY_NOW=2026-11-03T12:00:00Z run && ! called 'pgv/fail' || return 1
  # 21000 -> 22051 is more than 5%.
  : >"$CALLS"; set_count tgb books 22051
  { ! run && [[ "$(fail_message)" == *"tgb.books"* ]]; } || return 1
  # A big table that falls under the floor is the move to catch: 50000 -> 9000.
  setup; PGVERIFY_NOW=2026-11-02T12:00:00Z run || return 1
  : >"$CALLS"; set_count the_greatest users 9000
  PGVERIFY_NOW=2026-11-03T12:00:00Z run && return 1
  [[ "$(fail_message)" == *"the_greatest.users"* ]]
}
t_first_run_has_no_baseline() {
  setup
  [ ! -e "$PGVERIFY_ROOT/state/row-counts" ] && run && ! called 'pgv/fail' &&
    [ "$(wc -l <"$PGVERIFY_ROOT/state/row-counts")" = 10 ] &&
    grep -qx 'the_greatest.users 50000' "$PGVERIFY_ROOT/state/row-counts" &&
    grep -qx 'tgb.user_list_books 50000' "$PGVERIFY_ROOT/state/row-counts"
}
t_baseline_is_previous_night_even_after_alert() {
  setup; PGVERIFY_NOW=2026-11-02T12:00:00Z run || return 1
  : >"$CALLS"; set_count the_greatest music_albums 70000
  PGVERIFY_NOW=2026-11-03T12:00:00Z run && return 1
  grep -qx 'the_greatest.music_albums 70000' "$PGVERIFY_ROOT/state/row-counts" || return 1
  [ "$(grep -c 'pgv/fail' "$CALLS")" = 1 ] || return 1
  # The same count the next night is no change: one real change, one alert.
  : >"$CALLS"
  PGVERIFY_NOW=2026-11-04T12:00:00Z run && ! called 'pgv/fail' && called 'hc\.test/pgv$'
}
t_empty_core_table_leaves_baseline() {
  setup; run || return 1
  : >"$CALLS"; set_count the_greatest users 0
  ! run && grep -qx 'the_greatest.users 50000' "$PGVERIFY_ROOT/state/row-counts"
}
t_dump_uses_no_subscriptions() {
  setup
  run && [ "$(grep -c '^pg_dump .*-Fc --no-subscriptions ' "$CALLS")" = 2 ] &&
    called '^pg_dump .* the_greatest$' && called '^pg_dump .* tgb$'
}
t_empty_dump_pings_fail() {
  setup; export DUMP_MODE=empty
  ! run && [[ "$(fail_message)" == *empty* ]] && [ -z "$(dumps_in daily)" ] && ! called '^aws' && ! called 'hc\.test/pgv$'
}
t_unreadable_dump_pings_fail() {
  setup; upload_on; export LIST_EXIT=1
  ! run && [[ "$(fail_message)" == *unreadable* ]] && [ -z "$(dumps_in daily)" ] && ! called '^aws'
}
t_dump_failure_pings_fail() {
  setup; export DUMP_MODE=fail
  ! run && [[ "$(fail_message)" == *pg_dump* ]] && ! called '^aws'
}
t_upload_off_by_default() {
  setup
  { run && ! called '^aws' && ! called 'upload'; } || return 1
  setup; write_env ROLE=pgverify HC_PGVERIFY=https://hc.test/pgv PGVERIFY_REPO_BUCKET=b PGVERIFY_REPO_ENDPOINT=e \
    PGVERIFY_REPO_REGION=r PGVERIFY_REPO_PATH=/p PGVERIFY_REPO_KEY=k PGVERIFY_REPO_KEY_SECRET=s PGVERIFY_CIPHER_PASS=c
  run && ! called '^aws'
}
t_upload_on_uses_existing_names() {
  setup; upload_on
  run || return 1
  called '^aws s3 cp --only-show-errors /dumps/daily/postgres_the_greatest_backup_20261104T120000Z\.sql\.gz s3://dump-bucket/postgres_the_greatest_backup_20261104T120000Z\.sql\.gz$' &&
    called '^aws s3 cp --only-show-errors /dumps/daily/postgres_tgb_backup_20261104T120000Z\.sql\.gz s3://dump-bucket/postgres_tgb_backup_20261104T120000Z\.sql\.gz$' &&
    [ "$(sequence)" = "start info stop restore up replay lsn amcheck amcheck dropext dropext dump list dump list upload upload stop ok " ] &&
    [ "$(sort -u "$SANDBOX/log/aws-env")" = "dump-key-id dump-key-secret" ] &&
    [ "$(sort -u "$SANDBOX/log/aws-region")" = "dump-region-1" ] &&
    [ "$(sort -u "$SANDBOX/log/aws-endpoint")" = "https://dump.r2.test" ]
}
t_upload_needs_a_region() {
  setup; upload_on
  write_env ROLE=pgverify HC_PGVERIFY=https://hc.test/pgv PGVERIFY_REPO_BUCKET=b PGVERIFY_REPO_ENDPOINT=e \
    PGVERIFY_REPO_REGION=r PGVERIFY_REPO_PATH=/p PGVERIFY_REPO_KEY=k PGVERIFY_REPO_KEY_SECRET=s PGVERIFY_CIPHER_PASS=c \
    PGVERIFY_DUMP_BUCKET=dump-bucket PGVERIFY_DUMP_KEY=dk PGVERIFY_DUMP_KEY_SECRET=ds \
    PGVERIFY_DUMP_ENDPOINT=https://dump.r2.test PGVERIFY_UPLOAD_ENABLED=1
  ! run && [[ "$(fail_message)" == *PGVERIFY_DUMP_REGION* ]] && ! called '^pgbackrest' && ! called '^aws'
}
t_upload_needs_an_endpoint() {
  # The dump bucket is R2: without its endpoint the CLI would send the dumps to AWS.
  setup; write_env ROLE=pgverify HC_PGVERIFY=https://hc.test/pgv PGVERIFY_REPO_BUCKET=b PGVERIFY_REPO_ENDPOINT=e \
    PGVERIFY_REPO_REGION=r PGVERIFY_REPO_PATH=/p PGVERIFY_REPO_KEY=k PGVERIFY_REPO_KEY_SECRET=s PGVERIFY_CIPHER_PASS=c \
    PGVERIFY_DUMP_BUCKET=dump-bucket PGVERIFY_DUMP_KEY=dk PGVERIFY_DUMP_KEY_SECRET=ds PGVERIFY_DUMP_REGION=auto \
    PGVERIFY_UPLOAD_ENABLED=1
  ! run && [[ "$(fail_message)" == *PGVERIFY_DUMP_ENDPOINT* ]] && ! called '^pgbackrest' && ! called '^aws'
}
t_upload_endpoint_needs_https() {
  setup; write_env ROLE=pgverify HC_PGVERIFY=https://hc.test/pgv PGVERIFY_REPO_BUCKET=b PGVERIFY_REPO_ENDPOINT=e \
    PGVERIFY_REPO_REGION=r PGVERIFY_REPO_PATH=/p PGVERIFY_REPO_KEY=k PGVERIFY_REPO_KEY_SECRET=s PGVERIFY_CIPHER_PASS=c \
    PGVERIFY_DUMP_BUCKET=dump-bucket PGVERIFY_DUMP_KEY=dk PGVERIFY_DUMP_KEY_SECRET=ds PGVERIFY_DUMP_REGION=auto \
    PGVERIFY_DUMP_ENDPOINT=dump.r2.test PGVERIFY_UPLOAD_ENABLED=1
  ! run && [[ "$(fail_message)" == *https://* ]] && ! called '^pgbackrest' && ! called '^aws'
}
t_upload_failure_pings_fail() {
  setup; write_env ROLE=pgverify HC_PGVERIFY=https://hc.test/pgv PGVERIFY_REPO_BUCKET=b PGVERIFY_REPO_ENDPOINT=e \
    PGVERIFY_REPO_REGION=r PGVERIFY_REPO_PATH=/p PGVERIFY_REPO_KEY=k PGVERIFY_REPO_KEY_SECRET=s PGVERIFY_CIPHER_PASS=c \
    PGVERIFY_DUMP_BUCKET=dump-bucket PGVERIFY_DUMP_KEY=dk PGVERIFY_DUMP_KEY_SECRET=ds PGVERIFY_DUMP_REGION=r1 \
    PGVERIFY_DUMP_ENDPOINT=https://dump.r2.test PGVERIFY_UPLOAD_ENABLED=1
  export AWS_EXIT=1
  ! run && [[ "$(fail_message)" == *upload* ]] && [[ "$(fail_message)" != *dump-bucket* ]] && ! called 'hc\.test/pgv$' &&
    [ "$(cat "$SANDBOX/log/aws-calls")" = 3 ]
}
t_upload_retries_a_failed_attempt() {
  # R2 failed one multipart upload of two on 2026-11-08 (InvalidPart); a retry must save the night.
  setup; upload_on; export AWS_FAIL_TIMES=2
  run && called 'hc\.test/pgv$' && [ "$(cat "$SANDBOX/log/aws-calls")" = 4 ] &&
    [ "$(grep -c '^aws s3 cp .*postgres_the_greatest_backup' "$CALLS")" = 3 ]
}
t_upload_needs_its_settings() {
  setup; write_env ROLE=pgverify HC_PGVERIFY=https://hc.test/pgv PGVERIFY_REPO_BUCKET=b PGVERIFY_REPO_ENDPOINT=e \
    PGVERIFY_REPO_REGION=r PGVERIFY_REPO_PATH=/p PGVERIFY_REPO_KEY=k PGVERIFY_REPO_KEY_SECRET=s PGVERIFY_CIPHER_PASS=c \
    PGVERIFY_UPLOAD_ENABLED=1
  ! run && [[ "$(fail_message)" == *PGVERIFY_DUMP_BUCKET* ]] && ! called '^pgbackrest'
}
t_secrets_not_in_argv() {
  setup; upload_on; run
  ! grep -qE 'repo-key-secret|cipher-pass-xyz|dump-key-secret|dump-key-id|repo-key-id' "$CALLS"
}
t_prune_keeps_14_daily_12_monthly() {
  setup; adopted
  mkdir -p "$PGVERIFY_ROOT/dumps/daily" "$PGVERIFY_ROOT/dumps/monthly"
  local db d m
  for db in the_greatest tgb; do
    for d in $(seq 1 20); do touch "$PGVERIFY_ROOT/dumps/daily/postgres_${db}_backup_202610$(printf %02d "$d")T120000Z.sql.gz"; done
    for m in $(seq 1 15); do touch "$PGVERIFY_ROOT/dumps/monthly/postgres_${db}_backup_20250101T$(printf %02d "$m")0000Z.sql.gz"; done
  done
  touch "$PGVERIFY_ROOT/dumps/daily/notes.txt" "$PGVERIFY_ROOT/dumps/daily/postgres_other_backup_20200101T000000Z.sql.gz"
  run || return 1
  [ "$(dumps_in daily | grep -c '^postgres_the_greatest_backup_')" = 14 ] &&
    [ "$(dumps_in daily | grep -c '^postgres_tgb_backup_')" = 14 ] &&
    [ "$(dumps_in monthly | grep -c '^postgres_the_greatest_backup_')" = 12 ] &&
    [ "$(dumps_in monthly | grep -c '^postgres_tgb_backup_')" = 12 ] &&
    [ -e "$PGVERIFY_ROOT/dumps/daily/postgres_the_greatest_backup_20261104T120000Z.sql.gz" ] &&
    [ -e "$PGVERIFY_ROOT/dumps/daily/postgres_tgb_backup_20261020T120000Z.sql.gz" ] &&
    [ ! -e "$PGVERIFY_ROOT/dumps/daily/postgres_tgb_backup_20261007T120000Z.sql.gz" ] &&
    [ -e "$PGVERIFY_ROOT/dumps/daily/postgres_tgb_backup_20261008T120000Z.sql.gz" ] &&
    [ ! -e "$PGVERIFY_ROOT/dumps/monthly/postgres_tgb_backup_20250101T040000Z.sql.gz" ] &&
    [ -e "$PGVERIFY_ROOT/dumps/monthly/postgres_tgb_backup_20250101T050000Z.sql.gz" ] &&
    [ -e "$PGVERIFY_ROOT/dumps/monthly/postgres_tgb_backup_20261104T120000Z.sql.gz" ] &&
    [ -e "$PGVERIFY_ROOT/dumps/monthly/postgres_the_greatest_backup_20250101T150000Z.sql.gz" ] &&
    [ -e "$PGVERIFY_ROOT/dumps/daily/notes.txt" ] &&
    [ -e "$PGVERIFY_ROOT/dumps/daily/postgres_other_backup_20200101T000000Z.sql.gz" ]
}
t_first_success_of_the_month_copies_monthly() {
  setup
  local both; both="$(printf 'postgres_tgb_backup_20261104T120000Z.sql.gz\npostgres_the_greatest_backup_20261104T120000Z.sql.gz')"
  run && [ "$(dumps_in monthly)" = "$both" ] && [ -s "$PGVERIFY_ROOT/dumps/monthly/postgres_tgb_backup_20261104T120000Z.sql.gz" ]
}
t_month_with_a_copy_is_left_alone() {
  setup; adopted; mkdir -p "$PGVERIFY_ROOT/dumps/monthly"
  touch "$PGVERIFY_ROOT/dumps/monthly/postgres_tgb_backup_20261101T120000Z.sql.gz"
  run || return 1
  # tgb already has November; the_greatest does not.
  [ "$(dumps_in monthly)" = "$(printf 'postgres_tgb_backup_20261101T120000Z.sql.gz\npostgres_the_greatest_backup_20261104T120000Z.sql.gz')" ]
}
t_a_failed_first_does_not_cost_the_month() {
  setup; PGVERIFY_NOW=2026-11-01T12:00:00Z DUMP_MODE=fail run && return 1
  [ -z "$(dumps_in monthly)" ] || return 1
  PGVERIFY_NOW=2026-11-02T12:00:00Z run && [ "$(dumps_in monthly | wc -l)" = 2 ]
}
t_failed_dump_prunes_nothing() {
  setup; adopted; mkdir -p "$PGVERIFY_ROOT/dumps/daily"
  local d
  for d in $(seq 1 16); do touch "$PGVERIFY_ROOT/dumps/daily/postgres_tgb_backup_202610$(printf %02d "$d")T120000Z.sql.gz"; done
  export DUMP_MODE=empty
  ! run && [ "$(dumps_in daily | wc -l)" = 16 ]
}
t_sunday_restore_starts_from_empty() {
  setup; adopted; export PGVERIFY_NOW=$SUNDAY
  mkdir -p "$PGVERIFY_ROOT/pgdata/base"; touch "$PGVERIFY_ROOT/pgdata/PG_VERSION" "$PGVERIFY_ROOT/pgdata/stale-file"
  run && called '^pgbackrest .* restore' && ! called '^pgbackrest .*--delta' &&
    [ ! -e "$PGVERIFY_ROOT/pgdata/stale-file" ] && [ ! -e "$PGVERIFY_ROOT/pgdata/base" ]
}
t_weekday_uses_delta() {
  setup; adopted
  mkdir -p "$PGVERIFY_ROOT/pgdata"; touch "$PGVERIFY_ROOT/pgdata/PG_VERSION" "$PGVERIFY_ROOT/pgdata/kept-file"
  run && called '^pgbackrest .*restore --delta ' && [ -e "$PGVERIFY_ROOT/pgdata/kept-file" ]
}
t_first_ever_run_restores_into_an_empty_directory() {
  setup
  run && called '^pgbackrest .* restore' && ! called '^pgbackrest .*--delta'
}
t_restore_never_archives() {
  setup; adopted; mkdir -p "$PGVERIFY_ROOT/pgdata"; touch "$PGVERIFY_ROOT/pgdata/PG_VERSION"
  { run && called '^pgbackrest .*--stanza=main restore .*--archive-mode=off' && called '^pgbackrest .*--stanza=main restore .*--delta'; } || return 1
  setup; export PGVERIFY_NOW=$SUNDAY
  run && called '^pgbackrest .*--stanza=main restore .*--archive-mode=off'
}
t_lock_held_exits_without_ping() {
  setup
  flock "$PGVERIFY_LOCK" sleep 3 &
  sleep 0.5
  run; rc=$?
  wait
  [ "$rc" = 0 ] && ! called '^curl ' && ! called '^compose ' && ! called '^pgbackrest' && grep -q 'holds' "$SANDBOX/log/out"
}
t_interrupted_restore_recovers() {
  setup; adopted
  mkdir -p "$PGVERIFY_ROOT/pgdata/base" "$PGVERIFY_ROOT/state"
  touch "$PGVERIFY_ROOT/pgdata/PG_VERSION" "$PGVERIFY_ROOT/pgdata/half-copied" "$PGVERIFY_ROOT/state/restore-in-progress"
  run && called '^pgbackrest .* restore' && ! called '^pgbackrest .*--delta' &&
    [ ! -e "$PGVERIFY_ROOT/pgdata/half-copied" ] && [ ! -e "$PGVERIFY_ROOT/state/restore-in-progress" ]
}
t_marker_written_before_the_restore() {
  setup
  stub pgbackrest 'case "$*" in *" info"*) printf "[{\"name\":\"main\",\"archive\":[{\"max\":\"000000010000000000000010\"}]}]\n" ;; *" restore"*) [ -f "$PGVERIFY_ROOT/state/restore-in-progress" ] && echo MARKER >>"$SANDBOX/log/marker-seen"; mkdir -p "$PGVERIFY_ROOT/pgdata"; touch "$PGVERIFY_ROOT/pgdata/PG_VERSION" ;; esac'
  run && [ -f "$SANDBOX/log/marker-seen" ] && [ ! -e "$PGVERIFY_ROOT/state/restore-in-progress" ]
}
t_workers_disabled() {
  setup
  # The server is started with the flags (compose.pgverify.yml) and the script checks what it got.
  local compose="$HS_DIR/compose.pgverify.yml" s
  grep -q 'archive_mode=off' "$compose" && grep -q 'max_logical_replication_workers=0' "$compose" &&
    grep -q 'ssl=off' "$compose" && grep -q 'listen_addresses=' "$compose" || return 1
  run && called "^psql .*current_setting\('archive_mode'\).*current_setting\('max_logical_replication_workers'\)" || return 1
  # Each of the three settings, wrong on its own, fails the run before any dump.
  for s in 'on,0,' 'off,4,' 'off,0,0.0.0.0' 'off,0,127.0.0.1'; do
    setup; export SETTINGS=$s
    if run || called '^pg_dump' || [[ "$(fail_message)" != *"settings"* ]]; then echo "settings $s passed" >&2; return 1; fi
  done
}
t_postgres_stopped_on_failure() {
  setup; export AMCHECK_EXIT=2
  ! run && [ "$(grep -c '^compose stop' "$CALLS")" = 2 ] && called '^compose up'
}
t_recovery_that_never_finishes_fails() {
  setup; export ISREADY_EXIT=1 PGVERIFY_RECOVERY_TIMEOUT_S=0
  ! run && [[ "$(fail_message)" == *recover* ]] && ! called '^psql'
}
t_postgres_exiting_fails() {
  setup; export ISREADY_EXIT=1 PG_EXITED=1
  ! run && [[ "$(fail_message)" == *exited* ]] && ! called '^pg_dump'
}
t_not_mounted_fails() {
  setup; export NOT_MOUNTED=1
  ! run && [[ "$(fail_message)" == *"not mounted"* ]] && ! called '^pgbackrest'
}
t_missing_settings_fail_naming_them() {
  setup; write_env ROLE=pgverify HC_PGVERIFY=https://hc.test/pgv PGVERIFY_REPO_BUCKET=b
  ! run && [[ "$(fail_message)" == *PGVERIFY_REPO_ENDPOINT*PGVERIFY_CIPHER_PASS* ]] && ! called '^pgbackrest' &&
    [[ "$(fail_message)" != *b\ * ]]
}
t_pings_carry_no_bucket_or_path() {
  setup; export REPLAY_AGE=null AMCHECK_EXIT=2
  run && return 1
  local m; m="$(fail_message)"
  [ -n "$m" ] && ! grep -qE 'repo-bucket|dump-bucket|/repo-path|/mnt|pgv/|key' <<<"$m" || return 1
  setup; export RESTORE_EXIT=1
  run && return 1
  m="$(fail_message)"
  [ -n "$m" ] && ! grep -qE 'repo-bucket|dump-bucket|/repo-path|/mnt|key' <<<"$m"
}
t_pgbackrest_config_is_private_and_read_only_repo() {
  setup; run || return 1
  local conf="$PGVERIFY_ROOT/config/pgbackrest.conf"
  [ "$(stat -c %a "$conf")" = 600 ] && grep -qx 'repo1-s3-key=repo-key-id' "$conf" &&
    grep -qx 'repo1-s3-key-secret=repo-key-secret' "$conf" && grep -qx 'repo1-cipher-pass=cipher-pass-xyz' "$conf" &&
    grep -qx 'repo1-cipher-type=aes-256-cbc' "$conf" && grep -qx 'repo1-s3-bucket=repo-bucket' "$conf" &&
    grep -qx 'pg1-path=/var/lib/postgresql/18/docker' "$conf" && ! grep -q 'archive-push\|expire' "$conf"
}
# The guards around "empty the data directory": none of these may delete anything.
t_wrong_root_cannot_delete() {
  setup; export PGVERIFY_NOW=$SUNDAY
  # A directory with something in it that is not this job's: not adopted, not emptied.
  rm -rf "$PGVERIFY_ROOT"; mkdir -p "$PGVERIFY_ROOT/pgdata"
  touch "$PGVERIFY_ROOT/precious" "$PGVERIFY_ROOT/pgdata/precious-too"
  ! run && [ -e "$PGVERIFY_ROOT/precious" ] && [ -e "$PGVERIFY_ROOT/pgdata/precious-too" ] && ! called '^pgbackrest' &&
    [ ! -e "$PGVERIFY_ROOT/.pgverify-data" ] && called 'pgv/fail$' || return 1
  # Not an absolute path, a path with .., and the shallow ones.
  local bad
  for bad in "relative/dir" "$SANDBOX/pgv/../pgv" "/" "/mnt"; do
    setup; export PGVERIFY_NOW=$SUNDAY PGVERIFY_ROOT="$bad"
    if run || called '^pgbackrest' || ! called 'pgv/fail$'; then echo "refused-case failed: $bad" >&2; return 1; fi
  done
}
t_symlinked_data_directory_is_refused() {
  setup; export PGVERIFY_NOW=$SUNDAY
  mkdir -p "$SANDBOX/elsewhere"; touch "$SANDBOX/elsewhere/precious"
  echo pgverify >"$PGVERIFY_ROOT/.pgverify-data"
  ln -s "$SANDBOX/elsewhere" "$PGVERIFY_ROOT/pgdata"
  ! run && [ -e "$SANDBOX/elsewhere/precious" ] && ! called '^pgbackrest' && called 'pgv/fail$'
}
t_empty_disk_is_adopted_once() {
  setup; mkdir -p "$PGVERIFY_ROOT/lost+found"
  run && [ -f "$PGVERIFY_ROOT/.pgverify-data" ] && [ -d "$PGVERIFY_ROOT/dumps/daily" ] && [ -d "$PGVERIFY_ROOT/dumps/monthly" ]
}
t_static_config_is_local_only() {
  local d="$HS_DIR/pgverify"
  [ "$(grep -v '^#' "$d/pg_hba.conf" | grep -v '^$')" = "local all postgres peer" ] &&
    grep -qx "listen_addresses = ''" "$d/postgresql.conf" && grep -qx 'hot_standby = off' "$d/postgresql.conf" &&
    ! grep -qE '^archive_command|^primary_conninfo' "$d/postgresql.conf" &&
    grep -qE '^shared_buffers = (512MB|1GB|2GB)$' "$d/postgresql.conf"
}
t_timer_is_noon_utc() {
  grep -qx 'OnCalendar=\*-\*-\* 12:00:00 UTC' "$HS_DIR/guest/systemd/pg-restore-verify.timer" &&
    grep -qx 'Persistent=true' "$HS_DIR/guest/systemd/pg-restore-verify.timer" &&
    grep -q 'pg-restore-verify.sh' "$HS_DIR/guest/systemd/pg-restore-verify.service"
}

# --- recovery that ends early must not pass --------------------------------------------------------
t_recovery_stopped_short_of_the_archive_fails() {
  # The archive's newest segment is ...10; replay reached ...0F, the last byte of the segment before it
  # (the missing segment's own start would have been the LSN, one byte later: the off-by-one the check avoids).
  setup; export REPLAY_SEG=000000000000000F
  ! run && [[ "$(fail_message)" == *"stopped short"* ]] && ! called '^pg_amcheck' && ! called '^pg_dump' && ! called 'hc\.test/pgv$'
}
t_complete_recovery_passes_the_archive_check() {
  setup; run && ! called 'pgv/fail' || return 1
  # Replay past the archive's maximum (a segment archived after the info read) is fine.
  setup; export REPLAY_SEG=0000000000000011
  run && ! called 'pgv/fail' || return 1
  # The timeline differs between the archive and the cluster after recovery: only log and segment compare.
  setup; export ARCHIVE_MAX=000000020000000000000010
  run && ! called 'pgv/fail'
}
t_replay_position_uses_the_last_byte_replayed() {
  setup; run && called "^psql .*pg_walfile_name\(pg_last_wal_replay_lsn\(\) - 1\)"
}
t_no_archive_in_the_repo_fails_before_restoring() {
  setup; export ARCHIVE_MAX=
  ! run && [[ "$(fail_message)" == *"no archived WAL"* ]] && ! called '^pgbackrest .* restore' &&
    [ ! -e "$PGVERIFY_ROOT/state/restore-in-progress" ] || return 1
  setup; export INFO_EXIT=1
  ! run && ! called '^pgbackrest .* restore'
}
t_archive_is_read_before_the_restore() {
  setup; run || return 1
  local info restore
  info="$(grep -n '^pgbackrest .* info --output=json' "$CALLS" | head -1 | cut -d: -f1)"
  restore="$(grep -n '^pgbackrest .* restore' "$CALLS" | head -1 | cut -d: -f1)"
  [ -n "$info" ] && [ -n "$restore" ] && [ "$info" -lt "$restore" ]
}
# The wrapper Postgres runs as restore_command: only "not found" may mean "no more WAL".
wrapper_rc() { # wrapper_rc <pgbackrest exit>
  stub pgbackrest "exit $1"
  "$HS_DIR/pgverify/archive-get.sh" 000000010000000000000008 pg_wal/RECOVERYXLOG
}
t_restore_command_wrapper_separates_not_found_from_errors() {
  setup
  wrapper_rc 0 && true || return 1
  local rc
  rc=0; wrapper_rc 1 || rc=$?; [ "$rc" = 1 ] || return 1
  # 42 (read error), 55 (missing control file), 82 (anything else): all abort recovery (above 125).
  for code in 42 55 82 99 124 125 126 127 137; do
    rc=0; wrapper_rc "$code" || rc=$?
    [ "$rc" -gt 125 ] || { echo "pgbackrest exit $code became $rc" >&2; return 1; }
  done
  # The arguments reach pgBackRest unchanged.
  : >"$CALLS"; wrapper_rc 0
  called '^pgbackrest --stanza=main archive-get 000000010000000000000008 pg_wal/RECOVERYXLOG$'
}
t_restore_command_is_forced_on_the_server() {
  grep -q 'restore_command=/etc/pgverify-static/archive-get.sh %f %p' "$HS_DIR/compose.pgverify.yml" &&
    [ -x "$HS_DIR/pgverify/archive-get.sh" ]
}

# --- the row-count alert survives other failures -------------------------------------------------
t_row_alert_rides_on_a_later_failure_and_the_baseline_waits() {
  setup; PGVERIFY_NOW=2026-11-02T12:00:00Z run || return 1
  : >"$CALLS"; set_count the_greatest users 20000   # a 60% fall
  PGVERIFY_NOW=2026-11-03T12:00:00Z DUMP_MODE=fail run && return 1
  [[ "$(fail_message)" == *pg_dump* ]] && [[ "$(fail_message)" == *"the_greatest.users"* ]] || return 1
  # The failed night leaves the baseline: the next night still sees the fall, and alerts again.
  grep -qx 'the_greatest.users 50000' "$PGVERIFY_ROOT/state/row-counts" || return 1
  : >"$CALLS"
  PGVERIFY_NOW=2026-11-04T12:00:00Z run && return 1
  [[ "$(fail_message)" == *"the_greatest.users"* ]] || return 1
  # That run finished, so the baseline moved and the night after is clean.
  grep -qx 'the_greatest.users 20000' "$PGVERIFY_ROOT/state/row-counts" || return 1
  : >"$CALLS"
  PGVERIFY_NOW=2026-11-05T12:00:00Z run && ! called 'pgv/fail'
}
t_baseline_is_written_after_the_dumps() {
  setup; stub pg_dump 'echo PGDMP >"$PGVERIFY_ROOT${@: -2:1}"; [ ! -e "$PGVERIFY_ROOT/state/row-counts" ] && echo none-yet >>"$SANDBOX/log/baseline-order"'
  run && [ -s "$SANDBOX/log/baseline-order" ] && [ -f "$PGVERIFY_ROOT/state/row-counts" ]
}
t_a_failed_baseline_write_pings_fail() {
  setup; adopted; mkdir -p "$PGVERIFY_ROOT/state/row-counts.new"   # the write cannot create its file
  ! run && [[ "$(fail_message)" == *baseline* ]] && ! called 'hc\.test/pgv$'
}

# --- no silent exits ------------------------------------------------------------------------------
t_a_failed_install_pings_fail() {
  setup; adopted; touch "$PGVERIFY_ROOT/state"   # install -d on the state directory fails after the start ping
  ! run && [ "$(grep -c 'pgv/fail' "$CALLS")" = 1 ] && [[ "$(fail_message)" == *"data disk"* ]] && ! called 'hc\.test/pgv$'
}
t_an_unguarded_failure_pings_fail_once() {
  # No fail() call covers the write of the pgBackRest config: set -e ends the run, and the exit trap reports.
  setup; adopted; mkdir -p "$PGVERIFY_ROOT/config/pgbackrest.conf.new"   # the redirect cannot open its file
  ! run && [ "$(grep -c 'pgv/fail' "$CALLS")" = 1 ] && [[ "$(fail_message)" == *"aborted"* ]] && ! called '^pgbackrest'
}
t_a_reported_failure_is_not_reported_twice() {
  setup; export AMCHECK_EXIT=2
  ! run && [ "$(grep -c 'pgv/fail' "$CALLS")" = 1 ] && [[ "$(fail_message)" == *amcheck* ]] && [[ "$(fail_message)" != *aborted* ]]
}
t_term_pings_fail_and_stops_postgres() {
  setup
  stub pgbackrest 'case "$*" in *" restore"*) sleep 2 ;; *" info"*) printf "[{\"name\":\"main\",\"archive\":[{\"max\":\"000000010000000000000010\"}]}]\n" ;; esac'
  "$GUEST/pg-restore-verify.sh" >"$SANDBOX/log/out" 2>&1 &
  local pid=$!
  sleep 1
  kill -TERM "$pid"
  local rc=0; wait "$pid" || rc=$?
  [ "$rc" = 143 ] && [ "$(grep -c 'pgv/fail' "$CALLS")" = 1 ] && [[ "$(fail_message)" == *"exit 143"* ]] && ! called 'hc\.test/pgv$' &&
    ! called '^pg_dump'
}
t_term_after_postgres_started_stops_it() {
  setup
  stub psql 'sleep 2; echo f'
  "$GUEST/pg-restore-verify.sh" >"$SANDBOX/log/out" 2>&1 &
  local pid=$!
  sleep 1
  kill -TERM "$pid"
  local rc=0; wait "$pid" || rc=$?
  [ "$rc" = 143 ] && called '^compose up' && [ "$(grep -c '^compose stop' "$CALLS")" = 2 ] && [[ "$(fail_message)" == *"exit 143"* ]]
}
# The ping goes first: the stop can take the whole grace period, and systemd may kill the unit during it.
t_term_pings_before_stopping_postgres() {
  setup
  stub psql 'sleep 2; echo f'
  "$GUEST/pg-restore-verify.sh" >"$SANDBOX/log/out" 2>&1 &
  local pid=$!
  sleep 1
  kill -TERM "$pid"
  wait "$pid"
  local seq; seq="$(sequence)"
  [[ "$seq" == *"up fail stop "* ]] || { echo "$seq"; return 1; }
}
t_lock_held_still_exits_quietly() {
  # The exit trap must not report a run that never started.
  setup
  flock "$PGVERIFY_LOCK" sleep 2 &
  sleep 0.5
  run; local rc=$?
  wait
  [ "$rc" = 0 ] && ! called '^curl '
}

# --- free disk, before the dumps ------------------------------------------------------------------------
# A set of dumps of the given size in daily/, one per database.
dumps_of_kb() {
  mkdir -p "$PGVERIFY_ROOT/dumps/daily"
  dd if=/dev/zero of="$PGVERIFY_ROOT/dumps/daily/postgres_the_greatest_backup_20261103T120000Z.sql.gz" bs=1024 count="$1" 2>/dev/null
  dd if=/dev/zero of="$PGVERIFY_ROOT/dumps/daily/postgres_tgb_backup_20261103T120000Z.sql.gz" bs=1024 count="$1" 2>/dev/null
}
t_low_disk_fails_before_dumping() {
  setup; adopted; dumps_of_kb 1000; export FREE_KB=1500
  ! run && [[ "$(fail_message)" == *"free disk"* ]] && ! called '^pg_dump' && called '^compose stop' &&
    [ -f "$PGVERIFY_ROOT/dumps/daily/postgres_tgb_backup_20261103T120000Z.sql.gz" ] &&
    [[ "$(fail_message)" != *"$PGVERIFY_ROOT"* ]]
}
t_room_for_one_night_passes() {
  setup; adopted; dumps_of_kb 1000; export FREE_KB=2500
  run && called '^pg_dump' && called 'hc\.test/pgv$'
}
t_first_night_uses_the_floor() {
  setup; export FREE_KB=1000000
  ! run && [[ "$(fail_message)" == *"free disk"* ]] && ! called '^pg_dump' || return 1
  setup; export FREE_KB=9000000
  run && called '^pg_dump'
}
t_unreadable_free_disk_fails() {
  setup; stub df 'exit 1'
  ! run && [[ "$(fail_message)" == *"free disk"* ]] && ! called '^pg_dump'
}
t_success_message_reports_free_disk() {
  setup; export FREE_KB=209715200
  run && called '^curl .*--data-raw .*200 GB free.* https://hc\.test/pgv$'
}

# --- a hard kill leaves postmaster.pid ----------------------------------------------------------------
t_stale_postmaster_pid_is_removed_before_a_delta_restore() {
  setup; adopted; mkdir -p "$PGVERIFY_ROOT/pgdata"; touch "$PGVERIFY_ROOT/pgdata/PG_VERSION" "$PGVERIFY_ROOT/pgdata/postmaster.pid"
  run && called '^pgbackrest .*restore --delta' && [ ! -e "$SANDBOX/log/pid-seen" ]
}
t_a_server_that_will_not_stop_fails_before_the_restore() {
  setup; adopted; mkdir -p "$PGVERIFY_ROOT/pgdata"; touch "$PGVERIFY_ROOT/pgdata/PG_VERSION" "$PGVERIFY_ROOT/pgdata/postmaster.pid"
  export COMPOSE_STOP_EXIT=1
  ! run && [[ "$(fail_message)" == *"stop postgres"* ]] && ! called '^pgbackrest .* restore' && [ -e "$PGVERIFY_ROOT/pgdata/postmaster.pid" ]
}

check "happy path: start, restore, checks, dumps, success ping last" t_happy_path_sequence
check "t_restore_fail_pings_fail" t_restore_fail_pings_fail
check "t_replay_over_26h_old_pings_fail" t_replay_over_26h_old_pings_fail
check "a null replay timestamp fails with its own reason" t_replay_null_pings_fail
check "t_core_table_empty_stops_before_dumps" t_core_table_empty_stops_before_dumps
check "a core table that does not exist is a failure" t_core_table_missing_fails
check "a missing database is a failure" t_database_missing_fails
check "t_amcheck_fail_pings_fail" t_amcheck_fail_pings_fail
check "pg_amcheck installs what it needs and is scoped to the core tables" t_amcheck_scoped_and_installed
check "t_amcheck_removed_before_dump" t_amcheck_removed_before_dump
check "t_row_count_move_finishes_dumps_then_pings_fail_naming_table" t_row_count_move_finishes_dumps_then_pings_fail_naming_table
check "t_small_table_move_ignored (and the 5% boundary)" t_small_table_move_ignored
check "t_first_run_has_no_baseline" t_first_run_has_no_baseline
check "t_baseline_is_previous_night_even_after_alert" t_baseline_is_previous_night_even_after_alert
check "a run stopped by an empty core table leaves the baseline alone" t_empty_core_table_leaves_baseline
check "t_dump_uses_no_subscriptions" t_dump_uses_no_subscriptions
check "t_empty_dump_pings_fail" t_empty_dump_pings_fail
check "t_unreadable_dump_pings_fail" t_unreadable_dump_pings_fail
check "a failing pg_dump pings fail" t_dump_failure_pings_fail
check "t_upload_off_by_default" t_upload_off_by_default
check "t_upload_on_uses_existing_names" t_upload_on_uses_existing_names
check "a failed upload pings fail without naming the bucket" t_upload_failure_pings_fail
check "upload enabled without its settings fails before any restore" t_upload_needs_its_settings
check "upload enabled without a region fails before any restore" t_upload_needs_a_region
check "upload enabled without the dump bucket's endpoint fails before any restore" t_upload_needs_an_endpoint
check "an upload endpoint without https:// fails before any restore" t_upload_endpoint_needs_https
check "no secret reaches a command line" t_secrets_not_in_argv
check "t_prune_keeps_14_daily_12_monthly" t_prune_keeps_14_daily_12_monthly
check "the first successful run of a month copies the dumps to monthly" t_first_success_of_the_month_copies_monthly
check "a month that already has a copy is left alone, per database" t_month_with_a_copy_is_left_alone
check "a failed first of the month does not cost the month" t_a_failed_first_does_not_cost_the_month
check "a run whose dumps failed prunes nothing" t_failed_dump_prunes_nothing
check "t_sunday_restore_starts_from_empty" t_sunday_restore_starts_from_empty
check "t_weekday_uses_delta" t_weekday_uses_delta
check "a first run into an empty directory is a plain restore" t_first_ever_run_restores_into_an_empty_directory
check "every restore passes --archive-mode=off" t_restore_never_archives
check "t_lock_held_exits_without_ping" t_lock_held_exits_without_ping
check "t_interrupted_restore_recovers" t_interrupted_restore_recovers
check "the marker exists during the restore and is gone after it" t_marker_written_before_the_restore
check "t_workers_disabled" t_workers_disabled
check "postgres is stopped after a failed run too" t_postgres_stopped_on_failure
check "a recovery that never finishes fails" t_recovery_that_never_finishes_fails
check "postgres exiting during recovery fails" t_postgres_exiting_fails
check "an unmounted data disk fails before anything runs" t_not_mounted_fails
check "missing settings fail naming the variables, not their values" t_missing_settings_fail_naming_them
check "ping messages carry no bucket, key or path" t_pings_carry_no_bucket_or_path
check "the rendered pgBackRest config is 0600 with the read-only key and the cipher" t_pgbackrest_config_is_private_and_read_only_repo
check "a wrong data path cannot delete anything" t_wrong_root_cannot_delete
check "a symlinked data directory is refused" t_symlinked_data_directory_is_refused
check "a pristine mounted disk is adopted" t_empty_disk_is_adopted_once
check "the restored cluster's config is local-only" t_static_config_is_local_only
check "the timer runs at 12:00 UTC and catches up" t_timer_is_noon_utc
check "recovery that stopped short of the archive's newest segment fails" t_recovery_stopped_short_of_the_archive_fails
check "a complete recovery passes, including replay past the maximum and a different timeline" t_complete_recovery_passes_the_archive_check
check "the replay position is the last byte replayed" t_replay_position_uses_the_last_byte_replayed
check "a repository with no archive fails before any restore" t_no_archive_in_the_repo_fails_before_restoring
check "the archive's newest segment is read before the restore" t_archive_is_read_before_the_restore
check "the restore_command wrapper passes not-found through and aborts recovery on any other error" t_restore_command_wrapper_separates_not_found_from_errors
check "the wrapper is forced as restore_command on the server" t_restore_command_is_forced_on_the_server
check "a row-count alert rides on a later failure, and the baseline waits for a finished run" t_row_alert_rides_on_a_later_failure_and_the_baseline_waits
check "the baseline is written after the dumps" t_baseline_is_written_after_the_dumps
check "a failed baseline write pings fail" t_a_failed_baseline_write_pings_fail
check "a failed upload attempt is retried and the night passes" t_upload_retries_a_failed_attempt
check "a failed install pings fail" t_a_failed_install_pings_fail
check "an unguarded failure pings fail once, from the exit trap" t_an_unguarded_failure_pings_fail_once
check "a reported failure is not reported again" t_a_reported_failure_is_not_reported_twice
check "TERM pings fail and exits 143" t_term_pings_fail_and_stops_postgres
check "TERM with Postgres up stops it" t_term_after_postgres_started_stops_it
check "TERM pings before it stops Postgres" t_term_pings_before_stopping_postgres
check "a held lock still exits quietly" t_lock_held_still_exits_quietly
check "too little free disk for a night's dumps fails before dumping" t_low_disk_fails_before_dumping
check "room for one night's dumps passes" t_room_for_one_night_passes
check "a first night with no dumps yet is measured against the floor" t_first_night_uses_the_floor
check "free disk that cannot be read is a failure" t_unreadable_free_disk_fails
check "the success ping reports free disk" t_success_message_reports_free_disk
check "a stale postmaster.pid is removed before a delta restore" t_stale_postmaster_pid_is_removed_before_a_delta_restore
check "a server that will not stop fails before the restore" t_a_server_that_will_not_stop_fails_before_the_restore
finish
