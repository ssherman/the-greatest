# OpenSearch server: built from code, locked down — design

**Date:** 2026-10-13
**Status:** approved in conversation; awaiting review of this written spec
**Sequence:** first of three. Next is the Postgres server (same pattern, plus the move to Postgres 18), then
observability (Grafana metrics and alerts), which adds its collector agent to every server's cloud-init.

## 1. Why

Production search runs on a hand-built Linode created in 2023. Nothing about it is reproducible, and it has
already been attacked: someone deleted the indexes and left one document asking for bitcoin. The image it runs
(`the-greatest-books/opensearch/`) starts OpenSearch with `DISABLE_SECURITY_PLUGIN=true`, publishes
`9200:9200`, floats on `opensearchproject/opensearch:latest`, and hardcodes an AWS access key and secret in its
Dockerfile for S3 snapshots. It has since been locked down by hand.

Both sites use it: the old books site (indexes `books`, `authors`) and the new app
(`<domain>_<model>_production`, for example `books_books_production`, `music_albums_production`).

## 2. Goals and success test

- One command builds the server (`terraform apply`), one manual workflow configures and starts it.
- Nobody but our app servers can open a connection to OpenSearch, over IPv4 or IPv6.
- Defense in depth: a password on every request, a separate least-privilege login per site, encrypted traffic.
- The newest OpenSearch release, pinned, upgraded on purpose.
- Nothing hosting-specific, no certificates anybody renews by hand, no secrets or server IPs in the public repo.

**Success test (run, not claimed):** build the server, verify it, destroy it, rebuild it, verify it again, with no
SSH session used to fix anything in between. Then reindex and both sites search normally.

## 3. Non-goals

- **Backups.** The indexes are rebuilt from Postgres. The new app's reindex and the old site's (about 30 minutes)
  are the recovery path. No snapshot repository, no S3 plugin, no AWS key.
- Multiple nodes, OpenSearch Dashboards, plugins. The new app uses none.
- Monitoring. The observability spec adds the agent to this server's cloud-init later.
- Upgrading the web server from Ubuntu 24.04 (supported until 2029-05). A separate item.

## 4. Decisions

| Decision | Choice | Why |
|---|---|---|
| OS | Ubuntu 26.04 LTS (`linode/ubuntu26.04`, available on Linode since 2026-06-09, EOL 2031-05) | Latest LTS; Docker's apt repo publishes 26.04 packages |
| OpenSearch | Newest 3.x at implementation time, pinned by exact tag (3.8.0, released 2026-08-05, at time of writing) | Latest release; the old `:latest` tag is how the old server drifted |
| Size | Variable, default **Linode 8 GB** (4 cores, 160 GB), region `us-central` | Same as today's server; Shane has never had OpenSearch performance problems |
| Memory | 4 GB heap, `mem_limit: 7g`, memory locked; breaker and `thread_pool.search.queue_size` settings carried over from the old compose | Half of RAM to the heap, the rest to the OS file cache; old settings caused no problems |
| Storage | The instance disk, no Linode Block Storage volume | Portable; nothing on it needs to survive |
| Terraform | A separate root module with its own state | An apply for search cannot touch the web server, and the reverse |
| Encryption | The server's own self-generated certificate, reused for HTTP; clients do not verify it | The security plugin needs a certificate for its internal transport layer anyway. Encrypts against eavesdropping with no hostname, no Let's Encrypt, no renewals. Accepted gap: an attacker on the provider's network could impersonate the server |
| Deploy | A manual (`workflow_dispatch`) GitHub Actions workflow | Merging to `main` deploys the web app; it must never restart search |

Rejected: Let's Encrypt via Cloudflare DNS for the search hostname (most moving parts, likely a restart per
renewal); no encryption (password in plain text across the provider network); a WireGuard/Tailscale overlay
(adds a network service every search depends on); Linode Cloud Firewall and Linode VLANs (hosting lock-in,
see the infra-portability preference).

## 5. Security

Three layers. The firewall is the one that keeps attackers out; the other two cover a mistake in it.

### 5.1 Firewall

- Docker-published ports bypass `ufw`. The rules therefore live in the **`DOCKER-USER`** chain, for both
  `iptables` and `ip6tables`. Match the original destination port (`-m conntrack --ctorigdstport 9200`), because
  `DOCKER-USER` sees packets after Docker's DNAT.
- Rules: accept established traffic; accept new connections to 9200 from each allowlisted address; drop every
  other connection to 9200.
- **Closed before Docker ever starts.** Cloud-init installs `opensearch-firewall.service`, a systemd oneshot ordered
  `Before=docker.service` (and required by it). It creates the `DOCKER-USER` chains itself and fills them from
  `/etc/opensearch/allowlist`; Docker reuses an existing `DOCKER-USER` chain without flushing it. Ordering it
  *after* Docker would be wrong: `restart: unless-stopped` containers come up as soon as the daemon does, which
  would leave 9200 open for a few seconds on every reboot. A missing or empty allowlist file means drop everything
  on 9200, so there is no window on first boot or after a reboot when the port is open.
