#!/usr/bin/env bash
# shellcheck disable=SC2016  # stub bodies are single-quoted: they expand when the stub runs
# deployment/home-server/test/nic_watchdog_test.sh
# host/sbin/nic-watchdog: the decision logic. Every test drives the real script with stubbed
# journalctl, ping, ip, systemctl, curl and sleep, one simulated minute per check.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"

WD="$HS_DIR/host/sbin/nic-watchdog"
T=1000000

# Stray stub processes from the wedge tests (an `ip` that blocks in sleep) are killed here.
reap_stubs() {
  local f="${SANDBOX:-/nonexistent}/log/pids"
  # shellcheck disable=SC2046
  [ -f "$f" ] && kill $(cat "$f") 2>/dev/null
  # Release readers blocked on a FIFO carrier file (open O_RDWR never blocks).
  if [ -p "${NIC_WATCHDOG_SYS:-/nonexistent}/eno1/carrier" ]; then
    { exec 9<>"$NIC_WATCHDOG_SYS/eno1/carrier"; printf '1\n1\n1\n' >&9; exec 9>&-; } 2>/dev/null
  fi
  return 0
}

setup() {
  reap_stubs
  [ -z "${SANDBOX:-}" ] || rm -rf "$SANDBOX"
  new_sandbox
  unset PING_RC JOURNAL_RC CURL_RC NO_ROUTE IP_LINK_RC NIC_WATCHDOG_LINK_LIMIT NIC_WATCHDOG_PING_LIMIT NIC_WATCHDOG_UPTIME
  export NIC_WATCHDOG_ENV="$SANDBOX/nic-watchdog.env"
  export NIC_WATCHDOG_LOG_ONLY_FILE="$SANDBOX/log-only"
  export NIC_WATCHDOG_STATE="$SANDBOX/persist"
  export NIC_WATCHDOG_RUN="$SANDBOX/volatile"
  export NIC_WATCHDOG_SYS="$SANDBOX/sys"
  mkdir -p "$NIC_WATCHDOG_STATE" "$NIC_WATCHDOG_RUN" "$NIC_WATCHDOG_SYS/eno1"
  printf 'NIC=eno1\nHC_NIC_WATCHDOG=https://hc.test/abc\n' >"$NIC_WATCHDOG_ENV"
  carrier 1
  hang_off
  stub journalctl 'cat "$SANDBOX/kernel-log"; exit "${JOURNAL_RC:-0}"'
  # ping_seq lines are used up one per ping, then PING_RC applies. "hang" overruns any short limit.
  stub ping 'rc="${PING_RC:-0}"
if [ -s "$SANDBOX/ping-seq" ]; then
  mapfile -t seq <"$SANDBOX/ping-seq"
  rc="${seq[0]}"
  if [ "${#seq[@]}" -gt 1 ]; then printf "%s\n" "${seq[@]:1}" >"$SANDBOX/ping-seq"; else : >"$SANDBOX/ping-seq"; fi
fi
if [ "$rc" = hang ]; then echo $$ >>"$SANDBOX/log/pids"; command -p sleep 3; exit 0; fi
exit "$rc"'
  plain_ip
  stub systemctl ''
  stub curl 'echo "https://hc.test/abc" >&2; exit "${CURL_RC:-0}"'
  stub sleep ''
}

plain_ip() {
  stub ip 'case "$*" in "link set "*) exit "${IP_LINK_RC:-0}" ;; esac
case "$*" in "-4 route show default") [ -n "${NO_ROUTE:-}" ] || echo "default via 198.51.100.1 dev vmbr0" ;; esac'
}
carrier() { printf '%s\n' "$1" >"$NIC_WATCHDOG_SYS/eno1/carrier"; }
# real_sleep: the script's polling sleep (0.1) and reset pause (3, shortened to 1) really wait.
real_sleep() { stub sleep 'case "$1" in 0.1) command -p sleep 0.1 ;; 3) command -p sleep 1 ;; esac'; }
# wedged_ip [down|up]: that `ip link set` (both, with no argument) blocks in a background-safe sleep
# and records its pids for reap_stubs.
wedged_ip() {
  stub ip 'case "$*" in "link set eno1 '"${1:-}"'"*) echo $$ >>"$SANDBOX/log/pids"; command -p sleep 30 & echo $! >>"$SANDBOX/log/pids"; wait ;; esac
case "$*" in "-4 route show default") echo "default via 198.51.100.1 dev vmbr0" ;; esac'
  real_sleep
  export NIC_WATCHDOG_LINK_LIMIT=1
}
# slow_carrier: reading the carrier file blocks, until reap_stubs releases it.
slow_carrier() {
  rm -f "$NIC_WATCHDOG_SYS/eno1/carrier"; mkfifo "$NIC_WATCHDOG_SYS/eno1/carrier"
  real_sleep
  export NIC_WATCHDOG_LINK_LIMIT=1
}
restore_carrier() { reap_stubs; rm -f "$NIC_WATCHDOG_SYS/eno1/carrier"; carrier 1; }
ping_seq() { printf '%s\n' "$@" >"$SANDBOX/ping-seq"; }
# since_journal + hl: a journal that honours --since, for lines stamped with a time.
since_journal() {
  stub journalctl 'since=""; prev=""
for a in "$@"; do [ "$prev" = --since ] && since="${a#@}"; prev="$a"; done
awk -v s="$since" '"'"'$1 >= s'"'"' "$SANDBOX/kernel-log"; exit "${JOURNAL_RC:-0}"'
}
hl() { echo "$1 eno1: Detected Hardware Unit Hang:" >>"$SANDBOX/kernel-log"; }
no_reboot_state() { no_reboot && [ ! -e "$NIC_WATCHDOG_STATE/last_reboot" ] && [ ! -e "$NIC_WATCHDOG_STATE/gateway_reboot_marker" ]; }
# seed_episode <resets>: an open episode as of the previous check, one minute before T.
seed_episode() {
  echo "$1" >"$NIC_WATCHDOG_RUN/resets"; echo $((T - 120)) >"$NIC_WATCHDOG_RUN/last_reset"
  echo $((T - 60)) >"$NIC_WATCHDOG_RUN/last_check"
}
# seed_hang_ready: a hang seen on the previous check, so the next one is the second in a row.
seed_hang_ready() { hang_on; seed_episode 2; echo 1 >"$NIC_WATCHDOG_RUN/hang_streak"; }
# stuck_gone: the stuck stubs have finished, and `ip` works again.
stuck_gone() {
  local pid n
  reap_stubs
  pid="$(sed -n 's/^pid=//p' "$NIC_WATCHDOG_RUN/reset_wedged" 2>/dev/null)"
  for ((n = 0; n < 50; n++)); do
    [ -n "$pid" ] && [ -d "/proc/$pid" ] && [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)" != Z ] || break
    command -p sleep 0.05
  done
  plain_ip
}
hang_on() { echo "[  12.3] e1000e 0000:00:1f.6 eno1: Detected Hardware Unit Hang:" >"$SANDBOX/kernel-log"; }
hang_off() { : >"$SANDBOX/kernel-log"; }
run_at() { NIC_WATCHDOG_NOW="$1" "$WD" >>"$SANDBOX/log/out" 2>&1; RC=$?; }
# minutes <from> <to>: one check per simulated minute, T + 60 * m
minutes() { local m; for ((m = $1; m <= $2; m++)); do run_at $((T + 60 * m)); done; }
count() { grep -cE "$1" "$CALLS" || true; }
rv() { cat "$NIC_WATCHDOG_RUN/$1" 2>/dev/null; }
sv() { cat "$NIC_WATCHDOG_STATE/$1" 2>/dev/null; }
# last_reset is the reset's own time (check time plus seconds the script ran), so allow a little.
last_reset_near() { local v; v="$(rv last_reset)"; [ -n "$v" ] && [ "$v" -ge "$1" ] && [ "$v" -le $(($1 + 90)) ]; }
no_reboot() { ! called 'systemctl reboot'; }
no_reset() { ! called 'ip link set'; }

# --- hang path
t_one_hang_no_reset() { setup; hang_on; run_at "$T"; ! called 'ip link set eno1 down'; }
t_two_hangs_reset() {
  setup; hang_on; minutes 0 1
  [ "$(grep -oE 'ip link set eno1 (down|up)' "$CALLS" | tr '\n' ,)" = "ip link set eno1 down,ip link set eno1 up," ]
}
t_hang_sequence_reboots() {
  setup; export PING_RC=1; hang_on
  run_at "$T"; run_at $((T + 60)); [ "$(rv resets)" = 1 ] || return 1
  run_at $((T + 120)); [ "$(rv resets)" = 2 ] || return 1
  no_reboot || return 1
  run_at $((T + 180)); called '^systemctl reboot$'
}
t_hang_gateway_answers_capped() {
  setup; export PING_RC=0; hang_on; minutes 0 5
  [ "$(count 'ip link set eno1 down')" = 2 ] && no_reboot
}
t_separate_hangs_share_cap() {
  setup; export PING_RC=0
  local base
  for base in 0 180 360; do
    hang_on; run_at $((T + base)); run_at $((T + base + 60))
    hang_off; run_at $((T + base + 120))
  done
  [ "$(count 'ip link set eno1 down')" = 2 ] || return 1
  hang_on; run_at $((T + 21700)); run_at $((T + 21760))
  [ "$(count 'ip link set eno1 down')" = 3 ] && no_reboot
}
t_other_nic_ignored() {
  setup; echo "[  1.0] e1000e 0000:00:1f.6 eno10: Detected Hardware Unit Hang:" >"$SANDBOX/kernel-log"
  minutes 0 1
  no_reset && { [ -z "$(rv hang_streak)" ] || [ "$(rv hang_streak)" = 0 ]; }
}

