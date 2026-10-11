# Book Recommendations Collaborative Filtering (Increment 2: Home Server) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the collaborative-filtering trainer on the home server's `ol` VM once a day, unattended, so production gets a model and the "readers like you" signal becomes available there.

**Architecture:** A new systemd timer on the `ol` VM runs `guest/recommender-train.sh`, which takes the dump build's lock non-blocking, runs the already-built `recommender` compose service (`recommender.cli run`: pull the newest export from the R2 bucket, train, publish when the gate passes), and reports to one healthchecks.io check. `deploy.sh` builds the trainer image alongside the API so a merged trainer change reaches the VM; `compose.ol.yml` caps its memory and CPUs; `provision` renders the four `RECOMMENDER_R2_*` values and `HC_RECOMMENDER` from `secrets/home-server.env` into the `ol` VM's env file only. Nothing listens; no tunnel, no port, no Rails change.

**Tech Stack:** bash (`set -euo pipefail`, shellcheck-clean), systemd timers, Docker Compose v2, the existing home-server shell test harness (`deployment/home-server/test/`, stubs on `PATH`), healthchecks.io pings.

**Spec:** `docs/superpowers/specs/2026-10-09-book-recommendations-collaborative-design.md` §4.4 (and §4.3 for what the trainer's exit status means). Increment 1 (everything in Rails, the trainer code, its image and compose service) is merged: PR #372. The home-server runbook is `docs/features/home-server.md`; its spec is `docs/superpowers/specs/2026-10-03-home-server-design.md`.

## Global Constraints

- Every guest script sources `guest/lib.sh` after setting `here`, calls `load_env`, logs through `log`, pings through `hc_ping` (a blank URL is a no-op; the URL is never logged), and takes every path from the overridable variables there (`BUILD_LOCK`, `COMPOSE`, `ENV_FILE`, …). That is what lets `deployment/home-server/test/` run it against a sandbox.
- Unit timing, verbatim from the spec, with one amendment: `OnCalendar=*-*-* 04:00` and `OnBootSec=20min`. The VM's clock is UTC (checked 2026-10-10 with `timedatectl` on VM 110; provision sets no time zone), so 04:00 is 04:00 UTC: 1.5 h after the 02:30 UTC export, one hour after the 03:00 dump refresh, 1.5 h before the 05:30 reboot window. The spec's "04:00 Chicago" is amended to this in Task 5. Do not add a time-zone suffix.
- The trainer runs as `"$COMPOSE" run --rm --no-deps -T recommender run` (the `recommender` service has `profiles: ["recommender"]`; naming it on the command line enables it without the profile). The script never passes training flags: the defaults in `recommender.cli` are the shipped values.
- Compose limits, verbatim: `mem_limit: 14g`, `cpus: 10` on the `recommender` service in `compose.ol.yml`. The `RECOMMENDER_R2_*` pass-through already exists in `data-sources/docker-compose.yml` (`${RECOMMENDER_R2_ENDPOINT:-}` and the other three); `guest/compose.sh` exports the VM's env file with `set -a`, which is how those reach compose. `compose.ol.yml` adds only the limits.
- Secrets file keys (SOPS, `secrets/home-server.env`): `RECOMMENDER_R2_ENDPOINT`, `RECOMMENDER_R2_ACCESS_KEY`, `RECOMMENDER_R2_SECRET_KEY`, `RECOMMENDER_R2_BUCKET`, `HC_RECOMMENDER`. The VM env file (`/etc/the-greatest/home-server.env`) carries them under the same names, on the `ol` VM only. The fetcher VM receives none of them, not even blank.
- Unconfigured means all four `RECOMMENDER_R2_*` blank: the script logs and exits 0 without a ping (the same rule as the Rails jobs). A partial set is a failure (`fail` ping). The healthchecks.io check `recommender-train` is period 1 day, grace 2 days: one deferral (a dump-build day) is covered, a second day missed alerts.
- The repo is public. Never commit a ping URL, a token, a bucket name or a house address; tests use `https://hc.test/...` and `x` placeholders.
- Test harness rules: stubs are written with `stub <name> '<body>'`, single-quoted; a stub that wraps a real tool calls it with `command -p` (a plain `command chmod` found the stub again and forked until it took the machine down). `check "<name>" t_fn` and `finish` at the end of every test file.
- The whole gate is `deployment/home-server/test/run.sh` (shellcheck over every script plus every `*_test.sh`; `compose_config_test.sh` needs docker and skips without it). CI runs it as the `home-server` job. Run it from the repo root. No Rails, Python or lint change is part of this increment, so `bin/rails test` and `pytest` are not required for the gate; `bundle exec standardrb` is not touched.
- Never commit to `main`. Work on the worktree branch; push and PR only when asked.

## Review Focus

1. A dump-build day: `ol-refresh.sh` holds `BUILD_LOCK` for hours from 03:00. At 04:00 the trainer must not wait and must not fail: exit 0, no compose call, one success ping saying `deferred: lock held`. Test `t_lock_held` in Task 1.
2. `RECOMMENDER_R2_*` half set (a typo in the secrets file): the trainer would start, print `no store` and exit 1 with a message that hides the cause. The script must refuse before compose with a `fail` ping naming the four variables. Test `t_partial_config` in Task 1.
3. The trainer exits non-zero (gate failed, export older than three days, no export yet): the `fail` ping must carry the trainer's own last line, which is the only place the reason appears off the box. Test `t_gate_failed` in Task 1.
4. `compose.ol.yml` gains a second `cpus:` line. `provision_test.sh`'s `t_build_cpus_fit_vm` reads `cpus:` with `sed` and compares the result as one integer, so two lines make `[ "10\n10" -le 12 ]` an error, not a pass. The test must check every `cpus:` line. Task 3.
5. The fetcher VM must receive none of the trainer's secrets: `render_vm_env fetcher` must not emit any `RECOMMENDER_` or `HC_RECOMMENDER` line. Test `t_fetcher_isolation` (extended) in Task 4.

---

## File structure

| File | Responsibility |
|---|---|
| `deployment/home-server/guest/recommender-train.sh` | **Create.** The timer's script: config check, build lock, run the trainer, ping. |
| `deployment/home-server/guest/systemd/recommender-train.service` | **Create.** Oneshot unit running the script. |
| `deployment/home-server/guest/systemd/recommender-train.timer` | **Create.** 04:00 daily and 20 min after boot. |
| `deployment/home-server/guest/install-units.sh` | **Modify.** Role `ol` installs `recommender-train` too. |
| `deployment/home-server/guest/lib.sh` | **Modify.** The env-key comment lists the new keys. |
| `deployment/home-server/guest/deploy.sh` | **Modify.** Role `ol` builds `api` and `recommender`; `up` still names `api` only. |
| `deployment/home-server/compose.ol.yml` | **Modify.** `recommender` service limits. |
| `deployment/home-server/lib/vm.sh` | **Modify.** `render_vm_env ol` emits the five new keys. |
| `deployment/home-server/lib/verify.sh` | **Modify.** `--verify` asserts the timer is enabled on `ol`. |
| `deployment/home-server/test/recommender_train_test.sh` | **Create.** The script against stubbed compose and curl. |
| `deployment/home-server/test/timers_test.sh` | **Modify.** `install-units` installs the new timer on `ol`, not on `fetcher`. |
| `deployment/home-server/test/deploy_test.sh` | **Modify.** The `ol` build list. |
| `deployment/home-server/test/compose_config_test.sh` | **Modify.** The merged `recommender` service. |
| `deployment/home-server/test/provision_test.sh` | **Modify.** Every `cpus:` line fits the VM. |
| `deployment/home-server/test/render_test.sh` | **Modify.** Per-role key lists; fetcher isolation. |
| `docs/features/home-server.md` | **Modify.** Layout, secrets table, alerts table, recovery table, setup checklist. |
| `docs/features/recommendations.md` | **Modify.** Delivery state, the production paragraph, time zones. |
| `docs/superpowers/specs/2026-10-09-book-recommendations-collaborative-design.md` | **Modify.** Dated amendment to §4.4. |
| `docs/launch-todo.md` | **Modify.** §3 steps 3 and 4 name the real commands and times. |

The harness reference, for every task: `deployment/home-server/test/helpers.sh` provides `new_sandbox` (exports `SANDBOX`, `STATE_DIR`, `OL_DATA`, `BUILD_LOCK`, `ENV_FILE`, `CALLS`, and puts `$SANDBOX/bin` first on `PATH`), `write_env <KEY=value>...`, `stub <name> '<body>'` (logs `<name> <args>` to `$CALLS` then runs the body), `called '<regex>'` (greps `$CALLS`), `check "<name>" <fn>` and `finish`. `$GUEST` is `deployment/home-server/guest`, `$HS_DIR` is `deployment/home-server`, `$REPO_ROOT` the repo root. Run one test file directly (`deployment/home-server/test/recommender_train_test.sh`) or everything with `deployment/home-server/test/run.sh`.

---

### Task 1: The trainer script and its units

**Files:**
- Create: `deployment/home-server/guest/recommender-train.sh`
- Create: `deployment/home-server/guest/systemd/recommender-train.service`
- Create: `deployment/home-server/guest/systemd/recommender-train.timer`
- Modify: `deployment/home-server/guest/install-units.sh` (the `units` case for `ol`)
- Modify: `deployment/home-server/guest/lib.sh` (the comment above `load_env`)
- Test: `deployment/home-server/test/recommender_train_test.sh` (new), `deployment/home-server/test/timers_test.sh`

**Interfaces:**
- Consumes: `guest/lib.sh` (`load_env`, `log`, `hc_ping <url> [start|fail] [message]`, `BUILD_LOCK`, `COMPOSE`); the `recommender` compose service from `data-sources/docker-compose.yml` (entrypoint `python -m recommender.cli`, so the service argument `run` is the subcommand); the VM env keys `HC_RECOMMENDER`, `RECOMMENDER_R2_ENDPOINT`, `RECOMMENDER_R2_ACCESS_KEY`, `RECOMMENDER_R2_SECRET_KEY`, `RECOMMENDER_R2_BUCKET` (rendered by Task 4).
- Produces: the unit name `recommender-train` (`.service` + `.timer`) that `install-units.sh` installs for role `ol`; the exit/ping contract documented in Global Constraints.

- [ ] **Step 1: Write the failing tests for the script**

Create `deployment/home-server/test/recommender_train_test.sh`:

```bash
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
  "run --rm --no-deps -T recommender run") printf "%b\n" "${TRAIN_OUT:-2026-10-10: 48112 users, 10013 items, 500650 rows; hit@10 0.312 recall@50 0.401 over 46950 users}"; exit "${TRAIN_EXIT:-0}" ;;
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
  ! train && called '^curl .*--data-raw gate failed: .*latest stays 2026-10-09 https://hc\.test/train/fail$' &&
    ! called 'hc\.test/train$'
}
t_lock_held() {
  setup
  flock "$BUILD_LOCK" sleep 3 &
  sleep 0.5
  train; rc=$?
  wait
  [ "$rc" = 0 ] && ! called '^compose ' && ! called 'train/start' && called '^curl .*--data-raw deferred: lock held https://hc\.test/train$'
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
check "a held build lock defers without running the trainer" t_lock_held
check "no R2 variables at all is a quiet skip: no trainer, no ping" t_not_configured
check "R2 variables partly set fail before the trainer runs" t_partial_config
check "no check URL: the trainer still runs, nothing is pinged" t_no_check_url
check "the trainer's output reaches the journal" t_output_logged
finish
```

`chmod +x deployment/home-server/test/recommender_train_test.sh`.

Why these assertions: `hc_ping` in `lib.sh` calls `curl ... --data-raw "$message" "$url"`, so the stub's call log line is `curl -fsS -m 10 --retry 3 -o /dev/null --data-raw <message> <url>`; a success ping ends in `hc.test/train`, a start ping in `/train/start`, a failure in `/train/fail`. `write_env` overwrites the env file, so the config tests write their own.

- [ ] **Step 2: Run the test to verify it fails**

Run: `deployment/home-server/test/recommender_train_test.sh`
Expected: every check FAILs (the script does not exist; `train` returns 127).

- [ ] **Step 3: Write the script**

Create `deployment/home-server/guest/recommender-train.sh`:

```bash
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
```

`chmod +x deployment/home-server/guest/recommender-train.sh`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `deployment/home-server/test/recommender_train_test.sh`
Expected: `all passed` (8 checks).

- [ ] **Step 5: Write the units**

Create `deployment/home-server/guest/systemd/recommender-train.service`:

```ini
[Unit]
Description=Train the book-recommendations model on the newest export (docs/features/home-server.md)
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/opt/the-greatest/deployment/home-server/guest/recommender-train.sh
TimeoutStartSec=2h
```

Create `deployment/home-server/guest/systemd/recommender-train.timer`:

```ini
[Unit]
Description=Train the book-recommendations model daily, and at boot

[Timer]
OnCalendar=*-*-* 04:00
OnBootSec=20min

[Install]
WantedBy=timers.target
```

- [ ] **Step 6: Write the failing install-units tests**

In `deployment/home-server/test/timers_test.sh`, replace `t_units_for_ol` and `t_units_for_fetcher` with:

```bash
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
```

and change their `check` labels to `check "ol gets the refresh and train timers" t_units_for_ol` and `check "fetcher gets neither" t_units_for_fetcher`.

- [ ] **Step 7: Run the timers test to verify the ol check fails**

Run: `deployment/home-server/test/timers_test.sh`
Expected: `FAIL  ol gets the refresh and train timers`; the fetcher check passes.

- [ ] **Step 8: Install the unit for role ol and document the env keys**

In `deployment/home-server/guest/install-units.sh` change the `ol` case:

```bash
  ol) units+=(ol-refresh recommender-train) ;;
```

In `deployment/home-server/guest/lib.sh` replace the comment line above `load_env` with:

```bash
# ROLE, REPO_REF, TUNNELS_ENABLED, TUNNEL_TOKEN, HC_HEARTBEAT, HC_DEPLOY, HC_REFRESH;
# on ol also HC_RECOMMENDER and RECOMMENDER_R2_ENDPOINT/ACCESS_KEY/SECRET_KEY/BUCKET
# (compose.sh exports them, which is how the recommender service gets them).
```

- [ ] **Step 9: Run both test files and shellcheck**

Run: `deployment/home-server/test/timers_test.sh && deployment/home-server/test/recommender_train_test.sh && (command -v shellcheck >/dev/null && shellcheck -x deployment/home-server/guest/recommender-train.sh deployment/home-server/test/recommender_train_test.sh || uvx --from shellcheck-py shellcheck -x deployment/home-server/guest/recommender-train.sh deployment/home-server/test/recommender_train_test.sh)`
Expected: `all passed` twice; shellcheck prints nothing.

- [ ] **Step 10: Commit**

```bash
git add deployment/home-server/guest/recommender-train.sh deployment/home-server/guest/systemd/recommender-train.service deployment/home-server/guest/systemd/recommender-train.timer deployment/home-server/guest/install-units.sh deployment/home-server/guest/lib.sh deployment/home-server/test/recommender_train_test.sh deployment/home-server/test/timers_test.sh
git commit -m "Home server: recommender-train timer and script on the ol VM"
```

---

### Task 2: deploy.sh builds the trainer image on ol

**Files:**
- Modify: `deployment/home-server/guest/deploy.sh` (the `case "$ROLE"` that picks `service`, and the `build` call)
- Test: `deployment/home-server/test/deploy_test.sh`

**Interfaces:**
- Consumes: the `recommender` service name from `data-sources/docker-compose.yml`.
- Produces: on role `ol`, `"$COMPOSE" build api recommender`; `up` is unchanged (`api`, plus `cloudflared` when tunnels are on). The trainer is a one-shot `run --rm` service and is never brought `up`.

Why: `deploy.sh` watches `data-sources/` and `deployment/home-server/`, so a merged change to `src/recommender/` triggers a deploy, but today the deploy builds only `api`; the timer would keep running the old image until something else rebuilt it.

- [ ] **Step 1: Write the failing tests**

In `deployment/home-server/test/deploy_test.sh`, replace `t_ol_without_version` with:

```bash
t_ol_without_version() {
  setup; write_env ROLE=ol REPO_REF=main TUNNELS_ENABLED=0 HC_DEPLOY=https://hc.test/deploy
  commit data-sources/app v2
  deploy && called '^compose build api recommender$' && ! called '^compose up'
}
t_ol_with_version() {
  setup; write_env ROLE=ol REPO_REF=main TUNNELS_ENABLED=0 HC_DEPLOY=https://hc.test/deploy
  echo 2026-09-30 >"$OL_DATA/current-version"
  commit data-sources/src/recommender/ease.py v2
  deploy && called '^compose build api recommender$' && called '^compose up -d --remove-orphans api$' &&
    ! called 'up .*recommender'
}
```

and add, directly after the existing `check` line for `t_ol_without_version` (keep that line's label as it is):

```bash
check "ol builds the trainer image with the api and brings up only the api" t_ol_with_version
```

The fetcher's build list does not change, so `t_watched` (`compose build fetcher`) stays as it is.

- [ ] **Step 2: Run the test to verify it fails**

Run: `deployment/home-server/test/deploy_test.sh`
Expected: the two `ol` checks FAIL (`compose build api` is called, not `compose build api recommender`); everything else passes.

- [ ] **Step 3: Build both images on ol**

In `deployment/home-server/guest/deploy.sh` replace

```bash
case "$ROLE" in
  ol) service=api ;;
  fetcher) service=fetcher ;;
  *) fail "unknown ROLE '$ROLE'" ;;
esac
# A failed build leaves the running container exactly as it was.
"$COMPOSE" build "$service" || fail "image build for $service at ${target:0:12}"
```

with

```bash
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `deployment/home-server/test/deploy_test.sh`
Expected: `all passed`.

- [ ] **Step 5: Commit**

```bash
git add deployment/home-server/guest/deploy.sh deployment/home-server/test/deploy_test.sh
git commit -m "Home server: deploy builds the recommender image on ol"
```

---

### Task 3: compose.ol.yml limits for the trainer

**Files:**
- Modify: `deployment/home-server/compose.ol.yml`
- Test: `deployment/home-server/test/compose_config_test.sh`, `deployment/home-server/test/provision_test.sh` (`t_build_cpus_fit_vm`)

**Interfaces:**
- Consumes: the `recommender` service and `recommender-work` volume defined in `data-sources/docker-compose.yml`.
- Produces: the merged `ol` model's `recommender` service with `mem_limit: 14g`, `cpus: 10`, visible only when the service is named or the `recommender` profile is on.

- [ ] **Step 1: Write the failing compose test**

In `deployment/home-server/test/compose_config_test.sh` add after `t_fetcher_untouched`:

```bash
t_recommender() {
  # `config` normalises 14g to bytes (as a number or a string); accept any of the three.
  cfg ol recommender | jq -e '.services.recommender as $r |
    ($r.mem_limit == 15032385536 or $r.mem_limit == "15032385536" or $r.mem_limit == "14g") and $r.cpus == 10 and
    ($r.environment | has("RECOMMENDER_R2_ENDPOINT") and has("RECOMMENDER_R2_ACCESS_KEY") and
      has("RECOMMENDER_R2_SECRET_KEY") and has("RECOMMENDER_R2_BUCKET")) and
    ($r.volumes[0].target == "/work")' >/dev/null
}
t_recommender_off_by_default() { ! cfg ol | jq -e '.services | has("recommender")' >/dev/null; }
t_recommender_not_on_fetcher() { cfg fetcher recommender | jq -e '.services.recommender.mem_limit == null' >/dev/null; }
```

and, with the other `check` lines:

```bash
check "the trainer gets 14g and 10 CPUs on ol, with the R2 variables and its work volume" t_recommender
check "the trainer is off until named or its profile is on" t_recommender_off_by_default
check "the fetcher's compose does not cap the trainer" t_recommender_not_on_fetcher
```

- [ ] **Step 2: Run it to verify it fails**

Run: `deployment/home-server/test/compose_config_test.sh`
Expected: `FAIL  the trainer gets 14g and 10 CPUs on ol...`; the other two new checks pass already (the base file defines the service without limits). If it prints `SKIP  docker not installed`, docker is not on this machine: the CI job runs it; note that in the task report.

- [ ] **Step 3: Fix the CPU-fit test before adding a second cpus line**

In `deployment/home-server/test/provision_test.sh` replace `t_build_cpus_fit_vm` with:

```bash
# Every service's CPU cap must fit inside the ol VM (build and recommender).
t_build_cpus_fit_vm() {
  local cpus found=0
  vm_spec ol || return 1
  while read -r cpus; do
    found=1
    [ "$cpus" -le "$CORES" ] || return 1
  done < <(sed -n 's/^ *cpus: *\([0-9]*\)$/\1/p' "$HS_DIR/compose.ol.yml")
  [ "$found" = 1 ]
}
```

Keep its `check` label as it is. Run `deployment/home-server/test/provision_test.sh`: still `all passed` (one `cpus:` line today).

- [ ] **Step 4: Add the limits**

Append to `deployment/home-server/compose.ol.yml`:

```yaml
  recommender:
    # recommender-train.timer, 04:00: after the 03:00 refresh has either skipped
    # or taken the build lock (then the train defers), so it never shares the
    # VM with a build and gets the build's share. The fit held 3.2 GiB at
    # 10,013 books in 2026-10; memory grows with the square of the books that
    # have five or more readers.
    mem_limit: 14g
    cpus: 10
```

- [ ] **Step 5: Run both tests**

Run: `deployment/home-server/test/compose_config_test.sh && deployment/home-server/test/provision_test.sh`
Expected: `all passed` twice. If the first check still fails on `mem_limit`, print `cfg ol recommender | jq .services.recommender.mem_limit` and match what compose emits (one of the three spellings; do not loosen the test beyond that).

- [ ] **Step 6: Commit**

```bash
git add deployment/home-server/compose.ol.yml deployment/home-server/test/compose_config_test.sh deployment/home-server/test/provision_test.sh
git commit -m "Home server: cap the recommender at 14g and 10 CPUs on ol"
```

---

### Task 4: provision renders the trainer's secrets into the ol VM

**Files:**
- Modify: `deployment/home-server/lib/vm.sh` (`render_vm_env`)
- Modify: `deployment/home-server/lib/verify.sh` (`verify_vms`)
- Test: `deployment/home-server/test/render_test.sh`

**Interfaces:**
- Consumes: `load_secrets` in `lib/common.sh` exports every `KEY=value` line of `secrets/home-server.env`, so `RECOMMENDER_R2_ENDPOINT`, `RECOMMENDER_R2_ACCESS_KEY`, `RECOMMENDER_R2_SECRET_KEY`, `RECOMMENDER_R2_BUCKET` and `HC_RECOMMENDER` are plain variables when `render_vm_env` runs (blank when absent, like the `HC_*` values).
- Produces: `/etc/the-greatest/home-server.env` on `ol` with exactly these keys, in this order: `ROLE REPO_REF TUNNELS_ENABLED TUNNEL_TOKEN HC_HEARTBEAT HC_DEPLOY HC_REFRESH HC_RECOMMENDER RECOMMENDER_R2_ENDPOINT RECOMMENDER_R2_ACCESS_KEY RECOMMENDER_R2_SECRET_KEY RECOMMENDER_R2_BUCKET`. The fetcher's file is unchanged: `ROLE REPO_REF TUNNELS_ENABLED TUNNEL_TOKEN HC_HEARTBEAT HC_DEPLOY HC_REFRESH`.

- [ ] **Step 1: Write the failing render tests**

In `deployment/home-server/test/render_test.sh`:

Add to the `export` block near the top, after the `HC_FETCHER_*` line:

```bash
export HC_RECOMMENDER=https://hc.test/ol-train RECOMMENDER_R2_ENDPOINT=https://acct.r2.test
export RECOMMENDER_R2_ACCESS_KEY=rec-access RECOMMENDER_R2_SECRET_KEY=rec-secret RECOMMENDER_R2_BUCKET=rec-bucket
```

Replace `t_fetcher_isolation` and `t_env_keys` with:

```bash
t_fetcher_isolation() {
  local env; env="$(env_from_yaml "$SANDBOX/fetcher.yaml")"
  grep -qx 'TUNNEL_TOKEN=fetcher-token' <<<"$env" && ! grep -q 'ol-' <<<"$env" &&
    ! grep -q 'RECOMMENDER' <<<"$env" && ! grep -q 'rec-' <<<"$env"
}
t_ol_trainer_env() {
  env_from_yaml "$SANDBOX/ol.yaml" | grep -qx 'HC_RECOMMENDER=https://hc.test/ol-train' &&
    env_from_yaml "$SANDBOX/ol.yaml" | grep -qx 'RECOMMENDER_R2_ENDPOINT=https://acct.r2.test' &&
    env_from_yaml "$SANDBOX/ol.yaml" | grep -qx 'RECOMMENDER_R2_SECRET_KEY=rec-secret' &&
    env_from_yaml "$SANDBOX/ol.yaml" | grep -qx 'RECOMMENDER_R2_BUCKET=rec-bucket'
}
t_env_keys() {
  local keys
  keys="$(env_from_yaml "$SANDBOX/ol.yaml" | cut -d= -f1 | tr '\n' ' ')"
  [ "$keys" = "ROLE REPO_REF TUNNELS_ENABLED TUNNEL_TOKEN HC_HEARTBEAT HC_DEPLOY HC_REFRESH HC_RECOMMENDER RECOMMENDER_R2_ENDPOINT RECOMMENDER_R2_ACCESS_KEY RECOMMENDER_R2_SECRET_KEY RECOMMENDER_R2_BUCKET " ] || return 1
  keys="$(env_from_yaml "$SANDBOX/fetcher.yaml" | cut -d= -f1 | tr '\n' ' ')"
  [ "$keys" = "ROLE REPO_REF TUNNELS_ENABLED TUNNEL_TOKEN HC_HEARTBEAT HC_DEPLOY HC_REFRESH " ]
}
```

Extend `t_blank_secrets` so an absent trainer secret renders blank too:

```bash
t_blank_secrets() {
  (unset OL_TUNNEL_TOKEN HC_OL_HEARTBEAT RECOMMENDER_R2_BUCKET; render_vm_env ol "$SANDBOX/blank.env") &&
    grep -qx 'TUNNEL_TOKEN=' "$SANDBOX/blank.env" && grep -qx 'RECOMMENDER_R2_BUCKET=' "$SANDBOX/blank.env"
}
```

Add the check line next to `check "ol gets its role, token and refresh check" t_ol_env`:

```bash
check "ol gets the trainer's check and R2 values" t_ol_trainer_env
```

and relabel the keys check: `check "each env has exactly the keys guest/lib.sh documents, ol with the trainer's" t_env_keys`.

- [ ] **Step 2: Run it to verify it fails**

Run: `deployment/home-server/test/render_test.sh`
Expected: `t_ol_trainer_env`, `t_env_keys` and `t_blank_secrets` FAIL; `t_fetcher_isolation` passes.

- [ ] **Step 3: Render the keys for ol only**

In `deployment/home-server/lib/vm.sh` replace the `ol)` branch of `render_vm_env`:

```bash
    ol) printf '%s\n' "ROLE=ol" "REPO_REF=$REPO_REF" "TUNNELS_ENABLED=$TUNNELS_ENABLED" \
          "TUNNEL_TOKEN=${OL_TUNNEL_TOKEN:-}" "HC_HEARTBEAT=${HC_OL_HEARTBEAT:-}" \
          "HC_DEPLOY=${HC_OL_DEPLOY:-}" "HC_REFRESH=${HC_OL_REFRESH:-}" \
          "HC_RECOMMENDER=${HC_RECOMMENDER:-}" \
          "RECOMMENDER_R2_ENDPOINT=${RECOMMENDER_R2_ENDPOINT:-}" \
          "RECOMMENDER_R2_ACCESS_KEY=${RECOMMENDER_R2_ACCESS_KEY:-}" \
          "RECOMMENDER_R2_SECRET_KEY=${RECOMMENDER_R2_SECRET_KEY:-}" \
          "RECOMMENDER_R2_BUCKET=${RECOMMENDER_R2_BUCKET:-}" ;;
