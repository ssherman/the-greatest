#!/usr/bin/env bash
# deployment/home-server/guest/wikidata-refresh.sh
# wikidata-refresh.timer, daily at 04:00 and at boot (`wikidata` VM only): build the newest
# Wikidata dump if this box has not tried it yet (the build downloads it, about
# 157 GB), and serve it only if
# every gate passes. Spec: docs/superpowers/specs/2026-10-03-home-server-design.md §6.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
load_env
API_URL="${API_URL:-http://127.0.0.1:8083}"
PROMOTE_TIMEOUT_S="${PROMOTE_TIMEOUT_S:-600}"
POLL_S="${POLL_S:-5}"

hc() { hc_ping "${HC_REFRESH:-}" "$@"; }
fail() { log "refresh failed: $1"; hc fail "$1"; exit 1; }
versions() { "$COMPOSE" run --rm --no-deps -T wikidata-build python -m wikidata.pipeline.versions "$@" --root /data; }

exec 9>"$BUILD_LOCK"
if ! flock -n 9; then
  log "a build or deploy holds $BUILD_LOCK; trying next run"
  hc "" "deferred: lock held"
  exit 0
fi

# The data disk mounts with nofail so a missing disk cannot hang boot; a build
# must then refuse, or it would fill the OS disk instead.
mountpoint -q "$WD_DATA" || fail "$WD_DATA is not mounted"

serve() {
  # Called under `|| log`, where set -e is off: fail explicitly.
  printf '%s\n' "$1" >"$WD_DATA/current-version.tmp" || return 1
  mv "$WD_DATA/current-version.tmp" "$WD_DATA/current-version" || return 1
  WD_DATA_VERSION="$1" "$COMPOSE" up -d wikidata
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

# Serve $1 (a passing version), going back to the one served now if the API will not take it.
# Used after a build and, with no build, when a passing version was never served.
promote() {
  local new="$1" old
  old="$(cat "$WD_DATA/current-version" 2>/dev/null || true)"
  serve "$new" || log "compose up on $new failed"
  if ! wait_for "$new"; then
    if [ -n "$old" ]; then
      serve "$old" || log "compose up on $old failed"
      wait_for "$old" || log "the API did not come back on $old either"
    else
      # Leaving current-version would make every deploy start a crash-looping API.
      rm -f "$WD_DATA/current-version"
      "$COMPOSE" stop wikidata || true
    fi
    fail "$new passed its gates but the API did not serve it; back on ${old:-nothing}"
  fi
  versions prune --keep 2 --current "$new" || log "prune failed; old versions left on disk"
  hc "" "serving $new"
}

hc start
action="$(versions next-action)" || fail "could not ask Wikidata for the latest dump"
log "next action: $action"
case "$action" in
  "skip "*)
    # "Built" is not "served": a build can pass while promotion fails, and that date then
    # stays passing. Retry the promotion here, without rebuilding.
    newest="$(versions status 2>/dev/null | jq -r '.passing[-1] // empty' 2>/dev/null || true)"
    served="$(cat "$WD_DATA/current-version" 2>/dev/null || true)"
    if [ -n "$newest" ] && [ "$newest" != "$served" ]; then
      log "$newest passed its gates but is not served (serving ${served:-nothing}); retrying promotion"
      promote "$newest"
      exit 0
    fi
    hc "" "$action"; exit 0 ;;
  "build "*) date="${action#build }" ;;
  *) fail "unexpected next-action output: $action" ;;
esac

# The build's DuckDB work can hold per-thread state outside memory_limit, so
# back the VM with swap (as ol-refresh.sh does). Done
# only once a build is certain (after next-action: skip runs touch nothing),
# and deliberately not in fstab, so boot never depends on it.
SWAP_SIZE="${SWAP_SIZE:-8G}"
swapfile="$WD_DATA/swapfile"
if ! swapon --show=NAME --noheadings | grep -qxF "$swapfile"; then
  if [ ! -f "$swapfile" ]; then
    { fallocate -l "$SWAP_SIZE" "$swapfile" && chmod 600 "$swapfile" && mkswap "$swapfile" >/dev/null; } ||
      { rm -f "$swapfile"; fail "could not create the $SWAP_SIZE swap file $swapfile"; }
  fi
  swapon "$swapfile" || fail "could not enable swap on $swapfile"
fi

# A failed or killed week leaves its ~157 GB dump behind, and the success-only prune below
# never runs for it. Free every earlier week's dump and dead version before downloading
# this one; the served version and passing versions are never touched.
current="$(cat "$WD_DATA/current-version" 2>/dev/null || true)"
versions prune --before "$date" ${current:+--current "$current"} ||
  log "could not free the disk of earlier dumps; building anyway"

log "building $date"
built=0
"$COMPOSE" run --rm --no-deps -T wikidata-build && built=1
status="$(versions status)" || fail "could not read version status after building $date"

if [ "$built" = 0 ]; then
  if jq -e --arg d "$date" 'any(.failed[]; . == $d)' >/dev/null <<<"$status"; then
    gates="$(jq -r '[.gates[] | select(.status == "fail") | .name] | join(", ")' \
      "$WD_DATA/versions/$date/build_report.json" 2>/dev/null || echo unknown)"
    fail "gates failed for $date ($gates); still serving $(cat "$WD_DATA/current-version" 2>/dev/null || echo nothing)"
  fi
  fail "the build of $date did not finish; it runs again next time"
fi

new="$(jq -r '.passing[-1] // empty' <<<"$status")"
[ -n "$new" ] || fail "the build of $date exited 0 but no passing version exists"
promote "$new"