# --- gateway path
t_gateway_timeline() {
  setup; export PING_RC=1
  minutes 0 4; [ "$(count 'ip link set eno1 down')" = 0 ] || return 1
  minutes 5 5; [ "$(count 'ip link set eno1 down')" = 1 ] || return 1
  minutes 6 14; [ "$(count 'ip link set eno1 down')" = 1 ] || return 1
  minutes 15 15; [ "$(count 'ip link set eno1 down')" = 2 ] || return 1
  minutes 16 29; no_reboot || return 1
  minutes 30 31
  called '^systemctl reboot$' && [ -e "$NIC_WATCHDOG_STATE/gateway_reboot_marker" ]
}
t_gateway_recovery_clears() {
  setup; export PING_RC=1; minutes 0 10
  export PING_RC=0; run_at $((T + 660))
  [ ! -e "$NIC_WATCHDOG_RUN/gateway_lost_since" ] && [ ! -e "$NIC_WATCHDOG_RUN/resets" ] || return 1
  export PING_RC=1; run_at $((T + 720))
  [ "$(rv gateway_lost_since)" = $((T + 720)) ] && [ ! -e "$NIC_WATCHDOG_RUN/resets" ]
}

# --- reboot limits
t_reboot_inside_limit_refused() {
  setup; export PING_RC=1; hang_on; echo $((T - 3600)) >"$NIC_WATCHDOG_STATE/last_reboot"
  minutes 0 40
  no_reboot && [ "$(count 'ip link set eno1 down')" = 3 ] && last_reset_near $((T + 1920))
}
t_reboot_after_limit_allowed() {
  setup; export PING_RC=1; hang_on; echo $((T - 25200)) >"$NIC_WATCHDOG_STATE/last_reboot"
  minutes 0 3; called '^systemctl reboot$'
}
t_corrupt_reboot_time_refused() {
  setup; export PING_RC=1; hang_on; echo garbage >"$NIC_WATCHDOG_STATE/last_reboot"
  minutes 0 3
  no_reboot && [ "$(sv last_reboot)" = $((T + 180)) ]
}
t_future_reboot_time_refused() {
  setup; export PING_RC=1; hang_on; echo $((T + 3600)) >"$NIC_WATCHDOG_STATE/last_reboot"
  minutes 0 3
  no_reboot && [ "$(sv last_reboot)" = $((T + 180)) ]
}
t_marker_blocks_gateway_reboot() {
  setup; export PING_RC=1; : >"$NIC_WATCHDOG_STATE/gateway_reboot_marker"
  echo $((T - 25200)) >"$NIC_WATCHDOG_STATE/last_reboot"
  minutes 0 31; no_reboot || return 1
  minutes 32 46
  no_reboot && [ "$(count 'ip link set eno1 down')" = 3 ]
}
t_marker_clears_when_gateway_answers() {
  setup; : >"$NIC_WATCHDOG_STATE/gateway_reboot_marker"
  echo $((T - 25200)) >"$NIC_WATCHDOG_STATE/last_reboot"
  export PING_RC=0; run_at "$T"
  [ ! -e "$NIC_WATCHDOG_STATE/gateway_reboot_marker" ] || return 1
  export PING_RC=1; minutes 1 32
  called '^systemctl reboot$'
}
t_marker_does_not_block_hang() {
  setup; export PING_RC=1; hang_on; : >"$NIC_WATCHDOG_STATE/gateway_reboot_marker"
  echo $((T - 25200)) >"$NIC_WATCHDOG_STATE/last_reboot"
  minutes 0 3; called '^systemctl reboot$'
}
t_state_written_before_reboot() {
  setup; export PING_RC=1
  stub systemctl 'echo "last_reboot=$([ -e "$NIC_WATCHDOG_STATE/last_reboot" ] && echo y || echo n) marker=$([ -e "$NIC_WATCHDOG_STATE/gateway_reboot_marker" ] && echo y || echo n)" >>"$SANDBOX/log/sysstate"'
  minutes 0 30
  [ "$(cat "$SANDBOX/log/sysstate")" = "last_reboot=y marker=y" ] || return 1
  setup; export PING_RC=1; hang_on
  stub systemctl 'echo "last_reboot=$([ -e "$NIC_WATCHDOG_STATE/last_reboot" ] && echo y || echo n)" >>"$SANDBOX/log/sysstate"'
  minutes 0 3
  [ "$(cat "$SANDBOX/log/sysstate")" = "last_reboot=y" ]
}
t_unwritable_state_no_reboot() {
  setup; export PING_RC=1; hang_on
  rm -rf "$NIC_WATCHDOG_STATE"; : >"$NIC_WATCHDOG_STATE"
  minutes 0 5; no_reboot || return 1
  setup; export PING_RC=1
  rm -rf "$NIC_WATCHDOG_STATE"; : >"$NIC_WATCHDOG_STATE"
  minutes 0 32; no_reboot
}

# --- carrier and unknowns
t_carrier_down_no_episode() {
  setup; export PING_RC=1; carrier 0; minutes 0 39
  no_reset && no_reboot && [ ! -e "$NIC_WATCHDOG_RUN/gateway_lost_since" ] && ! called '^ping '
}
t_carrier_stays_down_after_reset() {
  setup; export PING_RC=2; carrier 0
  echo 2 >"$NIC_WATCHDOG_RUN/resets"; echo $((T - 120)) >"$NIC_WATCHDOG_RUN/last_reset"
  echo $((T - 60)) >"$NIC_WATCHDOG_RUN/last_check"
  minutes 0 29; no_reboot || return 1
  minutes 30 30; called '^systemctl reboot$'
}
t_hang_with_carrier_down_is_episode() {
  setup; export PING_RC=1; carrier 0; hang_on; minutes 0 1
  called 'ip link set eno1 down'
}
t_ping_unknown_no_action() { setup; export PING_RC=2; minutes 0 39; no_reset && no_reboot; }
t_no_route_no_action() { setup; export PING_RC=1 NO_ROUTE=1; minutes 0 39; no_reset && no_reboot; }
t_journal_fails_no_action() { setup; export PING_RC=1 JOURNAL_RC=1; hang_on; minutes 0 39; no_reset && no_reboot; }
t_carrier_missing_no_action() {
  setup; export PING_RC=1; hang_on; rm -f "$NIC_WATCHDOG_SYS/eno1/carrier"
  minutes 0 39; no_reset && no_reboot
}
t_missing_nic_exits_1() {
  setup; echo 'HC_NIC_WATCHDOG=https://hc.test/abc' >"$NIC_WATCHDOG_ENV"; hang_on
  export PING_RC=1; minutes 0 3
  [ "$RC" = 1 ] && no_reset && no_reboot
}

# --- pause and rehearsal
t_stale_state_discarded() {
  setup; export PING_RC=1; minutes 0 20
  run_at $((T + 10800 + 1200))
  no_reboot && [ "$(rv gateway_lost_since)" = $((T + 12000)) ]
}
t_log_only_no_actions() {
  setup; export PING_RC=1; hang_on; : >"$NIC_WATCHDOG_LOG_ONLY_FILE"
  minutes 0 5
  export PING_RC=0; minutes 6 9
  no_reset && no_reboot || return 1
  grep -q 'would reset' "$SANDBOX/log/out" && grep -q 'would reboot' "$SANDBOX/log/out" || return 1
  local f
  for f in last_reboot gateway_reboot_marker answering_resets report; do
    [ ! -e "$NIC_WATCHDOG_STATE/$f" ] || return 1
  done
  [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ]
}

