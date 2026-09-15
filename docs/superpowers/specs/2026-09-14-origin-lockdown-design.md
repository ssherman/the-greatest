# Origin lockdown — design

**Date:** 2026-09-14
**Status:** approved design, awaiting implementation plan
**Scope:** the production origin `45.33.28.21` (nginx in Docker, `deployment/`), plus one
setting in the private `the-greatest-cloudflare` repo

## 1. What this is

Today the origin answers anyone who knows its IP. `curl --resolve thegreatestmusic.org:443:45.33.28.21 https://thegreatestmusic.org/` returns the full site with no `cf-ray`, and
`POST /contact_messages` reaches Rails. Every Cloudflare protection — WAF, Super Bot Fight
Mode, the load-bearing challenge rules, the edge rate limits — is optional for anyone who
finds the IP, and origin IPs are trivially found (Censys and Shodan index TLS certificates by
hostname). Every IP-keyed rate limit in the app is forgeable the same way, because
`CF-Connecting-IP` is trusted without checking who sent it.

After this design ships, nginx serves a page only when **all** of the following hold:

1. the TCP connection comes from a Cloudflare IP range;
2. the request names one of our hostnames (SNI on 443, `Host` on 80);
3. on 443, Cloudflare presented its origin-pull client certificate.

Anything else gets a closed connection or a rejected TLS handshake — no page, no redirect,
no certificate shown to an IP scanner. As a side effect nginx's `$remote_addr`, the
bot-blocker's per-IP limits, and Rails' `request.remote_ip` become the visitor's address
instead of the Cloudflare edge's.

Everything lives in `docker-compose.prod.yml`, the nginx image, and the repo — nothing
hosting-provider-specific, nothing new running at request time.

### Non-goals

- **SSH stays as it is** (port 22 open, key-only, root disabled, fail2ban). GitHub Actions
  deploys over SSH from `ubuntu-latest`; GitHub's `actions` list is 6,980 ranges and cannot
  be allowlisted anywhere sensible. Shane's call, 2026-09-14: "password auth is turned off,
  I think that is still pretty secure."
