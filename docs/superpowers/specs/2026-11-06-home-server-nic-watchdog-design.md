# Home server: automatic recovery from a hung network card

## Why

The home server's network card hung on 2026-11-03 and stayed hung for 3.4 days, until Shane rebooted
the host by hand. The Open Library API, page fetcher and WorldCat all sit behind that card. On
production, 1,489 `goodreads` workflow steps failed during the outage. healthchecks.io did alert, but
the emails landed in a folder Shane doesn't watch.

The goal is that a hang like this costs minutes, not days, with nobody at the machine. Turning TSO and
GSO off may make hangs rarer, but nothing shows it stops them, so recovery has to exist either way.

## What the host's journal shows

Read from `pve-mini` on 2026-11-06. It is one machine (HP Elite Mini 800 G9) across every boot listed.

- **The hang was one event, not many.** All 148,172 messages carry the same `TDH b8`, `TDT e2` and
  `time_stamp`: the transmit ring froze and never moved. The PHY reported link up, so carrier state
  does not reveal a hang.
- **The card has hung for years, and the kernel used to fix it.** About 205 hang messages from 2023 to
  2025-07, on kernels 6.2.16-3 and 6.8.12-2, came with 53 `NETDEV WATCHDOG` and `Reset adapter
  unexpectedly` pairs. A sampled case: hang at 23:58:58, reset at 23:59:05, link up at 23:59:08.
- **That reset no longer happens.** There are no resets in any of the three hangs since: 2025-09-24 on
  6.8.12-15, 2025-11-16 on 6.14.11-2, and this one on 7.0.14-24. The two 2025 hangs lasted about 90
  seconds and ended with a power-off. The reason is unknown, and three episodes is a small sample.
- **Quiet periods prove little.** The hang before this one was almost a year earlier, so a good stretch
  after a change is weak evidence.

Cycling the link goes through the driver's own down and up path, so the old resets suggest it will
work. That has not been tested against a real hang on kernel 7.0. Reboot exists for the case where it
doesn't.

## Goals

- Detect a hung card, or a card that has silently stopped passing traffic, within a couple of minutes.
- Reset the card first, and reboot the host only if that fails.
- Never let a router or ISP problem cause repeated reboots.
- Tell Shane afterwards that it acted, so silent recoveries don't hide whether TSO/GSO off helped.
- Make the TSO/GSO setting part of `provision`, so a rebuilt host keeps it.

## Non-goals

- Finding why the card hangs, or why the kernel's reset stopped. No kernel pinning, BIOS update or
  replacement NIC here.
- Re-running the failed Goodreads steps. That is separate work.
- Changing how Rails behaves during an outage (the fetch gate stays as it is).
- Fixing where alert emails land. That is a Gmail filter or push channel, and Shane's to set up.

## What would make this a failure

- A reboot loop, however it arises.
- A reboot caused by the watchdog's own error, such as a missing command or an unreadable journal
  being read as "network down".
- Anything acting on VM 101 `musicbrainz` directly. Host reboots and NIC resets affect it as a side
  effect, and Shane has accepted that; nothing may run `qm` against it.
- A house IP, token or ping URL in the repo, the PR or the logs.

## Decided by Shane

- We should never restart a healthy server: a fresh gateway check runs immediately before every reboot, and an answering gateway always vetoes it.
- The watchdog may reboot the host by itself, at most once every 6 hours. This restarts every VM,
  including `musicbrainz`, and interrupts any running Open Library build, which runs again later.
- After a reboot triggered only by a lost gateway, no further gateway-only reboot happens until the
  gateway has answered at least once. Hang messages can still trigger a reboot under the 6-hour limit,
  because they point at the card rather than the router.
- The sequence is detect, reset the NIC, and reboot only if that fails.
- It lives in `deployment/home-server`, with tests, on its own PR.
- TSO and GSO are off on the physical NIC, through a `post-up` line under its stanza in
  `/etc/network/interfaces`, not on `vmbr0`. Already applied by hand on the live host on 2026-11-06.