# --- reporting
t_report_kept_until_sent() {
  setup; export PING_RC=1; hang_on; minutes 0 1
  [ -e "$NIC_WATCHDOG_STATE/report" ] || return 1
  export PING_RC=0 CURL_RC=7; hang_off; run_at $((T + 120))
  [ -e "$NIC_WATCHDOG_STATE/report" ] || return 1
  export CURL_RC=0; : >"$CALLS"; run_at $((T + 180))
  called 'curl .*--data-binary .*hc\.test/abc/fail' && [ ! -e "$NIC_WATCHDOG_STATE/report" ]
}
t_report_sent_while_hanging() {
  setup; export PING_RC=0; hang_on; echo "reset" >"$NIC_WATCHDOG_STATE/report"
  run_at "$T"; called 'hc\.test/abc/fail'
}
t_report_survives_reboot() {
  setup; export PING_RC=1; hang_on; minutes 0 3
  called '^systemctl reboot$' && [ -s "$NIC_WATCHDOG_STATE/report" ] || return 1
  rm -rf "${NIC_WATCHDOG_RUN:?}"/*
  export PING_RC=0; hang_off; : >"$CALLS"; run_at $((T + 900))
  called 'hc\.test/abc/fail' && [ ! -e "$NIC_WATCHDOG_STATE/report" ]
}
t_hourly_ping() {
  setup; export PING_RC=0
  run_at "$T"; run_at $((T + 60)); run_at $((T + 3700))
  [ "$(count 'curl .*hc\.test/abc$')" = 2 ]
}
t_blank_url_sends_nothing() {
  setup; export PING_RC=0
  printf 'NIC=eno1\nHC_NIC_WATCHDOG=\n' >"$NIC_WATCHDOG_ENV"
  echo "reset" >"$NIC_WATCHDOG_STATE/report"
  run_at "$T"; ! called curl
}
t_url_never_logged() {
  setup; export PING_RC=0 CURL_RC=7
  echo "reset" >"$NIC_WATCHDOG_STATE/report"
  run_at "$T"; rm -f "$NIC_WATCHDOG_STATE/report"; run_at $((T + 60))
  [ "$(count '^curl ')" = 2 ] && grep -q failed "$SANDBOX/log/out" && ! grep -q 'hc\.test' "$SANDBOX/log/out"
}

# --- fix round 1
t_missing_state_dir_cap_holds() {
  setup; export PING_RC=0; hang_on; rm -rf "$NIC_WATCHDOG_STATE"
  minutes 0 7
  [ -d "$NIC_WATCHDOG_STATE" ] && [ "$(count 'ip link set eno1 down')" = 2 ] && no_reboot &&
    [ "$(count 'curl .*hc\.test/abc$')" = 1 ]
}
t_unwritable_state_answering_no_reset() {
  setup; export PING_RC=0; hang_on; rm -rf "$NIC_WATCHDOG_STATE"; : >"$NIC_WATCHDOG_STATE"
  minutes 0 7
  no_reset && no_reboot && ! called 'hc\.test/abc$'
}
# The journal stub filters timestamped lines on --since, like the real one. sleep really waits, so
# the reset ends at least a second after the check began (SECONDS advances).
journal_window_case() { # journal_window_case <with-line-after-reset: 0|1> -> prints the hang streak
  setup; export PING_RC=0; real_sleep
  stub journalctl 'since=""; prev=""
for a in "$@"; do [ "$prev" = --since ] && since="${a#@}"; prev="$a"; done
awk -v s="$since" '"'"'$1 >= s'"'"' "$SANDBOX/kernel-log"; exit "${JOURNAL_RC:-0}"'
  echo "$((T - 10)) eno1: Detected Hardware Unit Hang:" >"$SANDBOX/kernel-log"
  run_at "$T"
  echo "$((T + 30)) eno1: Detected Hardware Unit Hang:" >>"$SANDBOX/kernel-log"
  run_at $((T + 60))   # streak 2, resets; the reset ends after T + 60
  [ -n "$(rv last_reset)" ] || return 1
  # a hang line stamped when this check began, before the reset ended
  echo "$((T + 60)) eno1: Detected Hardware Unit Hang:" >>"$SANDBOX/kernel-log"
  [ "$1" = 0 ] || echo "$((T + 119)) eno1: Detected Hardware Unit Hang:" >>"$SANDBOX/kernel-log"
  run_at $((T + 120))
  local v; v="$(rv hang_streak || true)"; echo "${v:-0}"
}
t_journal_window_starts_at_reset() {
  [ "$(journal_window_case 0)" = 0 ] || return 1
  [ "$(journal_window_case 1)" = 3 ]
}
t_reset_counted_before_link_down() {
  setup; export PING_RC=1; hang_on
  stub ip 'case "$*" in "link set eno1 down") echo "resets=$(cat "$NIC_WATCHDOG_RUN/resets")" >>"$SANDBOX/log/seen" ;; esac
case "$*" in "-4 route show default") echo "default via 198.51.100.1 dev vmbr0" ;; esac'
  minutes 0 1
  [ "$(cat "$SANDBOX/log/seen")" = "resets=1" ]
}
t_admin_down_no_episode_no_action() {
  setup; export PING_RC=1; rm -f "$NIC_WATCHDOG_SYS/eno1/carrier"; mkdir "$NIC_WATCHDOG_SYS/eno1/carrier"
  minutes 0 39
  no_reset && no_reboot && ! called '^ping '
}
t_admin_down_in_episode_reboots() {
  setup; export PING_RC=2
  rm -f "$NIC_WATCHDOG_SYS/eno1/carrier"; mkdir "$NIC_WATCHDOG_SYS/eno1/carrier"
  echo 2 >"$NIC_WATCHDOG_RUN/resets"; echo $((T - 120)) >"$NIC_WATCHDOG_RUN/last_reset"
  echo $((T - 60)) >"$NIC_WATCHDOG_RUN/last_check"
  minutes 0 29; no_reboot && called 'ip link set eno1 up' || return 1
  minutes 30 30; called '^systemctl reboot$'
}
t_failed_link_set_logged_sequence_advances() {
  setup; export PING_RC=1 IP_LINK_RC=1; hang_on
  minutes 0 2
  [ "$(rv resets)" = 2 ] && grep -q 'ip link set eno1 down failed' "$SANDBOX/log/out" || return 1
  minutes 3 3; called '^systemctl reboot$'
}

# --- final review fixes
t_marker_directory_blocks_gateway_reboot() {
  setup; export PING_RC=1; mkdir "$NIC_WATCHDOG_STATE/gateway_reboot_marker"
  echo $((T - 25200)) >"$NIC_WATCHDOG_STATE/last_reboot"
  minutes 0 31; no_reboot || return 1
  minutes 32 46
  no_reboot && [ "$(count 'ip link set eno1 down')" = 3 ]
}
t_leading_zero_reboot_time_refused() {
  local v
  for v in 0100 0999999; do
    setup; export PING_RC=1; hang_on; echo "$v" >"$NIC_WATCHDOG_STATE/last_reboot"
    minutes 0 3
    no_reboot && [ "$(sv last_reboot)" = $((T + 180)) ] && [ "$(rv resets)" = 2 ] || return 1
  done
}
t_failed_reboot_logged_and_reported() {
  setup; export PING_RC=1; hang_on; stub systemctl 'exit 1'
  minutes 0 3
  grep -q 'systemctl reboot failed' "$SANDBOX/log/out" && grep -q 'reboot failed' "$NIC_WATCHDOG_STATE/report"
}
t_reset_outcome_reported() {
  setup; export PING_RC=1; hang_on; minutes 0 1
  grep -q 'reset eno1 (hang, gateway lost): carrier back after 0s' "$NIC_WATCHDOG_STATE/report" || return 1
  grep -q 'reset of eno1 finished: carrier back after 0s' "$SANDBOX/log/out" || return 1
  setup; export PING_RC=1; hang_on; carrier 0; minutes 0 1
  grep -q 'hang, gateway lost): carrier not back after 15s' "$NIC_WATCHDOG_STATE/report" || return 1
  setup; export PING_RC=1 IP_LINK_RC=1; hang_on; minutes 0 1
  grep -q 'hang, gateway lost): ip link failed' "$NIC_WATCHDOG_STATE/report"
}
t_exact_arguments() {
  setup; export PING_RC=0; run_at "$T"
  called '^journalctl -k -b 0 --no-pager -o cat --since @' && called '^ping -c 3 -W 2 -I vmbr0 198\.51\.100\.1$'
}
t_wedged_link_reboots_when_allowed() {
  setup; wedged_ip; export PING_RC=1; hang_on
  minutes 0 1
  local rc=0
  { called '^systemctl reboot$' && [ "$(count 'ip link set')" = 1 ] && ! called 'ip link set eno1 up'; } || rc=1
  reap_stubs; return $rc
}
t_wedged_link_refused_then_retries_without_link() {
  setup; wedged_ip; export PING_RC=1; hang_on; echo $((T - 3600)) >"$NIC_WATCHDOG_STATE/last_reboot"
  minutes 0 1
  local rc=0
  { no_reboot && [ -e "$NIC_WATCHDOG_RUN/reset_wedged" ] && [ "$(count 'ip link set')" = 1 ]; } || rc=1
  # later checks: no ip link call, and the reboot is tried (refused) again
  minutes 2 4
  { [ "$(count 'ip link set')" = 1 ] && [ "$(grep -c 'reboot refused' "$SANDBOX/log/out")" -ge 4 ]; } || rc=1
  # a stale gap does not clear reset_wedged
  run_at $((T + 10000))
  { no_reboot && [ -e "$NIC_WATCHDOG_RUN/reset_wedged" ] && [ "$(count 'ip link set')" = 1 ]; } || rc=1
  # six hours after the last reboot it goes ahead
  run_at $((T + 20000))
  { called '^systemctl reboot$' && [ "$(count 'ip link set')" = 1 ]; } || rc=1
  reap_stubs; return $rc
}

# --- never restart a healthy server
# reach_reboot <route> <final ping status>: bring the real script to the one check that would reboot,
# by each route that can get there, and run that check with the final ping answering as told.
# Returns non-zero if the ping meant to be final was never used, which would make the result empty.
reach_reboot() {
  setup; export PING_RC=1
  case "$1" in
    hang) hang_on; minutes 0 2; ping_seq 1 "$2"; run_at $((T + 180)) ;;
    gateway) minutes 0 29; ping_seq 1 "$2"; run_at $((T + 1800)) ;;
    stuck_down|stuck_up)
      wedged_ip "${1#stuck_}"; hang_on; run_at "$T"; ping_seq 1 "$2"; run_at $((T + 60)) ;;
    wedged_retry)
      wedged_ip; hang_on; run_at "$T"; ping_seq 1 0; run_at $((T + 60))
      [ -e "$NIC_WATCHDOG_RUN/reset_wedged" ] || return 1
      ping_seq "$2"; run_at $((T + 120)) ;;
    admin_down_up)
      wedged_ip up; rm -f "$NIC_WATCHDOG_SYS/eno1/carrier"; mkdir "$NIC_WATCHDOG_SYS/eno1/carrier"
      seed_episode 2; ping_seq "$2"; run_at "$T" ;;
    carrier_down) carrier 0; seed_episode 2; minutes 0 29; ping_seq "$2"; run_at $((T + 1800)) ;;
    carrier_down_hang) carrier 0; seed_hang_ready; ping_seq "$2"; run_at "$T" ;;
    answering_then_lost)
      export PING_RC=0; hang_on; minutes 0 1
      export PING_RC=1; echo 2 >"$NIC_WATCHDOG_RUN/resets"; ping_seq 1 "$2"; run_at $((T + 360)) ;;
    *) return 1 ;;
  esac
  [ ! -s "$SANDBOX/ping-seq" ]
}
REBOOT_ROUTES="hang gateway stuck_down stuck_up wedged_retry admin_down_up carrier_down carrier_down_hang answering_then_lost"
t_answering_gateway_vetoes_every_reboot() {
  local route rc=0
  for route in $REBOOT_ROUTES; do
    reach_reboot "$route" 0 || { echo "$route: did not reach the final ping"; rc=1; }
    if called '^systemctl reboot$' || [ -e "$NIC_WATCHDOG_STATE/last_reboot" ] || [ -e "$NIC_WATCHDOG_STATE/gateway_reboot_marker" ]; then
      echo "$route: rebooted or wrote reboot state with the gateway answering"; rc=1
    fi
    grep -q 'reboot vetoed' "$SANDBOX/log/out" || { echo "$route: the veto was not logged"; rc=1; }
    reap_stubs
    # the same check, with the final ping getting no reply, does reboot
    reach_reboot "$route" 1 || { echo "$route: did not reach the final ping"; rc=1; }
    { called '^systemctl reboot$' && [ -e "$NIC_WATCHDOG_STATE/last_reboot" ]; } ||
      { echo "$route: did not reboot with no reply"; rc=1; }
    reap_stubs
  done
  return $rc
}
t_one_reboot_call_in_the_script() {
  # every line that could reboot the host, leaving out comments and log messages
  local lines
  lines="$(sed -E 's/(^|[[:space:]])#[[:space:]].*//' "$WD" | grep -v 'log "' |
    grep -E 'systemctl[[:space:]]|/sbin/|(^|[[:space:]])(reboot|shutdown|poweroff|halt|telinit)[[:space:]]*(-|;|$)')"
  [ "$lines" = '  if ! systemctl reboot; then' ] || return 1
  # and the gate sits between the limits and that call, on the only path to it
  awk '/gate_allows_reboot "\$reason" \|\| return 1/ {g=NR} /put "\$STATE\/last_reboot" "\$NOW" \|\|/ {w=NR} /if ! systemctl reboot; then/ {r=NR}
    END {exit !(g && w && r && g < w && w < r)}' "$WD"
}
t_slow_carrier_read_no_reboot() {
  setup; slow_carrier; export PING_RC=0
  run_at "$T"; run_at $((T + 60))
  local rc=0
  { no_reboot_state && no_reset && [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ] && [ ! -e "$NIC_WATCHDOG_RUN/gateway_lost_since" ]; } || rc=1
  grep -q 'carrier read for eno1 did not finish' "$SANDBOX/log/out" || rc=1
  # the read recovers on a healthy host: still nothing, then or at six hours
  restore_carrier
  run_at $((T + 120)); run_at $((T + 21900))
  { no_reboot_state && no_reset && [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ]; } || rc=1
  return $rc
}
t_slow_carrier_read_in_episode_gate_decides() {
  local rc=0 how final
  for how in hang episode; do
    for final in 0 1; do
      setup; slow_carrier
      if [ "$how" = hang ]; then
        seed_hang_ready
      else
        seed_episode 2; echo $((T - 1800)) >"$NIC_WATCHDOG_RUN/gateway_lost_since"
      fi
      ping_seq 1 "$final"; run_at "$T"
      [ ! -s "$SANDBOX/ping-seq" ] || rc=1
      [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ] || rc=1
      if [ "$final" = 0 ]; then
        { no_reboot && [ ! -e "$NIC_WATCHDOG_STATE/last_reboot" ]; } || rc=1
      else
        called '^systemctl reboot$' || rc=1
      fi
      reap_stubs
    done
  done
  return $rc
}
t_gate_unknown_ping_refuses_without_evidence() {
  setup; export PING_RC=1; minutes 0 29
  ping_seq 1 2; run_at $((T + 1800))
  no_reboot && [ ! -e "$NIC_WATCHDOG_STATE/last_reboot" ] && [ ! -e "$NIC_WATCHDOG_STATE/gateway_reboot_marker" ] &&
    [ ! -s "$SANDBOX/ping-seq" ] && grep -q 'no direct evidence' "$SANDBOX/log/out" || return 1
  setup; seed_hang_ready; ping_seq 1 2; run_at "$T"
  no_reboot && [ ! -e "$NIC_WATCHDOG_STATE/last_reboot" ] && [ ! -s "$SANDBOX/ping-seq" ]
}
t_gate_unknown_ping_with_port_down_proceeds() {
  setup; export PING_RC=2; carrier 0; seed_hang_ready; run_at "$T"
  called '^systemctl reboot$' && grep -q 'ping exited 2, and carrier reads 0' "$NIC_WATCHDOG_STATE/report"
}
t_gate_unknown_ping_with_stuck_command_proceeds() {
  setup; wedged_ip down; export PING_RC=1; hang_on; run_at "$T"; ping_seq 1 2; run_at $((T + 60))
  local rc=0
  { called '^systemctl reboot$' && grep -q 'a link command is stuck' "$NIC_WATCHDOG_STATE/report"; } || rc=1
  reap_stubs; return $rc
}
t_gate_slow_carrier_read_is_not_evidence() {
  setup; slow_carrier; seed_hang_ready; ping_seq 1 2; run_at "$T"
  local rc=0
  { no_reboot && [ ! -s "$SANDBOX/ping-seq" ] && [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ]; } || rc=1
  reap_stubs; return $rc
}
t_gate_ping_overrun() {
  setup; real_sleep; export NIC_WATCHDOG_LINK_LIMIT=1 NIC_WATCHDOG_PING_LIMIT=1
  seed_hang_ready; ping_seq 1 hang; run_at "$T"
  no_reboot && [ ! -e "$NIC_WATCHDOG_STATE/last_reboot" ] && grep -q 'ping did not finish' "$NIC_WATCHDOG_STATE/report" || return 1
  setup; real_sleep; export NIC_WATCHDOG_LINK_LIMIT=1 NIC_WATCHDOG_PING_LIMIT=1
  carrier 0; seed_hang_ready; ping_seq hang; run_at "$T"
  called '^systemctl reboot$'
}
t_gate_no_route() {
  # the route is there for the check's own ping and gone when the gate looks
  setup; export PING_RC=1; seed_hang_ready
  stub ip 'case "$*" in "-4 route show default")
  [ -e "$SANDBOX/route-seen" ] || { : >"$SANDBOX/route-seen"; echo "default via 198.51.100.1 dev vmbr0"; } ;; esac'
  run_at "$T"
  no_reboot && [ ! -e "$NIC_WATCHDOG_STATE/last_reboot" ] && grep -q 'no default route on vmbr0, and no direct evidence' "$SANDBOX/log/out" || return 1
  setup; export PING_RC=1 NO_ROUTE=1; carrier 0; seed_hang_ready; run_at "$T"
  called '^systemctl reboot$'
}
t_answering_reset_slow_link_refused_then_decides_on_a_fresh_ping() {
  local which rc=0
  for which in down up; do
    setup; wedged_ip "$which"; export PING_RC=0; hang_on; run_at "$T"
    # the reset has moved the link, so this check's own gate ping gets no reply: E2 inside one check
    ping_seq 0 1; run_at $((T + 60))
    { no_reboot_state && [ -e "$NIC_WATCHDOG_RUN/reset_wedged" ] && [ ! -s "$SANDBOX/ping-seq" ]; } || rc=1
    grep -q 'moved under 300s ago' "$SANDBOX/log/out" || rc=1
    # still stuck with the gateway answering: the gate vetoes each check
    minutes 2 3
    { no_reboot_state && grep -q 'reboot vetoed' "$SANDBOX/log/out"; } || rc=1
    stuck_gone; hang_off; run_at $((T + 240))
    { no_reboot_state && [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ]; } || rc=1
  done
  return $rc
}
t_stuck_check_sends_report_and_ping() {
  setup; wedged_ip down; export PING_RC=1; hang_on; run_at "$T"
  ping_seq 1 0; run_at $((T + 60))
  local rc=0
  # the report of the stuck command goes out on the check whose gate answered
  { called 'curl .*hc\.test/abc/fail' && [ ! -e "$NIC_WATCHDOG_STATE/report" ]; } || rc=1
  # a later check that stops early because it is still stuck still sends the success ping
  : >"$CALLS"; export PING_RC=0; run_at $((T + 120))
  { called 'curl .*hc\.test/abc$' && [ -n "$(sv last_ping)" ] && no_reboot; } || rc=1
  # and a pending report goes out on such a check too
  echo "reset" >"$NIC_WATCHDOG_STATE/report"; : >"$CALLS"; run_at $((T + 180))
  { called 'curl .*hc\.test/abc/fail' && [ ! -e "$NIC_WATCHDOG_STATE/report" ] && [ -e "$NIC_WATCHDOG_RUN/reset_wedged" ]; } || rc=1
  reap_stubs; return $rc
}
t_report_states_the_actual_reason() {
  setup; wedged_ip down; export PING_RC=1; minutes 0 4; run_at $((T + 300))
  local rc=0
  called '^systemctl reboot$' || rc=1
  grep -q 'ip link set eno1 down did not finish' "$NIC_WATCHDOG_STATE/report" || rc=1
  grep -q 'reboot (stuck ip link set eno1 down): gateway gave no reply' "$NIC_WATCHDOG_STATE/report" || rc=1
  ! grep -q 'reboot (hang)' "$NIC_WATCHDOG_STATE/report" || rc=1
  reap_stubs; return $rc
}

