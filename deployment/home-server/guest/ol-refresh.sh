#!/usr/bin/env bash
# deployment/home-server/guest/ol-refresh.sh
# ol-refresh.timer, daily at 03:00 and at boot (`ol` VM only): build the newest
# Open Library dump if this box has not tried it yet, and serve it only if
# every gate passes. Spec: docs/superpowers/specs/2026-10-03-home-server-design.md §6.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
load_env
API_URL="${API_URL:-http://127.0.0.1:8080}"
PROMOTE_TIMEOUT_S="${PROMOTE_TIMEOUT_S:-600}"
POLL_S="${POLL_S:-5}"

hc() { hc_ping "${HC_REFRESH:-}" "$@"; }
fail() { log "refresh failed: $1"; hc fail "$1"; exit 1; }
versions() { "$COMPOSE" run --rm --no-deps -T build python -m openlibrary.pipeline.versions "$@" --root /data; }

exec 9>"$BUILD_LOCK"
if ! flock -n 9; then
  log "a build or deploy holds $BUILD_LOCK; trying next run"
  hc "" "deferred: lock held"
  exit 0
fi

# The data disk mounts with nofail so a missing disk cannot hang boot; a build
# must then refuse, or it would fill the OS disk instead.
mountpoint -q "$OL_DATA" || fail "$OL_DATA is not mounted"

hc start
action="$(versions next-action)" || fail "could not ask Open Library for the latest dump"
log "next action: $action"
case "$action" in
  "skip "*) hc "" "$action"; exit 0 ;;
  "build "*) date="${action#build }" ;;
  *) fail "unexpected next-action output: $action" ;;
esac

log "building $date"
built=0
"$COMPOSE" run --rm --no-deps -T build && built=1
status="$(versions status)" || fail "could not read version status after building $date"

if [ "$built" = 0 ]; then
  if jq -e --arg d "$date" 'any(.failed[]; . == $d)' >/dev/null <<<"$status"; then
    gates="$(jq -r '[.gates[] | select(.status == "fail") | .name] | join(", ")' \
      "$OL_DATA/versions/$date/build_report.json" 2>/dev/null || echo unknown)"
    fail "gates failed for $date ($gates); still serving $(cat "$OL_DATA/current-version" 2>/dev/null || echo nothing)"
  fi
  fail "the build of $date did not finish; it runs again next time"
fi

new="$(jq -r '.passing[-1] // empty' <<<"$status")"
[ -n "$new" ] || fail "the build of $date exited 0 but no passing version exists"
old="$(cat "$OL_DATA/current-version" 2>/dev/null || true)"

serve() {
  # Called under `|| log`, where set -e is off: fail explicitly.
  printf '%s\n' "$1" >"$OL_DATA/current-version.tmp" || return 1
  mv "$OL_DATA/current-version.tmp" "$OL_DATA/current-version" || return 1
  OL_DATA_VERSION="$1" "$COMPOSE" up -d api
}
serving() { curl -fsS -m 10 "$API_URL/version" | jq -r '.dump_date'; }
wait_for() {
  local deadline=$((SECONDS + PROMOTE_TIMEOUT_S))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(serving 2>/dev/null || true)" = "$1" ]; then return 0; fi
    sleep "$POLL_S"
  done
  return 1
}

serve "$new" || log "compose up on $new failed"
if ! wait_for "$new"; then
  if [ -n "$old" ]; then
    serve "$old" || log "compose up on $old failed"
    wait_for "$old" || log "the API did not come back on $old either"
  else
    # Leaving current-version would make every deploy start a crash-looping API.
    rm -f "$OL_DATA/current-version"
    "$COMPOSE" stop api || true
  fi
  fail "$new passed its gates but the API did not serve it; back on ${old:-nothing}"
fi

versions prune --keep 2 --current "$new" || log "prune failed; old versions left on disk"
hc "" "serving $new"
