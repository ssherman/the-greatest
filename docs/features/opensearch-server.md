# OpenSearch server

## What it is

One Linode (Ubuntu 26.04, Linode 8 GB `g6-standard-4`, region `us-central`) that runs OpenSearch
3.9.0 from `deployment/opensearch/compose.yml`. Two callers use it: the new app (login
`the_greatest_app`, indexes `books_*_production`, `music_*_production`, `games_*_production`) and the
old books site (login `tgb_legacy`, indexes `books` and `authors`). A third login, `admin`, is the
break-glass login (`deployment/opensearch/security/internal_users.yml.tmpl`). `securityadmin.sh` does not
use it: it authenticates with the admin client certificate (`admin.pem`, matched by
`plugins.security.authcz.admin_dn` in `deployment/opensearch/config/opensearch.yml`).

There are no backups. The search indexes can be rebuilt from the database, so the recovery for a lost
server is to rebuild it and reindex (see "Rebuild").

Three layers protect it. A firewall rule in Docker's `DOCKER-USER` chain drops port 9200 for everyone
except the allowlisted app servers, and it is in place before Docker starts. Each caller has a login
that can reach only its own indexes, with no access to the security API. All traffic is HTTPS with a
certificate the server generates for itself. The design and the reasoning are in
`docs/superpowers/specs/2026-10-13-opensearch-server-design.md`.

## Files

```
deployment/terraform/opensearch/    # the Linode: main.tf, variables.tf, cloud-init.yaml, terraform.tfvars.example
deployment/opensearch/
  compose.yml                       # the OpenSearch container (pinned image, IPv4-only port)
  config/opensearch.yml             # node settings
  security/                         # roles, role mappings, users template, API allowlist, audit
  systemd/opensearch-firewall.service   # applies the allowlist before Docker starts
  bin/deploy.sh                     # the five deploy steps, run on the server
  bin/render-firewall.sh, install-firewall.sh, apply-firewall.sh
  bin/generate-certs.sh, render-security.sh, hash-password.sh, apply-security.sh
  test/                             # unit tests (run.sh) and local-e2e-test.sh
deployment/scripts/verify-opensearch-lockdown.sh   # --outside and --inside checks
.github/workflows/deploy-opensearch.yml            # manual deploy
secrets/.env.opensearch             # SOPS: allowlist and the three passwords
```

## Build

0. **Merge this branch to main first.** cloud-init clones `main` and runs
   `deployment/opensearch/bin/install-firewall.sh` from it (`deployment/terraform/opensearch/cloud-init.yaml`),
   and the deploy workflow pulls `main`. Building from an unmerged branch silently skips the boot firewall unit.