```

and update the comment above the function to: `# render_vm_env <role> <out>: the VM's /etc/the-greatest/home-server.env. Each VM gets only its own token and check URLs; the trainer's R2 values go to ol alone.`

- [ ] **Step 4: Run it to verify it passes**

Run: `deployment/home-server/test/render_test.sh`
Expected: `all passed`.

- [ ] **Step 5: Let --verify assert the timer**

In `deployment/home-server/lib/verify.sh`, in `verify_vms`, after the `for role in ol fetcher` loop and before the `fetcher: /health answers` line, add:

```bash
  expect "ol: recommender-train.timer is enabled" vm_ssh ol "systemctl is-enabled --quiet recommender-train.timer"
```

There is no sandbox test for `verify_vms` (it needs the VM); shellcheck covers the line.

- [ ] **Step 6: Run the whole gate**

Run: `deployment/home-server/test/run.sh`
Expected: shellcheck silent; every `*_test.sh` ends `all passed` (or `SKIP  docker not installed` for the compose test); exit 0.

- [ ] **Step 7: Commit**

```bash
git add deployment/home-server/lib/vm.sh deployment/home-server/lib/verify.sh deployment/home-server/test/render_test.sh
git commit -m "Home server: provision renders the trainer's R2 values and check into ol"
```

