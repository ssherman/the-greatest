# Home Server NIC Watchdog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Proxmox host detects a hung or silent network card, resets it, reboots only if that fails, and reports what it did.

**Architecture:** One bash script, `host/sbin/nic-watchdog`, runs once a minute from a systemd timer. Each run is one check: read the signals, decide from small state files, act, exit. `provision` installs it and keeps the TSO/GSO setting.

**Tech Stack:** Bash, systemd, the existing `deployment/home-server` shell tests and shellcheck.

**Spec:** `docs/superpowers/specs/2026-11-06-home-server-nic-watchdog-design.md`

## Global Constraints

- Work only in `deployment/home-server/` and `docs/features/home-server.md`. Run tests with `deployment/home-server/test/run.sh` from the repo root.
- No house IP, token or ping URL in commits, PRs, logs or test output. Tests use documentation addresses (`198.51.100.1`) and `https://hc.test/...`.
- Nothing may run `qm` against VM 101. Do not SSH to the host, run `provision`, or ping any real healthchecks.io URL. Shane runs `provision`.
- Test stubs must not call themselves by name; a stub wrapping a real tool uses `command -p`.
- Do not push or open a PR without asking Shane.
- Only `ping` exit status 1 counts as gateway lost. Anything unknown means log only and never act.

## Review Focus

- A pause: the timer stopped for hours and then restarted must not act on the old clock and reboot at once.
- A wrong clock: a stored reboot time in the future must not block reboots forever.
- A downed port: `ping` can exit 2 (network unreachable) when carrier is gone, which must not stall an episode at "unknown".
- A similar interface: a hang logged for `eno10` must not count for `eno1`.
- Rehearsal leaks: log-only mode must not write a reboot time, a marker or a report.

---

### Task 1: The watchdog script and its tests

**Files:**
- Create: `deployment/home-server/host/sbin/nic-watchdog`
- Create: `deployment/home-server/test/nic_watchdog_test.sh`

**Interfaces:**
- Produces: `nic-watchdog`, no arguments, exit 0 on any completed check, including log-only decisions.
- Reads these from the environment, with defaults, so tests can redirect them:

| Variable | Default |
|---|---|
| `NIC_WATCHDOG_ENV` | `/etc/the-greatest-home-server/nic-watchdog.env` |
| `NIC_WATCHDOG_LOG_ONLY_FILE` | `/etc/the-greatest-home-server/nic-watchdog-log-only` |
| `NIC_WATCHDOG_STATE` | `/var/lib/nic-watchdog` (survives reboot) |
| `NIC_WATCHDOG_RUN` | `/run/nic-watchdog` (clears on boot) |
| `NIC_WATCHDOG_SYS` | `/sys/class/net` |
| `NIC_WATCHDOG_NOW` | current epoch seconds |

- The env file holds `NIC=` and `HC_NIC_WATCHDOG=`. Parse it line by line for those two keys; never source it. Missing `NIC` logs and exits 1 without acting.
- All logging is plain stdout lines; the service's `SyslogIdentifier` tags them.

**State files.** Each holds one value.

| File | Holds |
|---|---|
| `$RUN/last_check` | Epoch of the previous check |
| `$RUN/hang_streak` | Consecutive checks with hang messages |
| `$RUN/hang_seen` | Present once a hang was seen in this episode |
| `$RUN/gateway_lost_since` | Epoch the gateway was first lost |
| `$RUN/resets` | Resets in this episode |
| `$RUN/last_reset` | Epoch of the last reset |
| `$STATE/last_reboot` | Epoch of the last reboot this script asked for |
| `$STATE/gateway_reboot_marker` | Presence means a gateway-only reboot happened and the gateway hasn't answered since. Contents are never read |
| `$STATE/answering_resets` | One epoch per line: resets done while the gateway answered |
| `$STATE/last_ping` | Epoch of the last success ping |
| `$STATE/report` | Lines waiting to be sent |

**One check, in order** (constants at the top: `GATEWAY_RESET_1=300`, `GATEWAY_RESET_2=900`, `GATEWAY_REBOOT=1800`, `RETRY_RESET=1800`, `REBOOT_LIMIT=21600`, `ANSWERING_RESET_CAP=2`, `STALE_GAP=300`):

