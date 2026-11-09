#!/usr/bin/env bash
# shellcheck disable=SC2016  # stub bodies are single-quoted: they expand when the stub runs
# deployment/home-server/test/wikidata_refresh_test.sh
# guest/wikidata-refresh.sh against a stubbed compose (the versions CLI, the build,
# the API) and a stubbed curl (healthchecks.io and the API's /version).
set -uo pipefail
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"

setup() {
  new_sandbox
  write_env ROLE=wikidata REPO_REF=main TUNNELS_ENABLED=0 HC_REFRESH=https://hc.test/refresh
  export PROMOTE_TIMEOUT_S=1 POLL_S=0 API_URL=http://api.test
  unset NEXT_ACTION NEXT_ACTION_FAIL BUILD_EXIT BROKEN_VERSION NOT_MOUNTED SWAP_ACTIVE MKSWAP_EXIT SWAP_SIZE PRUNE_BEFORE_EXIT
  stub swapon 'case "${1:-}" in --show*) [ -n "${SWAP_ACTIVE:-}" ] && echo "$WD_DATA/swapfile" ;; esac; true'
  stub fallocate 'command -p touch "${!#}"'
  stub mkswap 'exit "${MKSWAP_EXIT:-0}"'
  # `command -p` searches the default PATH, never $SANDBOX/bin. A plain
  # `command chmod` finds this stub again and forks forever.
  stub chmod 'command -p chmod "$@"'
  stub mountpoint '[ -z "${NOT_MOUNTED:-}" ]'
  stub curl 'url="${!#}"
case "$url" in
  */version) [ -f "$SANDBOX/serving" ] || exit 7; printf "{\"dump_date\":\"%s\"}" "$(command -p cat "$SANDBOX/serving")" ;;
esac'
  stub compose 'case "$*" in
  *"versions next-action"*) [ -z "${NEXT_ACTION_FAIL:-}" ] || exit 1; echo "$NEXT_ACTION" ;;
  *"versions status"*) command -p cat "$SANDBOX/status.json" ;;
  *"versions prune --before"*) exit "${PRUNE_BEFORE_EXIT:-0}" ;;
  *"versions prune"*) ;;
  "run --rm --no-deps -T wikidata-build") exit "${BUILD_EXIT:-0}" ;;
  "up -d wikidata") if [ "$WD_DATA_VERSION" = "${BROKEN_VERSION:-}" ]; then command -p rm -f "$SANDBOX/serving"; else echo "$WD_DATA_VERSION" >"$SANDBOX/serving"; fi ;;
  "stop wikidata") command -p rm -f "$SANDBOX/serving" ;;
esac'
  export COMPOSE="$SANDBOX/bin/compose"
}
status_json() { printf '%s' "$1" >"$SANDBOX/status.json"; }
serving() { echo "$1" >"$WD_DATA/current-version"; echo "$1" >"$SANDBOX/serving"; }
refresh() { "$GUEST/wikidata-refresh.sh" >"$SANDBOX/log/out" 2>&1; }

