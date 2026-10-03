# Home server (Proxmox) for the data services: design

Date: 2026-10-03 · Branch: `worktree-home-server`

## Goal

Run the two Python services in `data-sources/` (the Open Library API,
`docs/features/open-library-data-service.md`, and the page fetcher,
`docs/features/page-fetcher-service.md`) in production on a Proxmox server in Shane's house,
reached by production Rails through Cloudflare Tunnels with Cloudflare Access in front.

Everything is code in this repo. After a disaster, the manual steps are installing Proxmox from
the ISO and adding one SSH key. After that, one script brings back the host, the VMs, the services
and the Open Library data with no further input.

Success:

- Production Rails calls both services through `https://ol-api.thegreatestbooks.org` and
  `https://page-fetcher.thegreatestbooks.org`, authenticated with an Access service token.
- The fetcher cannot reach any private address: the LAN, the router, the Proxmox host, the `ol`
  VM, or any device's public IPv6 address in the house. This holds against root inside the
  fetcher VM.
- A power cut, a container crash, a bad deploy and a bad dump each recover with no human
  involved. Anything that cannot recover sends Shane an email.
- A merge to `main` that touches `data-sources/` or `deployment/home-server/` is live on the box
  within 15 minutes, the same way merging deploys Rails today.
- The Open Library data refreshes itself when a new dump appears, goes live only if every build
  gate passes, and otherwise leaves the previous version serving.

