#!/usr/bin/env bash
# Unit test for deployment/postgres/bin/backup.sh. Docker and curl are stubbed: docker answers
# `pgbackrest info` from numbered files (call 1 = before the backup, call 2 = after) and the backup
# command from state files; curl records every ping to $SANDBOX/log/pings as "<suffix>|<message>".
# shellcheck disable=SC2016  # stub bodies are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
mkdir -p "$SANDBOX/state" "$SANDBOX/srv/state"
stub docker 'st="$SANDBOX/state"
case "$*" in
  *"info --output=json"*)
    n="$(cat "$st/info_n" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" >"$st/info_n"
    if [ "$(cat "$st/info_rc_$n")" != 0 ]; then echo "ERROR: [056]: unable to find s3://SECRETBUCKET" >&2; exit "$(cat "$st/info_rc_$n")"; fi
    cat "$st/info_$n" ;;
  *" backup "*|*" backup")
    if [ -e "$st/backup_slow" ]; then sleep 30; fi
    cat "$st/backup_out"; cat "$st/backup_err" >&2; exit "$(cat "$st/backup_rc")" ;;
esac'
# The ping URL carries a secret in its path; the stub records only the suffix and message, so a
# test can look for the URL in the script's output without finding the stub's own record.
stub curl 'url=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in --data-raw) data="$2"; shift ;; http*) url="$1" ;; esac
  shift
done
if [ -e "$SANDBOX/state/curl_fails" ]; then exit 22; fi
suffix="${url#http://hc.test/SECRETPING}"; suffix="${suffix#/}"
printf "%s|%s\n" "${suffix:-success}" "$data" >>"$SANDBOX/log/pings"'