---

### Task 5: Documentation and the spec amendment

**Files:**
- Modify: `docs/features/home-server.md`
- Modify: `docs/features/recommendations.md`
- Modify: `docs/superpowers/specs/2026-10-09-book-recommendations-collaborative-design.md` (§4.4)
- Modify: `docs/launch-todo.md` (§3)

No code; the check is reading each edit against the code from Tasks 1–4. Keep the existing voice of each document.

- [ ] **Step 1: The runbook**

In `docs/features/home-server.md`:

1. Layout diagram: change the line `│   build (timer)                                                       │` to `│   build, train (timers)                                               │` (keep the box aligned: the new line must be exactly as long as the one it replaces, so drop eight of the trailing spaces; check with `awk '{print length}'` on the diagram's lines, which must all be equal).
2. Secrets table: after the `HC_OL_HEARTBEAT, ...` row add

   ```
   | `HC_RECOMMENDER` | optional | healthchecks.io ping URL for `recommender-train`, `ol` only |
   | `RECOMMENDER_R2_ENDPOINT`, `RECOMMENDER_R2_ACCESS_KEY`, `RECOMMENDER_R2_SECRET_KEY`, `RECOMMENDER_R2_BUCKET` | the trainer | The recommendations bucket (`docs/features/recommendations.md`, "Collaborative signal"): its S3 endpoint and a token scoped to it. All four or none; `ol` only. With none set, `recommender-train` logs a skip and does not ping. |
   ```
3. "What happens without anyone" table: after the `Bad dump` row add

   ```
   | Stale model | `recommender-train.timer` (04:00, and 20 min after boot) runs `recommender-train.sh`. The trainer refuses an export older than three days or a model that fails its gate and exits non-zero, which pings `fail` with its last line; `model/latest` in the bucket and the model Rails serves stay as they were. A day under the build lock defers (`success` with `deferred: lock held`); the check's 2-day grace covers one. |
   ```
4. Alerts table: after the `ol-refresh` row add

   ```
   | `recommender-train` | `recommender-train.sh`: `start`, then `success` with the trainer's last line, `deferred: lock held`, or `fail` | 1 day / 2 days |
   ```

   Change "the account and the five checks above" in the setup checklist to "the account and the six checks above", and the sentence "Deploy and refresh also send a plain success ping with a message when they defer" to "Deploy, refresh and train also send a plain success ping with a message when they defer".
5. In the paragraph that starts "Security updates install on both VMs" add a final sentence: "`recommender-train` is the same shape as the build: a one-shot `run --rm` under a timer, no restart policy, run again at the next 04:00 or 20 minutes after boot; the trainer itself says `already trained; nothing to do` when there is nothing new."

- [ ] **Step 2: The feature doc**

In `docs/features/recommendations.md`:

1. Delivery state (the paragraph starting "State of delivery"): replace "its second, the home-server timer that trains in production, is not, so production has no model and the signal is unavailable there until it lands." with "its second, the home-server timer that trains in production, is built (`deployment/home-server/guest/recommender-train.sh`); the one-time setup that gives production its first model is `docs/launch-todo.md`, section 3."
2. The "**Production** runs the same three legs" paragraph: replace "the trainer as a `recommender` compose service under a systemd timer (04:00 Chicago) on the home server's `ol` VM, pinging a healthchecks.io check." with "the trainer as the `recommender` compose service under `recommender-train.timer` (04:00 UTC, and 20 minutes after boot) on the home server's `ol` VM, pinging the healthchecks.io check `recommender-train` (`docs/features/home-server.md`)." Replace "That deployment is spec 2 §4.4 and its increment 2, not yet built; until it is and the store is configured, the jobs log a skip and the signal stays unavailable." with "Until the bucket's values are in both secrets files, the Rails jobs log a skip, the timer logs `RECOMMENDER_R2_* not set` and exits, and the signal stays unavailable."
3. "**Time zones.**": replace "The home server's 04:00 Chicago train therefore runs 6.5-7.5 h after the export, depending on daylight saving." with "The `ol` VM's clock is UTC too, so the 04:00 train runs 1.5 h after the export, an hour after the 03:00 dump refresh (a refresh that starts a build holds the lock, and the train defers to the next day)."

- [ ] **Step 3: The spec amendment**

In `docs/superpowers/specs/2026-10-09-book-recommendations-collaborative-design.md` §4.4, change `OnCalendar=*-*-* 04:00`, `OnBootSec=20min`.` to:

```
`OnCalendar=*-*-* 04:00`, `OnBootSec=20min`. (Amended 2026-10-10: the VM's clock is UTC and
  provision sets no time zone, so this is 04:00 UTC, 1.5 h after the 02:30 UTC export, not 04:00
  Chicago; `deploy.sh` builds the trainer image with the API's so merged trainer changes reach the
  VM; the `RECOMMENDER_R2_*` pass-through lives in `data-sources/docker-compose.yml`, so
  `compose.ol.yml` adds only the limits.)
```

- [ ] **Step 4: The launch todo**

In `docs/launch-todo.md` §3:

1. Step 3: replace "Run `deployment/home-server/provision` so the `ol` VM gets the units and env." with "Run `deployment/home-server/provision` (`SOPS_AGE_KEY_FILE` set) so the `ol` VM gets the new env; its next deploy (within 15 minutes) installs `recommender-train.timer` and builds the trainer image. `provision --verify` then reports `ol: recommender-train.timer is enabled`. If the VMs were pointed at a branch to test this, `provision --ref main` goes **before** the merge: GitHub deletes the merged branch and a VM tracking it fails its next deploy."
2. Step 4: replace "(04:00 Chicago; or `systemctl start recommender-train` on the `ol` VM)" with "(04:00 UTC; or `sudo systemctl start recommender-train` on the `ol` VM, then `journalctl -u recommender-train` for the trainer's output)".

- [ ] **Step 5: Check the edits**

Run: `grep -n "Chicago" docs/features/recommendations.md docs/features/home-server.md docs/launch-todo.md`
Expected: no output (the only remaining "Chicago" is in the spec's amendment, which the grep does not cover). Run `deployment/home-server/test/run.sh` once more (docs cannot break it; this is the pre-commit gate).

- [ ] **Step 6: Commit**

```bash
git add docs/features/home-server.md docs/features/recommendations.md docs/superpowers/specs/2026-10-09-book-recommendations-collaborative-design.md docs/launch-todo.md
git commit -m "Docs: the recommender-train timer in the home-server runbook, feature doc, spec and launch todo"
```

---

## After the plan: acceptance on the real VM (Shane, not a subagent)

The sandbox tests prove the scripts; only the box proves the units. Auto mode cannot run `provision` (it is a production deploy), so these are run by hand with `!`:

1. Put `RECOMMENDER_R2_ENDPOINT/ACCESS_KEY/SECRET_KEY/BUCKET` and `HC_RECOMMENDER` in `secrets/home-server.env` (`sops secrets/home-server.env`), the trainer's own token on the bucket, and create the `recommender-train` check (period 1 day, grace 2 days). Launch todo §3 steps 1–2.
2. Either merge first and wait for the VMs' next deploy, or test the branch on the VM: `deployment/home-server/provision --ref <branch>`, wait for `ol-deploy` to ping, then `ssh` to `ol` and `sudo systemctl start recommender-train && journalctl -u recommender-train -n 50`. **Then `provision --ref main` before merging.**
3. After merging and provisioning on `main`: launch todo §3 step 4 (export from a console, start the train, confirm `RecommendationModel.active_for(:books)` after the next :15 load).