1. **Stale state.** If `last_check` exists and is more than `STALE_GAP` old, or in the future, delete all `$RUN` episode files. Keep the previous value for step 3, then write NOW to `last_check` straight away, so every later stop has recorded the check.
2. **Carrier.** Read `$SYS/$NIC/carrier`. Unreadable: log, stop.
3. **Hang.** `journalctl -k -b 0 --no-pager -o cat --since @<later of last_check and last_reset, else NOW-120>`. Capture output and status first and match after, with a fixed string `$NIC: Detected Hardware Unit Hang`. Do not use `--grep`, which exits 1 on no match. Non-zero status: log, stop. A hang increments `hang_streak` and sets `hang_seen`; no hang sets the streak to 0.
4. **Episode** means `hang_seen` exists or `resets` is above 0.
5. **Carrier down with no episode and no hang:** log, delete `gateway_lost_since`, stop.
6. **Gateway.** If carrier is down, gateway is `lost` without pinging. Otherwise read it from `ip -4 route show default` (no route: log, stop) and run `ping -c 3 -W 2 -I vmbr0 <gw>`: 0 is `answers`, 1 is `lost`, anything else logs and stops.
7. **Gateway answers:** delete `gateway_lost_since` and the marker, send any report and any hourly ping (below). If there is no hang this check, also delete all episode files and stop. Otherwise, at streak 2 or more, reset if `answering_resets` holds fewer than `ANSWERING_RESET_CAP` entries newer than `REBOOT_LIMIT`, and record the time; else log. Never reboot. Stop.
8. **Gateway lost, set clock:** write `gateway_lost_since` if absent.
9. **Hang this check, streak 2 or more:** with `resets` below 2, reset. Otherwise try a reboot of kind `hang`. Stop.
10. **Gateway-only:** `age = NOW - gateway_lost_since`. With `resets` at 0 and age at least `GATEWAY_RESET_1`, reset. With `resets` at 1 and age at least `GATEWAY_RESET_2`, reset. With age at least `GATEWAY_REBOOT`, try a reboot of kind `gateway`. Otherwise wait.

**Try a reboot of kind K:**
- Refused if `last_reboot` is non-numeric or in the future; rewrite it with NOW so the limit restarts instead of blocking forever.
- Refused if `last_reboot` is less than `REBOOT_LIMIT` old.
- Refused when K is `gateway` and the marker exists.
- Refused if the state directory can't be written.
- When refused: log why, and reset if `last_reset` is at least `RETRY_RESET` old or absent.
- When allowed: write `last_reboot`, write the marker if K is `gateway`, append to the report, then call `systemctl reboot`. Each write must succeed before the next step, and the reboot must not run if any failed.

**A reset:** `ip link set "$NIC" down`, `sleep 3`, `ip link set "$NIC" up`, then up to 15 one-second waits for carrier. Then increment `resets`, write `last_reset`, append to the report. Nothing else: not `vmbr0`, not `qm`.

**Log-only mode** (the file exists): every reset and reboot logs `would reset` or `would reboot` instead. Resets still update `resets` and `last_reset`, so the sequence advances. It writes no `last_reboot`, marker, `answering_resets` or report.

**Sending**, only on a check where the gateway answers and `HC_NIC_WATCHDOG` is not blank:
- If `report` exists: `curl -fsS -m 10 -o /dev/null --data-binary @report "$HC/fail"`, removing the file only on success.
- Otherwise, if `last_ping` is at least 3600 old or absent: `curl -fsS -m 10 -o /dev/null "$HC"`, writing `last_ping` on success.
- Discard curl's stderr, since it can contain the URL. Log only "sent" or "failed".

- [ ] **Step 1: Write the failing tests**

`nic_watchdog_test.sh` sources `helpers.sh`. `setup` makes a sandbox, points the variables above into it, writes `NIC=eno1` and `HC_NIC_WATCHDOG=https://hc.test/abc`, sets carrier to 1, and stubs `journalctl` (prints `$SANDBOX/kernel-log`, exits `${JOURNAL_RC:-0}`), `ping` (exits `${PING_RC:-0}`), `ip` (prints `default via 198.51.100.1 dev vmbr0` for a route query unless `NO_ROUTE` is set), `systemctl`, `curl` (exits `${CURL_RC:-0}`) and `sleep`. A helper `run_at <epoch>` runs the script once with `NIC_WATCHDOG_NOW` set, saving output to `$SANDBOX/log/out`. A helper `hang_on`/`hang_off` fills or empties `kernel-log`.

Each test below asserts through `called` on the stub log and through state files. Time starts at `T=1000000`; checks are 60 s apart unless stated.