t_skip_built() {
  setup; serving 2026-08-31; export NEXT_ACTION="skip built 2026-08-31"
  refresh && ! called '^compose run --rm --no-deps -T wikidata-build$' && called 'hc\.test/refresh$'
}
t_skip_built_but_unserved_promotes_without_building() {
  setup; serving 2026-08-31; export NEXT_ACTION="skip built 2026-09-30"
  status_json '{"passing":["2026-08-31","2026-09-30"],"failed":[],"incomplete":[]}'
  refresh && [ "$(cat "$WD_DATA/current-version")" = 2026-09-30 ] &&
    ! called '^compose run --rm --no-deps -T wikidata-build$' &&
    called 'versions prune --keep 2 --current 2026-09-30' && called 'hc\.test/refresh$' && ! called 'refresh/fail'
}
t_skip_built_unserved_promotion_fails_again() {
  setup; serving 2026-08-31; export NEXT_ACTION="skip built 2026-09-30" BROKEN_VERSION=2026-09-30
  status_json '{"passing":["2026-08-31","2026-09-30"],"failed":[],"incomplete":[]}'
  ! refresh && [ "$(cat "$WD_DATA/current-version")" = 2026-08-31 ] &&
    [ "$(command -p cat "$SANDBOX/serving")" = 2026-08-31 ] && called 'refresh/fail' &&
    ! called 'versions prune --keep' && ! called '^compose run --rm --no-deps -T wikidata-build$'
}
t_skip_built_and_served_touches_nothing() {
  setup; serving 2026-09-30; export NEXT_ACTION="skip built 2026-09-30"
  status_json '{"passing":["2026-08-31","2026-09-30"],"failed":[],"incomplete":[]}'
  refresh && ! called '^compose up' && ! called '^compose run --rm --no-deps -T wikidata-build$' && ! called 'refresh/fail'
}
t_skip_failed() {
  setup; serving 2026-08-31; export NEXT_ACTION="skip failed 2026-09-30"
  refresh && ! called '^compose run --rm --no-deps -T wikidata-build$' && ! called 'refresh/fail'
}
t_promotes() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30"
  status_json '{"passing":["2026-08-31","2026-09-30"],"failed":[],"incomplete":[]}'
  refresh && [ "$(cat "$WD_DATA/current-version")" = 2026-09-30 ] &&
    called 'versions prune --keep 2 --current 2026-09-30' && called 'hc\.test/refresh$'
}
t_gate_failure() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30" BUILD_EXIT=1
  status_json '{"passing":["2026-08-31"],"failed":["2026-09-30"],"incomplete":[]}'
  mkdir -p "$WD_DATA/versions/2026-09-30"
  echo '{"gates":[{"name":"row_counts","status":"pass"},{"name":"evaluation_set","status":"fail"}]}' \
    >"$WD_DATA/versions/2026-09-30/build_report.json"
  ! refresh && [ "$(cat "$WD_DATA/current-version")" = 2026-08-31 ] &&
    called 'evaluation_set.*refresh/fail' && ! called '^compose up -d wikidata$'
}
t_crash() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30" BUILD_EXIT=137
  status_json '{"passing":["2026-08-31"],"failed":[],"incomplete":["2026-09-30"]}'
  ! refresh && [ "$(cat "$WD_DATA/current-version")" = 2026-08-31 ] &&
    called 'did not finish.*refresh/fail'
}
t_reverts() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30" BROKEN_VERSION=2026-09-30
  status_json '{"passing":["2026-08-31","2026-09-30"],"failed":[],"incomplete":[]}'
  ! refresh && [ "$(cat "$WD_DATA/current-version")" = 2026-08-31 ] &&
    [ "$(command -p cat "$SANDBOX/serving")" = 2026-08-31 ] && called 'refresh/fail' && ! called 'versions prune --keep'
}
t_first_promotion_fails() {
  setup; export NEXT_ACTION="build 2026-09-30" BROKEN_VERSION=2026-09-30
  status_json '{"passing":["2026-09-30"],"failed":[],"incomplete":[]}'
  ! refresh && [ ! -f "$WD_DATA/current-version" ] && called '^compose stop wikidata$'
}
t_lock_held() {
  setup; export NEXT_ACTION="build 2026-09-30"
  flock "$BUILD_LOCK" sleep 3 &
  sleep 0.5
  refresh; rc=$?
  wait
  [ "$rc" = 0 ] && ! called '^compose ' && called 'deferred: lock held'
}
t_unmounted() {
  setup; export NEXT_ACTION="build 2026-09-30" NOT_MOUNTED=1
  ! refresh && ! called '^compose ' && called 'not mounted.*refresh/fail'
}
t_unreachable() {
  setup; export NEXT_ACTION_FAIL=1
  ! refresh && ! called '^compose run --rm --no-deps -T wikidata-build$' && called 'refresh/fail'
}

