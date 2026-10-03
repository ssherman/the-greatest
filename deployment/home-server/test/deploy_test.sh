#!/usr/bin/env bash
# shellcheck disable=SC2016  # stub bodies are single-quoted: they expand when the stub runs
# deployment/home-server/test/deploy_test.sh
# guest/deploy.sh against a real git origin, with compose and install-units stubbed.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"

gitc() { git -c user.email=test@example.com -c user.name=test "$@"; }

setup() {
  new_sandbox
  origin="$SANDBOX/origin.git"; work="$SANDBOX/work"
  git init -q --bare "$origin"
  git clone -q "file://$origin" "$work" 2>/dev/null
  commit data-sources/app v1
  git clone -q --depth 1 --branch main "file://$origin" "$SANDBOX/repo"
  export REPO_DIR="$SANDBOX/repo"
  git -C "$REPO_DIR" rev-parse HEAD >"$STATE_DIR/deployed-sha"
  write_env ROLE=fetcher REPO_REF=main TUNNELS_ENABLED=0 HC_DEPLOY=https://hc.test/deploy
  unset BUILD_EXIT
  stub compose 'if [ "$1" = build ]; then exit "${BUILD_EXIT:-0}"; fi'
  stub install-units ''
  stub docker ''
  stub curl ''
  export COMPOSE="$SANDBOX/bin/compose" INSTALL_UNITS="$SANDBOX/bin/install-units"
}
commit() {
  (cd "$work" && mkdir -p "$(dirname "$1")" && echo "$2" >"$1" && git add -A &&
    gitc commit -qm "$1" && git push -q origin HEAD:main)
}
head_of_origin() { git -C "$work" rev-parse HEAD; }
deploy() { "$GUEST/deploy.sh" "$@" >"$SANDBOX/log/out" 2>&1; }

t_unwatched() {
  setup; before="$(cat "$STATE_DIR/deployed-sha")"; commit docs/readme x
  deploy && [ "$(cat "$STATE_DIR/deployed-sha")" = "$before" ] && ! called '^compose build' &&
    called 'hc\.test/deploy$'
}
t_watched() {
  setup; commit data-sources/app v2
  deploy && called '^compose build fetcher$' && called '^compose up -d --remove-orphans$' &&
    [ "$(cat "$STATE_DIR/deployed-sha")" = "$(head_of_origin)" ]
}
t_home_server_dir() {
  setup; commit deployment/home-server/compose.ol.yml x
  deploy && called '^compose build fetcher$'
}
t_failed_build() {
  setup; before="$(cat "$STATE_DIR/deployed-sha")"; commit data-sources/app v2; export BUILD_EXIT=1
  ! deploy && [ "$(cat "$STATE_DIR/deployed-sha")" = "$before" ] && ! called '^compose up' &&
    called 'deploy/fail'
}
t_retry_after_failure() {
  t_failed_build || return 1
  unset BUILD_EXIT; : >"$CALLS"
  deploy && called '^compose build fetcher$' && [ "$(cat "$STATE_DIR/deployed-sha")" = "$(head_of_origin)" ]
}
t_force_flag() { setup; deploy --force && called '^compose build fetcher$' && called '^compose up -d'; }
t_force_marker() {
  setup; touch "$STATE_DIR/force-deploy"
  deploy && called '^compose build fetcher$' && [ ! -f "$STATE_DIR/force-deploy" ]
}
t_ol_without_version() {
  setup; write_env ROLE=ol REPO_REF=main TUNNELS_ENABLED=0 HC_DEPLOY=https://hc.test/deploy
  commit data-sources/app v2
  deploy && called '^compose build api$' && ! called '^compose up'
}
t_ol_without_version_tunnels() {
  setup; write_env ROLE=ol REPO_REF=main TUNNELS_ENABLED=1 HC_DEPLOY=https://hc.test/deploy
  commit data-sources/app v2
  deploy && called '^compose up -d cloudflared$' && ! called '^compose up -d --remove-orphans$'
}
t_ol_build_running() {
  setup; write_env ROLE=ol REPO_REF=main TUNNELS_ENABLED=0 HC_DEPLOY=https://hc.test/deploy
  commit data-sources/app v2
  flock "$BUILD_LOCK" sleep 3 &
  sleep 0.5
  deploy; rc=$?
  wait
  [ "$rc" = 0 ] && ! called '^compose '
}

check "a change outside the watched paths deploys nothing" t_unwatched
check "a data-sources change builds and restarts the service" t_watched
check "a deployment/home-server change deploys too" t_home_server_dir
check "a failed build leaves the container and deployed-sha alone" t_failed_build
check "the next run retries a failed build" t_retry_after_failure
check "--force deploys without a change" t_force_flag
check "the force-deploy marker deploys once and is cleared" t_force_marker
check "ol with no data version builds but does not start api" t_ol_without_version
check "ol with no data version still starts the tunnel" t_ol_without_version_tunnels
check "ol does not deploy under a running build" t_ol_build_running
finish