Hang path:
- `t_one_hang_no_reset`: one check with a hang: `! called 'ip link set eno1 down'`.
- `t_two_hangs_reset`: second check calls `ip link set eno1 down` then `ip link set eno1 up`.
- `t_hang_sequence_reboots`: `PING_RC=1`, hang on every check: the reset count after checks 2, 3 is 1, 2; check 4 calls `systemctl reboot`.
- `t_hang_gateway_answers_capped`: `PING_RC=0`, hang on 6 checks: exactly 2 `link set eno1 down` calls, no `systemctl reboot`.
- `t_separate_hangs_share_cap`: three separate hangs with clean checks between, all inside 6 hours and `PING_RC=0`: exactly 2 resets. A fourth at `T+21700` resets again.
- `t_other_nic_ignored`: log says `eno10: Detected Hardware Unit Hang`, two checks: no reset, `hang_streak` is 0.

Gateway path (`PING_RC=1`, no hang):
- `t_gateway_timeline`: checks each minute to 31 minutes: no reset before minute 5, 1 reset by minute 5, 2 by minute 15, reboot by minute 30, and `gateway_reboot_marker` exists.
- `t_gateway_recovery_clears`: lost for 10 minutes, then `PING_RC=0`: `gateway_lost_since` and `resets` are gone and the next loss starts its clock over.

Reboot limits:
- `t_reboot_inside_limit_refused`: `last_reboot` is 1 hour old, hang path reaches a reboot, checks continuing each minute: no `systemctl reboot`, and one more reset 30 minutes after the last.
- `t_reboot_after_limit_allowed`: `last_reboot` is 7 hours old: reboots.
- `t_corrupt_reboot_time_refused`: `last_reboot` holds `garbage`: no reboot, and the file now holds the check's time.
- `t_future_reboot_time_refused`: `last_reboot` is 1 hour ahead: no reboot, and the file now holds the check's time.
- `t_marker_blocks_gateway_reboot`: marker exists and `last_reboot` is 7 hours old, gateway-only for 31 minutes: no reboot, resets continue.
- `t_marker_clears_when_gateway_answers`: `PING_RC=0` once removes the marker, and a later outage can reboot.
- `t_marker_does_not_block_hang`: marker exists, `last_reboot` is 7 hours old, hang path: reboots.
- `t_state_written_before_reboot`: the `systemctl` stub records whether `last_reboot` and the marker exist at call time; both do.
- `t_unwritable_state_no_reboot`: `NIC_WATCHDOG_STATE` is a regular file: no `systemctl reboot` on either path.

Carrier and unknowns:
- `t_carrier_down_no_episode`: carrier 0, 40 checks: no reset, no reboot, no `gateway_lost_since`, and `ping` not called.
- `t_carrier_stays_down_after_reset`: an episode has 2 resets, then carrier 0, `PING_RC=2` and no hang, with checks each minute: `systemctl reboot` by 30 minutes after the gateway was first lost (Review Focus: port down, no ping needed).
- `t_hang_with_carrier_down_is_episode`: carrier 0 and hang on two checks: reset is called.
- `t_ping_unknown_no_action`: `PING_RC=2`, 40 checks: no reset, no reboot.
- `t_no_route_no_action`, `t_journal_fails_no_action` (`JOURNAL_RC=1` and a hang in the log), `t_carrier_unreadable_no_action`: no reset, no reboot.
- `t_missing_nic_exits_1`: env file without `NIC`: exit 1, no reset.

Pause and rehearsal:
- `t_stale_state_discarded`: gateway lost 20 minutes, then a check 3 hours later with `PING_RC=1`: no reboot, and `gateway_lost_since` equals the new check's time.
- `t_log_only_no_actions`: log-only file present, hang path to the end: no `ip link set`, no `systemctl reboot`, output has `would reset` and `would reboot`, and no `last_reboot`, marker, `answering_resets` or `report` file.

Reporting:
- `t_report_kept_until_sent`: a reset happens, then `PING_RC=0` with `CURL_RC=7`: `report` still exists. Next check with `CURL_RC=0`: `curl` was called with `/fail` and `report` is gone.
- `t_report_sent_while_hanging`: gateway answers with hang logged: `/fail` is called.
- `t_report_survives_reboot`: after a reboot, empty `$RUN`: `report` exists and is sent on the first answering check.
- `t_hourly_ping`: healthy checks at `T`, `T+60`, `T+3700`: exactly 2 success pings.
- `t_blank_url_sends_nothing`: `HC_NIC_WATCHDOG=` with a report present: `! called curl`.
- `t_url_never_logged`: a report send and an hourly ping, each with `CURL_RC=7` and the stub printing the URL to stderr: `$SANDBOX/log/out` never has `hc.test`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `deployment/home-server/test/nic_watchdog_test.sh`
Expected: FAIL, script not found.

