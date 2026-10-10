#!/usr/bin/env bash
# shellcheck disable=SC2016  # stub bodies are single-quoted: they expand when the stub runs
# deployment/home-server/test/recommender_train_test.sh
# guest/recommender-train.sh against a stubbed compose (the trainer) and a
# stubbed curl (healthchecks.io).
set -uo pipefail
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"

R2=(RECOMMENDER_R2_ENDPOINT=https://x.r2.test RECOMMENDER_R2_ACCESS_KEY=x
    RECOMMENDER_R2_SECRET_KEY=x RECOMMENDER_R2_BUCKET=x)
setup() {
  new_sandbox
  write_env ROLE=ol REPO_REF=main TUNNELS_ENABLED=0 HC_RECOMMENDER=https://hc.test/train "${R2[@]}"
  unset TRAIN_EXIT TRAIN_OUT
  stub curl ''
  stub compose 'case "$*" in
  "run --rm --no-deps -T recommender run") printf "%b\n" "${TRAIN_OUT-2026-10-10: 48112 users, 10013 items, 500650 rows; hit@10 0.312 recall@50 0.401 over 46950 users}"; exit "${TRAIN_EXIT:-0}" ;;
esac'
  export COMPOSE="$SANDBOX/bin/compose"
}
train() { "$GUEST/recommender-train.sh" >"$SANDBOX/log/out" 2>&1; }
# The sequence of the calls that matter, first word each: proves start is
# pinged before the trainer runs and success after.
sequence() { grep -E '^(curl .*hc\.test/train/start$|compose run|curl .*hc\.test/train$)' "$CALLS" | cut -d' ' -f1 | tr '\n' ' '; }

t_published() {
  setup
  train && [ "$(sequence)" = "curl compose curl " ] &&
    called '^curl .*--data-raw 2026-10-10: 48112 users.*hc\.test/train$' && ! called 'train/fail'
}
t_nothing_to_do() {
  setup; export TRAIN_OUT="2026-10-10 already trained; nothing to do"
  train && called '^curl .*--data-raw 2026-10-10 already trained; nothing to do https://hc\.test/train$'
}
t_gate_failed() {
  setup; export TRAIN_EXIT=1 TRAIN_OUT="2026-10-10: 1 users, 1 items, 1 rows; hit@10 0.100 recall@50 0.100 over 1 users\ngate failed: hit@10 0.100 < 0.9 x 0.312; latest stays 2026-10-09"
  ! train && called '^curl .*--data-raw exit 1: gate failed: .*latest stays 2026-10-09 https://hc\.test/train/fail$' &&
    ! called 'hc\.test/train$'
}
t_lock_held() {
  setup
  flock "$BUILD_LOCK" sleep 3 &
  sleep 0.5
  train; rc=$?
  wait
  [ "$rc" = 0 ] && ! called '^compose ' && ! called 'train/start' && called '^curl .*--data-raw deferred: lock held https://hc\.test/train/log$' &&
    ! called 'hc\.test/train$'
}
t_killed() {
  setup; export TRAIN_EXIT=137 TRAIN_OUT=""
  ! train && called '^curl .*--data-raw exit 137: no output https://hc\.test/train/fail$'
}
t_not_configured() {
  setup; write_env ROLE=ol REPO_REF=main TUNNELS_ENABLED=0 HC_RECOMMENDER=https://hc.test/train
  train && ! called '^compose ' && ! called '^curl ' && grep -q 'not set' "$SANDBOX/log/out"
}
t_partial_config() {
  setup; write_env ROLE=ol REPO_REF=main TUNNELS_ENABLED=0 HC_RECOMMENDER=https://hc.test/train \
    RECOMMENDER_R2_ENDPOINT=https://x.r2.test RECOMMENDER_R2_BUCKET=x
  ! train && ! called '^compose ' && called '^curl .*--data-raw .*RECOMMENDER_R2_.*hc\.test/train/fail$'
}
t_no_check_url() {
  setup; write_env ROLE=ol REPO_REF=main TUNNELS_ENABLED=0 "${R2[@]}"
  train && called '^compose run --rm --no-deps -T recommender run$' && ! called '^curl '
}
t_output_logged() {
  setup; train && grep -q 'hit@10 0.312' "$SANDBOX/log/out"
}

check "a published model pings start, runs the trainer, pings success with its last line" t_published
check "nothing to do is a success with the trainer's message" t_nothing_to_do
check "a failed gate pings fail with the trainer's last line and exits non-zero" t_gate_failed
check "a trainer killed without output pings fail with its exit status" t_killed
check "a held build lock logs a deferral without running the trainer or pinging success" t_lock_held
check "no R2 variables at all is a quiet skip: no trainer, no ping" t_not_configured
check "R2 variables partly set fail before the trainer runs" t_partial_config
check "no check URL: the trainer still runs, nothing is pinged" t_no_check_url
check "the trainer's output reaches the journal" t_output_logged
finish
