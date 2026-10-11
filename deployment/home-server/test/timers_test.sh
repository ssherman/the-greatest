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
t_units_idempotent() {
  setup; "$GUEST/install-units.sh" && : >"$CALLS" &&
    "$GUEST/install-units.sh" && ! called 'daemon-reload'
}

check "heartbeat pings when the service answers" t_beat_when_up
check "heartbeat stays silent when the service is down" t_silent_when_down
check "the ol heartbeat asks /version" t_ol_beats_on_version
check "the fetcher heartbeat asks /health" t_fetcher_beats_on_health
check "no reboot-required flag, no reboot" t_no_flag_no_reboot
check "the flag reboots" t_flag_reboots
check "a running build defers the reboot" t_build_defers_reboot
check "ol gets the refresh and train timers" t_units_for_ol
check "fetcher gets neither" t_units_for_fetcher
check "a second install changes nothing" t_units_idempotent
finish