export STATE_DIR="$SANDBOX/srv" REPO_DIR="$SANDBOX/repo" HC_PG_BACKUP="http://hc.test/SECRETPING"
BACKUP="$BIN/backup.sh"
info_json() {   # info_json LABEL... : a stanza with those backups
  local labels="" l
  for l in "$@"; do labels="$labels${labels:+,}{\"label\":\"$l\"}"; done
  printf '[{"name":"main","backup":[%s],"status":{"code":0,"message":"ok"}}]' "$labels"
}
scenario() {   # scenario BEFORE_JSON AFTER_JSON : a backup that works
  local st="$SANDBOX/state"
  rm -f "${st:?}"/* "$SANDBOX/log/pings" "$SANDBOX/log/out" "$SANDBOX/srv/state/backup.log" "$SANDBOX/srv/state/backup.log.1"
  printf '%s' "$1" >"$st/info_1"; printf '%s' "$2" >"$st/info_2"
  echo 0 >"$st/info_rc_1"; echo 0 >"$st/info_rc_2"; echo 0 >"$st/backup_rc"
  : >"$st/backup_out"; : >"$st/backup_err"; : >"$CALLS"; : >"$SANDBOX/log/pings"
}
run_backup() { "$BACKUP" >"$SANDBOX/log/out" 2>&1; rc=$?; }
out() { cat "$SANDBOX/log/out"; }
pings() { cat "$SANDBOX/log/pings"; }
line_no() { grep -nE "$1" "$CALLS" | head -1 | cut -d: -f1; }
OLD="$(info_json 20261101-090000F)"
NEW="$(info_json 20261101-090000F 20261106-090000F_20261101-090000F)"

# --- full on Sunday, diff otherwise -----------------------------------------------------------------------
scenario "$OLD" "$NEW"
BACKUP_DOW=7 run_backup
if [ "$rc" = 0 ] && called 'pgbackrest --stanza=main backup --type=full'; then pass "t_sunday_is_full"; else fail "t_sunday_is_full" "rc=$rc $(cat "$CALLS")"; fi
ok=1
for d in 1 2 3 4 5 6; do
  scenario "$OLD" "$NEW"
  BACKUP_DOW=$d run_backup
  if [ "$rc" = 0 ] && called 'pgbackrest --stanza=main backup --type=diff' && ! called 'type=full'; then :; else ok=0; fail "t_weekday_is_diff (day $d)" "rc=$rc $(cat "$CALLS")"; fi
done
if [ "$ok" = 1 ]; then pass "t_weekday_is_diff: Monday to Saturday"; fi
# The real clock decides when BACKUP_DOW is unset: the default must agree with `date -u`.
scenario "$OLD" "$NEW"
run_backup
want="diff"; if [ "$(date -u +%u)" = 7 ]; then want="full"; fi
if called "backup --type=$want"; then pass "the default day is today in UTC ($want)"; else fail "default day" "$(cat "$CALLS")"; fi
scenario "$(info_json)" "$(info_json 20261106-090000F)"
BACKUP_DOW=3 run_backup
if [ "$rc" = 0 ] && called 'backup --type=full'; then pass "no backup yet: full, even on a Wednesday"; else fail "first backup is full" "rc=$rc $(cat "$CALLS")"; fi
scenario '[{"name":"main","backup":[],"status":{"code":2,"message":"no valid backups"}}]' "$(info_json 20261106-090000F)"
BACKUP_DOW=3 run_backup
if [ "$rc" = 0 ] && called 'backup --type=full'; then pass "a stanza with an empty backup list: full"; else fail "empty stanza is full" "rc=$rc $(cat "$CALLS")"; fi

# --- success pings only after info shows the new label ----------------------------------------------------
scenario "$OLD" "$NEW"
BACKUP_DOW=3 run_backup
if [ "$rc" = 0 ] && [ "$(cut -d'|' -f1 "$SANDBOX/log/pings" | tr '\n' ' ')" = "start success " ]; then
  pass "a start ping, then success"; else fail "ping sequence" "rc=$rc $(pings)"; fi
start_line="$(line_no 'curl .*/start')" backup_line="$(line_no 'backup --type')"
second_info="$(grep -nE 'info --output=json' "$CALLS" | sed -n 2p | cut -d: -f1)"
succ_line="$(grep -nE 'curl ' "$CALLS" | tail -1 | cut -d: -f1)"
if [ -n "$start_line" ] && [ "$start_line" -lt "$backup_line" ] && [ "$backup_line" -lt "$second_info" ] && [ "$second_info" -lt "$succ_line" ]; then
  pass "t_success_pings_only_after_info_shows_new_label: start, backup, info, then success"; else fail "t_success_pings_only_after_info_shows_new_label" "$(cat "$CALLS")"; fi
if grep -q '20261106-090000F' "$SANDBOX/log/pings"; then pass "the success ping names the new label"; else fail "label in ping" "$(pings)"; fi

# --- failures ---------------------------------------------------------------------------------------------------
scenario "$OLD" "$NEW"
echo 28 >"$SANDBOX/state/backup_rc"; echo "ERROR: [028]: backup and archive info files exist but do not match (s3://SECRETBUCKET/secret/path)" >"$SANDBOX/state/backup_err"
BACKUP_DOW=3 run_backup
if [ "$rc" != 0 ] && grep -q '^fail|' "$SANDBOX/log/pings" && ! grep -q '^success|' "$SANDBOX/log/pings"; then
  pass "t_backup_exit_nonzero_pings_fail_not_success"; else fail "t_backup_exit_nonzero_pings_fail_not_success" "rc=$rc $(pings)"; fi
if grep '^fail|' "$SANDBOX/log/pings" | grep -q '\[028\]' && grep '^fail|' "$SANDBOX/log/pings" | grep -q '28'; then
  pass "the fail ping carries the error class and the exit code"; else fail "class in ping" "$(pings)"; fi
if ! pings | grep -q 'SECRETBUCKET' && ! out | grep -q 'SECRETBUCKET'; then
  pass "t_no_repo_details_in_ping_or_output: neither the ping nor stdout holds the bucket"; else fail "bucket leaked" "$(pings) $(out)"; fi
log="$SANDBOX/srv/state/backup.log"
if grep -q 'SECRETBUCKET' "$log" && [ "$(stat -c %a "$log")" = 600 ]; then pass "full detail is kept in a 0600 log"; else fail "backup.log" "$(ls -l "$log" 2>&1)"; fi

scenario "$OLD" "$OLD"
BACKUP_DOW=3 run_backup
if [ "$rc" != 0 ] && grep -q '^fail|' "$SANDBOX/log/pings" && ! grep -q '^success|' "$SANDBOX/log/pings"; then
  pass "t_exit_zero_but_no_new_label_pings_fail"; else fail "t_exit_zero_but_no_new_label_pings_fail" "rc=$rc $(pings)"; fi
scenario "$OLD" "$NEW"
echo 1 >"$SANDBOX/state/info_rc_2"
BACKUP_DOW=3 run_backup
if [ "$rc" != 0 ] && ! grep -q '^success|' "$SANDBOX/log/pings" && grep -q '^fail|' "$SANDBOX/log/pings"; then
  pass "a backup that cannot be confirmed by info is a fail"; else fail "second info fails" "rc=$rc $(pings)"; fi
scenario "$OLD" "$NEW"
echo 1 >"$SANDBOX/state/info_rc_1"
BACKUP_DOW=3 run_backup
if [ "$rc" != 0 ] && grep -q '^fail|' "$SANDBOX/log/pings" && ! called 'backup --type'; then
  pass "info failing first pings fail and starts no backup"; else fail "first info fails" "rc=$rc $(cat "$CALLS")"; fi
scenario "not json" "$NEW"
BACKUP_DOW=3 run_backup
if [ "$rc" != 0 ] && ! called 'backup --type' && grep -q '^fail|' "$SANDBOX/log/pings"; then pass "unreadable info output fails closed"; else fail "bad json" "rc=$rc"; fi

# --- a lock refused by a running backup is a clear fail -----------------------------------------------------------
scenario "$OLD" "$NEW"
echo 50 >"$SANDBOX/state/backup_rc"; echo "ERROR: [050]: unable to acquire lock on file '/tmp/pgbackrest/main-backup.lock'" >"$SANDBOX/state/backup_err"
BACKUP_DOW=3 run_backup
if [ "$rc" != 0 ] && grep -qi '^fail|.*\[050\].*lock' "$SANDBOX/log/pings" && ! grep -q '^success|' "$SANDBOX/log/pings"; then
  pass "t_lock_refused_pings_fail_clearly: names the lock"; else fail "t_lock_refused_pings_fail_clearly" "rc=$rc $(pings)"; fi

# --- pings: URL never logged, undeliverable pings are not fatal, blank URL ------------------------------------------
scenario "$OLD" "$NEW"
BACKUP_DOW=3 run_backup
if ! out | grep -q 'SECRETPING' && ! grep -q 'SECRETPING' "$SANDBOX/srv/state/backup.log" 2>/dev/null; then
  pass "t_ping_url_never_logged"; else fail "t_ping_url_never_logged" "$(out)"; fi
scenario "$OLD" "$NEW"
touch "$SANDBOX/state/curl_fails"
BACKUP_DOW=3 run_backup
if [ "$rc" = 0 ] && out | grep -q 'could not ping' && ! out | grep -q 'SECRETPING'; then
  pass "an undeliverable ping is logged and not fatal (success path)"; else fail "undeliverable ping" "rc=$rc $(out)"; fi
scenario "$OLD" "$OLD"
touch "$SANDBOX/state/curl_fails"
BACKUP_DOW=3 run_backup
if [ "$rc" != 0 ] && ! out | grep -q 'SECRETPING'; then pass "a real failure still exits non-zero when pings are undeliverable"; else fail "failure with dead monitor" "rc=$rc $(out)"; fi
scenario "$OLD" "$NEW"
HC_PG_BACKUP="" BACKUP_DOW=3 run_backup
if [ "$rc" = 0 ] && ! called '^curl' && [ "$(out | grep -c 'HC_PG_BACKUP')" = 1 ] && called 'backup --type=diff'; then
  pass "a blank URL: the backup runs, one line is logged, exit 0"; else fail "blank url" "rc=$rc $(out)"; fi
scenario "$OLD" "$OLD"
HC_PG_BACKUP="" BACKUP_DOW=3 run_backup
if [ "$rc" != 0 ]; then pass "a blank URL does not hide a real failure"; else fail "blank url failure" "rc=$rc"; fi

# --- the log cannot fill the disk ---------------------------------------------------------------------------------------
scenario "$OLD" "$NEW"
head -c 6000000 /dev/zero | tr '\0' x >"$SANDBOX/srv/state/backup.log"
BACKUP_DOW=3 run_backup
if [ -f "$SANDBOX/srv/state/backup.log.1" ] && [ "$(stat -c %s "$SANDBOX/srv/state/backup.log")" -lt 1000000 ]; then
  pass "backup.log is rotated by size"; else fail "rotation" "$(ls -l "$SANDBOX/srv/state")"; fi
for _ in 1 2 3; do
  scenario "$OLD" "$NEW" ; head -c 6000000 /dev/zero | tr '\0' x >"$SANDBOX/srv/state/backup.log"; BACKUP_DOW=3 run_backup
done
if [ ! -e "$SANDBOX/srv/state/backup.log.2" ]; then pass "only one rotated file is kept"; else fail "bounded rotation" "$(ls "$SANDBOX/srv/state")"; fi

# --- a missing REPO_DIR, a TERM, and a backup pgBackRest marks as having errors -----------------------------------------------
scenario "$OLD" "$NEW"
REPO_DIR="" BACKUP_DOW=3 run_backup
if [ "$rc" != 0 ] && grep -q '^fail|.*REPO_DIR' "$SANDBOX/log/pings" && ! called 'backup --type'; then
  pass "t_unset_repo_dir_pings_fail"; else fail "t_unset_repo_dir_pings_fail" "rc=$rc $(pings) $(out)"; fi
scenario "$OLD" "$NEW"
# A slow backup: the stub sleeps; the whole process group is TERMed, as systemd does.
touch "$SANDBOX/state/backup_slow"
BACKUP_DOW=3 setsid "$BACKUP" >"$SANDBOX/log/out" 2>&1 &
pid=$!
sleep 1
kill -TERM -- "-$pid"
wait "$pid"; rc=$?
if [ "$rc" != 0 ] && grep -qi '^fail|.*terminated' "$SANDBOX/log/pings" && ! grep -q '^success|' "$SANDBOX/log/pings" \
   && grep -qi '^fail|.*lock' "$SANDBOX/log/pings"; then
  pass "t_term_pings_fail_terminated: says a lock may be left behind"; else fail "t_term_pings_fail_terminated" "rc=$rc $(pings) $(out)"; fi
scenario "$OLD" '[{"name":"main","backup":[{"label":"20261101-090000F"},{"label":"20261106-090000F_20261101-090000F","error":true}],"status":{"code":0,"message":"ok"}}]'
BACKUP_DOW=3 run_backup
if [ "$rc" != 0 ] && grep -qi '^fail|.*error' "$SANDBOX/log/pings" && ! grep -q '^success|' "$SANDBOX/log/pings"; then
  pass "t_backup_with_error_flag_pings_fail: exit 0 but info says error"; else fail "t_backup_with_error_flag_pings_fail" "rc=$rc $(pings)"; fi
scenario "$OLD" '[{"name":"main","backup":[{"label":"20261101-090000F","error":true},{"label":"20261106-090000F_20261101-090000F","error":false}],"status":{"code":0,"message":"ok"}}]'
BACKUP_DOW=3 run_backup
if [ "$rc" = 0 ]; then pass "an old backup with errors does not fail a new clean one"; else fail "old error flag" "rc=$rc $(pings)"; fi
finish
