# Home server

## What it is

A Proxmox box in Shane's house that runs the three Python services in `data-sources/`: the Open
Library API (`docs/features/open-library-data-service.md`), the page fetcher
(`docs/features/page-fetcher-service.md`) and the WorldCat exact-lookup API
(`docs/features/worldcat-data-service.md`). Production Rails reaches them at
`ol-api.thegreatestbooks.org`, `page-fetcher.thegreatestbooks.org` and
`worldcat-api.thegreatestbooks.org`, through Cloudflare Tunnels, behind Cloudflare Access with a
service token. The design is in
`docs/superpowers/specs/2026-10-03-home-server-design.md`; its §12 overrides the earlier sections
where they disagree.

The host is an HP Elite Mini 800 G9: i7-12700T (12 cores, 20 threads), 62 GB usable RAM, Proxmox
9.2. Two ZFS pools: `rpool` (1 TB, system and `local-zfs`) and `rpool2` (4 TB). ZFS's cache (the
ARC) is capped at 8 GiB. The operator reaches it as the SSH alias `pve-mini`, defined in
`~/.ssh/config` on the operator's machine, and `PVE_HOST` in the secrets names only that alias, so
the SSH target is never committed in clear. It has a static LAN IPv4, reserved on the router; the
value lives in `PVE_LAN_IPV4`. It has no global IPv6.

The first target was a different machine (an i7-7700K), retired on 2026-10-03 before go-live.

## Layout

```
               Cloudflare edge (Access: service token "prod-rails")
                  │                                  │
           tunnel home-ol                    tunnel home-fetcher
                  │                                  │
           (and tunnels home-worldcat, to VM 130, and home-wikidata, to VM 150)
┌──────────────── Proxmox host (pve-mini) ──────────────────────────────┐
│  vmbr0  LAN, static IPv4              vmbr1  private 10.20.0.0/24, NAT │
│   │                                    │     no IPv6, private egress   │
│   │                                    │     dropped                   │
│  VM 110 "ol"                        VM 120 "fetcher"                  │
│   cloudflared ─► openlibrary:8080     cloudflared ─► page-fetcher:8081 │
│   build, train (timers)                                               │
│   /srv/ol-data (own disk)           VM 101 "musicbrainz" (by hand)    │
│  VM 130 "worldcat"                                                    │
│   cloudflared ─► worldcat:8082                                        │
│   /srv/wc-data (own disk)                                             │
│  VM 150 "wikidata"                                                    │
│   cloudflared ─► wikidata:8083                                        │
│   download + build (weekly timer), /srv/wd-data (own disk)            │
└────────────────────────────────────────────────────────────────────────┘
```