# --- the stuck-command flag
t_wedge_clears_when_process_gone() {
  setup; wedged_ip down; export PING_RC=1; hang_on; run_at "$T"; ping_seq 1 0; run_at $((T + 60))
  no_reboot && [ "$(sed -n 's/^what=//p' "$NIC_WATCHDOG_RUN/reset_wedged")" = down ] || return 1
  stuck_gone; hang_off; export PING_RC=0; : >"$CALLS"
  run_at $((T + 120))
  [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ] && called '^ip link set eno1 up$' && ! called 'ip link set eno1 down' || return 1
  grep -q 'reset_wedged cleared' "$SANDBOX/log/out" || return 1
  # still healthy, on the next check and six hours on
  : >"$CALLS"; run_at $((T + 180)); run_at $((T + 21900)); run_at $((T + 21960))
  no_reboot && no_reset && [ ! -e "$NIC_WATCHDOG_STATE/last_reboot" ] && [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ]
}
t_wedge_up_gone_leaves_a_link_that_is_up() {
  setup; wedged_ip up; export PING_RC=1; hang_on; run_at "$T"; ping_seq 1 0; run_at $((T + 60))
  stuck_gone; hang_off; export PING_RC=0; : >"$CALLS"; run_at $((T + 120))
  [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ] && no_reset && no_reboot || return 1
  # the stuck command was up, but the link is administratively down: bring it up
  setup; wedged_ip up; export PING_RC=1; hang_on; run_at "$T"; ping_seq 1 0; run_at $((T + 60))
  stuck_gone; hang_off; rm -f "$NIC_WATCHDOG_SYS/eno1/carrier"; mkdir "$NIC_WATCHDOG_SYS/eno1/carrier"
  : >"$CALLS"; run_at $((T + 120))
  [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ] && called '^ip link set eno1 up$' && no_reboot
}
t_wedge_recovery_up_stuck_defers_to_next_check() {
  setup; export PING_RC=1; hang_on; wedged_ip down; run_at "$T"; ping_seq 1 0; run_at $((T + 60))
  reap_stubs; wedged_ip up; ping_seq 1; run_at $((T + 120))
  local rc=0
  { no_reboot && [ "$(sed -n 's/^what=//p' "$NIC_WATCHDOG_RUN/reset_wedged")" = up ]; } || rc=1
  reap_stubs; return $rc
}
t_wedge_unreadable_flag_counts_as_gone() {
  setup; export PING_RC=0; : >"$NIC_WATCHDOG_RUN/reset_wedged"; run_at "$T"
  [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ] && called '^ip link set eno1 up$' && no_reboot
}
t_wedge_pid_reuse_not_trusted() {
  setup; wedged_ip down; export PING_RC=1; hang_on; run_at "$T"; ping_seq 1 0; run_at $((T + 60))
  # keep the real start time, but point the pid at a different live process
  local other start
  command -p sleep 30 &
  other=$!; disown
  echo "$other" >>"$SANDBOX/log/pids"
  start="$(sed -n 's/^start=//p' "$NIC_WATCHDOG_RUN/reset_wedged")"
  [ -n "$start" ] || return 1
  printf 'pid=%s\nwhat=down\nstart=%s\n' "$other" "$start" >"$NIC_WATCHDOG_RUN/reset_wedged"
  [ -d "/proc/$other" ] || return 1
  plain_ip; hang_off; export PING_RC=0; : >"$CALLS"; run_at $((T + 120))
  local rc=0
  { [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ] && called '^ip link set eno1 up$' && no_reboot; } || rc=1
  reap_stubs; return $rc
}
t_failed_reboot_returns_nonzero() {
  setup; wedged_ip down; export PING_RC=1; hang_on; stub systemctl 'exit 1'
  minutes 0 1
  local rc=0
  { called '^systemctl reboot$' && grep -q 'systemctl reboot failed' "$SANDBOX/log/out"; } || rc=1
  # link_overrun only logs this when try_reboot says no reboot went ahead
  grep -q 'no reboot; reset_wedged set' "$SANDBOX/log/out" || rc=1
  run_at $((T + 120))
  { [ "$(count 'ip link set eno1 down')" = 1 ] && ! called 'ip link set eno1 up'; } || rc=1
  reap_stubs; return $rc
}
t_log_only_never_causes_reboot() {
  # a carrier overrun in log-only
  setup; slow_carrier; export PING_RC=1; : >"$NIC_WATCHDOG_LOG_ONLY_FILE"; seed_hang_ready; run_at "$T"
  local rc=0 f
  { [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ] && no_reboot && no_reset && [ ! -e "$NIC_WATCHDOG_STATE/report" ]; } || rc=1
  restore_carrier
  # a link command that would stick is never run in log-only
  setup; wedged_ip; export PING_RC=1; hang_on; : >"$NIC_WATCHDOG_LOG_ONLY_FILE"
  minutes 0 5
  { grep -q 'would reboot' "$SANDBOX/log/out" && [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ] && no_reset && no_reboot; } || rc=1
  for f in last_reboot gateway_reboot_marker answering_resets report; do
    [ ! -e "$NIC_WATCHDOG_STATE/$f" ] || rc=1
  done
  # the file comes off on a healthy host: nothing, then or at six hours
  rm -f "$NIC_WATCHDOG_LOG_ONLY_FILE"; plain_ip; hang_off; export PING_RC=0
  minutes 6 7; run_at $((T + 22000))
  { no_reboot && no_reset; } || rc=1
  # the resets log-only pretended to do do not count once it is off: the hang path starts over
  setup; export PING_RC=1; hang_on; : >"$NIC_WATCHDOG_LOG_ONLY_FILE"; minutes 0 5
  rm -f "$NIC_WATCHDOG_LOG_ONLY_FILE"; run_at $((T + 360))
  { no_reboot && no_reset && [ ! -e "$NIC_WATCHDOG_STATE/last_reboot" ]; } || rc=1
  # and neither does the gateway clock it ran
  setup; export PING_RC=1; : >"$NIC_WATCHDOG_LOG_ONLY_FILE"; minutes 0 31
  rm -f "$NIC_WATCHDOG_LOG_ONLY_FILE"; run_at $((T + 1920))
  { no_reboot && [ "$(rv gateway_lost_since)" = $((T + 1920)) ]; } || rc=1
  return $rc
}