## Behavior

A systemd timer runs `nic-watchdog` every minute, first at 3 minutes after boot.

### What it looks at

| Signal | How | Meaning |
|---|---|---|
| Hang | `journalctl -k -b 0` for `<nic>: Detected Hardware Unit Hang` since the later of the previous check and the last reset | The driver reports a stuck ring |
| Gateway | `ping -c 3 -W 2 -I vmbr0 <gateway>`, the gateway read on each run from the default route, which must be through `vmbr0` | Traffic actually flows. **Only exit status 1 (no reply) counts as lost.** Any other status is "unknown" |
| Carrier | `/sys/class/net/<nic>/carrier` | The cable and switch are up |

### What it does

| Situation | Action |
|---|---|
| Gateway answers, no hang messages | Healthy. Clear the episode and send any pending report |
| Carrier down, no episode in progress | Log only. A reset or reboot can't fix a cable or a switch. The gateway-lost clock does not run |
| Carrier down during an episode (after a hang was seen or a reset was done) | Keep going as if carrier were up. A port the driver can't bring back, or a card that is hanging, must not stop the path to a reboot |
| Hang messages on 2 checks in a row | Reset. If hang messages continue after that reset, reset once more on the next check. If they continue after the second reset **and** the gateway is lost, reboot |
| Hang messages with the gateway answering | At most 2 resets in any 6 hours, tracked on disk so a card that keeps hanging can't get around the cap. After that, log only. These resets stay out of the count the lost path uses, so a later outage starts at its first reset. Never reboot: traffic is flowing, the gate vetoes it, and for 5 minutes after such a reset the gate refuses even if pings fail, because the reset itself can be why |
| Gateway lost, carrier up, no hang messages | Reset at 5 minutes, again at 15 minutes, reboot at 30 minutes. This is the silent failure the forum reports describe, but it also looks like a dead router, which is why it waits much longer |
| Anything unknown (no default route through `vmbr0`, a failed read) | Log only. Never act on it. The gateway clock restarts, so a later loss does not count the time before it |
| A carrier read takes over 10 seconds | Carrier is unknown, and that is not evidence of anything. Log it, put it in the report, kill the read, and write no flag. The bounded route read and ping still run: an answering gateway does nothing, and a lost one starts the normal clock. Only the gate can turn that into a reboot |
| An `ip link set` takes over 10 seconds | The command may be stuck in the driver (a reasoned mechanism, not observed). Each link command runs in the background with a 10 second limit; on an overrun the watchdog stops waiting without reaping, writes `/run/nic-watchdog/reset_wedged` naming that command, puts it in the report, and tries a reboot through the gate. See "A stuck link command" below. `KillMode=process` keeps a stuck child from holding the unit up. A host wedged badly enough might not finish `systemctl reboot` either |

Worst-case time to a reboot is about 4 minutes on the hang path and 30 on the gateway path. If a reset was made while the gateway answered, or a stuck command has just finished, the gate adds a wait of up to 5 minutes after that move.

**The final gateway check.** Every reboot passes through one gate in `try_reboot`, after the limits and
immediately before `last_reboot`, the marker and `systemctl reboot`. It is the only `systemctl reboot`
in the script. The gate runs a fresh `ping -c 3 -W 2 -I vmbr0 <gateway>` under the bounded wait and
decides:

| Fresh result | Decision |
|---|---|
| Exit 0, the gateway answers | **No reboot, on any path.** Logged |
| Exit 1, no reply | The reboot may go ahead |
| Any other status, the ping overruns, or no default route through `vmbr0` | The reboot may go ahead only with direct evidence the port is down: carrier reads 0, the interface is administratively down (a carrier read that ran and failed), or a link command is still stuck. Otherwise no reboot, logged |
| The check could not run at all (its output file cannot be written) | No reboot, even with evidence. The gateway must have been asked |

A carrier read that overruns is not evidence. A refused gate writes neither `last_reboot` nor the
marker. Log-only mode runs the gate too, so "would reboot" means the gate would have allowed it.

