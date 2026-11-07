#!/usr/bin/env bash
# shellcheck disable=SC2016  # stub bodies are single-quoted: they expand when the stub runs
# deployment/home-server/test/timers_test.sh
# heartbeat.sh, reboot-if-required.sh and install-units.sh.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"

setup() {
  new_sandbox
  write_env ROLE=fetcher REPO_REF=main TUNNELS_ENABLED=0 HC_HEARTBEAT=https://hc.test/beat
  export REBOOT_FLAG="$SANDBOX/run/reboot-required" SYSTEMD_DIR="$SANDBOX/systemd"
  mkdir -p "$SYSTEMD_DIR"
  unset SERVICE_DOWN
  stub curl 'case "${!#}" in http://127.0.0.1:*) [ -z "${SERVICE_DOWN:-}" ] ;; esac'
  stub systemctl ''
}

t_beat_when_up() { setup; "$GUEST/heartbeat.sh" && called 'hc\.test/beat$'; }
t_silent_when_down() {
  setup; export SERVICE_DOWN=1
  "$GUEST/heartbeat.sh"; ! called 'hc\.test/beat'
}
t_ol_beats_on_version() {
  setup; write_env ROLE=ol HC_HEARTBEAT=https://hc.test/beat
  "$GUEST/heartbeat.sh" && called 'curl .*127\.0\.0\.1:8080/version'
}
t_fetcher_beats_on_health() {
  setup; "$GUEST/heartbeat.sh" && called 'curl .*127\.0\.0\.1:8081/health' && ! called '8080/version'
}
t_worldcat_beats_on_version() {
  setup; write_env ROLE=worldcat HC_HEARTBEAT=https://hc.test/beat
  "$GUEST/heartbeat.sh" && called 'curl .*127\.0\.0\.1:8082/version' && called 'hc\.test/beat$'
}
t_no_flag_no_reboot() { setup; "$GUEST/reboot-if-required.sh" && ! called 'systemctl reboot'; }
t_flag_reboots() { setup; touch "$REBOOT_FLAG"; "$GUEST/reboot-if-required.sh" && called '^systemctl reboot$'; }
t_build_defers_reboot() {
  setup; touch "$REBOOT_FLAG"
  flock "$BUILD_LOCK" sleep 3 &
  sleep 0.5
  "$GUEST/reboot-if-required.sh"; rc=$?
  wait
  [ "$rc" = 0 ] && ! called 'systemctl reboot'
}
t_restore_check_defers_the_pgverify_reboot() {
  setup; write_env ROLE=pgverify; touch "$REBOOT_FLAG"; export PGVERIFY_LOCK="$SANDBOX/run/pgverify.lock"
  flock "$PGVERIFY_LOCK" sleep 3 &
  sleep 0.5
  "$GUEST/reboot-if-required.sh"; rc=$?
  wait
  [ "$rc" = 0 ] && ! called 'systemctl reboot' || return 1
  # With the check not running it reboots.
  : >"$CALLS"
  "$GUEST/reboot-if-required.sh" && called '^systemctl reboot$'
}
t_other_roles_ignore_the_pgverify_lock() {
  setup; touch "$REBOOT_FLAG"; export PGVERIFY_LOCK="$SANDBOX/run/pgverify.lock"
  flock "$PGVERIFY_LOCK" sleep 3 &
  sleep 0.5
  "$GUEST/reboot-if-required.sh"; rc=$?
  wait
  [ "$rc" = 0 ] && called '^systemctl reboot$'
}
t_units_for_ol() {
  setup; write_env ROLE=ol
  "$GUEST/install-units.sh" && [ -f "$SYSTEMD_DIR/ol-refresh.timer" ] &&
    [ -f "$SYSTEMD_DIR/recommender-train.timer" ] && [ -f "$SYSTEMD_DIR/recommender-train.service" ] &&
    called 'systemctl daemon-reload' && called 'systemctl enable --now ol-refresh.timer' &&
    called 'systemctl enable --now recommender-train.timer'
}
t_units_for_fetcher() {
  setup; "$GUEST/install-units.sh" && [ ! -f "$SYSTEMD_DIR/ol-refresh.timer" ] &&
    [ ! -f "$SYSTEMD_DIR/recommender-train.timer" ] && [ -f "$SYSTEMD_DIR/the-greatest-deploy.timer" ]
}
t_units_for_worldcat() {
  setup; write_env ROLE=worldcat
  "$GUEST/install-units.sh" && [ -f "$SYSTEMD_DIR/the-greatest-deploy.timer" ] &&
    [ -f "$SYSTEMD_DIR/the-greatest-heartbeat.timer" ] && [ -f "$SYSTEMD_DIR/reboot-if-required.timer" ] &&
    [ ! -f "$SYSTEMD_DIR/ol-refresh.timer" ] && [ ! -f "$SYSTEMD_DIR/recommender-train.timer" ] &&
    [ "$(find "$SYSTEMD_DIR" -type f | wc -l)" = 6 ]
}
t_units_for_pgverify() {
  setup; write_env ROLE=pgverify
  "$GUEST/install-units.sh" && [ -f "$SYSTEMD_DIR/pg-restore-verify.timer" ] && [ -f "$SYSTEMD_DIR/pg-restore-verify.service" ] &&
    [ -f "$SYSTEMD_DIR/the-greatest-deploy.timer" ] && [ -f "$SYSTEMD_DIR/reboot-if-required.timer" ] &&
    # No heartbeat: it runs no always-on service, and pg-restore-verified is its alert.
    [ ! -e "$SYSTEMD_DIR/the-greatest-heartbeat.timer" ] && [ ! -e "$SYSTEMD_DIR/ol-refresh.timer" ] &&
    [ ! -e "$SYSTEMD_DIR/recommender-train.timer" ] && [ "$(find "$SYSTEMD_DIR" -type f | wc -l)" = 6 ] &&
    called 'systemctl enable --now pg-restore-verify.timer' && ! called 'heartbeat'
}
t_others_get_no_pg_unit() {
  local r
  for r in ol fetcher worldcat; do
    setup; write_env ROLE=$r
    "$GUEST/install-units.sh" && [ ! -e "$SYSTEMD_DIR/pg-restore-verify.timer" ] || return 1
  done
}
t_units_idempotent() {
  setup; "$GUEST/install-units.sh" && : >"$CALLS" &&
    "$GUEST/install-units.sh" && ! called 'daemon-reload'
}

check "heartbeat pings when the service answers" t_beat_when_up
check "heartbeat stays silent when the service is down" t_silent_when_down
check "the ol heartbeat asks /version" t_ol_beats_on_version
check "the fetcher heartbeat asks /health" t_fetcher_beats_on_health
check "the worldcat heartbeat asks /version on 8082" t_worldcat_beats_on_version
check "no reboot-required flag, no reboot" t_no_flag_no_reboot
check "the flag reboots" t_flag_reboots
check "a running build defers the reboot" t_build_defers_reboot
check "a running restore check defers the pgverify reboot, and its absence does not" t_restore_check_defers_the_pgverify_reboot
check "the other roles do not wait for the pgverify lock" t_other_roles_ignore_the_pgverify_lock
check "ol gets the refresh and train timers" t_units_for_ol
check "fetcher gets neither" t_units_for_fetcher
check "worldcat gets the three base units and nothing else" t_units_for_worldcat
check "pgverify gets the deploy, reboot and restore-check timers and no heartbeat" t_units_for_pgverify
check "no other role gets the restore check" t_others_get_no_pg_unit
check "a second install changes nothing" t_units_idempotent
finish