1. Copy `deployment/terraform/opensearch/terraform.tfvars.example` to `terraform.tfvars` and fill it in. The first entry of `authorized_keys` must be the public key that
matches the `DEPLOY_SSH_KEY` GitHub secret (the same first key the web server's tfvars uses). cloud-init
gives only the first key to the `deploy` user, and the workflow logs in as `deploy` with that secret; any
other first key fails with an auth error, and the fix is a rebuild.
2. Create the Linode and read its addresses:

```bash
terraform -chdir=deployment/terraform/opensearch init
terraform -chdir=deployment/terraform/opensearch apply
terraform -chdir=deployment/terraform/opensearch output -raw ipv4
terraform -chdir=deployment/terraform/opensearch output -raw ipv6
```

`ipv6` is printed with a `/128` suffix. `verify-opensearch-lockdown.sh` strips it; strip it yourself for
anything else, such as a manual `curl`.

3. Wait for cloud-init to finish:

```bash
ssh deploy@<ipv4> cloud-init status --wait
```

4. Get the host-key fingerprint and set the two GitHub secrets:

```bash
ssh-keyscan -t ecdsa <ipv4> 2>/dev/null | ssh-keygen -lf - | awk '{print $2}'
gh secret set OPENSEARCH_SSH_HOST --body <ipv4>
gh secret set OPENSEARCH_SSH_HOST_FINGERPRINT --body '<SHA256:...>'
```

5. Create `secrets/.env.opensearch`. It is SOPS binary format, the same as `secrets/.env.production`
   (sops/age key setup: `deployment/SECRETS.md`). Write a plain file named `secrets/.env.opensearch.plain`
   (gitignored by `secrets/*.plain` in `.gitignore`) with these four lines (passwords from
   `openssl rand -hex 32`), then encrypt it:

```
OPENSEARCH_ALLOWED_IPS=203.0.113.10,203.0.113.11
OPENSEARCH_ADMIN_PASSWORD=<hex>
OPENSEARCH_APP_PASSWORD=<hex>
OPENSEARCH_LEGACY_PASSWORD=<hex>
```

```bash
sops --encrypt --filename-override secrets/.env.opensearch secrets/.env.opensearch.plain > secrets/.env.opensearch
```

Delete `secrets/.env.opensearch.plain`, then commit and merge the encrypted file BEFORE the first workflow
run (the workflow pulls `main`). Edit with `sops secrets/.env.opensearch`; read with `sops -d secrets/.env.opensearch`.
Never pass `--input-type` or `--output-type dotenv`. `OPENSEARCH_ALLOWED_IPS` is comma-separated with no
spaces, because `deploy.sh` sources the file.

## Deploy

Actions, "Deploy OpenSearch", Run workflow, or:

```bash
gh workflow run deploy-opensearch.yml
```

The workflow is manual only. Merging to `main` never restarts search. It SSHes to the server as
`deploy`, runs `git pull --ff-only` in the server's clone (which tracks `main`, so merge first), decrypts
`secrets/.env.opensearch` into a temporary file, and runs `deployment/opensearch/bin/deploy.sh`. It needs
the GitHub secrets `OPENSEARCH_SSH_HOST` and `OPENSEARCH_SSH_HOST_FINGERPRINT`, plus the repo's existing
`DEPLOY_SSH_KEY` and `AGE_PRIVATE_KEY`.

`deploy.sh` does five steps, each safe to repeat:

1. Firewall: validate the allowlist, install it to `/etc/opensearch/allowlist`, and install the boot unit.
2. Certificates: generate on the first run only.
3. Users and roles: hash the passwords and install the security files.
4. Start: `docker compose up -d`, with `--force-recreate` only when `opensearch.yml` or a certificate changed.
5. Load the security files into the security index with `securityadmin.sh`.

An unchanged redeploy restarts nothing.

## Verify

Run both modes after every build or rebuild. Both must end with `all passed`.

From a laptop that has IPv6 and is on an unfiltered network:

```bash
SEARCH_IPV4=<ipv4> SEARCH_IPV6=<ipv6> deployment/scripts/verify-opensearch-lockdown.sh --outside
```

For each address it first connects to port 22. If that fails the check FAILS, because a dropped 9200
proves nothing from a machine that cannot reach the server. Then 9200 (and 9300 on IPv4) must be a true
drop: curl exit 28 with zero connect time. "Connection refused" fails. A network that blocks outbound
9200 gives a false pass, so do not run this from a hotel or office network. fail2ban on the server may
ban a laptop that runs the script many times in a row.

From the new app server:

```bash
SEARCH_IPV4=<ipv4> OPENSEARCH_APP_PASSWORD=<pw> OPENSEARCH_LEGACY_PASSWORD=<pw> \
  deployment/scripts/verify-opensearch-lockdown.sh --inside
```

It checks that both logins work, each is refused on the other site's indexes and on the security API,
and a request with no login is refused. Read the passwords from `sops -d secrets/.env.opensearch`.

Reboot check. From a laptop, run the probe while the server reboots. Every value must be `000`:

```bash
while :; do curl -sk -m 2 -o /dev/null -w '%{http_code} ' https://<ipv4>:9200/; sleep 1; done
ssh deploy@<ipv4> sudo reboot      # in another terminal
```

Then confirm Docker is ordered after the firewall unit. `opensearch-firewall.service` must appear in both
`Requires` and `After`:

```bash
ssh deploy@<ipv4> systemctl show -p Requires,After docker.service
```

## Add or remove an app server

```bash
sops secrets/.env.opensearch
```

Edit `OPENSEARCH_ALLOWED_IPS` (comma-separated, no spaces), commit, merge, and run the workflow. A bad
entry fails the deploy and leaves the allowlist the server is already using alone.

Removing an IP stops NEW connections only. The firewall's `ESTABLISHED,RELATED` rule
(`deployment/opensearch/bin/render-firewall.sh`) lets a removed server's open keep-alive connections
continue until they close. To cut them immediately, run `sudo conntrack -D -s <ip>` on the search server
(`conntrack` may need `sudo apt install conntrack`).

## Rotate a password

Generate a new one with `openssl rand -hex 32` and put it in `secrets/.env.opensearch` with
`sops secrets/.env.opensearch`. Commit and merge that change first: the workflow runs `git pull --ff-only`
from `main`, so run before the merge it re-applies the old password and changes nothing. Then run the
workflow. The app users are `reserved: true`, so they cannot change their own passwords; the only way is
SOPS plus the workflow, where `securityadmin.sh` reloads them.

The app's copy of the password lives in its `OPENSEARCH_URL` (for the new app, `secrets/.env.production`),
and merging deploys the app. So the two sides change at different moments, and searches on that app fail
with 401 from whichever happens first until the other lands. Minimise the gap: put both SOPS changes in
the same merge, and run the workflow as soon as that merge's app deploy finishes. The gap is a search
outage of that length. Rotating `tgb_legacy` has the same shape with the old site's environment.

## Upgrade OpenSearch

1. Change the image tag in `deployment/opensearch/compose.yml`.
2. Run `deployment/opensearch/test/local-e2e-test.sh`. It starts the real compose file on port 19200 with
   a 1g heap, under the project `tg-opensearch-e2e`, and takes about 2 minutes. This is how to check an
   upgrade before deploying.
3. Merge and run the workflow. The new tag recreates the container; search is down for about a minute.

## Rebuild

```bash
terraform -chdir=deployment/terraform/opensearch apply -replace=linode_instance.search
```

`-replace` destroys the old instance first, so search is down until the rebuild, the deploy and the
reindex all finish. Wait for cloud-init before running the workflow:

```bash
ssh deploy@<ipv4> cloud-init status --wait
```

If the IP is reused, ssh warns about a changed host key; remove the old entry with
`ssh-keygen -R <ipv4>`. Then update both GitHub secrets (the host if the IP changed, the fingerprint always), update
`OPENSEARCH_URL` in both apps if the IP changed, run the workflow, run both verify modes, and reindex both
sites.

## Switchover from the old server (once)

0. **Prove the build first.** Follow Build, then Verify, then destroy and rebuild once (Rebuild), then
   Verify again, with no SSH fixes in between (spec section 9, steps 1-2: the success test). Only then
   switch over.

Merge the branch before starting: the workflow pulls `main`. Merging changes nothing for the web app
except the client switch, which stays inert until `OPENSEARCH_SSL_VERIFY=false` is set.

1. **Old site first.** Deploy the old repo's `opensearch-server-client` branch. On the old site's server,
   run its reindex once with `OPENSEARCH_URL=https://tgb_legacy:<pw>@<ipv4>:9200 OPENSEARCH_SSL_VERIFY=false`
   set for that one command only, while the live site still uses the old server. When it finishes, set both
   variables in the old site's environment and redeploy it. Check a search on the old site.
2. **New app.** In `secrets/.env.production` (`sops secrets/.env.production`), set
   `OPENSEARCH_URL=https://the_greatest_app:<pw>@<ipv4>:9200` and `OPENSEARCH_SSL_VERIFY=false`, then
   merge (merging deploys). On the web server run each of these, one after the other:

   ```bash
   docker compose -f docker-compose.prod.yml exec web bin/rails search:books:recreate_and_reindex_all
   docker compose -f docker-compose.prod.yml exec web bin/rails search:music:recreate_and_reindex_all
   docker compose -f docker-compose.prod.yml exec web bin/rails search:games:recreate_and_reindex_all
   ```

   Check a search on each site.
3. **Soak** for a day or two. Until step 4, rollback is setting `OPENSEARCH_URL` back to the old server.
4. **Retire the old server.** Delete the old Linode (the 2023 "opensearch" one) in the Linode dashboard,
   delete `the-greatest-books/opensearch/`, and deactivate the AWS access key hardcoded in its Dockerfile
   in AWS IAM.

## Gotchas

- Docker bypasses ufw for published ports. That is why the allowlist is in `DOCKER-USER`, not ufw.
- Never publish a bare `9200:9200`. It makes docker-proxy listen on `[::]:9200`, which `DOCKER-USER` never
  sees. The compose file binds `0.0.0.0` only.
- Never `systemctl restart opensearch-firewall`. Docker requires that unit, so a restart restarts Docker.
- `deploy.sh` refuses to run if `OPENSEARCH_PORT` is set. The firewall covers 9200 only. (The local e2e
  test sets it to 19200 and does not use `deploy.sh`.)
- Changes to `opensearch.yml` or the certificates need a container recreate. `deploy.sh` detects them by
  fingerprint and does it.
- `terraform output -raw ipv6` ends in `/128`. Strip it before using the address by hand.

## Known gaps

- cloud-init does not stop if the firewall install fails. `deploy.sh` installs the firewall again before it
  starts OpenSearch, so the first deploy still closes the port first.
- The SSH step in the deploy workflow uses the action's default 10-minute command timeout.
