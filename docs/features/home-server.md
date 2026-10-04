# Home server

## What it is

A Proxmox box in Shane's house that runs the two Python services in `data-sources/`: the Open
Library API (`docs/features/open-library-data-service.md`) and the page fetcher
(`docs/features/page-fetcher-service.md`). Production Rails reaches them at
`ol-api.thegreatestbooks.org` and `page-fetcher.thegreatestbooks.org`, through Cloudflare Tunnels,
behind Cloudflare Access with a service token. The design is in
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
┌──────────────── Proxmox host (pve-mini) ──────────────────────────────┐
│  vmbr0  LAN, static IPv4              vmbr1  private 10.20.0.0/24, NAT │
│   │                                    │     no IPv6, private egress   │
│   │                                    │     dropped                   │
│  VM 110 "ol"                        VM 120 "fetcher"                  │
│   cloudflared ─► openlibrary:8080     cloudflared ─► page-fetcher:8081 │
│   build (timer)                                                       │
│   /srv/ol-data (own disk)           VM 101 "musicbrainz" (by hand)    │
└────────────────────────────────────────────────────────────────────────┘
```

| VM | Role | vCPU | RAM | Disks | Network |
|---|---|---|---|---|---|
| 110 `ol` | Open Library API and dump builds | 12 | 24 GB, no ballooning | 32 GB OS disk on `local-zfs`; 300 GB data disk on `rpool2`, ext4, mounted at `/srv/ol-data` | `vmbr0`, LAN |
| 120 `fetcher` | Camoufox page fetcher | 4 | 4 GB, no ballooning | 40 GB OS disk on `local-zfs` | `vmbr1`, static `10.20.0.10`, gateway `10.20.0.1` |
| 101 `musicbrainz` | MusicBrainz, built by hand | 8 | 16 GB | 1 TB on `rpool2` | LAN |

All guests with `onboot` come back by themselves after a host reboot. VM 101 is not managed by
`provision`, which never touches it. After a converge, and in `--verify`, provision asserts that every
guest running beforehand other than 110 and 120 (VM 101 included) is still running. Its
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
`provision --rebuild ol` replaces the OS disk and keeps the data.

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
| `--rebuild ol\|fetcher` | Replaces that VM's OS disk with a fresh cloud image. The data disk is kept. |
| `--enable-tunnels` | Starts `cloudflared` on both VMs. It dies unless both tunnel tokens are set. Run it only after Cloudflare Access is in place. The flag is stored on the host, so a later `--rebuild` keeps it. |
| `--disable-tunnels` | Removes the flag, pushes `TUNNELS_ENABLED=0` to both VMs and forces a deploy, which stops and removes `cloudflared`. |
| `--verify` | Not read-only: it re-runs convergence (DNS, packages without the upgrade, network, firewall, VM creation), so it can change things, and then fails its idempotence check if anything changed. Check classes: host, VMs, egress (with positive controls, from the VM and the container, including the house's public IPv4 on 80 and 443), idempotence, and pre-existing guests. |
| `--verify --external-from user@host` | Adds the exposure check: ports 22, 8006, 111 and 3128 on the host's public address, probed from that machine. |
| `--verify --recovery` | Adds a recovery check: SIGKILLs each service's main process and expects Docker to restart it, then **reboots the host** (`systemctl reboot`), waits up to about 10 minutes, and re-runs the host, VM, egress and pre-existing guest checks. Ask before running it. |
| `--ref <ref>` | Sets the repo ref the VMs track, stored on the host, then runs a converge. Default `main`. Letters, digits and `. _ / -` only; anything else dies before provision does anything. |

The keys in `secrets/home-server.env` (SOPS-encrypted). Each VM receives only its own values.

| Key | Needed | Meaning |
|---|---|---|
| `PVE_HOST` | every run | What provision SSHes to (the `pve-mini` alias) |
| `PVE_LAN_IPV4`, `PVE_LAN_GATEWAY4` | every run | The host's static LAN address and the router |
| `OL_TUNNEL_TOKEN`, `FETCHER_TUNNEL_TOKEN` | `--enable-tunnels` | The two Cloudflare tunnel tokens |
| `HC_OL_HEARTBEAT`, `HC_OL_DEPLOY`, `HC_OL_REFRESH`, `HC_FETCHER_HEARTBEAT`, `HC_FETCHER_DEPLOY` | optional | healthchecks.io ping URLs; blank means no ping |
| `VM_STORAGE` | optional | OS disks and cloud-init drive. Default `local-lvm`; `local-zfs` here |
| `DATA_STORAGE` | optional | The `ol` data disk. Default `VM_STORAGE`; `rpool2` here |
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

Network and firewall changes are applied under an armed automatic revert (`confirm-or-revert`) that
fires in about two minutes. The network revert restores `/etc/network/interfaces` and reloads it.
The firewall revert does not restore the old rules: it sets `enable: 0` in `cluster.fw` and stops
`pve-firewall`, which leaves the firewall disabled until the next provision run rewrites it.

## What happens without anyone

| Event | What recovers it |
|---|---|
| Power cut | BIOS "Restore on AC Power Loss" boots the host. VMs with `onboot` start in order (`ol`, then `fetcher`). Docker starts at boot and every container is `restart: unless-stopped`. A build cut short runs again at the next 03:00 or 10 minutes after boot (`ol-refresh.timer`). |
| A container exits | `restart: unless-stopped` restarts it. |
| Bad deploy | `the-greatest-deploy.timer` (boot plus 2 minutes, then every 15 minutes) runs `deploy.sh` every 15 minutes. A failed build leaves the running container alone and the deployed SHA where it was, so the next run tries again; each failure pings `fail`. |
| Bad dump | `ol-refresh.sh` promotes a version only when every gate passes. A failed build keeps the previous version serving and pings `fail`. If the new API does not report the new date in time, it writes the previous date back. |
| Box offline | Nothing recovers it. `ol-heartbeat` and `fetcher-heartbeat` stop pinging and healthchecks.io emails Shane. |

Security updates install on both VMs through `unattended-upgrades`, and `reboot-if-required.timer`
reboots a VM at 05:30 only if a reboot is pending and no build lock is held. On the host,
`unattended-upgrades` installs Debian security updates only; Proxmox packages are upgraded only by
`provision`, and the host never reboots itself. The one-shot `build` service has no restart policy
(it runs with `run --rm`); a build cut short (crash, OOM, reboot) runs again at the next timer run. A build that fails its gates is not retried until a newer dump appears; delete its version directory to force a rebuild.

## Alerts

healthchecks.io, free tier. A missed or failed ping emails Shane. The periods and graces below are
settings to create on healthchecks.io; the code only sends the pings. Deploy and refresh also send a
plain success ping with a message when they defer because a lock or build is held.

| Check | Pinged by | Period / grace |
|---|---|---|
| `ol-heartbeat` | timer every 5 min, only if `127.0.0.1:8080/version` answers | 5 min / 15 min |
| `fetcher-heartbeat` | timer every 5 min, only if `127.0.0.1:8081/health` answers | 5 min / 15 min |
| `ol-deploy`, `fetcher-deploy` | `deploy.sh`: `success` on a deploy or a no-op, `fail` on error | 15 min / 1 h |
| `ol-refresh` | `ol-refresh.sh`: `start`, then `success`, no-op or `fail` | 1 day / 6 h |

`ol-heartbeat` is down until the first build finishes, because the API does not start without a
built version.

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
   `rpool2`, it may still hold `vm-110-*` zvols from the previous `ol` VM, which nothing references
   any more; `zfs list -r rpool2` shows them, and deleting them is a decision for Shane.
5. Put the tunnel tokens and ping URLs into the secrets, then run `provision --enable-tunnels` once
   Access is in place (below). The Open Library build does not wait for this: its timer starts about
   10 minutes after the `ol` VM boots. On a fresh box it must download the dumps first, so allow
   longer than the 2.5 hours measured with the dumps already present.
6. Run `provision --verify`.

One VM: `provision --rebuild ol|fetcher`. The data disk is kept.

Switch the tunnels off: run `provision --disable-tunnels`. It removes
`/etc/the-greatest-home-server/tunnels-enabled` on the host, pushes `TUNNELS_ENABLED=0` to both
VMs and forces a deploy, which stops and removes `cloudflared` (compose leaves a running container
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

## Done once by hand

- BIOS: "Restore on AC Power Loss" set to Power On. Remove any installer USB.
- Cloudflare (Shane's own tool, not scheduled work):
  1. Two dashboard-managed tunnels: `home-ol`, with `ol-api.thegreatestbooks.org` to
     `http://openlibrary:8080` (an alias on the `api` service), and `home-fetcher`, with `page-fetcher.thegreatestbooks.org` to
     `http://page-fetcher:8081` (an alias on the `fetcher` service; both aliases live in
     `compose.tunnel.yml`). Their tokens go in `secrets/home-server.env`.
  2. Two Access self-hosted applications on those hostnames, each with one Service Auth policy
     allowing the service token `prod-rails`. Make the token non-expiring or calendar its renewal:
     when it expires, both services fail together.
  3. Exempt both hostnames from Bot Fight Mode and any bot or WAF rule that would challenge a
     non-browser client from the production server's IP. A challenge reaches the client as a 403.
  4. Access goes on before a hostname is routed. Run `provision --enable-tunnels` only after that.
- healthchecks.io: the account and the five checks above, with their ping URLs in
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