check "a dump already built is a no-op that still checks in" t_skip_built
check "a dump whose build already failed is a quiet skip, not a rebuild" t_skip_failed
check "a built but unserved version is promoted on skip, without a build" t_skip_built_but_unserved_promotes_without_building
check "a skip whose promotion fails again rolls back and fails" t_skip_built_unserved_promotion_fails_again
check "a skip with the newest passing version already served touches nothing" t_skip_built_and_served_touches_nothing
check "a passing build is promoted and old versions pruned" t_promotes
check "failed gates keep the old version and name the gate" t_gate_failure
check "a build that died keeps the old version" t_crash
check "an API that will not serve the new version is reverted" t_reverts
check "first promotion fails: no current-version is left behind" t_first_promotion_fails
t_swap_active() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30" SWAP_ACTIVE=1
  status_json '{"passing":["2026-08-31","2026-09-30"],"failed":[],"incomplete":[]}'
  refresh && ! called '^fallocate ' && ! called '^mkswap ' && ! called '^swapon /'
}
t_swap_default_size() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30"
  status_json '{"passing":["2026-08-31","2026-09-30"],"failed":[],"incomplete":[]}'
  refresh && called "^fallocate -l 8G $WD_DATA/swapfile"
}
t_versions_run_in_build_service() {
  setup; serving 2026-08-31; export NEXT_ACTION="skip built 2026-08-31"
  refresh && called '^compose run --rm --no-deps -T wikidata-build python -m wikidata.pipeline.versions next-action --root /data$'
}
t_swap_created() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30" SWAP_SIZE=1M
  status_json '{"passing":["2026-08-31","2026-09-30"],"failed":[],"incomplete":[]}'
  refresh && called "^fallocate -l 1M $WD_DATA/swapfile" && called "^chmod 600 $WD_DATA/swapfile" &&
    called "^mkswap $WD_DATA/swapfile" &&
    [ "$(grep -E '^(swapon /|compose run --rm --no-deps -T wikidata-build$)' "$CALLS" | cut -d' ' -f1 | tr '\n' ' ')" = "swapon compose " ]
}
t_swap_fails() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30" MKSWAP_EXIT=1
  ! refresh && called 'swap file.*refresh/fail' && ! called '^swapon /' &&
    ! called '^compose run --rm --no-deps -T wikidata-build$'
}

t_prunes_earlier_weeks_before_the_build() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30"
  status_json '{"passing":["2026-08-31","2026-09-30"],"failed":[],"incomplete":[]}'
  refresh && called 'versions prune --before 2026-09-30 --current 2026-08-31 --root /data$' || return 1
  local pruned built
  pruned="$(grep -nE 'versions prune --before' "$CALLS" | head -1 | cut -d: -f1)"
  built="$(grep -nE '^compose run --rm --no-deps -T wikidata-build$' "$CALLS" | head -1 | cut -d: -f1)"
  [ -n "$pruned" ] && [ -n "$built" ] && [ "$pruned" -lt "$built" ]
}
t_prune_before_failing_does_not_stop_the_build() {
  setup; serving 2026-08-31; export NEXT_ACTION="build 2026-09-30" PRUNE_BEFORE_EXIT=1
  status_json '{"passing":["2026-08-31","2026-09-30"],"failed":[],"incomplete":[]}'
  refresh && called '^compose run --rm --no-deps -T wikidata-build$'
}

check "earlier weeks' dumps are pruned before the build starts" t_prunes_earlier_weeks_before_the_build
check "a prune that fails does not stop the build" t_prune_before_failing_does_not_stop_the_build
check "a held build lock means no second build" t_lock_held
check "an unmounted data disk refuses to build" t_unmounted
check "Wikidata unreachable is a failure" t_unreachable
check "active swap is left alone" t_swap_active
check "the swap file is 8G by default" t_swap_default_size
check "the versions CLI runs in the wikidata-build service" t_versions_run_in_build_service
check "missing swap is created and enabled before the build" t_swap_created
check "a swap file that cannot be made fails the refresh before any build" t_swap_fails
finish