**The 5-minute refusal.** A port this watchdog moved while the gateway was answering can fail pings
because of that move: the command may have overrun after taking effect, or the port may still be coming
back. So `/run/nic-watchdog/answering_link_move` holds the time, written just before any reset made while
the gateway answers and whenever a stuck command has just finished. The gate refuses while that time is
under 5 minutes old, logs it, and then decides on a fresh ping. The gate pings first, so an answering
gateway still vetoes and the report still goes out. Ending an episode does not clear the file. A reset
made while the gateway was already lost does not write it, so a real outage keeps its timing.

**What the gate cannot tell apart.** It cannot separate a dead router from a silently failed card: no
reply, carrier up, no hang messages. The gateway path can still reboot once in that case, at 30 minutes,
and the marker stops it repeating. A port recovering from the watchdog's own reset also fails pings, and
that case is handled by the 5-minute refusal.

**A stuck link command.** Only a stuck `ip link set` writes `reset_wedged`. It holds the command's pid,
that process's start time, and whether it was the down or the up. At the start of each check:

- If that pid is alive with the same start time, so it is the same process and not a reused pid, the
  check makes no `ip link` call, tries a reboot through the gate, and stops. A limit or the gate can
  refuse, and the next check asks again.
- Otherwise the file is deleted and logged, and the 5-minute refusal starts, whichever command it was.
  If the stuck command was the down, or the link is administratively down, `ip link set <nic> up` runs
  under the bounded wait. Then the usual wait for carrier, whether or not that ran, and the normal check
  carries on.

A stuck `ip link` is never killed. A carrier or route read that overruns gets `kill -9`, so a read that
stays stuck does not leave one process per check.

It lives in `/run`, so a boot clears it. Neither a stale gap nor the end of an episode does.

If a check stops early for a stuck command and the gate's ping answered, it still sends any pending
report or the hourly ping. Overruns go in the report, and a report names the actual reason for a reboot:
it says `reboot (hang)` only if a hang was seen.

**The reboot limit.** The time of the last reboot is stored on disk and written before calling
`systemctl reboot`, after the report and the marker, so a write that fails does not use up the limit. Inside the 6 hours, the watchdog doesn't reboot: it logs that it wanted to and
keeps resetting every 30 minutes. If that file is unreadable or corrupt, treat it as "rebooted just
now", so a damaged file can't allow a loop.

**One gateway-only reboot per outage.** A dead router looks the same as a card that has silently
stopped passing traffic, so a gateway-only reboot sets a marker on disk that survives the reboot. While
it is set, the gateway path doesn't reboot: it logs that and keeps resetting every 30 minutes. The first
time the gateway answers, the marker clears. Without this, a router dead for two days would cause about
8 reboots. The known cost: a card that silently fails right after a reboot, before the gateway has
answered once, stays at resets and needs Shane. If the marker file can't be read, treat it as set. The
hang path ignores the marker and uses only the 6-hour limit.

**A reset** is `ip link set <nic> down`, 3 seconds, `ip link set <nic> up`, then a wait of up to 15
seconds for carrier. It only cycles the physical port. VMs keep running and `vmbr0` is left alone.

**Log-only mode.** If `/etc/the-greatest-home-server/nic-watchdog-log-only` exists, the watchdog tracks
state and logs each action it would take, but does not reset or reboot. It writes no `reset_wedged`,
`last_reboot`, marker, `answering_resets` or report. The resets it pretended to do and the clock it ran
are discarded on the first real check after it, so nothing in it can lead to a later real reboot. It
exists for the rollout rehearsal below, and `provision --verify` fails while the file is present, so it
can't be left on unnoticed.

**To pause it** for planned network work, run `systemctl stop nic-watchdog.timer`. A later `provision`
starts it again.

### Telling Shane

A new optional secret, `HC_NIC_WATCHDOG`, holds a healthchecks.io ping URL. Blank means no pings, the
same as the other checks.