- The allowlist is `OPENSEARCH_ALLOWED_IPS` in SOPS (IPv4 and IPv6 addresses of the app servers, including the old
  site's server until it shuts down). The deploy writes it to `/etc/opensearch/allowlist` and re-runs the unit.
  Adding the worker server at launch is a SOPS edit plus a workflow run.
- The rule renderer **rejects** an empty or malformed allowlist and fails the deploy, rather than opening the port
  or locking the apps out.
- `ufw` stays on for everything else: SSH only inbound. SSH key-only, fail2ban, unattended security upgrades, as on
  the web server.
- Ubuntu 26.04 runs `iptables` on the nftables backend. Proving the `DOCKER-USER` rules hold on a real boot is part
  of verification (§8.3), not an assumption.

### 5.2 Logins

- Security plugin on. `DISABLE_INSTALL_DEMO_CONFIG=true`; no demo certificates, no `admin/admin`.
- Users, roles and role mappings are files in the repo (`deployment/opensearch/security/`). Password hashes are
  computed at deploy time from SOPS values with the plugin's hash tool, then applied with `securityadmin.sh` using
  the admin client certificate. Re-applying is idempotent.

| User | Password (SOPS) | Can do |
|---|---|---|
| `admin` | `OPENSEARCH_ADMIN_PASSWORD` | Everything. Break-glass and setup only; no app uses it |
| `the_greatest_app` | `OPENSEARCH_APP_PASSWORD` | Create, delete, write and search indexes matching `books_*_production`, `music_*_production`, `games_*_production`; cluster health and bulk/msearch |
| `tgb_legacy` | `OPENSEARCH_LEGACY_PASSWORD` | The same on the old site's indexes only (`books`, `authors`; confirm the full list from the old server before writing roles) |

- Neither app user can change cluster settings, roles or the security index.
- Passwords are generated URL-safe (`openssl rand -hex 32`), because they travel inside `OPENSEARCH_URL`.

### 5.3 Encryption

- The first deploy generates, with `openssl`, a private CA, a node certificate and an admin client certificate
  into a root-only host directory. Ten-year validity: the server is replaced long before then. Later deploys
  leave existing certificates alone.
- Transport and HTTP TLS both use the node certificate.
- Clients connect to `https://<user>:<password>@<server-ip>:9200` and skip verification (§7).

## 6. Build and deploy

### 6.1 Files

```
deployment/terraform/opensearch/
  main.tf  variables.tf  cloud-init.yaml  terraform.tfvars.example
deployment/opensearch/
  compose.yml                       # OpenSearch only, pinned tag, port 9200
  config/opensearch.yml             # single-node, security + TLS settings
  security/                         # config.yml, roles.yml, roles_mapping.yml, internal_users.yml.tmpl
  bin/deploy.sh                     # what the workflow runs on the server
  bin/render-firewall.sh            # allowlist -> DOCKER-USER rules (v4 + v6)
  bin/render-security.sh            # SOPS passwords -> internal_users.yml
  bin/generate-certs.sh             # first run only
  systemd/opensearch-firewall.service
  test/run.sh  test/*_test.sh  test/local-e2e-test.sh
deployment/scripts/verify-opensearch-lockdown.sh
secrets/.env.opensearch             # SOPS; new creation rule in .sops.yaml
.github/workflows/deploy-opensearch.yml
```

### 6.2 Terraform

One `linode_instance` from `linode/ubuntu26.04`, same variables as the web module (token, label, region, type,
authorized keys, root password), user data from `cloud-init.yaml`. Its own local state, gitignored like the web
module's. No firewall, VLAN or volume resources.

### 6.3 Cloud-init (first boot)

Modelled on `deployment/terraform/web-cloud-init.yaml`:

1. `deploy` user, SSH keys only, `ssh_pwauth: false`, fail2ban, `ufw` (OpenSSH only), unattended-upgrades.
2. Host settings OpenSearch needs: `vm.max_map_count=262144`, swap off or `bootstrap.memory_lock` with unlimited
   memlock, `nofile` 65536.
3. Install `opensearch-firewall.service` and enable it **before** installing Docker.
4. Install Docker from Docker's apt repository.
5. Clone the repo. Do not start OpenSearch: the server has no secrets yet.

### 6.4 Deploy workflow

`deploy-opensearch.yml`, `workflow_dispatch` only. Same shape as `deploy-production.yml`: SSH with a pinned host
fingerprint, pull, decrypt `secrets/.env.opensearch` with the age key, run `deployment/opensearch/bin/deploy.sh`.
New GitHub secrets: `OPENSEARCH_SSH_HOST`, `OPENSEARCH_SSH_HOST_FINGERPRINT` (a rebuild changes the host key, so
the runbook says to update it). It reuses `DEPLOY_SSH_KEY` and `AGE_PRIVATE_KEY`.

`deploy.sh`, every step safe to repeat:

1. Write the allowlist and restart `opensearch-firewall.service`. Abort on a bad allowlist.
2. Generate certificates if absent.
3. `docker compose up -d` (a no-op when nothing changed).
4. Wait for the node, render `internal_users.yml`, apply the security config with `securityadmin.sh`.

## 7. App changes

Both apps already build their client from `OPENSEARCH_URL` with `opensearch-ruby`. Each gains one option:
`transport_options: {ssl: {verify: false}}` when `OPENSEARCH_SSL_VERIFY=false`, and verification stays on
otherwise. Development keeps plain `http://localhost:9200` and is unaffected.

- New app: `web-app/app/lib/search/shared/client.rb`. Add `OPENSEARCH_SSL_VERIFY` to `.env.example` and
  `deployment/ENV.md`.
- Old site (`the-greatest-books` repo): `admin/app/lib/search/books_index.rb` and `authors_index.rb`.

## 8. Verification

### 8.1 CI

The CI step "Shell tests and shellcheck" also runs `deployment/opensearch/test/run.sh` and shellchecks the new
scripts. Plain bash pass/fail tests, in the style of `deployment/home-server/test/` and
`deployment/nginx/test/generate-cloudflare-snippets_test.sh`:

- **Firewall rendering:** an allowlist of IPv4 and IPv6 addresses yields accept rules for exactly those, plus the
  drop rule, in both families. Empty, malformed or wildcard input exits non-zero.
- **Security rendering:** the output defines exactly `admin`, `the_greatest_app` and `tgb_legacy`, each mapped to
  its role, with hashed (never plain) passwords; no demo users.
- **Ruby:** a Minitest for `Search::Shared::Client`: verification is off only when `OPENSEARCH_SSL_VERIFY=false`.

### 8.2 Local end-to-end (manual, like `deployment/nginx/test/local-lockdown-test.sh`)

Starts the real compose file locally with generated certificates and the rendered security config, then asserts:
no password → 401; `the_greatest_app` can create, write and search `books_books_production` and is refused on
`books`; `tgb_legacy` the reverse; neither can change cluster settings; `admin` works.

### 8.3 On the real server

`deployment/scripts/verify-opensearch-lockdown.sh`, modelled on `verify-origin-lockdown.sh`:

- From a non-allowlisted machine: connections to 9200 refused or timed out on IPv4 **and IPv6**.
- From each app server: both logins work over HTTPS; each is refused on the other's indexes.

Run it after every build or rebuild. The success test in §2 runs it twice around a destroy and rebuild, before the
switchover.

## 9. Switchover (once)

The old server keeps running untouched until the last step, so rollback before then is changing `OPENSEARCH_URL`
back.

1. `terraform apply`; add the host and fingerprint secrets; run `deploy-opensearch`; run the verify script.
2. Destroy and rebuild once, verify again (§2).
3. **Old site first** (it has the real traffic): run its reindex as a one-off command pointed at the new server
   while the live site still serves from the old one; when it finishes, deploy the old site with the new
   `OPENSEARCH_URL` and `OPENSEARCH_SSL_VERIFY=false`.
4. **New app:** merge the client change, set `OPENSEARCH_URL` and `OPENSEARCH_SSL_VERIFY=false` in
   `secrets/.env.production` (merging deploys), then run `search:books:recreate_and_reindex_all`,
   `search:music:recreate_and_reindex_all` and `search:games:recreate_and_reindex_all`. Search on the new sites is
   empty while that runs; acceptable with books unlaunched and music and games nearly idle.
5. Soak a day or two. Then Shane deletes the old Linode, deletes `the-greatest-books/opensearch/`, and
   **deactivates the AWS access key** hardcoded in its Dockerfile.

These steps live in the runbook (§10), not `docs/launch-todo.md`: the switchover does not depend on the launch.

## 10. Documentation

- New runbook `docs/features/opensearch-server.md`: build, deploy, verify, the switchover, adding an app server's
  IP, rotating a password, upgrading OpenSearch, rebuilding.
- `deployment/ENV.md`: `OPENSEARCH_SSL_VERIFY`, and the shape of `OPENSEARCH_URL` with credentials.
- `deployment/README.md`: point "External Services" at the runbook.

## 11. Check during implementation

- The exact newest OpenSearch 3.x tag on the day; read its security-plugin docs for the Docker setup and
  `securityadmin.sh` flags rather than relying on 1.x/2.x examples.
- The full list of indexes on the old server, before writing `tgb_legacy`'s role.
- That the `DOCKER-USER` rules, including IPv6, hold on a real Ubuntu 26.04 boot with the Docker version installed,
  and that Docker keeps a `DOCKER-USER` chain created before it starts. Check it with a reboot: probe 9200 from
  outside in a loop while the server comes back up; it must never answer.
- That `opensearch-ruby` takes credentials from the URL for both apps' client versions.