| VM | Role | vCPU | RAM | Disks | Network |
|---|---|---|---|---|---|
| 110 `ol` | Open Library API, dump builds, recommendations trainer | 12 | 24 GB, no ballooning | 32 GB OS disk on `local-zfs`; 300 GB data disk on `rpool2`, ext4, mounted at `/srv/ol-data` | `vmbr0`, LAN |
| 120 `fetcher` | Camoufox page fetcher | 4 | 4 GB, no ballooning | 40 GB OS disk on `local-zfs` | `vmbr1`, static `10.20.0.10`, gateway `10.20.0.1` |
| 130 `worldcat` | WorldCat exact-lookup API | 2 | 4 GB, no ballooning | 32 GB OS disk on `local-zfs`; 40 GB data disk on `rpool2`, ext4, mounted at `/srv/wc-data` | `vmbr0`, LAN |
| 150 `wikidata` | Wikidata exact-lookup API and its weekly dump build | 8 | 12 GB, no ballooning | 32 GB OS disk on `local-zfs`; 400 GB data disk on `rpool2`, ext4, label `wd-data`, mounted at `/srv/wd-data` | `vmbr0`, LAN |
| 140 `pgverify` | Nightly Postgres restore check and dev dump (below) | 4 | 8 GB, no ballooning | 32 GB OS disk on `local-zfs`; 400 GB data disk on `rpool2`, ext4, label `pgverify`, mounted at `/mnt/pgverify` | `vmbr1`, static `10.20.0.20`, gateway `10.20.0.1` |
| 101 `musicbrainz` | MusicBrainz, built by hand. **Stopped** until a second server arrives (Shane's decision, 2026-11-08), which is what makes room for VM 150's 12 GB | 8 | 16 GB | 1 TB on `rpool2` | LAN |

All guests with `onboot` come back by themselves after a host reboot. VM 101 is not managed by
`provision`, which never touches it. After a converge, and in `--verify`, provision asserts that every
guest running beforehand other than 110, 120, 130, 140 and 150 (VM 101 included) is still running. Its
Cloudflare tunnel runs inside the VM. VM 101's NIC has `firewall=1`, so once the host firewall is
on its traffic passes through pve-firewall's bridge conntrack chains and the `vmbr1` CT-zone rule,
even though no rule names it. Provision asserts only that it keeps running, not that its traffic is
unaffected.

`vmbr1` is a private NAT bridge. The fetcher sits on it, resolves DNS through 1.1.1.1 and 1.0.0.1, and the Proxmox firewall drops everything
the fetcher sends to a private destination (`/etc/pve/firewall/120.fw`, enforced on the host so
root inside the VM cannot change it). It also drops the house's own public IPv4: the router answers
on that address itself (NAT hairpin), so it would reach the router's admin pages on 80 and 443.
`120.fw` is rendered from `host/firewall/120.fw.tmpl` with that address in the `house_public`
ipset; the address is never committed. Provision reads it on the host from Cloudflare's
`/cdn-cgi/trace` on every run, and dies rather than write an empty set if it can't. If Google Fiber
changes the address, re-run `provision`; until then `--verify`'s egress probe fails, which is how
the drift shows up. The Open Library data lives on its own disk, so
`provision --rebuild ol` replaces the OS disk and keeps the data. The WorldCat data disk is kept
the same way.

The `worldcat` VM sits on the LAN bridge like `ol`. Its firewall (`130.fw`) accepts only SSH from
the LAN; the API publishes on loopback and leaves through `cloudflared`.

The `wikidata` VM (150) is the same shape, with `150.fw` and `/srv/wd-data`. Its API is the exact-lookup
service in `docs/features/wikidata-data-service.md`; `wikidata-refresh.timer` (04:00 daily and 15 minutes
after boot) runs `guest/wikidata-refresh.sh`, a copy of `ol-refresh.sh`'s promote-or-roll-back logic. The
build downloads the dump itself (about 157 GB, roughly 4.5 hours), so the script holds the build lock for the
whole run; a second timer firing during it defers, and so does a deploy (it takes the same lock, as on `ol`). It puts an 8 GB swap file on the data disk
(`/srv/wd-data/swapfile`, not in fstab) once a build is certain. Memory: API `mem_limit` 1 GB, build 10 GB,
`compose.wikidata.yml`. It writes `current-version`, runs `compose up -d wikidata` and polls `/version` on
8083; if the API does not serve the new date in time it writes the previous date back, and with no previous
version it removes `current-version` and stops the API. Only passing versions are kept (two, via
`versions prune`). Until the first build passes there is no `current-version`: `deploy.sh` builds the image,
starts only `cloudflared`, and `wikidata-heartbeat` stays silent.

## The Postgres restore check (`pgverify`, VM 140)

A backup counts only once it has been restored. Runbook, alerts and what to do about each:
`docs/features/postgres-server.md`. The VM stays off until `PGVERIFY_ENABLED=1` in `secrets/home-server.env`, at step 7
of the move: until then `provision` and `--verify` neither create nor touch it, and with it on provision refuses a
blank `HC_PGVERIFY`. `pg-restore-verify.timer` runs `guest/pg-restore-verify.sh`
at 12:00 UTC (after the 09:00 backup window; `Persistent=true`, so a VM that was down at noon runs it on
return). Spec: `docs/superpowers/specs/2026-11-06-postgres-server-design.md` §8 and §9. The VM runs nothing
else and has no heartbeat unit: `pg-restore-verified` is its alert, and a missed run alerts by silence.

What a run does, stopping at the first failure except the row-count alert:

1. Takes `/run/pgverify.lock` (a held lock logs and exits 0 without pinging; the next run reports), pings
   `start`, checks its settings and that the data disk is mounted.
2. Restores the latest backup with `pgbackrest restore --delta --archive-mode=off`, or from an empty data
   directory on Sundays, on a first run and after an interrupted restore (a marker file written before the
   restore and removed after it). Starts Postgres and waits for recovery to finish. It confirms it runs with
   `archive_mode=off`, `max_logical_replication_workers=0` and no `listen_addresses`.
3. Fails if the last replayed transaction is over 26 hours old or if there is none (`pg_last_xact_replay_timestamp()`
   is null on an idle backup; production writes constantly, so a heartbeat write is not added), if either
   database or any core table is missing or empty, or if `pg_amcheck` fails on the core tables and their indexes.
   `amcheck` is dropped again before any dump.
   It also reads the archive's newest WAL segment from `pgbackrest info` before restoring, and fails if replay
   did not reach it (compared on log and segment, from the last byte replayed): recovery that gives up early
   finishes on a new timeline and would otherwise pass every other check. The server's `restore_command` is
   `pgverify/archive-get.sh`, which passes pgBackRest's "not found" (exit 1) through as normal end of WAL and
   exits above 125 on any other `archive-get` failure, so a read error aborts recovery instead of ending it.
4. Counts the core tables exactly. A table over 10,000 rows in either night's counts that moved over 5% makes the
   run report failure at the end, naming the table, after the dumps; the names also ride on any other failure
   message. The baseline (`/mnt/pgverify/state/row-counts`) is replaced at the end of every run that gets that
   far, even after an alert, so one real change alerts once; a run that fails earlier leaves it.
5. Fails if free disk is under one night's dumps (the newest set on disk; 8 GB before there is one), and reports free
   disk in the journal and the success ping. Then `pg_dump -Fc --no-subscriptions` of `the_greatest` and `tgb` into `/mnt/pgverify/dumps/daily/`, each checked with
   `pg_restore --list`. The first successful run of each month copies each database's dump to `monthly/`. 14 daily and 12 monthly are kept,
   pruned by name (the UTC timestamp sorts as text). Dumps of a database dropped from the script's `DATABASES` list
   are no longer pruned; delete them by hand.
6. With `PGVERIFY_UPLOAD_ENABLED=1` only, uploads the dumps as `postgres_the_greatest_backup_<UTC ts>.sql.gz` and
   `postgres_tgb_backup_<UTC ts>.sql.gz` (the names `bin/refresh-dev-db.sh` reads) with a pinned `amazon/aws-cli`
   container, the key passed by environment, to the R2 dumps bucket (`PGVERIFY_DUMP_ENDPOINT`, passed as
   `AWS_ENDPOINT_URL`; region `auto`). That bucket locks every dump for 14 days and deletes it after 30
   (`docs/features/postgres-server.md`). It goes on with the restore check itself, at step 7 of the Postgres move;
   the bucket is separate from the old server's S3 bucket, which dev keeps reading until cutover. A failed upload
   pings `fail`, so it fails the night.
7. Stops Postgres (every run, failed or not, so the next `--delta` restore finds it stopped) and pings success.
   A run that ends any other way (a failed write, TERM) pings `fail` from an exit trap, so it is never silent.
   If this job holds its lock, `reboot-if-required` skips that night and tries again the next.

Safety by construction: the VM's pgBackRest key is read-only, and every restore passes `--archive-mode=off`, so
nothing restored can write to the production repo. The command line forces the settings that matter over the
restored `postgresql.auto.conf`. Postgres has no TCP listener and publishes no port; its config and `pg_hba.conf`
(`local all postgres peer`) are `deployment/home-server/pgverify/`, because neither lives in the data directory
and a backup does not carry them. The image is built from `deployment/postgres/Dockerfile`, so production and this
VM run one pinned image. Emptying the data directory is guarded: the root must be a deep absolute path, a mount
point, adopted only when pristine (or already carrying the sentinel the job writes), and the data directory
must not be a symlink.

`140.fw` (`host/firewall/140.fw.tmpl`, rendered like `120.fw`) is enforced on the host: inbound only SSH from
`10.20.0.1`, outbound anything except private destinations and the house's own public IPv4. `vmbr1` NATs out
through `vmbr0` with no destination filter, so HTTPS to R2, healthchecks.io, Docker Hub and the Debian mirrors
works; the fetcher beside it cannot reach the VM.

The VM's env (`secrets/home-server.env`, SOPS) takes: `PGVERIFY_ENABLED` (provision only; default off), `HC_PGVERIFY`, `HC_PGVERIFY_DEPLOY`, `PGVERIFY_REPO_BUCKET`,
`PGVERIFY_REPO_ENDPOINT`, `PGVERIFY_REPO_REGION`, `PGVERIFY_REPO_PATH`, `PGVERIFY_REPO_KEY` and
`PGVERIFY_REPO_KEY_SECRET` (the restore token, Object Read on the R2 backups bucket; the endpoint is
`<account id>.r2.cloudflarestorage.com` with no scheme, the region `auto`), `PGVERIFY_CIPHER_PASS`,
`PGVERIFY_DUMP_BUCKET`, `PGVERIFY_DUMP_KEY`, `PGVERIFY_DUMP_KEY_SECRET` (the upload token, Object Read & Write on
the R2 dumps bucket), `PGVERIFY_DUMP_REGION` (`auto`, passed to the `aws` container as `AWS_DEFAULT_REGION`),
`PGVERIFY_DUMP_ENDPOINT` (`https://<account id>.r2.cloudflarestorage.com`, passed as `AWS_ENDPOINT_URL`; the run
and provision both refuse an upload without it) and `PGVERIFY_UPLOAD_ENABLED` (default `0`). The region is
required when upload is on. Values may use letters, digits and
`. _ : / @ + = , -` only; provision refuses anything else, because the VM's scripts source the env file as shell.

## Running provision

The script is `deployment/home-server/provision`, run from the dev machine. It decrypts
`secrets/home-server.env` with SOPS:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt
deployment/home-server/provision [mode]
```

| Mode | What it does |
|---|---|
| (none) | Converges the host (DNS, packages, network, firewall, the ZFS ARC cap), creates any missing VM, installs each VM's env and units. A second run reports no changes. It does not create ZFS pools or Proxmox storage entries. |
| `--rebuild ol\|fetcher\|worldcat\|wikidata\|pgverify` | Replaces that VM's OS disk with a fresh cloud image. The data disk is kept (`ol`'s, `worldcat`'s, `wikidata`'s and `pgverify`'s). |
| `--enable-tunnels` | Starts `cloudflared` on all four VMs. It dies unless all four tunnel tokens are set. Run it only after Cloudflare Access is in place. The flag is stored on the host, so a later `--rebuild` keeps it. |
| `--disable-tunnels` | Removes the flag, pushes `TUNNELS_ENABLED=0` to all four VMs and forces a deploy, which stops and removes `cloudflared`. |
| `--verify` | Not read-only: it re-runs convergence (DNS, packages without the upgrade, network, firewall, VM creation), so it can change things, and then fails its idempotence check if anything changed. Check classes: host (including the NIC watchdog: the timer is enabled and active, TSO and GSO are off on the NIC, the `post-up` offload line is in `/etc/network/interfaces`, and the log-only file is absent), VMs, egress (with positive controls, from the VM and the container, including the house's public IPv4 on 80 and 443), idempotence, and pre-existing guests. |
| `--verify --external-from user@host` | Adds the exposure check: ports 22, 8006, 111 and 3128 on the host's public address, probed from that machine. |
| `--verify --recovery` | Adds a recovery check: SIGKILLs each service's main process and expects Docker to restart it, then **reboots the host** (`systemctl reboot`), waits up to about 10 minutes, and re-runs the host, VM, egress and pre-existing guest checks. Ask before running it. |
| `--ref <ref>` | Sets the repo ref the VMs track, stored on the host, then runs a converge. Default `main`. Letters, digits and `. _ / -` only; anything else dies before provision does anything. |

The keys in `secrets/home-server.env` (SOPS-encrypted). Each VM receives only its own values.

| Key | Needed | Meaning |
|---|---|---|
| `PVE_HOST` | every run | What provision SSHes to (the `pve-mini` alias) |
| `PVE_LAN_IPV4`, `PVE_LAN_GATEWAY4` | every run | The host's static LAN address and the router |
| `OL_TUNNEL_TOKEN`, `FETCHER_TUNNEL_TOKEN` | `--enable-tunnels` | The Cloudflare tunnel tokens for `ol` and `fetcher` |
| `WORLDCAT_TUNNEL_TOKEN` | `--enable-tunnels`; the worldcat VM | The Cloudflare tunnel token for `worldcat`. Optional until tunnels are on, then required: `--enable-tunnels` dies without all four |
| `WIKIDATA_TUNNEL_TOKEN` | `--enable-tunnels`; the wikidata VM | The Cloudflare tunnel token for `wikidata`, same rules |
| `HC_OL_HEARTBEAT`, `HC_OL_DEPLOY`, `HC_OL_REFRESH`, `HC_FETCHER_HEARTBEAT`, `HC_FETCHER_DEPLOY` | optional | healthchecks.io ping URLs; blank means no ping |
| `HC_WORLDCAT_HEARTBEAT`, `HC_WORLDCAT_DEPLOY` | optional; the worldcat VM | healthchecks.io ping URLs; blank means no ping |
| `HC_WIKIDATA_HEARTBEAT`, `HC_WIKIDATA_DEPLOY`, `HC_WIKIDATA_REFRESH` | optional; the wikidata VM | healthchecks.io ping URLs; blank means no ping |
| `PGVERIFY_ENABLED` | optional; default off | `1` makes `pgverify` a managed VM. Off, provision and `--verify` leave VM 140 alone. Set at step 7 of the Postgres move. |
| `HC_PGVERIFY`, `HC_PGVERIFY_DEPLOY`, `PGVERIFY_*` | the `pgverify` VM | See "The Postgres restore check". Only the `pgverify` VM receives them. `HC_PGVERIFY` may not be blank. |
| `HC_RECOMMENDER` | optional | healthchecks.io ping URL for `recommender-train`, `ol` only |
| `HC_NIC_WATCHDOG` | optional; the host only | healthchecks.io ping URL for `nic-watchdog`; blank means no ping. Written to a mode 0600 file on the host, never to a VM |
| `RECOMMENDATIONS_R2_ENDPOINT`, `RECOMMENDATIONS_R2_ACCESS_KEY`, `RECOMMENDATIONS_R2_SECRET_KEY`, `RECOMMENDATIONS_R2_BUCKET` | the trainer | The recommendations bucket (`docs/features/recommendations.md`, "Collaborative signal"): its S3 endpoint and a token scoped to it. All four or none; `ol` only. With none set, `recommender-train` logs a skip and does not ping. |
| `VM_STORAGE` | optional | OS disks and cloud-init drive. Default `local-lvm`; `local-zfs` here |
| `DATA_STORAGE` | optional | The `ol`, `worldcat`, `wikidata` and `pgverify` data disks. Default `VM_STORAGE`; `rpool2` here |
| `IMAGE_STORAGE` | optional | Imported cloud images. Default `local` |
| `PVE_LAN_DNS` | optional | The host's resolver. Default `PVE_LAN_GATEWAY4` |
| `ARC_MAX_BYTES` | optional | ZFS ARC cap. Default 8 GiB |

`SSH_PUBKEY_FILE` is an environment variable on the dev machine, not a secret. It defaults to
`~/.ssh/id_ed25519.pub`, and provision dies if the file is missing. The dev machine also needs
`sops`, `jq`, `envsubst`, the age key, and GNU coreutils (provision uses `base64 -w0` and
`sha256sum`; on macOS, `brew install coreutils` and put its `gnubin` directory first on `PATH`).

Three behaviors:

- **DNS:** provision sets the host's DNS to the router before it runs apt. A host moved from an old
  network kept its old resolver and could not update.
- **IPv4 is static:** ifupdown2 can't mix `inet dhcp` with `inet6 static` on one bridge (it treats
  the whole bridge as DHCP), so the host takes `PVE_LAN_IPV4` rather than a lease.
- **It never reboots the host:** if the loaded ZFS module or the running kernel is older than what
  is installed (after an upgrade in this run or an earlier one), it stops before creating or
  changing any VM, including before `--rebuild`, and says to reboot. Reboot, then run it again.
  This is true of `provision` itself. The one exception on the host is the NIC watchdog ("Hung
  network card", below), which can reboot it.

Network and firewall changes are applied under an armed automatic revert (`confirm-or-revert`) that
fires in about two minutes. The network revert restores `/etc/network/interfaces` and reloads it.
The firewall revert does not restore the old rules: it sets `enable: 0` in `cluster.fw` and stops
`pve-firewall`, which leaves the firewall disabled until the next provision run rewrites it.

## What happens without anyone

| Event | What recovers it |
|---|---|
| Power cut | BIOS "Restore on AC Power Loss" boots the host. VMs with `onboot` start in order (`ol`, `fetcher`, then `worldcat`). Docker starts at boot and every container is `restart: unless-stopped`. A build cut short runs again at the next 03:00 or 10 minutes after boot (`ol-refresh.timer`). |
| A container exits | `restart: unless-stopped` restarts it. |
| Bad deploy | `the-greatest-deploy.timer` (boot plus 2 minutes, then every 15 minutes) runs `deploy.sh` every 15 minutes. A failed build leaves the running container alone and the deployed SHA where it was, so the next run tries again; each failure pings `fail`. On `ol` the deploy builds the trainer image first and the API's second, each in its own command: the API and the dump build share one image tag, so a trainer build that fails stops the deploy before the API image changes, and a half-built pair can never reach the next dump promotion's `up -d api`. A trainer image that fails to build therefore holds back an API change until it is fixed; the `fail` ping names the image. |
| Bad dump | `ol-refresh.sh` promotes a version only when every gate passes. A failed build keeps the previous version serving and pings `fail`. If the new API does not report the new date in time, it writes the previous date back. |
| Stale model | `recommender-train.timer` (04:00, and 20 min after boot) runs `recommender-train.sh`. The trainer refuses an export older than three days or a model that fails its gate and exits non-zero, which pings `fail` with its last line; `model/latest` in the bucket and the model Rails serves stay as they were. A day under the build lock defers and logs `deferred: lock held` to the check without counting as a run, so about three days without a completed run (period 1 day, grace 2 days) alerts. |
| Hung network card | With the gateway lost, `nic-watchdog` (every minute) resets the card, and reboots the host only if resets do not help, at most once every 6 hours. See "Hung network card", below. |
| Box offline | The watchdog tries first, but only if the host is still running. If it is off or the watchdog cannot recover it, nothing does. `ol-heartbeat`, `fetcher-heartbeat` and `worldcat-heartbeat` stop pinging and healthchecks.io emails Shane. |

Security updates install on all three VMs through `unattended-upgrades`, and `reboot-if-required.timer`
reboots a VM at 05:30 only if a reboot is pending and no build lock is held. On the host,
`unattended-upgrades` installs Debian security updates only; Proxmox packages are upgraded only by
`provision`, so apt upgrades never reboot the host. The only thing that can reboot it unattended is `nic-watchdog`. The one-shot `build` service has no restart policy
(it runs with `run --rm`); a build cut short (crash, OOM, reboot) runs again at the next timer run. A build that fails its gates is not retried until a newer dump appears; delete its version directory to force a rebuild. `recommender-train` is the same shape as the build: a one-shot `run --rm` under a timer, no restart policy, run again at the next 04:00 or 20 minutes after boot; the trainer itself says `already trained; nothing to do` when there is nothing new.

## Alerts

healthchecks.io, free tier. A missed or failed ping emails Shane. The periods and graces below are
settings to create on healthchecks.io; the code only sends the pings. Deploy and refresh also send a
plain success ping with a message when they defer because a lock or build is held; train logs its
deferral to the check's `/log` endpoint instead, so a run that keeps deferring still alerts.

| Check | Pinged by | Period / grace |
|---|---|---|
| `ol-heartbeat` | timer every 5 min, only if `127.0.0.1:8080/version` answers | 5 min / 15 min |
| `fetcher-heartbeat` | timer every 5 min, only if `127.0.0.1:8081/health` answers | 5 min / 15 min |
| `worldcat-heartbeat` | timer every 5 min, only if `127.0.0.1:8082/version` answers | 5 min / 15 min |
| `wikidata-heartbeat` | timer every 5 min, only if `127.0.0.1:8083/version` answers | 5 min / 15 min |
| `ol-deploy`, `fetcher-deploy`, `worldcat-deploy`, `wikidata-deploy` | `deploy.sh`: `success` on a deploy or a no-op, `fail` on error | 15 min / 1 h |
| `ol-refresh` | `ol-refresh.sh`: `start`, then `success`, no-op or `fail` | 1 day / 6 h |
| `wikidata-refresh` | `wikidata-refresh.sh`: `start`, then `success`, no-op or `fail` | 1 day / 12 h (the build itself takes most of a day) |
| `recommender-train` | `recommender-train.sh`: `start`, then `success` with the trainer's last line or `fail` with it; a deferral goes to `/log` and does not reset the period | 1 day / 2 days |
| `nic-watchdog` | The host's `nic-watchdog`: `success` at most hourly, on a check where the gateway answers; `/fail` with a report on the first such check after a reset, a reboot, or hang messages | 1 hour / 1 hour |

`ol-heartbeat` is down until the first build finishes, because the API does not start without a
built version. `worldcat-heartbeat` is down until the artifact is loaded and `current-version` is
written ("Loading the WorldCat artifact (once)", below), for the same reason: the WorldCat API
refuses to boot without a version whose gates passed. `wikidata-heartbeat` is down until the first
build passes and `wikidata-refresh` writes `current-version`.

## Hung network card

**We should never restart a healthy server: a fresh gateway check runs immediately before every reboot, and an answering gateway always vetoes it.**

The host's network card (`eno1`) hung on 2026-11-03 and stayed hung for 3.4 days, until Shane
rebooted the host by hand. All three services sit behind that card. `nic-watchdog` exists so that a
hang costs minutes. The design is in
`docs/superpowers/specs/2026-11-06-home-server-nic-watchdog-design.md`.

What the host's journal showed on 2026-11-06 (one machine, across every boot listed):

- The 3.4-day outage was one event. All 148,172 messages carry the same `TDH b8`, `TDT e2` and
  `time_stamp`: the transmit ring froze and never moved. The PHY reported link up, so carrier state
  does not reveal a hang.
- The card has hung for years, and the kernel used to fix it. About 205 hang messages from 2023 to
  2025-07 (kernels 6.2.16-3 and 6.8.12-2) came with 53 `NETDEV WATCHDOG` and `Reset adapter
  unexpectedly` pairs. A sampled case: hang at 23:58:58, reset at 23:59:05, link up at 23:59:08.
- That reset no longer happens. None of the three hangs since had one: 2025-09-24 (6.8.12-15),
  2025-11-16 (6.14.11-2) and 2026-11-03 (7.0.14-24). The two 2025 hangs lasted about 90 seconds and
  ended with a power-off. The cause is unknown, and three episodes is a small sample.
- A quiet stretch proves little. The hang before the last one was almost a year earlier.

TSO and GSO are off on the physical NIC, through a `post-up` line under its stanza in
`/etc/network/interfaces` (`provision` keeps it there). That may make hangs rarer. Nothing shows it
stops them.

### What it does

`nic-watchdog.timer` runs `/usr/local/sbin/nic-watchdog` every minute, first at 3 minutes after boot.
It reads the NIC name and the optional ping URL from `/etc/the-greatest-home-server/nic-watchdog.env`
(mode 0600). Provision takes the NIC name from `vmbr0`'s `bridge-ports` and dies unless that is exactly
one interface. Each check looks at three things:

- **Hang:** `journalctl -k -b 0` since the later of the previous check and the last reset, for
  `<nic>: Detected Hardware Unit Hang`, under a 30 second limit. An overrun is a failed read.
- **Gateway:** `ping -c 3 -W 2 -I vmbr0` to the gateway in the default route, read on runs where carrier is up or unknown. The
  route must be through `vmbr0`. Only "no reply" (exit status 1) counts as lost. Any other ping status,
  no default route through `vmbr0`, or a failing `journalctl` is "unknown": it logs, does nothing else,
  and restarts the gateway clock, so a later loss does not count the time before it. With carrier down
  the port carries nothing, so the check does not ping. The gate still does.
- **Carrier:** `/sys/class/net/<nic>/carrier`. A carrier file that exists but cannot be read means the
  interface is administratively down, and counts as carrier down.

| Situation | Action |
|---|---|
| Gateway answers, no hang message | Healthy. Clears the episode, sends any pending report |
| Carrier down, no hang, no episode | Log only. A reset cannot fix a cable or a switch, and the gateway clock does not run |
| Hang messages on 2 checks in a row, gateway lost | Reset. Hang messages after that reset: reset once more. Hang messages after the second reset: try a reboot, which the gate refuses until 5 minutes after the last link command |
| Hang messages, gateway answering | **The port is not touched:** no `ip link` and no reboot. Logs each check and appends one line to the report once per episode, which is the evidence of how often the card still hangs |
| Gateway lost, carrier up, no hang | Reset at 5 minutes, again at 15, try a reboot at 30 |
| Carrier down during an episode (a hang was seen or a reset was done) | Carries on toward a reboot as if carrier were up. If the interface is administratively down, it also runs `ip link set <nic> up`, at most once in 30 minutes, because each one restarts the gate's wait |
| A carrier read takes longer than 10 seconds | Carrier is unknown, which is not evidence of anything. Logs and reports it, kills the read, and writes no flag. The bounded route read and ping still run: an answering gateway does nothing, and a lost one starts the normal clock. Only the gate can turn that into a reboot |
| A route read takes longer than 10 seconds | Logs and reports it, kills the read, and pings the gateway remembered from the last good read. With nothing remembered it is unknown |
| An `ip link set` takes longer than 10 seconds | Writes `/run/nic-watchdog/reset_wedged` naming the command and reports it. While that command is still running, every later check skips all link commands and only tries a reboot through the gate |

A reset is `ip link set <nic> down`, 3 seconds, `ip link set <nic> up`, then up to 15 seconds waiting
for carrier. It cycles the physical port only: the VMs keep running and `vmbr0` is untouched. It only
starts with the gateway lost. The reset count is written before the link goes down, so a reset that is
killed partway still advances the sequence. A check where the gateway answers, the gate's included, clears
that count. `last_reset` is written after the link is back, so hang messages from before the reset do
not count against it. A gap of more than 5 minutes between checks (a pause, a reboot, a clock jump)
ends the episode. Each reset logs and reports its outcome: carrier back after how many seconds, not
back after 15, `ip link` failed, or the carrier read did not finish.

**The final gateway check.** Every reboot passes through one gate, after the limits and immediately
before `last_reboot`, the marker and `systemctl reboot`, which appears once in the script. It runs a
fresh `ping -c 3 -W 2 -I vmbr0 <gateway>`, and if that gets no reply, a second one 20 seconds later,
because one lost round can be a blip:

| Fresh result | Decision |
|---|---|
| Exit 0 on either round, the gateway answers | **No reboot, on any path.** Logged. It clears the reset count, the clock and the marker, like any check where the gateway answers, and sends any report |
| Exit 1 on both rounds, no reply | The reboot may go ahead |
| Any other status on either round, the ping overruns, or no default route through `vmbr0` | The reboot may go ahead only with direct evidence the port is down: carrier reads 0, the interface is administratively down (a carrier read that ran and failed), or a link command is still stuck. Otherwise no reboot, logged |
| The check could not run at all (its output file cannot be written, or `ping` or `ip` exits 126 or 127) | No reboot, even with evidence. The gateway must have been asked |

A carrier read that overruns is not evidence. A refused gate writes neither `last_reboot` nor the
marker.

**The 5-minute refusal.** No reboot within 300 seconds of any link command, because that command can be
why pings fail: the port may still be coming back, or a command may have overrun after taking effect.
There is one marker, `/run/nic-watchdog/last_link_move`, written just before every real link command: the
down and the up of a reset, the `up` on an administratively down interface, and the `up` after a stuck
command finishes. It holds seconds since boot, read from `/proc/uptime`, so a wall-clock step cannot void
it, and `/run` clears on boot along with that clock. Ending an episode does not clear it. If it cannot be
written, the move is refused and does not count toward the reset sequence. The one exception is the up
in a reset whose down already ran: that up runs anyway, because the reset took the port down and the
down's stamp is seconds old. A stamp that is unreadable or in the future counts as just now and is
rewritten. The gate pings first, so an answering gateway still vetoes and the report still goes out.

**What the gate cannot tell apart.** It cannot separate a dead router from a silently failed card: no
reply, carrier up, no hang messages. The gateway path can still reboot once in that case, at 30 minutes,
and the marker stops it repeating. A local firewall or router change that later makes the gateway stop
answering ping looks exactly the same: resets, then one reboot at 30 minutes. So does a router that stops
answering ICMP but keeps forwarding traffic: it is the same signal, and the host is healthy when it happens. A port recovering from the
watchdog's own command also fails pings, and that case is what the 5-minute refusal is for. It is a time
limit: a port that took over 5 minutes to carry traffic again would look lost.

**A stuck link command.** `ip link set`, the carrier read, the route read and the ping run in the
background under a limit (10 seconds, 15 for the ping), timed on `/proc/uptime` so a clock step can
neither fake nor hide an overrun. A carrier read, a route read or a ping that overruns gets `kill -9`, so
a read that stays stuck does not leave one process per check, unless it is in uninterruptible sleep: a
process in that state survives `kill -9`, so a read stuck in the driver can still leave one process per
check.
If an `ip link set` overruns, the watchdog stops waiting and never kills it (the flag depends on it
staying alive), and writes `/run/nic-watchdog/reset_wedged` with the command's pid, its start time and
whether it was the down or the up. Only a stuck link command writes that file. At the start of each later
check:

- Same pid and same start time still running: no `ip link` call, a reboot attempt through the gate, and
  the check stops. It still sends any report and ping if the gate's ping answered.
- Otherwise, including a pid that has been reused: the marker is written, the file is deleted and
  logged, and `ip link set <nic> up` runs, whichever command it was: `up` on an up link changes nothing.
  This repairs the watchdog's own earlier move, so it happens even if the gateway answers. Then the usual
  wait for carrier, and the normal check carries on. If the marker cannot be written, nothing moves, the
  file stays, and the next check tries again.

A route read that overruns is logged and reported, and the check pings the gateway remembered in
`/run/nic-watchdog/gateway` from the last good read, because whatever holds the route read can be the
fault that needs recovering from. With nothing remembered it stays unknown.

A boot clears the file. A stale gap and the end of an episode do not. The unit has `KillMode=process`,
so a stuck leftover child does not hold it up. This mechanism is reasoned, not observed: no stuck link
command has been seen. A host wedged badly enough might not finish `systemctl reboot` either, and then
only Shane can recover it.

Worst case to a reboot, with the gateway lost throughout: about 8 minutes on the hang path, about 6 for a
stuck `down` or `up`, 30 on the gateway path, and 35 on the gateway path with the interface administratively
down, where the `up` retried at minute 30 restarts the wait. Each adds the gate's 20 seconds. A dead router
gets one reboot, then none until the gateway answers.

**The 6-hour limit.** The watchdog reboots at most once every 6 hours. The time is the first thing
written before `systemctl reboot`, to `/var/lib/nic-watchdog/last_reboot`. If that write fails, no reboot.
The gateway marker comes next: if it fails, no reboot either, and `last_reboot` stays. Then the report: a
failed report write is logged and does not stop the reboot. A reboot that was stopped or failed keeps
`last_reboot`, which can only mean fewer reboots. A reboot that is refused falls back to a reset, at most
once every 30 minutes. A `last_reboot` that is unreadable or in the future counts as "rebooted just now".

**One gateway reboot per outage.** A dead router looks like a card that silently stopped passing
traffic. A reboot caused only by a lost gateway writes `/var/lib/nic-watchdog/gateway_reboot_marker`,
which survives the reboot. While it exists, the gateway path does not reboot again; it keeps resetting
every 30 minutes. The first check where the gateway answers removes it. The hang path ignores the
marker and uses only the 6-hour limit. The cost: a card that silently fails right after a reboot,
before the gateway has answered once, stays at resets until Shane steps in.

**If the state directory cannot be written,** it does not send success pings and does not reboot. It
still logs, and resets still run.

**Log-only mode.** While `/etc/the-greatest-home-server/nic-watchdog-log-only` exists, it tracks state
and logs "would reset" or "would reboot" instead of acting. "Would reboot" means the gate would have
allowed it. It writes no `reset_wedged`, `last_reboot`, marker or report. Its episode lives in
`/run/nic-watchdog/log-only`, a directory no real check reads, so the resets it pretended to do and the
clock it ran cannot lead to a later real reboot. `provision --verify` fails while the file exists, so it cannot be left
on unnoticed.

### Reading the record and pausing it

Every decision goes to the journal under the tag `nic-watchdog`:

```bash
ssh pve-mini journalctl -t nic-watchdog --since '1 day ago'
```

This is the long-term record of how often the card still hangs with TSO and GSO off. The ping URL is
never logged.

To pause it for planned network work: `systemctl stop nic-watchdog.timer`. The next `provision`
starts it again.

State files:

| Where | Holds | Survives a reboot |
|---|---|---|
| `/run/nic-watchdog/` | The episode: last check time, hang streak, `hang_seen`, `hang_reported`, gateway-lost clock, reset count, last reset. Also `reset_wedged` (the stuck command's pid, start time, and down or up), `last_link_move` and `gateway` (the last good gateway), which no episode rule clears. `log-only/` holds log-only mode's copy of all of it | No |
| `/var/lib/nic-watchdog/` | `last_reboot`, `gateway_reboot_marker`, `last_ping`, and `report` (the unsent report) | Yes |

### Telling Shane

With `HC_NIC_WATCHDOG` set, a check where the gateway answers sends a success ping at most once an
hour, so the check also proves the watchdog is alive. When it resets or reboots, and once per episode
when hang messages arrive with the gateway answering, it writes a report to
`/var/lib/nic-watchdog/report` at that moment, because the network may be down then. The first check where
the gateway answers sends the report to the check's `/fail` endpoint, even if hang messages are still
arriving, and deletes the file only once the send succeeds. The report names what was seen and done,
with times, and holds no address or URL.

### Rollout

Shane runs every step; agents do not run `provision`.

1. On the host, `touch /etc/the-greatest-home-server/nic-watchdog-log-only`. Then run `provision` from
   this branch with no `--ref`. That installs the host files from the local checkout and leaves the
   VMs tracking `main`. Plain `provision` upgrades host packages, so it may finish by asking for a
   reboot.
2. Rehearse detection. On the host, write a fake hang line to `/dev/kmsg` (for example
   `echo '<4>e1000e 0000:00:1f.6 eno1: Detected Hardware Unit Hang:' > /dev/kmsg`), once on each of
   two consecutive checks, then read `journalctl -t nic-watchdog` and confirm `would reset`. First
   confirm the fake line shows in `journalctl -k -o cat -n 1`: it must show
   `eno1: Detected Hardware Unit Hang`. If it does not, this rehearsal cannot run, and only the unit
   tests cover detection.
3. Confirm the gateway answers ping from `vmbr0`. Read `journalctl -t nic-watchdog --since '1 day ago'`:
   there must be no `gateway lost` lines from healthy minutes. A router that ignores ICMP would
   otherwise cause real resets, and a reboot within the hour.
4. Confirm a silent loss is seen. Step 3 only checks the healthy direction. This one is done while the
   log-only file is still there, so nothing moves. Drop the gateway's echo replies at the host, which leaves
   the link up and only touches ICMP from the gateway, so SSH stays up:
   ```bash
   GW=$(ip -4 route show default | awk '{print $3}')
   iptables -I INPUT -i vmbr0 -p icmp --icmp-type echo-reply -s "$GW" -j DROP
   ping -c 3 -W 2 -I vmbr0 "$GW"; echo "ping exit $?"     # must print: ping exit 1
   ```
   Wait for the next check, at most 2 minutes, then read `journalctl -t nic-watchdog --since '5 minutes ago'`:
   it must show `gateway lost`. Undo it straight away, and confirm the gateway answers again:
   ```bash
   iptables -D INPUT -i vmbr0 -p icmp --icmp-type echo-reply -s "$GW" -j DROP
   ping -c 3 -W 2 -I vmbr0 "$GW"; echo "ping exit $?"     # must print: ping exit 0
   ```
   Pulling the cable between the switch and the router works too, if the host's own link stays up, and
   plugging it back in undoes it. Pulling the host's own cable does not test this: carrier drops, so the log
   says `carrier is down` and no ping runs. If ping exits anything but 1, the watchdog treats the loss as
   unknown and would never recover from it: stop and find out why before going on.
5. Only then remove `/etc/the-greatest-home-server/nic-watchdog-log-only`.
6. Do one real reset. Run it detached, because it can drop the SSH session:
   `systemd-run --collect /bin/sh -c 'ip link set eno1 down; sleep 3; ip link set eno1 up'`. These
   are the commands the script runs. Then confirm the link is back, `vmbr0` is up, every VM is
   running, TSO and GSO are still off (`ethtool -k eno1`), and the three tunnels answer. Time how long
   the port takes to carry traffic again after the `up`, for example with a ping loop from the host,
   because the 300 second refusal depends on it. Also confirm `ip link set eno1 up` on an up link is a
   no-op: no carrier drop in `journalctl -k` and no lost pings. The recovery after a stuck command runs it
   unconditionally.
7. Create the healthchecks.io check (period 1 hour, grace 1 hour), add `HC_NIC_WATCHDOG` to
   `secrets/home-server.env`, and re-run `provision`.
8. After the next host reboot, check `ethtool -k eno1`. The `post-up` line has not yet been through a
   reboot, and `eno1` has no `auto` line. If the setting did not survive, `--verify` fails.

This rollout cannot show that a reset clears a real hang. Step 6 shows only that cycling the link
does no harm. Only the next real hang can show the rest, and the journal and the report will say which
path it took. Do not ping the check's URL as a test: a ping marks the check healthy.

## Rebuild runbook

Whole machine:

1. Install Proxmox from the ISO. Give the host a static LAN IPv4 and reserve that address on the
   router. Create the ZFS pools and the Proxmox storage entries that `VM_STORAGE` and `DATA_STORAGE`
   name, since provision doesn't. *(manual)*
2. In the node's Shell, append the dev machine's public key to `/root/.ssh/authorized_keys`.
   *(manual, one command)*
3. On the dev machine, add the `pve-mini` alias to `~/.ssh/config` and make sure `PVE_HOST`,
   `PVE_LAN_IPV4`, `PVE_LAN_GATEWAY4` and the storage names in `secrets/home-server.env` match.
   Check that the public key file exists and that `sops`, `jq`, `envsubst` and GNU coreutils are
   installed. A reinstalled host has a new SSH host key: remove its old entry with
   `ssh-keygen -R <host>` (the alias's HostName), or provision's BatchMode SSH fails on the
   mismatch. *(manual)*
4. Run `deployment/home-server/provision`. If it stops and says to reboot, reboot the host (guests
   with `onboot` come back by themselves) and run it again. If the reinstall re-imported an old
   `rpool2`, it may still hold `vm-110-*` and `vm-130-*` zvols from the previous `ol` and `worldcat` VMs,
   which nothing references any more; `zfs list -r rpool2` shows them, and deleting them is a decision for Shane.
5. Put the tunnel tokens and ping URLs into the secrets, then run `provision --enable-tunnels` once
   Access is in place (below). `--enable-tunnels` needs all four tokens, `WORLDCAT_TUNNEL_TOKEN`
   and `WIKIDATA_TUNNEL_TOKEN` included. The Open Library build does not wait for this: its timer starts about
   10 minutes after the `ol` VM boots. On a fresh box it must download the dumps first, so allow
   longer than the 2.5 hours measured with the dumps already present.
6. Run `provision --verify`.
7. Load the WorldCat artifact again if the `wc-data` disk is gone (a reinstalled host loses it).
   The artifact is built on the dev machine and lives there as well; see "Loading the WorldCat
   artifact (once)".

One VM: `provision --rebuild ol|fetcher|worldcat|wikidata`. The data disk is kept, so a rebuilt `ol` keeps
its Open Library version and a rebuilt `worldcat` keeps its artifact and `current-version`.

Switch the tunnels off: run `provision --disable-tunnels`. It removes
`/etc/the-greatest-home-server/tunnels-enabled` on the host, pushes `TUNNELS_ENABLED=0` to all
three VMs and forces a deploy, which stops and removes `cloudflared` (compose leaves a running container
of a disabled profile alone, so `deploy.sh` removes it by name). Removing the flag by hand and
re-running plain `provision` does the same. `--enable-tunnels` turns them back on.

Going live: after the PR merges, run `provision --ref main` **before** the PR branch is deleted.
The VMs track the ref stored on the host (the branch, until then), and fetch it every 15 minutes;
once the branch is gone they can no longer fetch, and each deploy pings `fail` until the ref is
changed.

Things that look fine but are not:

- The build's `cpus: 10` in `compose.ol.yml` must stay at or below the `ol` VM's vCPUs in `vm_spec`
  (12). A test checks it.
- A pinned kernel (`proxmox-boot-tool kernel pin`) would make the running kernel permanently older
  than the newest installed one, so the reboot guard would stop every converge for good. Unpin, or
  change the guard, before pinning.

### Loading the WorldCat artifact (once)

The WorldCat API serves a frozen dump (Anna's Archive, 2025-09-04), so its artifact is built once on
the dev machine (`data-sources/README.md`, "Running the WorldCat API") and copied to the VM. The VM
never builds it. Do this after `provision` has created VM 130. Until then the API container does not
start and `worldcat-heartbeat` stays silent.

The VM takes its address from DHCP on the LAN. Get it from the host:
`ssh pve-mini qm guest cmd 130 network-get-interfaces`. The only SSH user on the VM is `debian`, and
`/srv/wc-data` is a root-owned ext4 root with no `versions/` directory, so rsync runs `sudo rsync` on
the far side, and `--mkpath` makes it create the missing parent directory (`--mkpath` needs
rsync >= 3.2.3 on both ends; otherwise run `ssh debian@<vm-address> sudo mkdir -p /srv/wc-data/versions`
first).

```bash
rsync -a --info=progress2 --mkpath --rsync-path="sudo rsync" /home/shane/wc-data/versions/2025-09-04/ \
    debian@<vm-address>:/srv/wc-data/versions/2025-09-04/
ssh debian@<vm-address> 'sudo chmod -R a+rX /srv/wc-data/versions/2025-09-04 && echo 2025-09-04 | sudo tee /srv/wc-data/current-version && sudo touch /var/lib/the-greatest/force-deploy && sudo systemctl start the-greatest-deploy.service'
curl -fsS https://worldcat-api.thegreatestbooks.org/version -H "CF-Access-Client-Id: ..." -H "CF-Access-Client-Secret: ..."
```

- **The `chmod` is required.** The container runs as uid 10001, not as the user that owns the rsynced
  files, so without `a+rX` it cannot read the artifact and the API fails to boot.
- **`current-version` pins the served version.** It holds `2025-09-04` and nothing else.
- **The marker is `/var/lib/the-greatest/force-deploy`.** Until `current-version` exists, a deploy
  logs that there is no WorldCat version yet, starts only `cloudflared`, then finishes anyway: it
  records the deployed SHA and removes the marker. It does not wait. Without the marker, the next
  deploy that starts the API happens only after a commit touches `data-sources/` or
  `deployment/home-server/`. The marker plus `systemctl start` make a deploy run now, with the
  version in place, and bring the API up.
- **The API serves `GET /version` and has no health route.** That is why the heartbeat and the
  `curl` above use `/version`. The `curl` carries the `prod-rails` service token.
- **There is no refresh timer and never will be.** The dump is frozen. A different version would mean
  a new build, a new directory under `versions/` and a new `current-version`.
## Re-sorting a served version

A version built before `pipeline/sort_order.py` has unsorted `identifiers`, `works` and
`redirects`. It serves correct answers, just slowly (`docs/features/open-library-data-service.md`,
"Sort order"). Re-sort it in place instead of rebuilding. On the `ol` VM, with the merged code
deployed (the deploy takes the build lock itself, so finish it first):

```bash
cd /opt/the-greatest/deployment/home-server/guest
v=$(cat /srv/ol-data/current-version)
# The whole sequence holds the build lock, as deploy, ol-refresh, the trainer
# and the 05:30 reboot do: otherwise a deploy can restart the API mid-swap, or
# the reboot can stop the VM between two renames. -n: if a build or deploy holds
# it, nothing runs; try again once it is done.
sudo flock -n /run/ol-build.lock bash -euc '
  # 1. Sorted copies into $1/_resorted/, checked. The API keeps serving.
  ./compose.sh run --rm --no-deps -T build python -m openlibrary.pipeline.resort stage \
    --root /data --dump-date "$1" --memory-limit 6GB --threads 4
  # 2. Swap. Each table is briefly absent, so the API is stopped for it.
  ./compose.sh stop api
  ./compose.sh run --rm --no-deps -T build python -m openlibrary.pipeline.resort install \
    --root /data --dump-date "$1"
  ./compose.sh up -d api
' resort "$v"
```

If `install` fails, the API stays stopped and the lock is released. A failed check moves
nothing, so `./compose.sh up -d api` serves the old files again. Anything else: see the rollback
below before starting the API.

`install` checks every staged file (row count against the served file, row-group order) before
moving any, and moves the served files to `$v/_presort/`. To roll back, stop the API and move them
back. Delete `_presort/` once the API is confirmed good. A second `install` refuses while it exists.

Stopping the API fails Rails' Open Library calls, and a failed source is never retried: the finder
decides without it. Stop whatever is calling it first (for the Goodreads replay, delete the
`Books::GoodreadsReplay::ResolveEditionJob` jobs and re-run `books:goodreads_replay:resolve`
afterwards; it queues only what is unfinished).

## Done once by hand

- BIOS: "Restore on AC Power Loss" set to Power On. Remove any installer USB.
- Cloudflare (Shane's own tool, not scheduled work):
  1. Four dashboard-managed tunnels (the fourth, `home-wikidata`, sends its hostname to
     `http://wikidata:8083`, an alias on the `wikidata` service in `compose.tunnel.yml`): `home-ol`, with `ol-api.thegreatestbooks.org` to
     `http://openlibrary:8080` (an alias on the `api` service), `home-fetcher`, with `page-fetcher.thegreatestbooks.org` to
     `http://page-fetcher:8081` (an alias on the `fetcher` service), and `home-worldcat`, with
     `worldcat-api.thegreatestbooks.org` to `http://worldcat:8082` (an alias on the `worldcat`
     service; all three aliases live in `compose.tunnel.yml`). Their tokens go in
     `secrets/home-server.env`.
  2. Three Access self-hosted applications on those hostnames, each with one Service Auth policy
     allowing the service token `prod-rails`. Make the token non-expiring or calendar its renewal:
     when it expires, all three services fail together.
  3. Exempt all three hostnames from Bot Fight Mode and any bot or WAF rule that would challenge a
     non-browser client from the production server's IP. A challenge reaches the client as a 403.
  4. Access goes on before a hostname is routed. Run `provision --enable-tunnels` only after that.
- healthchecks.io: the account and the nine checks above, with their ping URLs in
  `secrets/home-server.env`.

## If the LAN changes

If the router, subnet or its address changes, the host's static IPv4 and its DNS no longer match
the network. Use the console (keyboard and monitor) to fix `address` and `gateway` for `vmbr0` in
`/etc/network/interfaces`, then `ifreload -a`. Update `PVE_LAN_IPV4`, `PVE_LAN_GATEWAY4` and
`PVE_LAN_DNS` in `secrets/home-server.env`, update the `pve-mini` HostName in `~/.ssh/config`, and
reserve the address on the new router. Then re-run
`provision`: it resets the host's DNS and re-derives the firewall's `lan` set from the host's new
route. Provision refuses to continue while `PVE_LAN_IPV4` and the address in
`/etc/network/interfaces` disagree, but it does not notice a gateway-only change.

## Measured

On the Mini, 2026-10-03 and 04, dump 2026-09-30. The build started 23:02 UTC with the dumps already
downloaded and ended 01:36 UTC.

| Stage | Seconds |
|---|---:|
| works_staging | 108.8 |
| works | 110.8 |
| authors_staging | 17.6 |
| authors | 15.8 |
| editions_staging | 467.3 |
| editions | 598.8 |
| work_authors | 6.8 |
| redirects | 6.7 |
| year_evidence | 76.3 |
| popularity | 9.2 |

- **Gates:** all five passed. `evaluation_set` took 7821.5 s, prepared fresh.
- **Artifact:** 10.40 GB across 10 tables (9.7 GB on disk).
- **Memory:** peak RAM used in the VM was 19,557 MB of 24 GB; peak swap used was 34 MB.
- **API**, curl on the VM:

| Call | Time |
|---|---:|
| `/resolve` (Gatsby, title, author and year), three runs | 9.98, 9.81, 9.94 s |
| `GET /works/OL468431W` | 1.11 s |
| `/works/OL468431W/editions` | 4.51 s |
| `/identifiers/isbn13/9780743273565` | 0.64 s |

- **Fetcher smoke check from the home IP:**
  - Goodreads Gatsby: status 200, title "The Great Gatsby by F. Scott Fitzgerald | Goodreads",
    `selector_found` true, 7291 ms.
  - bookshop.org 9780743273565 with `td:has-text("EAN/UPC")`: status 200, title "The Great Gatsby a
    book by F. Scott Fitzgerald - Bookshop.org US", `selector_found` true, 5151 ms. The Cloudflare
    challenge cleared.
- **`provision --verify`:** 36 PASS, 0 FAIL. The SKIPs were "no OL version yet" (before the build)
  and "host has no global IPv6".
- **For comparison, the retired 7700K box** (8 vCPU, 16 GB VM): `year_evidence` took 248 s and peaked
  at 15.3 GB RAM plus 8.2 GB of swap.

### `/resolve` under load, 2026-10-06

A dev run of the Goodreads import pinned the VM: the API container at ~1,100% CPU, load average 15,
DuckDB spilling up to 14 GB into the container's `/tmp`, and about one `/resolve` a minute, many past
the Rails client's 60 s timeout. The cause was the pile-up, not the VM's size. Every abandoned query
kept running, and they all shared the one 6 GB DuckDB pool and every core. The service now runs one
`/resolve` at a time, answers 503 to the rest, and interrupts a resolve at 55 s
(`docs/features/open-library-data-service.md`, "Load limits on `/resolve`"). It runs with
`OL_API_THREADS=8`.

Measured afterwards, on the VM with the same 12 vCPUs, 24 GB and `OL_API_MEMORY_LIMIT=6GB`:

| Call | Time | Peak API memory | Peak CPU | `/tmp` spill |
|---|---:|---:|---:|---:|
| `/resolve` Gatsby (title, author, ISBN) | 12.9 s | 3.7 GiB | 799% | none |
| `/resolve` Hamlet (title, author) | 12.1 s | 3.8 GiB | 803% | none |
| `/resolve` Pride and Prejudice (title, author) | 13.1 s | 3.6 GiB | 793% | none |

- **Five Hamlet resolves at once:** one answered 200 in 18.1 s; the other four got 503 in 6-8 ms.
- **The deadline:** inside the container, a real Hamlet resolve given a 3 s deadline stopped at
  3.20 s, and the connection answered the next query.
- **No resize:** one resolve needs well under 6 GB, so the VM stays at 12 vCPUs and 24 GB. Eight
  threads instead of twelve cost about 3 s a resolve (9.8-10 s on 2026-10-04).

## Lessons

- **The first build was OOM-killed in `year_evidence` on a 16 GB VM:** DuckDB list aggregates hold
  per-thread state outside `memory_limit`. The build keeps `--threads 4` and a 16 GB swap file as
  backstops, at 24 GB too.
- **The first build of dump 2026-09-30 crashed its evaluation gate:** DuckDB's `jaccard` raised on
  an empty string, because it evaluates over the whole dictionary of a dictionary-encoded Parquet
  chunk, including values no row uses. Fixed in the matcher (commit `d97dc375`).
- **Shell test stubs must not call themselves:** A stub that called its own command by name
  (`command chmod`) fork-bombed the dev machine. Stubs now wrap real tools with `command -p`, and
  `stub()` has a depth guard.
- **ol's first env push arrived empty:** `vm_ssh` looks up ol's address with an ssh to the host,
  and that ssh read the stdin meant for the VM. `vm_ip` now runs with `</dev/null`, and
  `push_vm_env` re-hashes the installed file before it deploys.
- **The first host reboot re-ran cloud-init over both VMs:** Proxmox derives the instance-id from
  a hash of the cloud-init files, and the env lives in the user-data, so every env change made the
  next boot a "new instance". Each VM now has a meta-data snippet with a fixed instance-id
  (`the-greatest-<name>`), and the runcmd skips the clone when a checkout exists.
- **The fetcher's IPv6 came back after a reboot:** systemd-networkd brings eth0 up with
  link-local addressing and turns IPv6 back on, undoing the sysctl. `first-boot.sh` adds a netplan
  file with `link-local: []`, and `--verify` checks `disable_ipv6` on eth0 itself.