- [ ] **Step 3: Implement `host/sbin/nic-watchdog`**

Follow the algorithm above. `set -uo pipefail`, deliberately no `-e`: a failed read must be seen and handled, never stop the script partway through a sequence. Executable bit set.

- [ ] **Step 4: Run the tests and shellcheck**

Run: `deployment/home-server/test/run.sh`
Expected: `all passed` for every file, and shellcheck reports nothing.

- [ ] **Step 5: Commit**

```bash
git add deployment/home-server/host/sbin/nic-watchdog deployment/home-server/test/nic_watchdog_test.sh
git commit -m "Home server: add the NIC watchdog script"
```

### Task 2: Provision installs it and keeps TSO/GSO off

**Files:**
- Create: `deployment/home-server/host/systemd/nic-watchdog.service`
- Create: `deployment/home-server/host/systemd/nic-watchdog.timer`
- Modify: `deployment/home-server/lib/host.sh`
- Modify: `deployment/home-server/lib/verify.sh`
- Modify: `deployment/home-server/provision`
- Test: `deployment/home-server/test/provision_test.sh`

**Interfaces:**
- Consumes: the Task 1 script and its env file format.
- Produces in `lib/host.sh`:
  - `bridge_nic`: stdin is `/etc/network/interfaces`; prints `vmbr0`'s single `bridge-ports` value; fails on zero or several.
  - `offload_line <nic>`: prints `post-up /usr/sbin/ethtool -K <nic> tso off gso off`.
  - `converge_host_nic`: sets and exports `NIC`, ensures the line and runtime setting.
  - `converge_host_watchdog`: installs the script, units and env file, and enables the timer.

**Units.** Service: `Type=oneshot`, `ExecStart=/usr/local/sbin/nic-watchdog`, `SyslogIdentifier=nic-watchdog`, `TimeoutStartSec=120`. Timer: `OnBootSec=3min`, `OnUnitActiveSec=1min`, `AccuracySec=5s`, `WantedBy=timers.target`.

**`converge_host_nic`:** after the existing network convergence, in `converge_host_network`'s neighbors.
- `NIC` comes from `bridge_nic` over the host's file; failure dies with a message naming `vmbr0`.
- If the host's file has no `iface $NIC inet manual` stanza, die rather than guess.
- If the stanza lacks `offload_line`, add it under that stanza through `network_change`, so it has the automatic revert.
- If the line exists, leave the file alone.
- Separately, read `ethtool -k $NIC`. If TSO or GSO is on, run the ethtool command on the host and `note_change`. This must not go through `network_change`.

**`converge_host_watchdog`:** `put_host` the script to `/usr/local/sbin/nic-watchdog` mode 0755 and both units to `/etc/systemd/system/`. Render the env file in a `new_tmpdir` directory and `put_host` it to `$HOST_STATE/nic-watchdog.env` mode 0600 (`HC_NIC_WATCHDOG` from the secrets, blank if unset). `daemon-reload` only if a unit changed. `systemctl enable --now nic-watchdog.timer`, with `note_change`, only if it isn't already enabled and active. A second run reports no changes.

**Other changes:**
- `converge_host_packages`: add `ethtool` to the `dpkg -s` check and the install line.
- `provision` converge mode: call `converge_host_nic` after `converge_host_network` and `converge_host_watchdog` after `converge_host_firewall`. Make the same addition wherever `verify_idempotent` in `lib/verify.sh` re-runs convergence, so it doesn't report a false failure.
- `verify_host` adds `expect` lines: timer enabled, timer active, TSO off on `$NIC`, GSO off on `$NIC`, offload line present, log-only file absent. `NIC` must be set for these: read it the same way when it's not exported yet.

- [ ] **Step 1: Write the failing tests in `provision_test.sh`, with `on_host` as a function override over a sandbox file**