- **Any run where the gateway answers** pings success at most once an hour, so the check also shows the
  watchdog is alive. Suggested settings: period 1 hour, grace 1 hour.
- **After a reset or reboot**, the watchdog writes a report to disk at the moment it acts, since the
  network is down then. It sends the report to the check's `/fail` endpoint on the first run where the
  gateway answers, even if hang messages are still arriving, and removes it only once sent. The report
  says what was seen and done, with times.

The URL is never logged. Every decision goes to the journal under the tag `nic-watchdog`, which is the
long-term record of how often the card still hangs now that TSO and GSO are off.

## Provision changes

- **Install.** New `host/sbin/nic-watchdog` and `host/systemd/nic-watchdog.{service,timer}`, installed
  by a new converge step with `put_host`, then `daemon-reload` and `enable --now`. The step's second run
  reports no changes.
- **Config file.** Provision renders `/etc/the-greatest-home-server/nic-watchdog.env`, mode 0600,
  holding `NIC` and `HC_NIC_WATCHDOG`.
- **The NIC name is read, not hardcoded.** Provision reads it from `vmbr0`'s `bridge-ports` and dies if
  that isn't exactly one interface. It is `eno1` today.
- **TSO/GSO.** Provision makes sure the `post-up` line is under the NIC's stanza, using `network_change`
  so it has the automatic revert. It must recognize the line already on the live host,
  `post-up /usr/sbin/ethtool -K eno1 tso off gso off`, as already done. It also applies the setting at
  runtime if it finds it off-target, without touching the network otherwise.
- **Packages.** `ethtool` joins the packages `converge_host_packages` ensures.
- **`--verify`** adds: the timer is enabled and active, TSO and GSO are off on the NIC, the `post-up`
  line is present, and the log-only file is absent.

`provision` itself still never reboots the host. Its guard against a stale kernel is unchanged.

## Tests

`deployment/home-server/test/nic_watchdog_test.sh`, in the existing shell style with stubs from
`helpers.sh`, picked up by `test/run.sh` and CI. Stubs must not call themselves by name. No test may
hit a real URL, and none may use a real healthchecks.io one. Paths and the clock need to be
overridable by the test so state and timing can be simulated.

Cases that must exist:

- A single hang message does nothing; two checks in a row reset.
- Hang persists: reset, reset, then reboot, in that order.
- Hang persists with the gateway answering: 2 resets, then log only, no reboot. Repeated separate
  hangs in 6 hours share that cap.
- Gateway lost with no hang: nothing before 5 minutes, resets at 5 and 15, reboot at 30.
- The gateway coming back at any point clears the episode.
- Carrier down with no episode: no reset, no reboot, and the gateway clock doesn't advance.
- Carrier that doesn't return after a reset: the episode continues and reaches a reboot.
- Hang messages with carrier down: treated as an episode.
- A report is sent while hang messages continue, as long as the gateway answers.
- `ping` exiting with anything but 1, no default route, and a failing `journalctl`: no action.
- A reboot inside 6 hours is refused and falls back to resets every 30 minutes; a reboot after 6 hours
  is allowed; a corrupt reboot-time file refuses.
- After a gateway-only reboot with the gateway never answering: no second reboot after 6 hours, resets
  every 30 minutes instead. Once the gateway answers, the marker clears and a later outage can reboot.
- With that marker set, persistent hang messages can still reboot once 6 hours have passed.
- An unreadable marker file blocks gateway-only reboots.
- The reboot time and the marker are on disk before `systemctl reboot` is called.
- Log-only mode: no `ip link` and no `systemctl reboot`, with the intended action logged.
- A report is kept when sending fails, sent later and removed once sent.
- A blank `HC_NIC_WATCHDOG` sends nothing, and the URL never appears in the output.
- Provision's offload step: leaves the live host's existing line alone, and adds the line once on a
  host without it.
- An answering final ping vetoes every route to a reboot, and each of those routes does reboot when that
  ping gets no reply.
