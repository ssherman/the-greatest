#!/usr/bin/env bash
# Unit test for deployment/postgres/bin/check-backup-health.sh. Docker, df and curl are stubbed; the
# docker stub answers from files under $SANDBOX/state.
# shellcheck disable=SC2016  # stub bodies are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
mkdir -p "$SANDBOX/state" "$SANDBOX/srv/state"
stub docker 'st="$SANDBOX/state"
if [ -e "$st/docker_slow" ]; then sleep 30; fi
if [ -e "$st/docker_down" ]; then echo "Cannot connect to the Docker daemon (SECRETBUCKET)" >&2; exit 1; fi
case "$*" in
  *psql*) if [ -e "$st/psql_down" ]; then echo "psql: connection refused" >&2; exit 2; fi; echo "$(cat "$st/failed_count")|$(cat "$st/archive_mode")|$(cat "$st/archive_command")" ;;
  *find*) cat "$st/ready"; exit "$(cat "$st/find_rc")" ;;
esac'
stub df 'cat "$SANDBOX/state/df"'
stub curl 'url=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in --data-raw) data="$2"; shift ;; http*) url="$1" ;; esac
  shift
done
if [ -e "$SANDBOX/state/curl_fails" ]; then exit 22; fi
suffix="${url#http://hc.test/SECRETPING}"; suffix="${suffix#/}"
printf "%s|%s\n" "${suffix:-success}" "$data" >>"$SANDBOX/log/pings"'