Out of scope: MusicBrainz (VM 130's resources are reserved for it, nothing more), SSH from outside
the house, any change to the Linode production box beyond its ENV, and every Cloudflare setting
(see §7: a checklist for Shane's own tool, not tasks).

## 1. The machine, as found (2026-10-03)

Read over SSH as root; nothing was changed.

| | Found |
|---|---|
| CPU | Intel i7-7700K: 4 cores / 8 threads, AVX2 |
| RAM | 32 GB |
| Disk | Samsung 970 EVO Plus 2 TB NVMe. Installer default LVM: 8 GB swap, 96 GB root, **1.7 TB thin pool `local-lvm`**, empty |
| Proxmox | 9.2.2 on Debian 13 (trixie), kernel 7.0.2-6-pve, single node `pve` |
| Repos | `pve-enterprise` and `ceph-squid` enterprise repos with no subscription, so `apt update` fails on them |
| Network | `vmbr0` on `nic0`, **IPv6 only**: a static public address in the house's ISP-assigned `/64`, a link-local gateway, the router as DNS. The LAN also serves IPv4 (`192.168.1.0/24`, router `192.168.1.1`); the host has none |
| Listening | sshd 22, pveproxy 8006, spiceproxy 3128, rpcbind 111, all on the public IPv6 address. Whether the router blocks them inbound is untested |
| Board | ASUS Maximus IX Hero; installer USB still attached; boot order puts Proxmox first |

Three facts from this drive the design:

- **GitHub and GHCR have no IPv6 address** (`github.com` and `ghcr.io` resolve to IPv4 only).
  An IPv6-only guest cannot clone the repo, so the guests need IPv4.
- **Every device in the house has a public IPv6 address** in the same `/64`. An
  egress block that drops only RFC 1918 ranges would leave them reachable from the fetcher.
- **8 threads is the CPU budget for everything**, MusicBrainz included later. `/resolve` measured
  5–6 s on 27 cores; expect roughly 15–20 s here, inside the Rails client's 60 s
  `resolve_timeout`. §9 measures it.

## 2. Shape

```
                 Cloudflare edge (Access: service token "prod-rails")
                    │                                  │
             tunnel home-ol                    tunnel home-fetcher
                    │                                  │
 ┌──────────────── pve (Proxmox host) ──────────────────────────────────────┐
 │  vmbr0  LAN: IPv4 DHCP + IPv6                vmbr1  private, NAT'd IPv4   │
 │   │                                           │     no IPv6, egress to    │
 │   │                                           │     private ranges DROP   │
 │  VM 110 "ol"                               VM 120 "fetcher"              │
 │   cloudflared ─► api:8080                    cloudflared ─► fetcher:8081  │
 │   build (timer)                                                          │
 │   /srv/ol-data  (own disk)                                               │
 │                                                                          │
 │  VM 130 reserved for MusicBrainz (not created)                           │
 └──────────────────────────────────────────────────────────────────────────┘
```

Two VMs, not one, and not LXC:

- **One VM** would put the fetcher on the same network as the `ol` API, which has no
  authentication, and on the LAN. Its egress block would then live inside the blast radius it
  exists to contain. The monthly build would also take the fetcher's CPU for hours.
- **LXC** shares the host kernel, so a browser exploit that escapes the fetcher lands on the
  Proxmox host. Proxmox's own guidance is to run Docker in a VM.

Provisioning is a script plus cloud-init, not Terraform. On one host with two or three VMs, an
idempotent script needs no API token, no state file and no provider to keep current. This is the
same split as the Linode box, where Terraform plus cloud-init hands off to `docker compose up`.

## 3. Repo layout

```
deployment/home-server/
  provision                 # the one entry point; run from the dev machine
  lib/                      # host.sh, vm.sh, verify.sh, ... sourced by provision
  host/                     # files written onto the Proxmox host
                            #   (apt sources, interfaces, firewall, sdn, unattended-upgrades)
  cloud-init/               # user-data templates per VM
  guest/                    # files the VMs run: deploy.sh, ol-refresh.sh,
                            #   systemd units and timers, reboot guard
  compose.ol.yml            # override on data-sources/docker-compose.yml
  compose.fetcher.yml       # override on data-sources/docker-compose.yml
secrets/home-server.env     # SOPS (age), new rule in .sops.yaml, same recipient
docs/features/home-server.md
```

The guests run the scripts from their own clone of the repo, so a merged change to `guest/`
reaches them through the deploy timer (§6) without re-provisioning. Changes to `host/` or
`cloud-init/` take effect when `provision` is run again.

## 4. The host

`provision` reaches the host as `root` over SSH (`PVE_HOST`, read from `secrets/home-server.env`: this is a public repo, so the house's address is
never committed in the clear),
converges it, and reports what it changed. Running it twice in a row reports no changes the second
time.

**Packages.** Disable the `pve-enterprise` and `ceph-squid` enterprise sources and add
`pve-no-subscription` (deb822, trixie). Install and enable `unattended-upgrades` for Debian
security updates only. Proxmox packages are upgraded by `provision` (`apt full-upgrade`), never by
a timer, because a Proxmox upgrade occasionally needs its release notes read. **The host never
reboots itself**; `provision` prints when a newer kernel is waiting.

**Network.**

- `vmbr0` keeps its static IPv6 configuration and gains `inet dhcp`. Nothing depends on the IPv4
  address staying the same: SSH uses IPv6 and the tunnels dial out.
- `vmbr1`: a private bridge, `10.20.0.0/24`, host at `10.20.0.1`, no IPv6. The host NATs it out
  through `vmbr0`'s IPv4 address. The plan picks the mechanism (a Proxmox SDN Simple zone with SNAT,
  or a plain bridge plus a masquerade rule); the requirement is that the NAT and the filtering
  below survive a reboot and a `pve-firewall` restart.
- Applying network changes uses `ifreload -a`. `provision` checks that it can still reach the host
  afterwards, and if a change cuts it off, the plan has to say how that change gets reverted
  without console access.

**Fetcher egress block.** Enforced on the host, on the fetcher VM's network interface, so nothing
inside the VM can change it:

- Drop from the fetcher to `0.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10`, `127.0.0.0/8`,
  `169.254.0.0/16`, `172.16.0.0/12`, `192.168.0.0/16`, `224.0.0.0/4` and `240.0.0.0/4`.
  This covers the host's own `10.20.0.1`, the LAN, the router, and the `ol` VM.
- No IPv6 at all on `vmbr1`, which is how the house's public `/64` is kept out of reach.
- DNS goes to public resolvers (`1.1.1.1`, `1.0.0.1`), set by cloud-init. The router's resolver
  is a private address and is blocked like everything else.
- Replies to connections coming *into* the fetcher VM are allowed (conntrack). Without them,
  `provision` could not SSH to it through the host.

**Host firewall.** Turn on the Proxmox firewall at the datacenter and node level with an input
policy of DROP. Allow 22 and 8006 from the LAN only: `192.168.1.0/24` and the current IPv6 `/64`.
The plan must say what happens to that rule when the ISP changes the prefix, and must make sure a
mistaken rule cannot lock out SSH (Proxmox's `management` ipset exists for exactly this).
Disable `rpcbind` and its socket; nothing here uses NFS.

**Boot.** VM 110 `onboot=1, startup=order=1`; VM 120 `onboot=1, startup=order=2`.

**Done once by hand, recorded in the runbook:** set the BIOS's "Restore on AC Power Loss" to
*Power On*, and remove the installer USB stick.

**No VM backups.** Every VM rebuilds from git; secrets are in SOPS; the Open Library data rebuilds
from the public dump (§6).

## 5. The VMs

Both VMs use the Debian 13 generic cloud image, `cpu=host`, `qemu-guest-agent`, and virtio-scsi
disks on `local-lvm` with `discard=on` and `ssd=1`.

| | `ol` (110) | `fetcher` (120) | MusicBrainz (130, reserved) |
|---|---|---|---|
| vCPU | 8 | 4 | — |
| RAM | 16 GB, no ballooning | 4 GB, no ballooning | ~10 GB of the remaining host memory |
| OS disk `scsi0` | 32 GB | 40 GB | — |
| Data disk `scsi1` | 300 GB thin, ext4, `/srv/ol-data` | — | — |
| NIC | `vmbr0`, IPv4 DHCP (plus SLAAC IPv6) | `vmbr1`, static `10.20.0.10/24`, gw `10.20.0.1` | — |

**CPU.** 12 vCPUs on 8 threads is deliberate oversubscription: an idle fetcher should leave
`/resolve` every core. The build container is capped at 6 CPUs (§6) so the live API keeps
headroom while a build runs.

**Memory.** Host ~2 GB, `ol` 16, `fetcher` 4, leaving ~10 for MusicBrainz. Ballooning is off
because DuckDB sizes itself to the memory it sees at startup. Inside `ol`: `OL_API_MEMORY_LIMIT`
6 GB, build `--memory-limit 8GB`. These are starting points that §9 measures. A build given less
memory than before spills more, which NVMe absorbs.

**Rebuilding a VM** (`provision --rebuild ol|fetcher`): stop the VM, delete only `scsi0`, import a
fresh cloud image as `scsi0`, regenerate cloud-init, start. `scsi1` is never touched, so a rebuilt
`ol` comes back on the version it was serving. `provision` creates a VM only if its VMID is
absent, and never destroys one except through `--rebuild`.

## 6. Inside the VMs

### First boot (cloud-init)

Both VMs: install Docker CE from Docker's Debian repo (enabled at boot), `qemu-guest-agent` and
`unattended-upgrades`; write `/etc/the-greatest/home-server.env` (mode 0600) holding only that
VM's secrets; shallow-clone `https://github.com/ssherman/the-greatest` (`main`) to
`/opt/the-greatest`; install the systemd units from `deployment/home-server/guest/`; run the
first deploy. `ol` also formats `scsi1` only if it has no filesystem, mounts it at
`/srv/ol-data` by UUID, and starts the refresh timer.

### Compose

Each VM runs `data-sources/docker-compose.yml` with its override:
`docker compose -f data-sources/docker-compose.yml -f deployment/home-server/compose.<vm>.yml`.

The override adds:

- **`cloudflared`**, a pinned image tag, running `tunnel run` with `TUNNEL_TOKEN` from the env
  file, `restart: unless-stopped`. It reaches the service by its compose name (`api:8080`,
  `fetcher:8081`); the published loopback ports stay as they are and serve `verify` and the
  heartbeat. **It is not started until Shane confirms Access is in place** (§7, step 4):
  `provision --enable-tunnels` turns it on, and that flag is stored on the host so a later
  `--rebuild` keeps it.
- On `ol`: `OL_DATA_HOST=/srv/ol-data`, `OL_API_MEMORY_LIMIT=6GB`, and the `build` service's
  `cpus: 6`, `--memory-limit 8GB`.
- On `fetcher`: nothing beyond `cloudflared`. `FETCHER_TZ` keeps its `America/Chicago` default,
  which is the dev machine's zone, and the dev machine is on the same network as the server.

Every container is `restart: unless-stopped`; Docker starts at boot, so the services come back
after a reboot without any unit of our own.

### Deploy timer, both VMs, every 15 minutes

`guest/deploy.sh`:

1. `git fetch origin main`.
2. If nothing under `data-sources/` or `deployment/home-server/` changed between the deployed
   commit (`/var/lib/the-greatest/deployed-sha`) and `origin/main`, stop.
3. Check out `origin/main`, `docker compose build` that VM's service, then `docker compose up -d`.
   Re-install changed systemd units.
4. Only after `up -d` succeeds, write the new SHA to `deployed-sha`. A failed build leaves the
   running container alone and the SHA where it was, so the next run tries again. Each failure
   pings `fail` (§8).

On `ol`, the deploy never starts `api` if no `current-version` exists (see below), and never
deploys while a build is running.

### Open Library refresh timer, `ol` only, daily 03:00 and at boot

Daily rather than monthly, so a missed run or a reboot can never skip a dump.
`guest/ol-refresh.sh`:

1. Take `/run/ol-build.lock`, or exit if a build already holds it.
2. Ask Open Library for the latest dump date. Exit with a `success` ping if that date is already
   built, whether its gates passed or failed. The build's own `manifest.json` records
   `gates_passed`, so it is the record; there is no separate state file.
3. Run the existing `build` service for that date. If `data-sources/` has no CLI for "latest
   dump date" and "only this date", the plan adds one there (in `openlibrary.pipeline`) rather
   than reimplementing discovery in shell.
4. **Gates pass:** write the date to `/srv/ol-data/current-version` (a plain file, since the API
   refuses symlinks), `OL_DATA_VERSION=<date> docker compose up -d api`, then poll `/version`
   until it reports that date. If it does not within the timeout, write the previous date back,
   bring the API up on it, and ping `fail`.
5. **Gates fail:** the manifest already says `gates_passed: false`; keep serving and ping `fail`
   with the gate names. The date is retried only if someone deletes its version directory.
6. Keep the newest two passing versions. Delete their dumps and `incoming` files and any
   `_staging` left by a date that has since been superseded. A failed date's `_staging` is kept
   until a newer date builds, because it is what explains the failure.

A fresh VM with an empty data disk takes this same path: nothing is built, so the first build is
an ordinary run, about 2–3 hours on this box before the API serves. Until then `api` is not
started, so it never sits in a restart loop against a missing version.

### Reboots for updates

`unattended-upgrades` installs security updates on both VMs with its own automatic reboot turned
off. A `reboot-if-required` timer at 05:30 reboots when `/run/reboot-required` exists **and** no
build lock is held; otherwise it waits for the next night. A build cut short by a power cut runs
again at the next 03:00 or boot.

## 7. Rails and Cloudflare

### Rails

- `Books::OpenLibrary::Configuration` and `PageFetcher::Configuration` each read
  `CLOUDFLARE_ACCESS_CLIENT_ID` and `CLOUDFLARE_ACCESS_CLIENT_SECRET` (one pair, shared). When both
  are set, the Faraday connection sends `CF-Access-Client-Id` and `CF-Access-Client-Secret` on
  every request. Neither set: no headers, so development is unchanged. Exactly one set:
  `ConfigurationError` at construction. The secret is never logged or included in an
  exception message.
- Production ENV in `secrets/.env.production`:
  `OPEN_LIBRARY_SERVICE_URL=https://ol-api.thegreatestbooks.org`,
  `PAGE_FETCHER_SERVICE_URL=https://page-fetcher.thegreatestbooks.org`, and the Access pair.
  Names added to `deployment/ENV.md` and `web-app/.env.example`.
- Timeouts unchanged. Cloudflare's 100 s proxied-response limit is above both
  `resolve_timeout` (60 s) and the fetcher's longest read (60 s + 10 s).
- A missing or wrong token gets Access's redirect or 403. Both clients already classify these as
  failures that count toward the circuit breaker, so a bad token shows up as an open circuit,
  not as data.
- Tests: for each configuration, headers present, absent and half-set (raises), with requests
  stubbed. `bin/rails test` and `standardrb`. There is no new page, so no Playwright test.

### Cloudflare: a checklist for Shane, not plan tasks

1. Two dashboard-managed tunnels: `home-ol`, with `ol-api.thegreatestbooks.org` →
   `http://api:8080`, and `home-fetcher`, with `page-fetcher.thegreatestbooks.org` →
   `http://fetcher:8081`. Their tokens go in `secrets/home-server.env`.
2. Two Access self-hosted applications on those hostnames, each with a single Service Auth policy
   allowing the service token `prod-rails`. Make it non-expiring or calendar its renewal: when it
   expires, both services fail together.
3. Exempt both hostnames from Bot Fight Mode and any bot or WAF rule that would challenge a
   non-browser client from a Linode IP. A challenge reaches the client as a 403.
4. Access goes on before a hostname is routed. Shane runs `provision --enable-tunnels` only
   after that.

Both hostnames are one level deep on purpose: Cloudflare's Universal SSL certificate does not
cover `a.b.thegreatestbooks.org`.

## 8. Alerting

healthchecks.io (free tier). Checks, each with its ping URL in `secrets/home-server.env`:

| Check | Pinged by | Period / grace |
|---|---|---|
| `ol-heartbeat` | timer every 5 min, only if `127.0.0.1:8080/version` answers | 5 min / 15 min |
| `fetcher-heartbeat` | timer every 5 min, only if `127.0.0.1:8081/health` answers | 5 min / 15 min |
| `ol-deploy`, `fetcher-deploy` | `deploy.sh`: `success` on a deploy or a no-op, `fail` on error | 15 min / 1 h |
| `ol-refresh` | `ol-refresh.sh`: `start`, then `success` / no-op / `fail` | 1 day / 6 h |

A missed or failed ping emails Shane. Until the first build finishes, `ol-heartbeat` is expected
to be down; the runbook says so. Creating the account and the checks is Shane's one-time step;
the plan may create the checks through the healthchecks.io API if he supplies an API key.

## 9. Verification

`provision --verify` runs everything that can be scripted; the rest is listed in the runbook.

- **Idempotent:** a second `provision` reports no changes.
- **Egress block:** from inside the fetcher VM, connections to `192.168.1.1`, `10.20.0.1:8006`,
  the `ol` VM's address and a house IPv6 address all fail; a public HTTPS site loads. The same
  probe is run from inside the fetcher **container**.
- **Exposure:** from outside the house (an external IPv6 port check), 22, 8006, 111 and 3128 on
  the host's public address are closed.
- **Recovery:** `docker kill` of each service, and a full host reboot, both end with everything
  serving and no human involved.
- **Measured** and recorded in `docs/features/home-server.md`: `/resolve` wall clock on the
  labelled cases and the Gatsby example; the first build's total time and peak memory; the
  fetcher smoke check from its doc, run on the VM. If `/resolve` comes near 60 s or the build
  runs out of memory, the §5 sizes change before go-live.
- **End to end:** after the Access checklist, one `Client#version` / `PageFetcher::Client#fetch`
  from a production Rails console through the tunnels.

## 10. Rebuild runbook (goes into `docs/features/home-server.md`)

Whole machine:

1. Install Proxmox from the ISO onto the NVMe. *(manual)*
2. In the node's Shell: append the dev machine's public key to `/root/.ssh/authorized_keys`.
   *(manual, one command)*
3. From the dev machine: `deployment/home-server/provision`, then
   `provision --enable-tunnels`. Host, VMs and services come back; the Open Library data
   rebuilds itself in about 2–3 hours.

One VM: `provision --rebuild ol|fetcher`. The data disk is kept.

The dev machine reaches the host over IPv6, so WSL needs `networkingMode=mirrored` in
`.wslconfig`.

## 11. Docs

- New `docs/features/home-server.md`: layout, the runbook, the alert checks, the measurements.
- `docs/features/open-library-data-service.md` and `docs/features/page-fetcher-service.md`:
  rewrite "Where it runs" and the promotion section (promotion is now automatic).
- `deployment/ENV.md`, `web-app/.env.example`: the new ENV names.

## 12. Amendment, 2026-10-03: the target moves to the HP Elite Mini

Decided by Shane before go-live, while the first box's first build was running. Nothing in
production depended on the first box. The original target (§1, i7-7700K) is retired from this
project once the Mini verifies.

**The Mini, as found:** HP Elite Mini 800 G9, i7-12700T (12 cores / 20 threads), 62 GB usable
RAM, Proxmox 9.0.10. Two NVMe drives, both ZFS: `rpool` (1 TB; system plus the empty
`local-zfs`) and `rpool2` (4 TB). Static IPv4 on `vmbr0`, which is VLAN-aware; **no global IPv6**.
It already runs VM 101 `musicbrainz` (8 vCPU, 16 GB, a 1 TB disk on `rpool2`, `onboot`), which
production's music data importer calls only when a list is added. It was set up by hand and is
productized later, separately.

**What changes:**

- **Storage is configuration, not code.** `VM_STORAGE` holds OS disks and the cloud-init drive,
  `DATA_STORAGE` holds the `ol` data disk, and `IMAGE_STORAGE` holds imported cloud images. They
  live in `secrets/home-server.env` beside the other house values. On the Mini that's `local-zfs`,
  `rpool2` and `local`.
- **ZFS's cache (the ARC) is capped at 8 GiB** on a host that runs ZFS, persistently, so it can't
  crowd out the VMs.
- **IPv6 is optional.** With no global IPv6 on `vmbr0`, the `lan` and `management` sets are IPv4
  only. The IPv6 egress probe SKIPs with its reason. The exposure check (`--external-from`) tests
  the house's public IPv4 instead; behind the router's NAT, with no port forwards, all ports must
  be closed.
- **Sizes:** `ol` gets 12 vCPU and 24 GB. The build container's CPU cap rises to 10. The fetcher
  is unchanged. MusicBrainz keeps its 16 GB, which leaves the host about 14 GB including the ARC.
  The build keeps `--threads 4` and the swap file as backstops until a measured build says
  otherwise.
- **Guests provision didn't create are never touched.** Verify asserts that every VM running
  before it started is still running afterwards.
- **Access:** the Mini is the SSH alias `pve-mini`, and `PVE_HOST` names it.