- `t_bridge_nic_reads_port`: the live shape (`bridge-ports eno1` under `vmbr0`, a `vmbr1` with `bridge-ports none` in another stanza) prints `eno1`.
- `t_bridge_nic_refuses_several`: `bridge-ports eno1 eno2` fails, and no `bridge-ports` fails.
- `t_offload_line_exact`: `offload_line eno1` equals `post-up /usr/sbin/ethtool -K eno1 tso off gso off`.
- `t_existing_offload_line_left_alone`: a file with the live line: `converge_host_nic` makes no `network_change` call and no edit.
- `t_offload_line_added_once`: a file without it: the line lands directly under `iface eno1 inet manual`, once, through `network_change` (overridden to run its mutate function). A second run adds nothing.
- `t_offload_missing_stanza_dies`: no `iface eno1` stanza: dies, file unchanged.
- `t_offload_runtime_reapplied`: file has the line, `ethtool -k` says TSO on: the ethtool command runs, `network_change` is not called.
- `t_watchdog_units_valid`: the timer holds `OnUnitActiveSec=1min` and `OnBootSec=3min`; the service holds `ExecStart=/usr/local/sbin/nic-watchdog`.
- `t_watchdog_env_mode`: with `HC_NIC_WATCHDOG` set, `put_host` is asked for `nic-watchdog.env` with mode 0600.

Register each with a `check` line before `finish`.

- [ ] **Step 2: Run to verify they fail**

Run: `deployment/home-server/test/provision_test.sh`
Expected: FAIL for the new checks, existing checks still pass.

- [ ] **Step 3: Implement the changes above**

- [ ] **Step 4: Run the whole suite and shellcheck**

Run: `deployment/home-server/test/run.sh`
Expected: `all passed` for every file, and shellcheck reports nothing.

- [ ] **Step 5: Commit**

```bash
git add deployment/home-server/host/systemd deployment/home-server/lib deployment/home-server/provision deployment/home-server/test/provision_test.sh
git commit -m "Home server: provision the NIC watchdog and TSO/GSO setting"
```

### Task 3: Runbook and documentation

**Files:**
- Modify: `docs/features/home-server.md`

**Interfaces:** consumes the behavior of Tasks 1 and 2. No code.

- [ ] **Step 1: Update `docs/features/home-server.md`**

- Keys table: add `HC_NIC_WATCHDOG`, optional, host only.
- Mode table: `--verify` also checks the timer, TSO/GSO, the offload line and the log-only file.
- "Three behaviors", "It never reboots the host": keep, as true of `provision`, and say the watchdog is the one exception.
- "What happens without anyone": add a row for a hung card, and change "Box offline" so it says the watchdog tries first.
- The sentence "the host never reboots itself" near the security updates: say apt upgrades never reboot it, and name the watchdog as the only thing that can.
- Alerts table: `nic-watchdog`, pinged by the host, success at most hourly plus `/fail` with a report after a reset or reboot, 1 hour / 1 hour.
- "Done once by hand": the check is now one more to create.
- New section "Hung network card": the journal findings from the spec, the decision table, the 6-hour limit and the one-gateway-reboot marker, how to read the record (`journalctl -t nic-watchdog`), how to pause it (`systemctl stop nic-watchdog.timer`, restarted by a later `provision`), the state file locations, and the rollout below as a runbook. Shane runs every step:
  1. `touch /etc/the-greatest-home-server/nic-watchdog-log-only` on the host, then `provision` from this branch with no `--ref`. It may finish by asking for a reboot, because plain `provision` upgrades host packages.
  2. Write a fake hang line to `/dev/kmsg` across two checks, read `journalctl -t nic-watchdog`, and confirm `would reset`. Confirm the fake line reaches `journalctl -k` first; if it doesn't, this rehearsal can't run and only the unit tests cover detection.
  3. Remove the log-only file.
  4. One real reset, run detached because it can drop the SSH session: `systemd-run --collect /bin/sh -c 'ip link set eno1 down; sleep 3; ip link set eno1 up'`. These are the same commands the script runs. Then confirm link, `vmbr0`, all VMs, TSO/GSO still off, and the tunnels answering.
  5. Create the healthchecks.io check, add `HC_NIC_WATCHDOG` to the secrets, re-run `provision`.
  6. Check `ethtool -k` after the next host reboot.

  Say plainly that this can't prove a reset clears a real hang, and that no one should ping the check's URL as a test.

- [ ] **Step 2: Check for leaks**

Run: `git diff main --unified=0 -- deployment docs | grep -E '^\+' | grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}|hc-ping' | grep -vE '198\.51\.100\.|203\.0\.113\.|192\.0\.2\.|10\.20\.0\.|127\.0\.0\.1|[0-9]\.[0-9]+\.[0-9]+-[0-9]+'`
Expected: no output.

- [ ] **Step 3: Run the full home-server suite one last time**

Run: `deployment/home-server/test/run.sh`
Expected: `all passed` for every file, and shellcheck reports nothing.

- [ ] **Step 4: Commit**

```bash
git add docs/features/home-server.md
git commit -m "Home server: document the NIC watchdog and its rollout"
```