export STATE_DIR="$SANDBOX/srv" REPO_DIR="$SANDBOX/repo" HC_PG_HEALTH="http://hc.test/SECRETPING"
CHECK="$BIN/check-backup-health.sh"
COUNT_FILE="$SANDBOX/srv/state/archive-failed-count"
scenario() {   # a healthy server unless a test changes it
  local st="$SANDBOX/state"
  rm -f "${st:?}"/* "$COUNT_FILE" "$SANDBOX/log/pings" "$SANDBOX/log/out"
  rmdir "$COUNT_FILE.tmp" 2>/dev/null
  echo 0 >"$st/failed_count"; : >"$st/ready"; echo 0 >"$st/find_rc"
  echo on >"$st/archive_mode"; echo 'pgbackrest --stanza=main archive-push %p' >"$st/archive_command"
  printf 'Use%%\n 42%%\n' >"$st/df"
  : >"$CALLS"; : >"$SANDBOX/log/pings"
}
run_check() { "$CHECK" >"$SANDBOX/log/out" 2>&1; rc=$?; }
out() { cat "$SANDBOX/log/out"; }
pings() { cat "$SANDBOX/log/pings"; }
passed() { [ "$rc" = 0 ] && [ "$(pings)" = "success|ok" ]; }
failed_with() { [ "$rc" != 0 ] && grep -q '^fail|' "$SANDBOX/log/pings" && ! grep -q '^success|' "$SANDBOX/log/pings" && { [ -z "${1:-}" ] || grep -qi "^fail|.*$1" "$SANDBOX/log/pings"; }; }

scenario; run_check
if passed; then pass "a healthy server pings success once"; else fail "healthy" "rc=$rc $(pings) $(out)"; fi
if called 'docker compose -f .*/repo/compose.yml exec -T postgres'; then pass "reaches the container through the compose file in REPO_DIR"; else fail "compose path" "$(cat "$CALLS")"; fi
if called 'find .*archive_status'; then pass "the .ready check looks under pg_wal/archive_status"; else fail "archive_status" "$(cat "$CALLS")"; fi
if called 'PGDATA'; then pass "...under the image's data path, not a guessed one"; else fail "PGDATA" "$(cat "$CALLS")"; fi

# --- .ready files ---------------------------------------------------------------------------------------------------
scenario; echo "/var/lib/postgresql/18/docker/pg_wal/archive_status/000000010000000000000042.ready" >"$SANDBOX/state/ready"
run_check
if failed_with 'archive'; then pass "t_ready_file_older_than_15_min_fails"; else fail "t_ready_file_older_than_15_min_fails" "rc=$rc $(pings)"; fi
if called '[-]mmin [+]15'; then pass "the threshold is 15 minutes"; else fail "threshold" "$(cat "$CALLS")"; fi
scenario; : >"$SANDBOX/state/ready"
run_check
if passed; then pass "t_ready_file_newer_passes: a file waiting a few minutes is normal"; else fail "t_ready_file_newer_passes" "rc=$rc $(pings)"; fi
scenario; echo 1 >"$SANDBOX/state/find_rc"
run_check
if failed_with; then pass "a failing queue check fails, never passes"; else fail "find failing" "rc=$rc $(pings)"; fi

# --- archive failure count --------------------------------------------------------------------------------------------
scenario; echo 7 >"$SANDBOX/state/failed_count"
run_check
if passed && [ "$(cat "$COUNT_FILE")" = 7 ] && [ "$(stat -c %a "$COUNT_FILE")" = 600 ]; then
  pass "t_first_run_no_stored_count_passes: passes and stores the count (0600)"; else fail "t_first_run_no_stored_count_passes" "rc=$rc $(pings) $(cat "$COUNT_FILE" 2>&1)"; fi
echo 9 >"$SANDBOX/state/failed_count"; : >"$SANDBOX/log/pings"
run_check
if failed_with 'fail' && [ "$(cat "$COUNT_FILE")" = 9 ]; then pass "t_archive_failure_count_increase_fails (and the new count is stored)"; else fail "t_archive_failure_count_increase_fails" "rc=$rc $(pings) $(cat "$COUNT_FILE")"; fi
: >"$SANDBOX/log/pings"
run_check
if passed; then pass "the same count on the next run passes: one alert per burst"; else fail "alert clears" "rc=$rc $(pings)"; fi
echo 2 >"$SANDBOX/state/failed_count"; : >"$SANDBOX/log/pings"
run_check
if passed && [ "$(cat "$COUNT_FILE")" = 2 ]; then pass "a stats reset lowering the count does not alert; the lower value is stored"; else fail "stats_reset" "rc=$rc $(pings) $(cat "$COUNT_FILE")"; fi
echo 3 >"$SANDBOX/state/failed_count"; : >"$SANDBOX/log/pings"
run_check
if failed_with; then pass "...and an increase from the lower value is caught"; else fail "after reset" "rc=$rc $(pings)"; fi
scenario; echo garbage >"$COUNT_FILE"; echo 4 >"$SANDBOX/state/failed_count"
run_check
if passed && [ "$(cat "$COUNT_FILE")" = 4 ]; then pass "a corrupt stored value is treated as none"; else fail "corrupt stored" "rc=$rc $(pings)"; fi
scenario; echo 5 >"$COUNT_FILE"; echo 9 >"$SANDBOX/state/failed_count"; echo 1 >"$SANDBOX/state/find_rc"
run_check
if [ "$(cat "$COUNT_FILE")" = 9 ]; then pass "the count is stored even when another check fails"; else fail "store on other failure" "$(cat "$COUNT_FILE")"; fi

# --- disk --------------------------------------------------------------------------------------------------------------
scenario; printf 'Use%%\n 80%%\n' >"$SANDBOX/state/df"
run_check
if failed_with 'disk'; then pass "t_disk_at_80_percent_fails"; else fail "t_disk_at_80_percent_fails" "rc=$rc $(pings)"; fi
scenario; printf 'Use%%\n 79%%\n' >"$SANDBOX/state/df"
run_check
if passed; then pass "79% passes"; else fail "79 percent" "rc=$rc $(pings)"; fi
scenario; printf 'Use%%\n 100%%\n' >"$SANDBOX/state/df"
run_check
if failed_with 'disk'; then pass "100% fails"; else fail "100 percent" "rc=$rc $(pings)"; fi
if called 'df .*/var/lib/docker'; then pass "df looks at /var/lib/docker"; else fail "df path" "$(cat "$CALLS")"; fi
scenario; stub df 'echo "df: cannot read" >&2; exit 1'
run_check
if failed_with 'disk'; then pass "a df that fails is a failure, not a pass"; else fail "df failing" "rc=$rc $(pings)"; fi
stub df 'cat "$SANDBOX/state/df"'

# --- Postgres down ----------------------------------------------------------------------------------------------------
scenario; touch "$SANDBOX/state/psql_down"
run_check
if failed_with 'postgres'; then pass "t_postgres_down_fails: psql refused"; else fail "t_postgres_down_fails" "rc=$rc $(pings)"; fi
scenario; touch "$SANDBOX/state/docker_down"
run_check
if failed_with 'postgres' && ! pings | grep -q SECRETBUCKET; then pass "t_postgres_down_fails: docker itself failing, and its message stays out of the ping"; else fail "docker down" "rc=$rc $(pings)"; fi
scenario; echo "not a number" >"$SANDBOX/state/failed_count"
run_check
if failed_with; then pass "an unreadable answer is a failure"; else fail "garbage count" "rc=$rc $(pings)"; fi
scenario; touch "$SANDBOX/state/psql_down"; echo 3 >"$COUNT_FILE"
run_check
if [ "$(cat "$COUNT_FILE")" = 3 ]; then pass "a down server leaves the stored count alone"; else fail "count kept" "$(cat "$COUNT_FILE")"; fi

# --- one short reason per failed check ----------------------------------------------------------------------------------
scenario; echo 3 >"$COUNT_FILE"; echo 9 >"$SANDBOX/state/failed_count"; echo "x.ready" >"$SANDBOX/state/ready"; printf 'Use%%\n 91%%\n' >"$SANDBOX/state/df"
run_check
msg="$(grep '^fail|' "$SANDBOX/log/pings" | cut -d'|' -f2-)"
if failed_with 'archive' && grep -qi 'disk' <<<"$msg" && grep -qi 'fail' <<<"$msg" && [ "${#msg}" -lt 300 ]; then
  pass "three failed checks give three short reasons in one ping"; else fail "reasons" "$msg"; fi

# --- pings ---------------------------------------------------------------------------------------------------------------------
scenario; run_check
if ! out | grep -q 'SECRETPING'; then pass "t_ping_url_never_logged"; else fail "t_ping_url_never_logged" "$(out)"; fi
scenario; touch "$SANDBOX/state/curl_fails"; run_check
if [ "$rc" = 0 ] && out | grep -q 'could not ping' && ! out | grep -q SECRETPING; then pass "an undeliverable ping is logged, not fatal"; else fail "dead monitor" "rc=$rc $(out)"; fi
scenario; touch "$SANDBOX/state/curl_fails"; touch "$SANDBOX/state/psql_down"; run_check
if [ "$rc" != 0 ]; then pass "a real failure still exits non-zero when pings fail"; else fail "failure with dead monitor" "rc=$rc"; fi
scenario; HC_PG_HEALTH="" run_check
if [ "$rc" = 0 ] && ! called '^curl' && [ "$(out | grep -c HC_PG_HEALTH)" = 1 ]; then pass "a blank URL: the checks run, one line is logged"; else fail "blank url" "rc=$rc $(out)"; fi
scenario; touch "$SANDBOX/state/psql_down"; HC_PG_HEALTH="" run_check
if [ "$rc" != 0 ]; then pass "a blank URL does not hide a failure"; else fail "blank url failure" "rc=$rc"; fi

# --- archiving must be on and point at pgBackRest ------------------------------------------------------------------------
scenario; echo off >"$SANDBOX/state/archive_mode"
run_check
if failed_with 'archive_mode'; then pass "t_archive_mode_off_fails"; else fail "t_archive_mode_off_fails" "rc=$rc $(pings)"; fi
scenario; echo '/bin/true' >"$SANDBOX/state/archive_command"
run_check
if failed_with 'archive_command'; then pass "t_archive_command_replaced_fails"; else fail "t_archive_command_replaced_fails" "rc=$rc $(pings)"; fi
scenario; echo 'pgbackrest --stanza=main archive-push %p || true' >"$SANDBOX/state/archive_command"
run_check
if failed_with 'archive_command'; then pass "a command that merely contains the expected one still fails"; else fail "archive_command suffix" "rc=$rc $(pings)"; fi
expected="$(sed -n "s/^EXPECTED_ARCHIVE_COMMAND='\(.*\)'$/\1/p" "$CHECK")"
if grep -qxF "archive_command = '$expected'" "$OS_DIR/config/postgresql.conf"; then
  pass "the expected archive_command is the one in config/postgresql.conf"; else fail "archive_command drift" "expected '$expected'"; fi
if grep -qxF "archive_mode = on" "$OS_DIR/config/postgresql.conf"; then pass "...and archive_mode = on there"; else fail "archive_mode in conf" ""; fi

# --- failing to store the count is a failure ------------------------------------------------------------------------------
scenario; mkdir "$COUNT_FILE.tmp"
run_check
if failed_with 'store'; then pass "t_unstorable_count_fails: otherwise every run counts as a first run"; else fail "t_unstorable_count_fails" "rc=$rc $(pings)"; fi
rmdir "$COUNT_FILE.tmp"

# --- a missing REPO_DIR and a TERM both ping fail --------------------------------------------------------------------------
scenario; REPO_DIR="" run_check
if failed_with 'REPO_DIR'; then pass "t_unset_repo_dir_pings_fail: the health check"; else fail "t_unset_repo_dir_pings_fail" "rc=$rc $(pings) $(out)"; fi
scenario; touch "$SANDBOX/state/docker_slow"
setsid "$CHECK" >"$SANDBOX/log/out" 2>&1 &
pid=$!
sleep 1
kill -TERM -- "-$pid"
wait "$pid"; rc=$?
if [ "$rc" != 0 ] && grep -qi '^fail|.*terminated' "$SANDBOX/log/pings" && ! grep -q '^success|' "$SANDBOX/log/pings"; then
  pass "t_term_pings_fail_terminated: the health check"; else fail "t_term_pings_fail_terminated" "rc=$rc $(pings)"; fi
finish
