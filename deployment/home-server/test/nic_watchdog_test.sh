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
  unset PING_RC JOURNAL_RC CURL_RC NO_ROUTE IP_LINK_RC NIC_WATCHDOG_LINK_LIMIT
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
  stub ping 'exit "${PING_RC:-0}"'
  stub ip 'case "$*" in "link set "*) exit "${IP_LINK_RC:-0}" ;; esac
case "$*" in "-4 route show default") [ -n "${NO_ROUTE:-}" ] || echo "default via 198.51.100.1 dev vmbr0" ;; esac'
  stub systemctl ''
  stub curl 'echo "https://hc.test/abc" >&2; exit "${CURL_RC:-0}"'
  stub sleep ''
}

carrier() { printf '%s\n' "$1" >"$NIC_WATCHDOG_SYS/eno1/carrier"; }
# real_sleep: the script's polling sleep (0.1) and reset pause (3, shortened to 1) really wait.
real_sleep() { stub sleep 'case "$1" in 0.1) command -p sleep 0.1 ;; 3) command -p sleep 1 ;; esac'; }
# wedged_ip: `ip link set` blocks in a background-safe sleep and records its pids for reap_stubs.
wedged_ip() {
  stub ip 'case "$*" in "link set "*) echo $$ >>"$SANDBOX/log/pids"; command -p sleep 30 & echo $! >>"$SANDBOX/log/pids"; wait ;; esac
case "$*" in "-4 route show default") echo "default via 198.51.100.1 dev vmbr0" ;; esac'
  real_sleep
  export NIC_WATCHDOG_LINK_LIMIT=1
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
t_wedged_carrier_read_reboots_and_blocks_link() {
  setup; real_sleep; export NIC_WATCHDOG_LINK_LIMIT=1 PING_RC=1
  rm -f "$NIC_WATCHDOG_SYS/eno1/carrier"; mkfifo "$NIC_WATCHDOG_SYS/eno1/carrier"
  echo $((T - 3600)) >"$NIC_WATCHDOG_STATE/last_reboot"
  run_at "$T"
  local rc=0
  { no_reboot && [ -e "$NIC_WATCHDOG_RUN/reset_wedged" ]; } || rc=1
  run_at $((T + 60))
  { no_reset && no_reboot; } || rc=1
  echo $((T - 25200)) >"$NIC_WATCHDOG_STATE/last_reboot"
  run_at $((T + 120))
  { called '^systemctl reboot$' && no_reset; } || rc=1
  reap_stubs; return $rc
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
check "a carrier read that wedges marks the boot wedged and reboots when allowed" t_wedged_carrier_read_reboots_and_blocks_link
reap_stubs
finish