# --- the clock behind the limit
# A wall-clock jump cannot be faked for one process here, so these split the two clocks: real time
# (what a stepped clock looks like to anything reading it) moves past the limit with uptime still.
t_clock_step_no_false_overrun() {
  setup; real_sleep; export NIC_WATCHDOG_LINK_LIMIT=1 PING_RC=0 NIC_WATCHDOG_UPTIME="$SANDBOX/uptime"
  echo "5000.00 4000.00" >"$NIC_WATCHDOG_UPTIME"
  stub ip 'case "$*" in "link set "*) command -p sleep 2 ;; esac
case "$*" in "-4 route show default") echo "default via 198.51.100.1 dev vmbr0" ;; esac'
  hang_on; minutes 0 1
  [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ] && no_reboot && [ "$(count 'ip link set eno1 (down|up)')" = 2 ] &&
    ! grep -q 'did not finish' "$SANDBOX/log/out"
}
t_uptime_moving_is_an_overrun() {
  setup; real_sleep; export NIC_WATCHDOG_LINK_LIMIT=5 PING_RC=1 NIC_WATCHDOG_UPTIME="$SANDBOX/uptime"
  echo "5000.08 4000.00" >"$NIC_WATCHDOG_UPTIME"
  stub ip 'case "$*" in "link set "*) echo "5100.09 4000.00" >"$NIC_WATCHDOG_UPTIME"; command -p sleep 1 ;; esac
case "$*" in "-4 route show default") echo "default via 198.51.100.1 dev vmbr0" ;; esac'
  hang_on; minutes 0 1
  grep -q 'ip link set eno1 down did not finish' "$SANDBOX/log/out" && ! grep -q 'value too great' "$SANDBOX/log/out"
}
t_uptime_comma_decimal_parses() {
  setup; real_sleep; export NIC_WATCHDOG_LINK_LIMIT=5 PING_RC=1 NIC_WATCHDOG_UPTIME="$SANDBOX/uptime"
  echo "5000,08 4000,00" >"$NIC_WATCHDOG_UPTIME"
  stub ip 'case "$*" in "link set "*) echo "5100,09 4000,00" >"$NIC_WATCHDOG_UPTIME"; command -p sleep 1 ;; esac
case "$*" in "-4 route show default") echo "default via 198.51.100.1 dev vmbr0" ;; esac'
  hang_on; minutes 0 1
  grep -q 'ip link set eno1 down did not finish' "$SANDBOX/log/out"
}
t_uptime_unreadable_still_bounds_the_wait() {
  setup; wedged_ip down; export PING_RC=1 NIC_WATCHDOG_UPTIME="$SANDBOX/no-such-file"; hang_on
  minutes 0 1
  local rc=0
  grep -q 'ip link set eno1 down did not finish' "$SANDBOX/log/out" || rc=1
  reap_stubs; return $rc
}

