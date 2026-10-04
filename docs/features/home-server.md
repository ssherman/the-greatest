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
`~/.ssh/config` on the operator's machine; the repo never names the address in clear. Its LAN IPv4
is static (192.168.1.214, reserved on the router). It has no global IPv6.

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
│   cloudflared ─► api:8080            cloudflared ─► fetcher:8081      │
│   build (timer)                                                       │
│   /srv/ol-data (own disk)           VM 101 "musicbrainz" (by hand)    │
└────────────────────────────────────────────────────────────────────────┘
```

| VM | Role | vCPU | RAM | Disks | Network |
|---|---|---|---|---|---|
| 110 `ol` | Open Library API and dump builds | 12 | 24 GB, no ballooning | OS on `local-zfs`; 300 GB data disk on `rpool2`, ext4, mounted at `/srv/ol-data` | `vmbr0`, LAN |
| 120 `fetcher` | Camoufox page fetcher | 4 | 4 GB, no ballooning | OS on `local-zfs` | `vmbr1`, static `10.20.0.10`, gateway `10.20.0.1` |
| 101 `musicbrainz` | MusicBrainz, built by hand | 8 | 16 GB | 1 TB on `rpool2` | LAN |

All guests with `onboot` come back by themselves after a host reboot. VM 101 is not managed by
`provision`: it never touches it, and `provision` asserts it is still running after a converge. Its
Cloudflare tunnel runs inside the VM.

`vmbr1` is a private NAT bridge. The fetcher sits on it, and the Proxmox firewall drops everything
the fetcher sends to a private destination (`/etc/pve/firewall/120.fw`, enforced on the host so
root inside the VM cannot change it). The Open Library data lives on its own disk, so
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
| (none) | Converges the host (DNS, packages, network, firewall, ZFS), creates any missing VM, installs each VM's env and units. A second run reports no changes. |
| `--rebuild ol\|fetcher` | Replaces that VM's OS disk with a fresh cloud image. The data disk is kept. |
| `--enable-tunnels` | Starts `cloudflared` on both VMs. Run it only after Cloudflare Access is in place. The flag is stored on the host, so a later `--rebuild` keeps it. |
| `--verify [--external-from user@host] [--recovery]` | Re-runs convergence (minus package upgrades) and checks the result. `--external-from` probes the host's public address from outside the house; `--recovery` kills each service and checks it returns. |
| `--ref <git ref>` | Sets the ref the VMs track. It is stored on the host. Default `main`. |

The encrypted house values in `secrets/home-server.env`:

| Key | Meaning |
|---|---|
| `PVE_HOST` | What provision SSHes to (the `pve-mini` alias) |
| `PVE_LAN_IPV4`, `PVE_LAN_GATEWAY4` | The host's static LAN address and the router |
| `PVE_LAN_DNS` | Optional. The host's resolver. Defaults to `PVE_LAN_GATEWAY4` |
| `VM_STORAGE` | OS disks and cloud-init drive (`local-zfs`) |
| `DATA_STORAGE` | The `ol` data disk (`rpool2`) |
| `IMAGE_STORAGE` | Imported cloud images (`local`) |

The file also holds the tunnel tokens, the healthchecks.io ping URLs and each VM's secrets.

Three behaviors:

- **DNS:** provision sets the host's DNS to the router before it runs apt. A host moved from an old
  network kept its old resolver and could not update.
- **IPv4 is static:** ifupdown2 can't mix `inet dhcp` with `inet6 static` on one bridge (it treats
  the whole bridge as DHCP), so the host takes `PVE_LAN_IPV4` rather than a lease.
- **It never reboots the host:** after an upgrade that brings a new kernel or ZFS version, it stops
  before creating or changing any VM and says to reboot. Reboot, then run it again.

Network and firewall changes are applied under an armed automatic revert (`confirm-or-revert`), so
a change that cuts off SSH rolls back by itself in about two minutes.

## What happens without anyone

| Event | What recovers it |
|---|---|
| Power cut | BIOS "Restore on AC Power Loss" boots the host. VMs with `onboot` start in order (`ol`, then `fetcher`). Docker starts at boot and every container is `restart: unless-stopped`. A build cut short runs again at the next 03:00 or boot (`ol-refresh.timer`). |
| A container exits | `restart: unless-stopped` restarts it. |
| Bad deploy | `the-greatest-deploy.timer` runs `deploy.sh` every 15 minutes. A failed build leaves the running container alone and the deployed SHA where it was, so the next run tries again; each failure pings `fail`. |
| Bad dump | `ol-refresh.sh` promotes a version only when every gate passes. A failed build keeps the previous version serving and pings `fail`. If the new API does not report the new date in time, it writes the previous date back. |
| Box offline | Nothing recovers it. `ol-heartbeat` and `fetcher-heartbeat` stop pinging and healthchecks.io emails Shane. |

Security updates install on both VMs through `unattended-upgrades`. `reboot-if-required.timer`
reboots a VM at 05:30 only if a reboot is pending and no build lock is held. The host is upgraded
only by `provision`.

## Alerts

healthchecks.io, free tier. A missed or failed ping emails Shane.

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
   router. *(manual)*
2. In the node's Shell, append the dev machine's public key to `/root/.ssh/authorized_keys`.
   *(manual, one command)*
3. On the dev machine, add the `pve-mini` alias to `~/.ssh/config` and make sure `PVE_HOST`,
   `PVE_LAN_IPV4`, `PVE_LAN_GATEWAY4` and the storage names in `secrets/home-server.env` match.
   *(manual)*
4. Run `deployment/home-server/provision`. If it stops and says to reboot, reboot the host (guests
   with `onboot` come back by themselves) and run it again.
5. Run `provision --enable-tunnels`, once Access is in place (below). The Open Library data
   rebuilds itself in about 2.5 hours on the Mini.
6. Run `provision --verify`.

One VM: `provision --rebuild ol|fetcher`. The data disk is kept.

## Done once by hand

- BIOS: "Restore on AC Power Loss" set to Power On. Remove any installer USB.
- Cloudflare (Shane's own tool, not scheduled work):
  1. Two dashboard-managed tunnels: `home-ol`, with `ol-api.thegreatestbooks.org` to
     `http://api:8080`, and `home-fetcher`, with `page-fetcher.thegreatestbooks.org` to
     `http://fetcher:8081`. Their tokens go in `secrets/home-server.env`.
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
`PVE_LAN_DNS` in `secrets/home-server.env` and reserve the address on the new router. Then re-run
`provision`: it resets the host's DNS and re-derives the firewall's `lan` set from the host's new
route. Provision refuses to continue while `PVE_LAN_IPV4` and the address in
`/etc/network/interfaces` disagree.

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
