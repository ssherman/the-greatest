#!/usr/bin/env bash
# deployment/home-server/guest/deploy.sh
# the-greatest-deploy.timer, every 15 minutes: bring this VM's service up to
# origin/$REPO_REF when anything it runs from has changed. --force, or the
# $STATE_DIR/force-deploy marker provision leaves, deploys without a change.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
load_env
INSTALL_UNITS="${INSTALL_UNITS:-$here/install-units.sh}"
WATCHED=(data-sources deployment/home-server)

force=0
if [ "${1:-}" = --force ] || [ -f "$STATE_DIR/force-deploy" ]; then force=1; fi

fail() { log "deploy failed: $1"; hc_ping "${HC_DEPLOY:-}" fail "$1"; exit 1; }

cd "$REPO_DIR"
git fetch --quiet --depth 1 origin "$REPO_REF" || fail "git fetch origin $REPO_REF"
target="$(git rev-parse FETCH_HEAD)"
deployed="$(cat "$STATE_DIR/deployed-sha" 2>/dev/null || true)"

needs_deploy() {
  [ "$force" = 1 ] && return 0
  [ -n "$deployed" ] || return 0
  git cat-file -e "$deployed^{commit}" 2>/dev/null || return 0
  ! git diff --quiet "$deployed" "$target" -- "${WATCHED[@]}"
}

if ! needs_deploy; then
  log "nothing to deploy (${target:0:12})"
  hc_ping "${HC_DEPLOY:-}" "" "no change"
  exit 0
fi

log "deploying ${target:0:12} (was ${deployed:0:12})"
if [ "$ROLE" = ol ]; then
  # Only a deploy with something to do takes the lock, so a no-op check every
  # 15 minutes never blocks the refresh. Never rebuild under a running data
  # build, and never let one start mid-deploy.
  exec 9>"$BUILD_LOCK"
  if ! flock -n 9; then
    log "a build or training run holds $BUILD_LOCK; deploying next time"
    hc_ping "${HC_DEPLOY:-}" "" "deferred: lock held"
    exit 0
  fi
fi
git checkout --quiet --force --detach "$target" || fail "checkout ${target:0:12}"
"$INSTALL_UNITS" || fail "install-units"

case "$ROLE" in
  # ol also builds the trainer image: recommender-train.timer runs it with
  # `run --rm`, so it is never brought up here, but a merged trainer change
  # must reach the VM the same way an API change does.
  ol) service=api; build=(api recommender) ;;
  fetcher) service=fetcher; build=(fetcher) ;;
  *) fail "unknown ROLE '$ROLE'" ;;
esac
# A failed build leaves the running container exactly as it was.
"$COMPOSE" build "${build[@]}" || fail "image build for ${build[*]} at ${target:0:12}"

if [ "$ROLE" = ol ] && [ ! -f "$OL_DATA/current-version" ]; then
  log "no Open Library version yet; ol-refresh starts api after the first build"
  if [ "${TUNNELS_ENABLED:-0}" = 1 ]; then "$COMPOSE" up -d cloudflared || fail "compose up cloudflared"; fi
else
  # Both services are defined on both VMs: name only this VM's.
  up=("$service")
  if [ "${TUNNELS_ENABLED:-0}" = 1 ]; then up+=(cloudflared); fi
  "$COMPOSE" up -d --remove-orphans "${up[@]}" || fail "compose up"
fi

# Tunnels switched off (provision --disable-tunnels): compose leaves a running
# container of a disabled profile alone, --remove-orphans included, so name it.
if [ "${TUNNELS_ENABLED:-0}" != 1 ]; then
  tunnel="$("$COMPOSE" --profile tunnel ps -q cloudflared)" || fail "compose ps cloudflared"
  if [ -n "$tunnel" ]; then
    log "tunnels are off: removing cloudflared"
    "$COMPOSE" --profile tunnel rm -sf cloudflared || fail "remove cloudflared"
  fi
fi

echo "$target" >"$STATE_DIR/deployed-sha"
rm -f "$STATE_DIR/force-deploy"
docker image prune -f >/dev/null || log "image prune failed"
hc_ping "${HC_DEPLOY:-}" "" "deployed ${target:0:12}"