- The gate's other outcomes: an unknown ping, a ping overrun and no default route each refuse without
  evidence and proceed with it.
- A slow carrier read: nothing on a healthy host; the gate decides in an episode; a dead host with a
  stuck read and no hang still pings, starts the clock and reaches a reboot.
- After a reset made while the gateway answered, failing pings do not reboot for 5 minutes, and do once
  that has passed with the gateway still lost. A reset made while the gateway was lost keeps the timing.
- Resets made while the gateway answers stay out of the outage count.
- A default route through another device is unknown, and a failed output redirect is unknown.
- An unknown result restarts the gateway clock.
- A failed report write leaves the 6-hour limit untouched.
- A stuck link command that finishes clears the flag and brings the link up, and nothing reboots
  afterwards. A reused pid is not trusted. A failed reboot makes no second `ip link set down`.
- A wall-clock jump during a healthy command is not an overrun.

## Rollout

Shane runs `provision`; agents are blocked from running it.

1. On the host, `touch /etc/the-greatest-home-server/nic-watchdog-log-only`. Then run `provision` from
   this branch with no `--ref`. Merge is not required first. That installs the host files from the local
   checkout and leaves the VMs tracking `main`. Plain `provision` also upgrades host packages, so it may
   finish by asking for a reboot.
2. **Rehearse detection** in log-only mode. Write a fake hang line to `/dev/kmsg`, which should reach
   `journalctl -k`, on two consecutive checks and read the journal to confirm the intended action. If
   the line does not reach `journalctl -k`, this rehearsal cannot run, and only the unit tests cover
   detection.
3. **Confirm the gateway answers ping from `vmbr0`.** Read `journalctl -t nic-watchdog --since '1 day ago'`:
   there must be no `gateway lost` lines from healthy minutes. A router that ignores ICMP would otherwise
   cause real resets, and a reboot within the hour. Only then remove the log-only file.
4. **Exercise one real reset**, with Shane's OK at the time, run detached because it can drop the SSH
   session. Confirm the link returns, `vmbr0` and all VMs are fine, TSO and GSO are still off, and the
   tunnels answer.
5. Create the healthchecks.io check, add `HC_NIC_WATCHDOG` to `secrets/home-server.env`, and re-run
   `provision`.
6. Check `ethtool -k <nic>` after the next host reboot. The `post-up` line has not yet been through
   one, and `eno1` has no `auto` line. If the setting did not survive, `--verify` will fail.

Do not ping healthchecks.io URLs as a test: a ping marks the check healthy.

**What this rollout can't show:** that a reset clears a real hang. Only the next real hang can. The
journal record and the report will show which path it took.

## Documentation

Update `docs/features/home-server.md`: the "What happens without anyone" table, "the host never
reboots itself" (the host now can, through this watchdog only), the secrets table, the Alerts table,
the `--verify` description, and a short section with the journal findings above. Mention pausing it.
No house addresses anywhere.

## Left to the builder

- The exact state files and their location under `/var/lib` and `/run`. Episode state should clear on
  boot; the reboot time and pending report must survive it.
- How the script is structured for testing, and how paths and the clock are overridden.
- How the report text is worded, as long as it contains no address or URL.

## Calls I made

These were not Shane's decisions, and any of them can be overruled.

- Requiring two checks in a row before a reset, because the old hangs could clear in seconds.
- The 5, 15 and 30 minute gateway thresholds, and resets every 30 minutes during the reboot limit.
- Carrier down meaning no action, unless an episode is already in progress.
- Hang messages alone can cause a reset, but a reboot also needs the gateway lost.
- The cap of 2 resets in 6 hours while the gateway answers.
- Sending reports and success pings whenever the gateway answers, even if hang messages continue.
- The `HC_NIC_WATCHDOG` check and its settings.
- Log-only mode, and the rehearsal steps that use it.
- Reading the NIC name from `vmbr0` rather than hardcoding `eno1`.
- The carrier-down, reset-cap and reporting rules above came from a reviewer's questions about gaps in
  the first draft.