# --- each overrun branch
t_up_overrun_in_reset() {
  setup; wedged_ip up; export PING_RC=1; hang_on; run_at "$T"; ping_seq 1 0; run_at $((T + 60))
  local rc=0
  { [ "$(count 'ip link set eno1 down')" = 1 ] && [ "$(count 'ip link set eno1 up')" = 1 ] && no_reboot; } || rc=1
  [ "$(sed -n 's/^what=//p' "$NIC_WATCHDOG_RUN/reset_wedged")" = up ] || rc=1
  # the report was sent on the check whose gate answered, so read the log for the overrun
  grep -q 'ip link set eno1 up did not finish' "$SANDBOX/log/out" || rc=1
  run_at $((T + 120))
  [ "$(count 'ip link set')" = 2 ] || rc=1
  reap_stubs; return $rc
}
t_carrier_overrun_in_reset_loop() {
  local rc=0 final
  for final in 1 0; do
    setup; real_sleep; export NIC_WATCHDOG_LINK_LIMIT=1 PING_RC="$final"; hang_on
    stub ip 'case "$*" in "link set eno1 up") command -p rm -f "$NIC_WATCHDOG_SYS/eno1/carrier"; command -p mkfifo "$NIC_WATCHDOG_SYS/eno1/carrier" ;; esac
case "$*" in "-4 route show default") echo "default via 198.51.100.1 dev vmbr0" ;; esac'
    minutes 0 1
    { no_reboot && [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ] && [ -n "$(rv last_reset)" ]; } || rc=1
    grep -q 'reset of eno1 finished: carrier read did not finish in 1s' "$SANDBOX/log/out" || rc=1
    [ "$final" = 0 ] || grep -q 'carrier read did not finish in 1s' "$NIC_WATCHDOG_STATE/report" || rc=1
    reap_stubs
  done
  return $rc
}
t_admin_down_up_overrun() {
  setup; wedged_ip up; export PING_RC=2
  rm -f "$NIC_WATCHDOG_SYS/eno1/carrier"; mkdir "$NIC_WATCHDOG_SYS/eno1/carrier"
  seed_episode 2; ping_seq 0; run_at "$T"
  local rc=0
  { no_reboot && [ "$(count 'ip link set eno1 up')" = 1 ]; } || rc=1
  [ "$(sed -n 's/^what=//p' "$NIC_WATCHDOG_RUN/reset_wedged")" = up ] || rc=1
  grep -q 'ip link set eno1 up did not finish' "$SANDBOX/log/out" || rc=1
  # the next check touches no link, and with an unknown ping the stuck command is the evidence
  run_at $((T + 60))
  { called '^systemctl reboot$' && [ "$(count 'ip link set')" = 1 ]; } || rc=1
  reap_stubs; return $rc
}

# --- a port the watchdog itself moved (review sequences E1 to E8)
# E1a: answering resets, then a fresh hang line and lost pings on the next check.
t_e1a_lost_pings_after_answering_resets() {
  setup; since_journal; export PING_RC=0
  hl "$T"; run_at "$T"; hl $((T + 30)); run_at $((T + 60)); hl $((T + 90)); run_at $((T + 120))
  [ "$(count 'ip link set eno1 down')" = 2 ] || return 1
  hl $((T + 170)); ping_seq 1 1; run_at $((T + 180))
  no_reboot_state && [ -e "$NIC_WATCHDOG_RUN/answering_link_move" ]
}
# E1b: the same, with carrier still 0 from the watchdog's own reset, so one lost round only.
t_e1b_carrier_still_down_after_answering_resets() {
  setup; since_journal; export PING_RC=0
  hl "$T"; run_at "$T"; hl $((T + 30)); run_at $((T + 60)); hl $((T + 90)); run_at $((T + 120))
  carrier 0; hl $((T + 170)); ping_seq 1; run_at $((T + 180))
  no_reboot_state
}
# E2a, E2b: a link command overruns on the answering path, and the next check's gate gets no reply
# because the port is down through the watchdog's own doing.
t_e2_stuck_after_answering_reset_next_check_no_reply() {
  local which rc=0
  for which in up down; do
    setup; hang_on; export PING_RC=0; wedged_ip "$which"
    run_at "$T"; run_at $((T + 60))
    hang_off; ping_seq 1; run_at $((T + 120))
    { no_reboot_state && [ -e "$NIC_WATCHDOG_RUN/reset_wedged" ]; } || rc=1
    grep -q 'moved under 300s ago' "$SANDBOX/log/out" || rc=1
    reap_stubs
  done
  return $rc
}
# E3: an up that overran and then finished by itself, with carrier still 0.
t_e3_stuck_up_finishes_by_itself() {
  setup; since_journal; export PING_RC=0
  hl "$T"; run_at "$T"; hl $((T + 30)); run_at $((T + 60))
  wedged_ip up; hl $((T + 90)); run_at $((T + 120))
  [ "$(sed -n 's/^what=//p' "$NIC_WATCHDOG_RUN/reset_wedged")" = up ] || return 1
  stuck_gone; carrier 0; : >"$CALLS"
  hl $((T + 180)); hl $((T + 181)); hl $((T + 182)); ping_seq 1; run_at $((T + 180))
  no_reboot_state && [ ! -e "$NIC_WATCHDOG_RUN/reset_wedged" ]
}
# Item 2 on its own: the outage count is at 2 already, so only the marker and the wait stop this.
t_stuck_up_finished_sets_the_refusal_and_waits() {
  setup; wedged_ip up; export PING_RC=1; hang_on; run_at "$T"; ping_seq 1 0; run_at $((T + 60))
  stuck_gone; carrier 0; : >"$CALLS"; echo 2 >"$NIC_WATCHDOG_RUN/resets"
  run_at $((T + 120))
  no_reboot_state && no_reset && [ "$(rv answering_link_move)" = $((T + 120)) ] &&
    grep -q 'moved under 300s ago' "$SANDBOX/log/out" &&
    [ "$(count 'sleep 1$')" = 15 ]
}
# E4: hang messages with traffic flowing, then a few seconds of loss.
t_e4_answering_resets_stay_out_of_the_outage_count() {
  setup; hang_on; export PING_RC=0; minutes 0 3
  [ "$(count 'ip link set eno1 down')" = 2 ] && [ ! -e "$NIC_WATCHDOG_RUN/resets" ] || return 1
  ping_seq 1 1; run_at $((T + 240))
  # a real outage starts at reset 1
  no_reboot_state && [ "$(rv resets)" = 1 ] && [ "$(count 'ip link set eno1 down')" = 3 ]
}
t_recovery_with_hang_still_logged_restarts_the_outage_count() {
  setup; hang_on; export PING_RC=1; minutes 0 2
  [ "$(rv resets)" = 2 ] || return 1
  # traffic comes back with the hang messages still arriving, then one lost round
  export PING_RC=0; run_at $((T + 180))
  [ ! -e "$NIC_WATCHDOG_RUN/resets" ] || return 1
  export PING_RC=1; run_at $((T + 240))
  no_reboot_state && [ "$(rv resets)" = 1 ]
}
# E5: a dead host with a stuck carrier read and no hang.
t_e5_dead_host_with_stuck_carrier_read_recovers() {
  setup; slow_carrier; export PING_RC=1
  run_at "$T"
  [ "$(rv gateway_lost_since)" = "$T" ] && called '^ping ' || return 1
  local m rc=0
  for m in 5 10 15 20 25; do run_at $((T + 60 * m)); done
  [ "$(count 'ip link set eno1 down')" = 2 ] || rc=1
  no_reboot || rc=1
  run_at $((T + 1800))
  called '^systemctl reboot$' || rc=1
  reap_stubs; return $rc
}
# E8: a redirect that fails looks like "no reply" and "administratively down".
t_e8_failed_redirect_is_unknown() {
  setup; export PING_RC=0; mkdir "$NIC_WATCHDOG_RUN/limited.out"; hang_on
  minutes 0 6
  no_reboot_state && no_reset && ! called '^ping ' && [ ! -e "$NIC_WATCHDOG_RUN/resets" ] || return 1
  # not even a stuck command lets a reboot through with the gateway never asked
  setup; wedged_ip down; export PING_RC=1; hang_on; run_at "$T"; ping_seq 1 0; run_at $((T + 60))
  rm -f "$NIC_WATCHDOG_RUN/limited.out"; mkdir "$NIC_WATCHDOG_RUN/limited.out"; : >"$CALLS"
  run_at $((T + 120))
  local rc=0
  { no_reboot_state && ! called '^ping ' && grep -q 'could not run the gateway check' "$SANDBOX/log/out"; } || rc=1
  reap_stubs
  # at the gate, an evidence read that could not run is not "administratively down"
  setup; seed_hang_ready
  stub ping '[ -e "$SANDBOX/ping-seen" ] || { : >"$SANDBOX/ping-seen"; exit 1; }
command -p rm -f "$NIC_WATCHDOG_RUN/limited.out"; command -p mkdir "$NIC_WATCHDOG_RUN/limited.out"; exit 2'
  run_at "$T"
  { no_reboot_state && grep -q 'no direct evidence' "$SANDBOX/log/out"; } || rc=1
  return $rc
}