- **No Linode Cloud Firewall.** It would be the cleanest network-layer lock (off-host, immune
  to Docker's iptables rewrite, ~30 lines of terraform), but it ties the setup to Linode.
  Shane wants the posture to move to any host as `docker compose up`.
- **No Cloudflare Tunnel.** It would remove every inbound port and every IP list, but it puts
  `cloudflared` in the request path of a revenue site. Cloudflare's status feed shows a
  tunnel-specific 11-hour "intermittent" incident on 2026-09-11/12 that did not touch ordinary
  proxied origins. Shane runs a tunnel for the MusicBrainz mirror in his office and wants it to
  stay there.
- **No custom (zone-level) AOP certificate.** It is the only portable mechanism that proves
  "from *my* zone" rather than "from Cloudflare", but it means generating and rotating a CA
  and a leaf key. Shane: "I like how Cloudflare just handles the cert keys." §9 records what
  this leaves open and the keyless way to close it later.
- **No host-level nftables/ufw work.** nginx is Docker-published, Docker bypasses ufw, and
  Docker 29 is mid-migration from iptables to an nftables backend that changes the
  `DOCKER-USER` hook again. The existing `ufw allow 80/443` lines in cloud-init stay: they
  are inert for published ports, but deleting them would read as a lockdown that is not one.
- **No Rails change.** `config.hosts` in production is still worth setting one day; nginx
  is the enforcement point for host validation in this design.
- **The legacy books origin (`104.200.17.36`) is untouched.** Zone-wide AOP on
  `thegreatestbooks.org` will present a client certificate to it too; its nginx does not
  verify, so nothing changes there.

## 2. Decisions

| # | Decision |
|---|---|
| 1 | **Cloudflare-only connections are enforced with a `geo` map on `$realip_remote_addr`, not `allow`/`deny`.** The realip module rewrites `$remote_addr` to the visitor's IP before the access module runs, so `allow <cloudflare ranges>; deny all;` would reject every legitimate visitor. `$realip_remote_addr` keeps the connection's real peer. |
| 2 | **Non-Cloudflare connections get `return 444`** (nginx closes the connection with no response) on both 80 and 443. `127.0.0.1/32` and `::1/128` are in the map so the container healthcheck keeps working. |
| 3 | **Unknown SNI on 443 gets `ssl_reject_handshake on`** in a `default_server`. No certificate is sent, so IP-scanning certificate indexers stop learning the hostnames, and a no-SNI `curl https://45.33.28.21` fails at the handshake. Unknown `Host` on 80 gets a `default_server` returning 444. |
| 4 | **The port-80 proxy branch is deleted.** Under Full/Strict SSL Cloudflare never sends an HTTPS visitor to origin port 80, so `if ($http_x_forwarded_proto != "https") … else proxy_pass` has no legitimate caller — it is the branch that lets an attacker's *Flexible*-mode zone reach Rails today (§3). Port 80 becomes redirect-only for our hostnames. |
| 5 | **Authenticated Origin Pulls uses Cloudflare's global certificate**, enabled by the zone setting `tls_client_auth`. The CA (`authenticated_origin_pull_ca.pem`, SHA-256 `9A:1A:C2:B4:BE:15:F9:F2:7E:EE:20:A7:34:CB:A4:E9:89:8F:61:00:1B:3B:D7:C8:4B:69:B5:6A:3E:25:A2:B9`, expires 2029-11-01) is committed with those facts in its header comment. It proves "from Cloudflare's network" — the same thing decision 1 proves — but without depending on a list, and Cloudflare holds the keys. |
| 6 | **Rollout is nginx `optional` → Cloudflare on → nginx `on`.** `optional` accepts Cloudflare's no-certificate requests today and starts verifying the moment Cloudflare presents one. The step that could 495 every request (Cloudflare on, if the CA were wrong) is the one with the fastest rollback: a single settings PATCH through `cfrules`, not a redeploy. |
| 7 | **The Cloudflare IP list is fetched at nginx image build** by a committed script with hard assertions (§5.3). Deploys already run `docker compose build --no-cache nginx`, so the list refreshes on every deploy with nothing to maintain. A bad fetch fails the build, which fails the deploy loudly and leaves the running image alone. |
| 8 | **`real_ip_header CF-Connecting-IP`** with `set_real_ip_from` for every Cloudflare range, in the `http` context. `X-Forwarded-For` then ends `…, <visitor>` and Rails' `RemoteIp` resolves it the same way it does now; nothing in the app changes. The bot-blocker's `limit_req`/`limit_conn` zones (90 r/s, 200 connections, keyed on `$binary_remote_addr`) switch from per-edge to per-visitor — an improvement, and 90 r/s per visitor cannot throttle a real one. |
| 9 | **`log_format main` gains `cf=$realip_remote_addr verify=$ssl_client_verify`**, permanently. It is how increment 2 is verified and it stays useful. |
| 10 | **`RUN nginx -t` ends the Dockerfile.** It validates `nginx.conf` and the generated snippets at build time; the site template is rendered at container start and is covered by the post-deploy script (§7). |
| 11 | **A post-deploy verification script** (`deployment/scripts/verify-origin-lockdown.sh`) encodes the probes in §6 so the check is one command after any future deploy. |

## 3. Current state (verified 2026-09-14)

- `deployment/nginx/the-greatest.conf.template`: one `:80` server for all hostnames whose
  `location /` proxies to Rails when `X-Forwarded-Proto: https` is present and redirects
  otherwise; seven `:443` servers (four canonical, three `www` redirects). No `default_server`
  on either port. First `:443` server (`www.thegreatestmusic.org`) is therefore the implicit
  default for unknown SNI, which is why a cross-tenant request on 443 happens to get a 301.
- No `real_ip` configuration anywhere under `deployment/nginx/`. `proxy-params.conf` sets
  `X-Real-IP $remote_addr` and `X-Forwarded-For $proxy_add_x_forwarded_for`.
- nginx runs from `docker-compose.prod.yml` with `ports: 80:80, 443:443`. `nginx.conf`, the
  template, `ssl-params.conf` and `proxy-params.conf` are bind-mounted read-only from the repo;
  everything else comes from the image (`deployment/nginx/Dockerfile`, which also installs
  `nginx-ultimate-bad-bot-blocker`). The deploy workflow rebuilds it `--no-cache` on every
  deploy.
- Certificates are Let's Encrypt via DNS-01 (`certbot/dns-cloudflare`); port 80 is not needed
  for ACME.
- Cloudflare DNS: every record pointing at `45.33.28.21` is proxied (`thegreatestmusic.org`,
  `www.`, `thegreatest.games`, `www.`, `new.thegreatestbooks.org`). No grey-cloud leak.
- Zone settings: `tls_client_auth = off` on all three zones; `ssl = strict` on music and
  games, `full` on books (must stay `full` until the legacy origin's certificate is renewed);
  `always_use_https = on` on books only.
- Cloudflare's published ranges: 15 IPv4 + 7 IPv6 CIDRs, `etag 38f79d050aa027e3be3865e495dcc9bc`,
  from `https://api.cloudflare.com/client/v4/ips` (no auth). Changes are rare and announced.
- Docker image `nginx:latest` (1.29.x): `$realip_remote_addr` (≥1.9.7), `geo` with a source
  variable, and `ssl_reject_handshake` (≥1.19.4) are all available.

### 3.1 The cross-tenant bypass, applied to this config

Certitude Consulting's 2023 research ("Using Cloudflare to bypass Cloudflare"): any Cloudflare
customer can point their own zone at your origin IP, switch their zone's protections off, and
reach your origin through Cloudflare's shared proxies. This defeats IP allowlisting (the traffic
really does come from Cloudflare IPs) and *global* Authenticated Origin Pulls (the
Cloudflare-provided client certificate is the same for every customer). Cloudflare's updated
guidance: use a custom AOP certificate, and validate the `Host` header at the origin.

Against our nginx today, an attacker's zone in **Flexible** SSL mode is enough: Cloudflare
connects to origin port 80 with `X-Forwarded-Proto: https`, the `:80` block proxies to Rails,
and `ApplicationController#detect_current_domain` falls back to `:books` for the unknown host.
The site is served with none of our edge rules in front. Decisions 3 and 4 close this for
every attacker without Cloudflare Enterprise (Host-header override in Origin Rules is
Enterprise-only). §9 covers the Enterprise case.

## 4. Why this shape (research summary)

Cloudflare's own ranking of origin protections: Tunnel and Authenticated Origin Pulls "very
secure", IP allowlisting "moderately secure". The reason allowlisting ranks lower is not IP
spoofing; it is the cross-tenant bypass above — which global AOP shares. So among the
portable, keyless mechanisms, the meaningful security comes from **host validation** plus
**Cloudflare-only connections**; global AOP is a list-independent second proof of the same
property. That is the stack this design ships, with the residual stated plainly in §9.

Rejected alternatives and why are in §1's non-goals.

## 5. Design

### 5.1 nginx enforcement, directive by directive

In `nginx.conf`, `http` context (before the `sites-enabled` include):

```nginx
include /etc/nginx/snippets/cloudflare-real-ip.conf;   # generated at image build
include /etc/nginx/snippets/cloudflare-geo.conf;       # generated at image build
```

`cloudflare-real-ip.conf` (generated):

```nginx
# Generated <UTC timestamp> from https://api.cloudflare.com/client/v4/ips (etag <etag>)
set_real_ip_from 173.245.48.0/20;
… one line per IPv4 and IPv6 CIDR …
real_ip_header CF-Connecting-IP;
```

`cloudflare-geo.conf` (generated):

```nginx
# Generated <UTC timestamp> from https://api.cloudflare.com/client/v4/ips (etag <etag>)
geo $realip_remote_addr $from_cloudflare {
    default      0;
    127.0.0.1/32 1;   # container healthcheck
    ::1/128      1;
    173.245.48.0/20 1;
    … one line per CIDR …
}
```

`snippets/cloudflare-only.conf` (committed, included in every named server block on both
ports):

```nginx
if ($from_cloudflare = 0) { return 444; }
```

`snippets/ssl-params.conf` gains:

```nginx
ssl_client_certificate /etc/nginx/certs/cloudflare-origin-pull-ca.pem;
ssl_verify_client optional;   # increment 3 flips this to `on`
```

`the-greatest.conf.template` gains two default servers and loses the port-80 proxy branch:

```nginx
server {                       # unknown Host on 80
    listen 80 default_server;
    return 444;
}

server {                       # unknown or missing SNI on 443
    listen 443 ssl default_server;
    ssl_reject_handshake on;
}

server {
    listen 80;
    server_name thegreatestmusic.org www.thegreatestmusic.org … new.thegreatestbooks.org;
    include /etc/nginx/snippets/cloudflare-only.conf;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }   # unchanged
    location / { return 301 https://$host$request_uri; }
}
```

Every existing `:443` server block adds `include /etc/nginx/snippets/cloudflare-only.conf;`
after its `include …/ssl-params.conf;`. Nothing else in the blocks changes.

`log_format main` becomes:

```nginx
log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                '$status $body_bytes_sent "$http_referer" '
                '"$http_user_agent" "$http_x_forwarded_for" '
                'cf=$realip_remote_addr verify=$ssl_client_verify';
```

### 5.2 Files

| File | Change |
|---|---|
| `deployment/nginx/bin/generate-cloudflare-snippets.sh` | new — §5.3 |
| `deployment/nginx/certs/cloudflare-origin-pull-ca.pem` | new — Cloudflare's CA, PEM preceded by a comment block with source URL, SHA-256 fingerprint, expiry |
| `deployment/nginx/snippets/cloudflare-only.conf` | new — the one-line `if` |
| `deployment/nginx/Dockerfile` | install `curl jq`; `COPY` the script, the CA, the snippet; `RUN` the generator into `/etc/nginx/snippets`; `RUN nginx -t` last |
| `deployment/nginx/nginx.conf` | two includes; log format |
| `deployment/nginx/snippets/ssl-params.conf` | the two AOP directives |
| `deployment/nginx/the-greatest.conf.template` | default servers; port-80 branch; eight includes (one per named server) |
| `docker-compose.prod.yml` | one read-only mount for `cloudflare-only.conf`, matching the other snippets |
| `deployment/scripts/verify-origin-lockdown.sh` | new — §7 |
| `deployment/README.md`, `deployment/TROUBLESHOOTING.md`, `deployment/SERVER-UPGRADE-GUIDE.md`, `docs/guides/stripe-account-setup.md` | §8 |
| **the-greatest-cloudflare** `lib/cf/zone.rb`, tests, `zones/*.yml` | `tls_client_auth` alongside `ssl` — §5.4 |

### 5.3 The generator

`generate-cloudflare-snippets.sh <output-dir> [<local-json-file>]`, `set -euo pipefail`:

1. Fetch `https://api.cloudflare.com/client/v4/ips` with `curl -fsS --retry 3 --retry-all-errors --max-time 20`
   (or read the optional local file, for offline tests).
2. Assert `.success == true`; ≥ 10 entries in `.result.ipv4_cidrs`; ≥ 3 in `.result.ipv6_cidrs`;
   every IPv4 entry matches `^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$` and every IPv6 entry
   matches `^[0-9A-Fa-f:]+/[0-9]{1,3}$`. Any failure: message to stderr, non-zero exit,
   nothing written.
3. Write the two snippets in §5.1, header comment carrying the UTC timestamp and `etag`.

This is the only place the list is fetched (the Cloudflare-side toggle is a setting, not a
list), and there is deliberately no committed copy to go stale.

### 5.4 Cloudflare side (`the-greatest-cloudflare`, private)

`tls_client_auth` becomes a managed setting next to `ssl`: `pull` reads
`GET /zones/:id/settings/tls_client_auth`, `diff` reports drift on it exactly as it does for
`ssl` (the settings digest covers every declared key), `apply` PATCHes
`{"value": "on"|"off"}`, and `validate!` rejects any value other than `on`/`off`. Tests
mirror the `ssl` ones. The
three zone files declare `tls_client_auth: on` with a comment pointing at this spec and at the
nginx side that consumes it. On books the comment also records that the legacy origin receives
and ignores the certificate.

## 6. Rollout

Each increment is a separate PR. Increment 1 and 3 are in this repo (merge to `main` deploys);
increment 2 is a `cfrules apply`.

### Increment 1 — nginx enforces Cloudflare-only + host validation; AOP in `optional` mode

Everything in §5 except `ssl_verify_client on`. After the deploy, from a machine outside
Cloudflare:

| Probe | Expected |
|---|---|
| `curl -sv --resolve thegreatestmusic.org:443:45.33.28.21 https://thegreatestmusic.org/` | empty reply (curl exit 52) — geo 444 |
| `curl -sv https://45.33.28.21/` (no SNI) | TLS handshake failure (curl exit 35), no certificate in the transcript |
| `curl -sv --resolve evil.test:443:45.33.28.21 https://evil.test/ -k` | TLS handshake failure — unknown SNI |
| `curl -sv -H 'Host: thegreatestmusic.org' -H 'X-Forwarded-Proto: https' http://45.33.28.21/` | empty reply — the port-80 hole; today this serves the site |
| `curl -sv -H 'Host: evil.test' http://45.33.28.21/` | empty reply — `:80` default server |
| `curl -si https://new.thegreatestbooks.org/api/v1/books` | 401 with `cf-ray` and `WWW-Authenticate: Bearer` — through Cloudflare, origin answered (the `/api/` path skips SBFM so a script can read it) |
| `curl -si https://thegreatestmusic.org/api/v1/books` and `…games…` | Rails' 404 (or 401 once their API increments ship) with `cf-ray`; **not** a 52x |
| Browser: the three sites | render normally |
| `docker compose -f docker-compose.prod.yml logs nginx` | `$remote_addr` is a visitor IP, `cf=<Cloudflare edge>`, `verify=NONE` on 443 |
| `docker compose ps` | nginx `healthy` |

Rollback: revert the PR; the deploy workflow rebuilds nginx. On-box emergency rollback if the
workflow is unavailable: `git checkout <previous-sha> -- deployment/nginx docker-compose.prod.yml && docker compose -f docker-compose.prod.yml build --no-cache nginx && docker compose -f docker-compose.prod.yml up -d nginx`.

### Increment 2 — Cloudflare presents the certificate

`cfrules diff` then `cfrules apply` on each zone with `tls_client_auth: on`. Cloudflare
immediately presents its client certificate; nginx (`optional`) verifies it.

- Success: every `:443` log line reads `verify=SUCCESS` within a minute. Watch for a day.
- Failure mode: the CA does not match → nginx answers 495 to every request → the sites are
  down. Rollback is `tls_client_auth: off` and re-apply (or `cfrules rollback`): one PATCH,
  seconds. That is why this step is second, not first.

### Increment 3 — enforce

`ssl_verify_client optional` → `on` in `ssl-params.conf`. One-line PR. Afterwards a
correct-SNI direct request with no client certificate gets HTTP 400 (nginx's "No required SSL
certificate was sent") rather than reaching the geo check; the verification script accepts
either. Through-Cloudflare probes unchanged.

## 7. Verification script

`deployment/scripts/verify-origin-lockdown.sh` runs the §6 probe table and exits non-zero on
the first unexpected result, printing which probe failed and what it got. `ORIGIN_IP` defaults
to `45.33.28.21` and is overridable for a rebuilt server. Direct probes must fail in one of the
expected ways (exit 52, exit 35, or HTTP 400); through-Cloudflare probes must show a `cf-ray`
and an origin-generated status (401 or 404), never 403, 5xx, or a Cloudflare 52x. It is run
from Shane's machine after each of the three increments, and after any future nginx change.

## 8. Documentation

- `deployment/README.md` — the Security section is rewritten to describe what the origin
  enforces (the three conditions in §1), where each is configured, the residual in §9, and the
  one-command verification.
- `deployment/TROUBLESHOOTING.md` — three entries: *every request 495 or 400 "client
  certificate"* (Cloudflare `tls_client_auth` and nginx `ssl_verify_client` disagree; which way
  to move); *site down after Cloudflare announced new IP ranges* (rebuild nginx — the list is
  refreshed at build); *nginx unhealthy after a config change* (loopback must remain in the geo
  map).
- `deployment/SERVER-UPGRADE-GUIDE.md` — one line: the lockdown ships in the image; nothing
  per server.
- `docs/guides/stripe-account-setup.md` — the "configure nginx's `real_ip` module" ops
  follow-up is marked done with a pointer here.
- Memory note `production-request-headers-untrusted` is updated after increment 3 ships.

## 9. Residual risk and the doors left open

**Accepted:** a Cloudflare *Enterprise* customer can still use Origin Rules' Host-header
override through their own zone to reach Rails with one of our hostnames, skipping our WAF,
SBFM, and rate limits. Nothing keyless and portable in this design stops that; it needs a
proof of "from my zone".

Two ways to close it later, each an isolated increment:

- **Origin secret header** (Cloudflare's "HTTP header validation"): a Transform Rule on each
  zone adds `X-Origin-Secret: <random>` to origin requests; a `map` in the template (the value
  reaches nginx through the existing envsubst templating from the SOPS-managed `.env`) sets
  `$origin_secret_ok`; the `cloudflare-only.conf` snippet also requires it. Rotation is
  nginx-accepts-both → Cloudflare switches → nginx drops the old. No keys. Adds a phase to
  `cfrules`.
- **Custom AOP certificate**: `POST /zones/:id/origin_tls_client_auth` with a leaf signed by a
  CA we hold; nginx verifies against our CA. The strongest option, and the one Shane declined
  for now because of the rotation duty.

Also open, and unrelated to the above: a volumetric flood aimed at the raw IP still reaches the
box's NIC (nginx closes each connection cheaply, but bandwidth is bandwidth). Only a network
firewall or Tunnel drops that earlier; both were declined for stated reasons. The IP is not
published anywhere, and rotating it on a rebuild is the documented remedy.
