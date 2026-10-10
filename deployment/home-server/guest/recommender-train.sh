#!/usr/bin/env bash
# deployment/home-server/guest/recommender-train.sh
# recommender-train.timer, daily at 04:00 (UTC, the VM's clock) and 20 minutes
# after boot, `ol` VM only: train the book-recommendations model on the newest
# export in the R2 bucket and publish it when it passes the gate. The trainer
# decides everything about the data (nothing new, a stale export, a failed
# gate: data-sources/src/recommender/cli.py `run`); this script checks the
# configuration, takes the dump build's lock, runs it, and reports.
# Spec: docs/superpowers/specs/2026-10-09-book-recommendations-collaborative-design.md §4.4.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
load_env

hc() { hc_ping "${HC_RECOMMENDER:-}" "$@"; }
fail() { log "train failed: $1"; hc fail "$1"; exit 1; }

# The Rails jobs' rule: all four unset is "not configured yet", a quiet skip
# (and, with a check URL set, a missed ping that alerts after the grace); a
# partial set is a mistake, reported.
configured=0
for value in "${RECOMMENDER_R2_ENDPOINT:-}" "${RECOMMENDER_R2_ACCESS_KEY:-}" \
             "${RECOMMENDER_R2_SECRET_KEY:-}" "${RECOMMENDER_R2_BUCKET:-}"; do
  if [ -n "$value" ]; then configured=$((configured + 1)); fi
done
if [ "$configured" = 0 ]; then log "RECOMMENDER_R2_* not set; nothing to train"; exit 0; fi
[ "$configured" = 4 ] || fail "RECOMMENDER_R2_ENDPOINT, RECOMMENDER_R2_ACCESS_KEY, RECOMMENDER_R2_SECRET_KEY and RECOMMENDER_R2_BUCKET must all be set or all be unset"

# A dump build (ol-refresh.sh, 03:00) holds this for hours and has the VM's
# memory; the check's 2-day grace covers the one deferral.
exec 9>"$BUILD_LOCK"
if ! flock -n 9; then
  log "a build or deploy holds $BUILD_LOCK; trying next run"
  hc "" "deferred: lock held"
  exit 0
fi

hc start
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
# -T: no TTY under systemd. The trainer's last line says what happened
# (published, nothing to do, refused, gate failed) and becomes the ping's
# message, the only place the reason is visible off the box.
if "$COMPOSE" run --rm --no-deps -T recommender run 2>&1 | tee "$out"; then
  hc "" "$(tail -n 1 "$out")"
else
  fail "$(tail -n 1 "$out")"
fi