# --- the five-minute refusal
t_refusal_lasts_under_300s_then_allows() {
  setup; hang_on; export PING_RC=0; minutes 0 1
  [ "$(rv answering_link_move)" = $((T + 60)) ] || return 1
  export PING_RC=1; echo 2 >"$NIC_WATCHDOG_RUN/resets"
  run_at $((T + 120)); run_at $((T + 359))
  no_reboot_state && [ "$(grep -c 'moved under 300s ago' "$SANDBOX/log/out")" = 2 ] || return 1
  run_at $((T + 360))
  called '^systemctl reboot$'
}
t_refusal_survives_the_end_of_the_episode() {
  setup; hang_on; export PING_RC=0; minutes 0 1
  hang_off; run_at $((T + 120))   # answers, no hang: clear_episode
  [ -e "$NIC_WATCHDOG_RUN/answering_link_move" ] && [ ! -e "$NIC_WATCHDOG_RUN/hang_seen" ] || return 1
  seed_hang_ready; echo $((T + 120)) >"$NIC_WATCHDOG_RUN/last_check"; ping_seq 1 1; run_at $((T + 180))
  no_reboot_state && grep -q 'moved under 300s ago' "$SANDBOX/log/out"
}
t_refusal_unreadable_or_future_counts_as_just_now() {
  local v
  for v in garbage $((T + 9000)); do
    setup; export PING_RC=1; seed_hang_ready; echo "$v" >"$NIC_WATCHDOG_RUN/answering_link_move"
    run_at "$T"
    no_reboot_state && [ "$(rv answering_link_move)" = "$T" ] || return 1
  done
}
t_stuck_up_with_network_truly_down_reboots_after_the_refusal() {
  setup; hang_on; export PING_RC=0; wedged_ip up; run_at "$T"; ping_seq 0 1; run_at $((T + 60))
  export PING_RC=1; hang_off; run_at $((T + 120)); run_at $((T + 359))
  local rc=0
  no_reboot_state || rc=1
  run_at $((T + 360))
  { called '^systemctl reboot$' && grep -q 'reboot (stuck ip link set eno1 up): gateway gave no reply' "$NIC_WATCHDOG_STATE/report"; } || rc=1
  reap_stubs; return $rc
}
t_move_while_lost_sets_no_marker_and_keeps_its_timing() {
  # a real hang: about 4 minutes
  setup; hang_on; export PING_RC=1; minutes 0 2; no_reboot || return 1
  minutes 3 3; called '^systemctl reboot$' && [ ! -e "$NIC_WATCHDOG_RUN/answering_link_move" ] || return 1
  # a silent failure: 30 minutes
  setup; export PING_RC=1; minutes 0 29; no_reboot || return 1
  minutes 30 30; called '^systemctl reboot$' && [ ! -e "$NIC_WATCHDOG_RUN/answering_link_move" ]
}

# --- the route's device
t_route_on_another_device_is_unknown() {
  setup; export PING_RC=1
  stub ip 'case "$*" in "-4 route show default") echo "default via 198.51.100.1 dev wg0" ;; esac'
  local m
  for m in 0 5 10 15 20 25 30 35; do run_at $((T + 60 * m)); done
  no_reboot_state && no_reset && ! called '^ping ' && [ ! -e "$NIC_WATCHDOG_RUN/gateway_lost_since" ] || return 1
  # the gate reads it too: vmbr0 for the check's own ping, wg0 by the time the gate looks
  setup; export PING_RC=1; seed_hang_ready
  stub ip 'case "$*" in "-4 route show default")
  if [ -e "$SANDBOX/route-seen" ]; then echo "default via 198.51.100.1 dev wg0"; else : >"$SANDBOX/route-seen"; echo "default via 198.51.100.1 dev vmbr0"; fi ;; esac'
  run_at "$T"
  no_reboot_state && [ "$(count '^ping ')" = 1 ] && grep -q 'no default route on vmbr0, and no direct evidence' "$SANDBOX/log/out"
}

# --- what a failed write costs
t_report_write_failure_leaves_the_limit_untouched() {
  setup; export PING_RC=1; hang_on; minutes 0 2
  rm -f "$NIC_WATCHDOG_STATE/report"; mkdir "$NIC_WATCHDOG_STATE/report"
  run_at $((T + 180))
  no_reboot_state && grep -q 'cannot write the report; not rebooting' "$SANDBOX/log/out" || return 1
  # the write works again, and the limit was not used up
  rmdir "$NIC_WATCHDOG_STATE/report"; run_at $((T + 240))
  called '^systemctl reboot$' && [ "$(sv last_reboot)" = $((T + 240)) ]
}

# --- the stale gateway clock
t_unknown_result_restarts_the_gateway_clock() {
  local how m
  for how in ping_status journal route; do
    setup; export PING_RC=1; run_at "$T"
    [ "$(rv gateway_lost_since)" = "$T" ] || return 1
    case "$how" in
      ping_status) export PING_RC=2 ;;
      journal) export JOURNAL_RC=1 ;;
      route) export NO_ROUTE=1 ;;
    esac
    for m in 5 10 15 20 25 30 35 40; do run_at $((T + 60 * m)); done
    [ ! -e "$NIC_WATCHDOG_RUN/gateway_lost_since" ] && no_reset && no_reboot || return 1
    unset JOURNAL_RC NO_ROUTE; export PING_RC=1; run_at $((T + 2700))
    [ "$(rv gateway_lost_since)" = $((T + 2700)) ] && no_reset && no_reboot || return 1
  done
}
t_unknown_at_the_gate_restarts_the_gateway_clock() {
  setup; export PING_RC=1; minutes 0 29
  ping_seq 1 2; run_at $((T + 1800))
  no_reboot_state && [ ! -e "$NIC_WATCHDOG_RUN/gateway_lost_since" ] || return 1
  run_at $((T + 1860))
  no_reboot_state && [ "$(rv gateway_lost_since)" = $((T + 1860)) ]
}

