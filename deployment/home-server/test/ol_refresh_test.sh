#!/usr/bin/env bash
# shellcheck disable=SC2016  # stub bodies are single-quoted: they expand when the stub runs
# deployment/home-server/test/ol_refresh_test.sh
# guest/ol-refresh.sh against a stubbed compose (the versions CLI, the build,
# the API) and a stubbed curl (healthchecks.io and the API's /version).
set -uo pipefail
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"

setup() {
  new_sandbox
  write_env ROLE=ol REPO_REF=main TUNNELS_ENABLED=0 HC_REFRESH=https://hc.test/refresh
  export PROMOTE_TIMEOUT_S=1 POLL_S=0 API_URL=http://api.test
  unset NEXT_ACTION NEXT_ACTION_FAIL BUILD_EXIT BROKEN_VERSION NOT_MOUNTED
  stub mountpoint '[ -z "${NOT_MOUNTED:-}" ]'
  stub curl 'url="${!#}"
case "$url" in
  */version) [ -f "$SANDBOX/serving" ] || exit 7; printf "{\"dump_date\":\"%s\"}" "$(cat "$SANDBOX/serving")" ;;
esac'
  stub compose 'case "$*" in
  *"versions next-action"*) [ -z "${NEXT_ACTION_FAIL:-}" ] || exit 1; echo "$NEXT_ACTION" ;;
  *"versions status"*) cat "$SANDBOX/status.json" ;;
  *"versions prune"*) ;;
  "run --rm --no-deps -T build") exit "${BUILD_EXIT:-0}" ;;
  "up -d api") if [ "$OL_DATA_VERSION" = "${BROKEN_VERSION:-}" ]; then rm -f "$SANDBOX/serving"; else echo "$OL_DATA_VERSION" >"$SANDBOX/serving"; fi ;;
  "stop api") rm -f "$SANDBOX/serving" ;;
esac'
  export COMPOSE="$SANDBOX/bin/compose"
}
status_json() { printf '%s' "$1" >"$SANDBOX/status.json"; }
serving() { echo "$1" >"$OL_DATA/current-version"; echo "$1" >"$SANDBOX/serving"; }
refresh() { "$GUEST/ol-refresh.sh" >"$SANDBOX/log/out" 2>&1; }

t_skip_built() {
  setup; serving 2026-08-31; export NEXT_ACTION="skip built 2026-08-31"
  refresh && ! called '^compose run --rm --no-deps -T build$' && called 'hc\.test/refresh$'
}
t_mismatch() {
  setup; export NEXT_ACTION="skip mismatch dumps resolve to more than one date"
  refresh && ! called '^compose run --rm --no-deps -T build$' && ! called 'refresh/fail'
}
t_promotes() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30"
  status_json '{"passing":["2026-08-31","2026-09-30"],"failed":[],"incomplete":[]}'
  refresh && [ "$(cat "$OL_DATA/current-version")" = 2026-09-30 ] &&
    called 'versions prune --keep 2 --current 2026-09-30' && called 'hc\.test/refresh$'
}
t_gate_failure() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30" BUILD_EXIT=1
  status_json '{"passing":["2026-08-31"],"failed":["2026-09-30"],"incomplete":[]}'
  mkdir -p "$OL_DATA/versions/2026-09-30"
  echo '{"gates":[{"name":"row_counts","status":"pass"},{"name":"evaluation_set","status":"fail"}]}' \
    >"$OL_DATA/versions/2026-09-30/build_report.json"
  ! refresh && [ "$(cat "$OL_DATA/current-version")" = 2026-08-31 ] &&
    called 'evaluation_set.*refresh/fail' && ! called '^compose up -d api$'
}
t_crash() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30" BUILD_EXIT=137
  status_json '{"passing":["2026-08-31"],"failed":[],"incomplete":["2026-09-30"]}'
  ! refresh && [ "$(cat "$OL_DATA/current-version")" = 2026-08-31 ] &&
    called 'did not finish.*refresh/fail'
}
t_reverts() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30" BROKEN_VERSION=2026-09-30
  status_json '{"passing":["2026-08-31","2026-09-30"],"failed":[],"incomplete":[]}'
  ! refresh && [ "$(cat "$OL_DATA/current-version")" = 2026-08-31 ] &&
    [ "$(cat "$SANDBOX/serving")" = 2026-08-31 ] && called 'refresh/fail' && ! called 'versions prune'
}
t_first_promotion_fails() {
  setup; export NEXT_ACTION="build 2026-09-30" BROKEN_VERSION=2026-09-30
  status_json '{"passing":["2026-09-30"],"failed":[],"incomplete":[]}'
  ! refresh && [ ! -f "$OL_DATA/current-version" ] && called '^compose stop api$'
}
t_lock_held() {
  setup; export NEXT_ACTION="build 2026-09-30"
  flock "$BUILD_LOCK" sleep 3 &
  sleep 0.5
  refresh; rc=$?
  wait
  [ "$rc" = 0 ] && ! called '^compose '
}
t_unmounted() {
  setup; export NEXT_ACTION="build 2026-09-30" NOT_MOUNTED=1
  ! refresh && ! called '^compose ' && called 'not mounted.*refresh/fail'
}
t_unreachable() {
  setup; export NEXT_ACTION_FAIL=1
  ! refresh && ! called '^compose run --rm --no-deps -T build$' && called 'refresh/fail'
}

check "a dump already built is a no-op that still checks in" t_skip_built
check "mismatch: Open Library mid-publication is a quiet skip" t_mismatch
check "a passing build is promoted and old versions pruned" t_promotes
check "failed gates keep the old version and name the gate" t_gate_failure
check "a build that died keeps the old version" t_crash
check "an API that will not serve the new version is reverted" t_reverts
check "first promotion fails: no current-version is left behind" t_first_promotion_fails
check "a held build lock means no second build" t_lock_held
check "an unmounted data disk refuses to build" t_unmounted
check "Open Library unreachable is a failure" t_unreachable
finish