# --- leftovers from stuck reads
t_stuck_reads_are_killed_and_link_commands_are_not() {
  setup; slow_carrier; export PING_RC=0; run_at "$T"; run_at $((T + 60))
  # a killed read leaves no subshell of the script behind
  [ "$(pgrep -fc "$WD")" = 0 ] || return 1
  grep -q Killed "$SANDBOX/log/out" && return 1
  restore_carrier
  # the route read: its pid is gone after the overrun
  setup; real_sleep; export NIC_WATCHDOG_LINK_LIMIT=1 PING_RC=0
  mkfifo "$SANDBOX/never"
  stub ip 'case "$*" in "-4 route show default") echo $$ >>"$SANDBOX/log/route-pid"; read -r _ <>"$SANDBOX/never" ;; esac'
  run_at "$T"
  local pid; pid="$(cat "$SANDBOX/log/route-pid")"
  [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null || return 1
  # a stuck link command stays alive for the flag to mean anything
  setup; wedged_ip down; export PING_RC=1; hang_on; run_at "$T"; ping_seq 1 0; run_at $((T + 60))
  pid="$(sed -n 's/^pid=//p' "$NIC_WATCHDOG_RUN/reset_wedged")"
  local rc=0
  kill -0 "$pid" 2>/dev/null || rc=1
  reap_stubs; return $rc
}
t_service_holds_killmode_process() {
  grep -qx 'KillMode=process' "$HS_DIR/host/systemd/nic-watchdog.service"
}

check "one hang alone does not reset" t_one_hang_no_reset
check "two hang checks reset the card, down then up" t_two_hangs_reset
check "hang sequence: reset, reset, then reboot" t_hang_sequence_reboots
check "hangs while the gateway answers stop at two resets and never reboot" t_hang_gateway_answers_capped
check "separate hangs share one cap inside six hours" t_separate_hangs_share_cap
check "a hang on another NIC is ignored" t_other_nic_ignored
check "gateway-only timeline: resets at 5 and 15 minutes, reboot at 30" t_gateway_timeline
check "gateway recovery clears the episode and the clock" t_gateway_recovery_clears
check "a reboot inside the limit is refused, resets retry every 30 minutes" t_reboot_inside_limit_refused
check "a reboot after the limit is allowed" t_reboot_after_limit_allowed
check "a corrupt last_reboot refuses and is rewritten" t_corrupt_reboot_time_refused
check "a future last_reboot refuses and is rewritten" t_future_reboot_time_refused
check "the marker blocks a gateway reboot but resets continue" t_marker_blocks_gateway_reboot
check "the marker clears when the gateway answers" t_marker_clears_when_gateway_answers
check "the marker does not block a hang reboot" t_marker_does_not_block_hang
check "state is written before systemctl reboot runs" t_state_written_before_reboot
check "an unwritable state directory never reboots" t_unwritable_state_no_reboot
check "carrier down with no episode does nothing and never pings" t_carrier_down_no_episode
check "carrier staying down after resets reboots without a ping" t_carrier_stays_down_after_reset
check "a hang with carrier down is an episode" t_hang_with_carrier_down_is_episode
check "an unknown ping status takes no action" t_ping_unknown_no_action
check "no default route takes no action" t_no_route_no_action
check "a failing journalctl takes no action" t_journal_fails_no_action
check "a missing carrier file takes no action" t_carrier_missing_no_action
check "a missing NIC exits 1 without acting" t_missing_nic_exits_1
check "stale state is discarded after a long pause" t_stale_state_discarded
check "log-only mode takes no action and writes no durable state" t_log_only_no_actions
check "a report is kept until it is sent" t_report_kept_until_sent
check "a report is sent while a hang is still logged" t_report_sent_while_hanging
check "a report survives a reboot" t_report_survives_reboot
check "the success ping goes out hourly" t_hourly_ping
check "a blank URL sends nothing" t_blank_url_sends_nothing
check "the URL never reaches the log" t_url_never_logged
check "a missing state directory is created and the reset cap holds" t_missing_state_dir_cap_holds
check "an unwritable state path refuses resets while the gateway answers" t_unwritable_state_answering_no_reset
check "the next journal window starts at the reset" t_journal_window_starts_at_reset
check "the reset is counted before the link goes down" t_reset_counted_before_link_down
check "admin-down with no episode takes no action" t_admin_down_no_episode_no_action
check "admin-down in an episode retries up and reaches a reboot" t_admin_down_in_episode_reboots
check "a failing ip link set is logged and the sequence advances" t_failed_link_set_logged_sequence_advances
check "a marker that is a directory still blocks a gateway reboot" t_marker_directory_blocks_gateway_reboot
check "a last_reboot with leading zeros is refused and rewritten" t_leading_zero_reboot_time_refused
check "a failed systemctl reboot is logged and reported" t_failed_reboot_logged_and_reported
check "a reset's outcome is logged and reported" t_reset_outcome_reported
check "journalctl and ping get their exact arguments" t_exact_arguments
check "an ip link that wedges goes straight to a reboot when allowed" t_wedged_link_reboots_when_allowed
check "a wedged reset refused by the limit stays wedged, makes no link call, reboots at six hours" t_wedged_link_refused_then_retries_without_link
check "INVARIANT: an answering gateway vetoes every route to a reboot; no reply reboots on each" t_answering_gateway_vetoes_every_reboot
check "the script has exactly one systemctl reboot" t_one_reboot_call_in_the_script
check "a slow carrier read on a healthy host: no reboot, no flag" t_slow_carrier_read_no_reboot
check "a slow carrier read in an episode: the gate decides" t_slow_carrier_read_in_episode_gate_decides
check "gate: an unknown ping with no evidence refuses" t_gate_unknown_ping_refuses_without_evidence
check "gate: an unknown ping with the port down proceeds" t_gate_unknown_ping_with_port_down_proceeds
check "gate: an unknown ping with a stuck command proceeds" t_gate_unknown_ping_with_stuck_command_proceeds
check "gate: a slow carrier read is not evidence" t_gate_slow_carrier_read_is_not_evidence
check "gate: a ping overrun needs evidence" t_gate_ping_overrun
check "gate: no default route needs evidence" t_gate_no_route
check "a slow ip link on the answering path is refused, and a fresh ping decides" t_answering_reset_slow_link_refused_then_decides_on_a_fresh_ping
check "a check stopped by a stuck command still sends the report and the ping" t_stuck_check_sends_report_and_ping
check "the report states the actual reason, not hang" t_report_states_the_actual_reason
check "a stuck command that finishes clears the flag, brings the link up, and nothing reboots" t_wedge_clears_when_process_gone
check "a finished stuck up leaves an up link alone and fixes an admin-down one" t_wedge_up_gone_leaves_a_link_that_is_up
check "a stuck up during recovery waits for the next check" t_wedge_recovery_up_stuck_defers_to_next_check
check "an empty or unreadable flag counts as finished" t_wedge_unreadable_flag_counts_as_gone
check "a reused pid is not trusted" t_wedge_pid_reuse_not_trusted
check "a failed reboot returns non-zero and the next check makes no link call" t_failed_reboot_returns_nonzero
check "log-only mode can never lead to a reboot" t_log_only_never_causes_reboot
check "a wall-clock jump during a healthy command is no overrun" t_clock_step_no_false_overrun
check "the uptime clock moving past the limit is an overrun" t_uptime_moving_is_an_overrun
check "a comma decimal in the uptime parses" t_uptime_comma_decimal_parses
check "an unreadable uptime still bounds the wait" t_uptime_unreadable_still_bounds_the_wait
check "an up that overruns in a reset" t_up_overrun_in_reset
check "a carrier read that overruns in the reset loop finishes the reset, no flag" t_carrier_overrun_in_reset_loop
check "an up that overruns on an administratively down link" t_admin_down_up_overrun
check "E1a: lost pings after answering resets do not reboot" t_e1a_lost_pings_after_answering_resets
check "E1b: carrier down after answering resets does not reboot" t_e1b_carrier_still_down_after_answering_resets
check "E2a, E2b: a stuck command after an answering reset, no reply next check, no reboot" t_e2_stuck_after_answering_reset_next_check_no_reply
check "E3: a stuck up that finishes by itself does not reboot" t_e3_stuck_up_finishes_by_itself
check "a finished stuck up sets the refusal and waits for carrier" t_stuck_up_finished_sets_the_refusal_and_waits
check "E4: answering resets stay out of the outage count" t_e4_answering_resets_stay_out_of_the_outage_count
check "recovery with hang messages still arriving restarts the outage count" t_recovery_with_hang_still_logged_restarts_the_outage_count
check "E5: a dead host with a stuck carrier read still recovers" t_e5_dead_host_with_stuck_carrier_read_recovers
check "E8: a failed redirect is unknown, and never reboots without asking the gateway" t_e8_failed_redirect_is_unknown
check "the refusal lasts while under 300s and allows a reboot at 300s" t_refusal_lasts_under_300s_then_allows
check "the refusal survives the end of the episode" t_refusal_survives_the_end_of_the_episode
check "an unreadable or future move time counts as just now" t_refusal_unreadable_or_future_counts_as_just_now
check "a stuck up with the network truly down reboots after the refusal" t_stuck_up_with_network_truly_down_reboots_after_the_refusal
check "a move while the gateway was lost sets no marker; hang at 4 minutes, silent at 30" t_move_while_lost_sets_no_marker_and_keeps_its_timing
check "a default route on another device is unknown" t_route_on_another_device_is_unknown
check "a report write failure leaves the 6 hour limit untouched" t_report_write_failure_leaves_the_limit_untouched
check "an unknown result restarts the gateway clock" t_unknown_result_restarts_the_gateway_clock
check "an unknown at the gate restarts the gateway clock" t_unknown_at_the_gate_restarts_the_gateway_clock
check "stuck reads are killed, stuck link commands are not" t_stuck_reads_are_killed_and_link_commands_are_not
check "the service holds KillMode=process" t_service_holds_killmode_process
reap_stubs
finish
