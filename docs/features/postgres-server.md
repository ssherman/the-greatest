# Postgres server

## What it is

One Linode (Ubuntu 26.04, `g6-standard-4`, `us-central`) that runs PostgreSQL 18 from
`deployment/postgres/compose.yml`, built by Terraform and configured by a manual workflow, on the pattern
of `docs/features/opensearch-server.md`. It holds two databases: `the_greatest` (the new app) and `tgb`
(the old books site, which the new app also reads as `legacy_books`). Design and reasoning:
`docs/superpowers/specs/2026-11-06-postgres-server-design.md`. No role or password from the old server is
carried over; every role is created fresh here.

| Role | Can do | Used by |
|---|---|---|
| `postgres` | Superuser. Unix socket inside the container only, never over the network | Setup, pgBackRest, break-glass |
| `the_greatest` | Owns database `the_greatest` | New app |
| `tgb_app` | Owns everything in `tgb`, member of `pg_monitor` | Old site |
| `tgb_reader` | `SELECT` on `tgb` | New app's `legacy_books` connection |

Port 6543, **IPv4 only**, `hostssl` + `scram-sha-256` only, one `pg_hba` line per role, database and client
address. A firewall rule in `DOCKER-USER` drops every other connection through the published port, and is in
place before Docker starts. It matches only connections that Docker's published port has DNATed, so the
container's own outbound connections, including `CREATE SUBSCRIPTION` to a remote 6543, pass.

The port binds IPv4 only, so **an IPv6 client can never connect**, whatever `POSTGRES_CLIENTS` says. Give
every app server an IPv4 entry. `render-hba.sh` warns on an IPv6 entry, naming the line, without failing the
deploy. The IPv6 firewall rules still load, as a second layer.

Backups are pgBackRest to a Cloudflare R2 bucket (the backups bucket): WAL continuously (`archive_timeout=300`), a
full on Sundays and a differential other days at 09:00 UTC, 30 days of retention, encrypted. The WAL archive is
locked for 14 days against delete and overwrite. From step 7 of the move, when the restore check starts, the home
VM's nightly dumps go to a second R2 bucket (the dumps bucket), locked whole for 14 days and expired after 30. Why R2, and what the locks do and do not protect:
spec §8.2. **A backup counts only after it
has been restored:** a VM on the home server restores the newest backup nightly, checks it and dumps both
databases (`docs/features/home-server.md`, "The Postgres restore check").

## Files

```
deployment/terraform/postgres/       # the Linode: main.tf, variables.tf, cloud-init.yaml, terraform.tfvars.example
deployment/postgres/
  Dockerfile, compose.yml            # official image pinned by digest, plus pgBackRest; project postgres-server
  config/postgresql.conf             # the whole server config; postgresql.auto.conf stays empty
  config/pgbackrest.conf.tmpl        # rendered by deploy.sh into /srv/postgres/config/pgbackrest.conf
  .env.postgres.example              # the shape of secrets/.env.postgres, placeholders only
  bin/deploy.sh                      # the deploy, run on the server
  bin/render-firewall.sh, render-hba.sh, install-firewall.sh, apply-firewall.sh, generate-certs.sh, apply-roles.sh
  bin/backup.sh, check-backup-health.sh, backup-common.sh, install-backup.sh
  bin/setup-r2.sh                    # the two R2 buckets, their locks and lifecycle rules (Shane, once)
  systemd/                           # firewall unit, backup and health timers
  migration/                         # the one-time 17 -> 18 move (removed afterwards, see the last section)
  test/                              # run.sh (CI), run.sh --docker, local-e2e-test.sh (by hand)
deployment/home-server/guest/pg-restore-verify.sh   # the nightly restore check
deployment/scripts/verify-postgres-lockdown.sh      # --outside and --inside checks
.github/workflows/deploy-postgres.yml               # manual deploy
.github/workflows/postgres-migration-tests.yml      # Docker-based migration tests, path-filtered
secrets/.env.postgres                               # SOPS: clients, passwords, backups bucket and token, ping URLs
```

## Who runs what

Agents run everything on live servers over SSH, including the old-server restart and the cutover, with Shane
choosing the window. **Shane runs** `terraform apply`, `provision`, the one-time R2 setup, the real sign-in
and write check at cutover, and he is the one who must see each alert (see "Alerts"). Each live step needs
Shane's go-ahead first, and the outputs are reported as they came.

## Build

1. **Merge to `main` first.** cloud-init clones `main` and installs the boot firewall from it, and the workflow
   pulls `main`. The web app merge is safe: the new `POSTGRES_SSLMODE` and `LEGACY_BOOKS_SSLMODE` are unset
   until the move. A plain `provision` is safe too: VM 140 is not created until `PGVERIFY_ENABLED=1` (step 7 of
   the move).

   **Warning, at the merge:** once this merges, anyone running `docker compose up` or `bin/refresh-dev-db.sh`
   recreates `db` on 18 with an empty new volume until the refresh ends. The 17 data stays in its old volume.
   Do the dev switch soon after merging ("Dev database", below).
2. **(Shane, R2, one time)** The buckets, their rules, then the tokens. Nothing here is done in the AWS console.

   a. In the Cloudflare dashboard create a **temporary** account API token that can edit R2 (Account, Workers R2
      Storage, Edit).
   b. Run `setup-r2.sh` from the dev machine. It reads everything from the environment, never from arguments, and
      prints neither the token nor the account id. Use the **pre-production** repo path now ("Prove it" switches
      it):

      ```bash
      read -rs CF_API_TOKEN; export CF_API_TOKEN          # paste the temporary token
      read -rs CF_ACCOUNT_ID; export CF_ACCOUNT_ID
      export PGBACKREST_REPO_BUCKET=<backups bucket> PGVERIFY_DUMP_BUCKET=<dumps bucket>
      export PGBACKREST_REPO_PATH=<pre-production repo path>
      deployment/postgres/bin/setup-r2.sh
      unset CF_API_TOKEN
      ```

      Pass: last line `setup-r2: done`. It creates either bucket if absent, then sets and reads back:

      | Bucket | Lock | Lifecycle |
      |---|---|---|
      | Backups | `<repo path, no leading slash>/archive/main/18-`, 14 days | Abort incomplete multipart uploads after 7 days. No expiry: pgBackRest expires |
      | Dumps | Every object, 14 days | Delete after 30 days; abort incomplete multipart uploads after 7 days |

      It is safe to repeat, and each run replaces both buckets' rules. It refuses (exit 2, before any request) a lock
      that is not shorter than the backup retention or the dump expiry: `expire` fails with 409 on a locked object.
      **Never lock the backup folders:** pgBackRest rewrites each backup's manifest while it runs, and a lock there
      makes every backup fail with 409.
   c. Create four R2 API tokens (R2, Manage API tokens), each scoped to **one** bucket:

      | Token | Permission | Bucket | Goes to |
      |---|---|---|---|
      | Server | Object Read & Write | Backups | `PGBACKREST_REPO_KEY`, `_KEY_SECRET` in `secrets/.env.postgres` |
      | Home VM restore | Object Read | Backups | `PGVERIFY_REPO_KEY`, `_KEY_SECRET` in `secrets/home-server.env` |
      | Home VM upload | Object Read & Write | Dumps | `PGVERIFY_DUMP_KEY`, `_KEY_SECRET` in `secrets/home-server.env` |
      | Developer refresh | Object Read | Dumps | an `aws` CLI profile on each dev machine ("Dev refresh from R2") |

      For R2's S3 API the access key id is the token's id and the secret is the SHA-256 of the token's value.
   d. **Delete the temporary token.** `setup-r2.sh` needs a new temporary token each time it runs again (the path
      switch in "Prove it"), and `setup-r2.sh --check` (read only) also needs one.
3. **(Shane, healthchecks.io)** Create `pg-backup` (1 day), `pg-health` (15 minutes) and `pg-restore-verified`
   (1 day), plus `HC_PGVERIFY_DEPLOY` for the VM's deploy timer. Set `pg-backup`'s grace **above the longest
   full backup**, not a flat 2 hours: read the longest full's start and stop in `pgbackrest info` and add
   margin (the unit allows 6 hours). Set up the Gmail filter and, if the plan has one, a phone push channel
   (see "Alerts").
4. Put the values in `secrets/.env.postgres` (shape: `deployment/postgres/.env.postgres.example`; passwords
   from `openssl rand -hex 32`; the cipher pass encrypts the repo, so losing it loses the backups) and in
   `secrets/home-server.env`. R2 values: `PGBACKREST_REPO_ENDPOINT` and `PGVERIFY_REPO_ENDPOINT` are
   `<account id>.r2.cloudflarestorage.com` with **no** scheme (pgBackRest's form); `PGVERIFY_DUMP_ENDPOINT` is
   `https://<account id>.r2.cloudflarestorage.com` (the aws CLI's form); every region is `auto`. Edit with `sops secrets/.env.postgres`, read with
   `sops -d secrets/.env.postgres`, never pass `--input-type`. Use a **pre-production** `PGBACKREST_REPO_PATH`
   until "Prove it" is done. `POSTGRES_CLIENTS` is `role database address` entries separated by semicolons,
   allowed pairs `the_greatest the_greatest`, `tgb_app tgb`, `tgb_reader tgb`, single host addresses only.
   Use each server's IPv4 address: the port binds IPv4 only.
5. Merge the encrypted file before the first workflow run.
6. **(Shane)** `terraform apply`:

```bash
cp deployment/terraform/postgres/terraform.tfvars.example deployment/terraform/postgres/terraform.tfvars   # fill in
terraform -chdir=deployment/terraform/postgres init
terraform -chdir=deployment/terraform/postgres apply
terraform -chdir=deployment/terraform/postgres output -raw ipv4
terraform -chdir=deployment/terraform/postgres output -raw ipv6      # ends in /128; strip it by hand
```

   The first `authorized_keys` entry must match the `DEPLOY_SSH_KEY` secret, as for OpenSearch.
7. `ssh deploy@<pg-ipv4> cloud-init status --wait`, then set the secrets:

```bash
ssh-keyscan -t ecdsa <pg-ipv4> 2>/dev/null | ssh-keygen -lf - | awk '{print $2}'
gh secret set POSTGRES_SSH_HOST --body <pg-ipv4>
gh secret set POSTGRES_SSH_HOST_FINGERPRINT --body '<SHA256:...>'
```

   Before the first deploy the boot firewall is deny-all. `ssh deploy@<pg-ipv4> sudo iptables -S DOCKER-USER`
   must show the `--ctstate DNAT` drop rule and no `-s` address.

## First deploy

Run the workflow (`gh workflow run deploy-postgres.yml`, or Actions, "Deploy Postgres"). It pulls `main`,
decrypts the secrets and runs `deployment/postgres/bin/deploy.sh`. It is manual only, so a merge never
restarts the database. The workflow times out at 30 minutes, which is fine for a deploy and **not** for a
restore.

`deploy.sh` is safe to repeat. In order: validate everything from SOPS before installing anything; install
the allowlist and firewall; generate the certificate (first run only); install `pg_hba.conf` and
`pgbackrest.conf`; look at the data directory and the backup repo; decide what to do (below); start
Postgres; wait for it; stanza; apply the roles; `pg_ctl reload`; `pgbackrest check`; install the backup and
health timers. Pass: the last line is `deploy: done`.

Command output from pgBackRest and Docker carries the bucket and endpoints, so `deploy.sh` never prints it:
a failure prints the step, the exit code, the bracketed error classes and the path of a root-only log,
`/srv/postgres/state/deploy.log` on the server.

### The bootstrap rule

A rebuilt server has a new system identifier, so pgBackRest refuses the old stanza. A server that started
empty against a real repo would look healthy and hold nothing. So `deploy.sh` decides from two facts:

| Data directory | Repo | Result |
|---|---|---|
| empty | no stanza | creates the cluster and the stanza (the first build) |
| empty | has a stanza | **refuses**, naming `POSTGRES_BOOTSTRAP`, unless you set it |
| present | any | normal deploy; `POSTGRES_BOOTSTRAP=restore` is refused (it would overwrite a live database) |
| unreadable | | stops; an unreadable repo is never read as "no stanza" |

`POSTGRES_BOOTSTRAP=restore` restores the latest backup, then starts. `POSTGRES_BOOTSTRAP=new-cluster`
starts a new, empty cluster and runs `stanza-upgrade`; the old backups stay listed under the old database id
until retention expires them. Once the cluster is registered, leaving `new-cluster` set is refused. Anything
else is exit 2.

**Check the repo path before any rebuild.** A wrong `PGBACKREST_REPO_PATH` on a working bucket reads as "no
stanza", and that is the one remaining way to start an empty database against a repo. Before a rebuild, run
`pgbackrest --stanza=main info` on the old server (or compare `PGBACKREST_REPO_PATH` with the value in
`secrets/.env.postgres` at the commit that was running). If the path is wrong, the deploy creates a stanza
at the wrong place and the real backups look absent.

### Restore runs over SSH, not the workflow

A restore plus WAL replay can take hours. The workflow's 30 minutes would kill it, and a killed deploy
leaves a half-restored directory (recovery: "A killed or failed restore", under "Rebuild"). `deploy.sh` waits `WAIT_TRIES_RESTORE` tries (default 4000, 3 seconds
each, about 3.3 hours) for Postgres to finish recovery after a restore. An ordinary start waits
`WAIT_TRIES` (200, about 10 minutes). Both are environment variables of `deploy.sh`; raise
`WAIT_TRIES_RESTORE` if a restore is known to be longer.

From the dev machine (`export SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt`):

```bash
ssh deploy@<pg-ipv4> 'umask 077; cat > ~/pg.env' < <(sops -d secrets/.env.postgres)
ssh -n deploy@<pg-ipv4> 'cd /home/deploy/apps/the-greatest && git pull --ff-only \
  && nohup env POSTGRES_BOOTSTRAP=restore deployment/postgres/bin/deploy.sh ~/pg.env > ~/deploy.out 2>&1 &'
ssh deploy@<pg-ipv4> 'tail -f ~/deploy.out'          # survives a dropped connection
ssh deploy@<pg-ipv4> 'rm -f ~/pg.env ~/deploy.out'    # when it has finished
```

`deploy.out` is safe to read: it holds what `deploy.sh` prints, which is already scrubbed. It ends in
`deploy: done`. A pass is that line plus `pgbackrest check` green and a successful `pg-backup` ping the next
morning.

## Verify

Run after every build or rebuild. Both modes must end with `all passed`.

From a laptop on an unfiltered network with IPv6 (not a hotel or office network, which can give a false
pass):

```bash
PG_IPV4=<pg-ipv4> PG_IPV6=<pg-ipv6> deployment/scripts/verify-postgres-lockdown.sh --outside
```

Each address first connects to port 22 as a control; if that fails the check fails, because a dropped 6543
proves nothing from a machine that cannot reach the server. Then 6543 must be a true drop (curl exit 28,
zero connect time); "refused" fails.

From each app server, once per login on that server, with that login's password:

```bash
PG_IPV4=<pg-ipv4> PGPASSWORD=<role password> deployment/scripts/verify-postgres-lockdown.sh --inside the_greatest the_greatest
PG_IPV4=<pg-ipv4> PGPASSWORD=<role password> deployment/scripts/verify-postgres-lockdown.sh --inside tgb_app tgb
PG_IPV4=<pg-ipv4> PGPASSWORD=<role password> deployment/scripts/verify-postgres-lockdown.sh --inside tgb_reader tgb
```

It checks that plaintext is refused by `pg_hba`, TLS connects, the login is refused on the other database,
it is not a superuser, and `postgres` cannot log in over the network. It uses `psql` if present, otherwise a
`postgres:18` container (`PG_CLIENT=psql|docker` forces one).

**These two modes are also the live proof of the firewall's DNAT test.** `test/firewall-netfilter_test.sh` runs
the real rules against real netfilter, but in a stand-in for Docker. Only the real server shows that the real
daemon's published port carries conntrack state DNAT: if it did not, `--outside` would connect instead of
being dropped. The third half, the container's own outbound connection, is step 4 of the move.

Two more checks the script does not make:

- **Root login is refused:** `ssh root@<pg-ipv4>` must be refused after the build.
- **Reboot probe.** The port must never answer from outside while the server boots. From a laptop; every
  value must be `000`:

```bash
while :; do curl -s -m 2 -o /dev/null -w '%{http_code} ' telnet://<pg-ipv4>:6543; sleep 1; done
ssh deploy@<pg-ipv4> sudo reboot      # in another terminal
ssh deploy@<pg-ipv4> systemctl show -p Requires,After docker.service   # postgres-firewall.service in both
```

## Prove it (before any real data)

Use the pre-production repo path and a small sentinel table. The local rehearsal
(`deployment/postgres/test/local-e2e-test.sh`) already exercised `deploy.sh` for real, the `pgbackrest info`
status codes 0, 1 and 2, `stanza-upgrade` for a new cluster over an existing stanza, and a restore onto a
fresh volume; this step repeats the parts that matter on the real server.

This proves `pg-backup`, `pg-health` and the backups bucket's lock. `pg-restore-verified` is proved at step 7 of
the move, because its VM does not exist until then. pgBackRest itself on R2 was proven on 2026-11-07 before any
server existed: `stanza-create`, `check`, a full, a differential, WAL archiving and a restore with replay all passed
with this repo's image and template, with the default URI style and region `auto` (spec §8.4). Backups and
`pg-health` work the same on R2 as on any S3 API; nothing in them changed.

On the server:

```bash
export POSTGRES_SUPERUSER_PASSWORD=unused-by-exec
c() { docker compose -f /home/deploy/apps/the-greatest/deployment/postgres/compose.yml "$@"; }
q() { c exec -T postgres psql -U postgres -X -At -v ON_ERROR_STOP=1 "$@"; }
q -d the_greatest -c "create table sentinel (id int primary key, note text)" -c "insert into sentinel values (1, 'before')"
```

1. **Backup.** `sudo systemctl start postgres-backup.service`, then `pgbackrest info` (below). Pass: a new label
   is listed and the `pg-backup` check shows a success ping. Wait for the `pg-health` check's first success ping
   as well (every 15 minutes).
2. **Restore to a chosen moment, on this same server.** Pick the moment, write a row after it, and push the WAL
   to the repo. The restore needs Postgres stopped, and `--delta` because the data directory is not empty:

   ```bash
   q -d postgres -c 'select now()'                # the chosen moment; keep the value
   sleep 2
   q -d the_greatest -c "insert into sentinel values (2, 'after')"
   q -d postgres -c 'select pg_switch_wal()'
   sleep 10                                       # archiving is asynchronous; pg_stat_archiver shows it arrive
   c stop postgres
   c run --rm --no-deps -T postgres pgbackrest --stanza=main restore --delta \
     --type=time --target='<the chosen moment>' --target-action=promote
   c up -d --no-recreate postgres
   q -d postgres -c 'select pg_is_in_recovery()'  # repeat until f; replay takes as long as it takes
   q -d the_greatest -c 'select id from sentinel' # must print only 1
   ```

   Then run the workflow once: it must end in `deploy: done`, with `pgbackrest check` green on the new timeline.

   **Time it.** Note how long the `restore` command took. On R2 a tiny restore took about 3.5 minutes in the
   2026-11-07 test, nearly all per-request latency, so this figure says little about real data. The real-data
   figure comes from the first real night at step 7 of the move: record both here.
3. **Prove the lock refuses a delete of a fresh WAL object.** From the dev machine, with the **server's** token
   (the one with delete rights), against the newest WAL object in the pre-production archive. Both commands must
   fail with `ObjectLockedByBucketPolicy`:

   ```bash
   e() { sops -d secrets/.env.postgres | sed -n "s/^$1=//p"; }
   export AWS_ACCESS_KEY_ID="$(e PGBACKREST_REPO_KEY)" AWS_SECRET_ACCESS_KEY="$(e PGBACKREST_REPO_KEY_SECRET)"
   export AWS_DEFAULT_REGION=auto AWS_ENDPOINT_URL="https://$(e PGBACKREST_REPO_ENDPOINT)"
   b="$(e PGBACKREST_REPO_BUCKET)"; p="$(e PGBACKREST_REPO_PATH)"; p="${p#/}"
   key="$(aws s3 ls --recursive "s3://$b/$p/archive/main/18-" | sort | tail -n 1 | awk '{print $4}')"
   aws s3api delete-object --bucket "$b" --key "$key"   # must fail: ObjectLockedByBucketPolicy
   printf x | aws s3 cp - "s3://$b/$key"                # must fail too: a lock refuses overwrite
   unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_ENDPOINT_URL AWS_DEFAULT_REGION
   ```

   If either succeeds, the lock is not in place: re-run `setup-r2.sh`, and run step 2 again, because the
   pre-production archive has now lost or damaged a WAL file. Step 1's backup succeeding with the lock set is the
   proof that the lock does not cover the backup folders.
4. **Break a backup on purpose:** a wrong key in `/srv/postgres/config/pgbackrest.conf` for one run. It must raise
   the `pg-backup` alert. While the key is still wrong, a write and `select pg_switch_wal()` make archiving fail,
   and `pg-health` must alert within 15 minutes. **A test passes only when Shane has seen the alert.** The
   workflow renders the file again, which puts the key back; the next runs must ping success.
5. **Destroy and rebuild** with no SSH fix in between, following "Rebuild" with the pre-production repo path,
   and verify again.
6. **Drop the sentinel table:** `q -d the_greatest -c 'drop table sentinel'`. Left behind, `compare.sh` reports
   it at steps 8 and 13, because it exists only on the new server. Then set `PGBACKREST_REPO_PATH` to the real
   one and **run `setup-r2.sh` again with it and `R2_REPLACE_LOCK=1`** (a new temporary token, deleted afterwards,
   as in Build step 2). The lock's prefix follows the path, so without this the real WAL archive is unlocked;
   the override is needed because the run moves the live lock, which the script otherwise refuses. This is the
   only planned use of `R2_REPLACE_LOCK=1`. R2 locks are rules on the bucket, not marks on each object, so
   replacing the rule unlocks the pre-production prefix at once. Then delete the whole pre-production repo path,
   archive included, and confirm with `setup-r2.sh --check` that the lock is on the real prefix. From here
   `pg-backup` and `pg-health` run on the real path.

## The move: 17 to 18 by logical replication

The old server stays up and unchanged except as noted. **Do not merge anything to the old repo that touches
the database during this, and run no migrations on either app from step 5 until cutover is done.** Logical
replication copies no schema changes and no sequences. Ask Shane before each step; report exact outputs.

**The migration freeze lasts at least 8 days:** the copy at steps 5 and 6, seven straight passing nights at
step 7, then the cutover. Any failed night restarts the count, and the freeze runs on with it. Nobody has to
run a migration for this to go wrong: **a merged migration runs itself** through `db:prepare` when the app
deploys, so any migration merged during the freeze changes the source's schema and breaks replication. Tell
everyone who merges to either app before step 5.

### Where each script runs

All of `deployment/postgres/migration/` takes `DATABASE` first and reads `SOURCE_DSN` and `TARGET_DSN` (a
libpq string without `dbname` or password, plus `SOURCE_PGPASSWORD` and `TARGET_PGPASSWORD`). Exit codes: 0
fine, 1 the check ran and found a difference, 2 the script could not do its job. A failed query is never a
pass.

- **`TARGET_PSQL` is for the new server's superuser, and it needs the container's socket.** The superuser
  exists on the Unix socket inside the container only, never over the network, so run these scripts on the
  new server with
  `export POSTGRES_SUPERUSER_PASSWORD=unused-by-exec` (compose refuses to interpolate without it, even for
  `exec`) and
  `export TARGET_PSQL="docker compose -f /home/deploy/apps/the-greatest/deployment/postgres/compose.yml exec -T postgres psql -U postgres"`.
  The script appends `-d DATABASE` itself, so the value is split on spaces and must not be quoted.
- **`load-schema.sh` ignores `TARGET_PSQL`** on purpose (loading as the superuser would make it the owner of
  every object). It needs `TARGET_DSN` as the database's **owner role**, and `pg_hba` admits that login only
  from its own listed address. So run it from the host listed in `POSTGRES_CLIENTS` for that role: the new
  app server for `the_greatest`, the old site's server for `tgb_app`. It also needs `SOURCE_DSN` from there,
  which is why step 4's temporary `postgres` rule admits those hosts as well as the new server.
- **Postgres clients.** Neither the new server's host nor the app servers are known to have `psql` and
  `pg_dump`. Where a host has none, put wrappers named `psql` and `pg_dump` on `PATH` that run a `postgres:18`
  container: `docker run --rm -i --network host -e PGPASSWORD -e PGCONNECT_TIMEOUT=15 postgres:18 psql "$@"`
  (and likewise `pg_dump`). `-i` matters: `load-schema.sh` pipes SQL on stdin. The rehearsal used such wrappers.
  Version: `pg_dump` must not be older than the server it reads (17), so 17 and 18 both work for the schema
  dump, and the output loads into 18. A client 17 against the 18 target also works. The version rule that
  does bite is the other direction: `pg_restore` cannot read a dump from a newer `pg_dump` (the dev database
  restore, below).
- **Reaching the old server as an admin.** `SOURCE_PSQL` cannot be an `ssh` command (psql's `-c "…"` loses its
  quoting through ssh), so the scripts connect over the network: step 4 adds a temporary `hostssl` rule for
  `postgres`, limited to the new server's address and the app hosts that run `load-schema.sh`, and step 16
  removes it. On the new server, and likewise on those app hosts for `load-schema.sh`:

  ```bash
  export SOURCE_DSN="host=<old-host> port=<old-port> user=postgres sslmode=require"
  export SOURCE_PGPASSWORD=<old postgres password>     # read it without echoing, e.g. read -rs
  export REPLICATION_HOST=<old-host>                   # how the NEW server reaches the OLD one
  export REPLICATION_PORT=<old-port>                   # only if it is not 5432
  ```

### Phase 0: prerequisites

1. **Old repo (private).** Pin `postgres:17` to the digest of the image now running and remove the `pull db`
   and `up -d db` steps from its deploy workflow. Before merging the branch that reads the connection from
   the environment (branch `postgres-env-config`):
   - set `TGB_DB_HOST`, `TGB_DB_PORT`, `TGB_DB_USERNAME`, `TGB_DB_PASSWORD`, `TGB_DB_SSLMODE` and
     `POSTGRES_PASSWORD` in `.env` on **both** old-site hosts, with today's values, and diff against a backup
     copy of `.env`;
   - run `docker compose -f docker-compose.prod.yml config` against each real `.env` (it must parse, and the
     connection values must come from that `.env`);
   - confirm the image build passes: no `docker build` was run when the branch was written. `bin/setup` was
     not checked either.

   Then Shane merges. Pass: the old site works and the database container's start time (`docker inspect`) is
   unchanged.
   **Optional, Shane decides:** rotate the old server's `postgres` and `the_greatest` passwords now, as routine
   housekeeping, rather than at the move, if the move is weeks away. Change `.env` on the old site, the new
   app's `LEGACY_BOOKS_PASSWORD` and `POSTGRES_PASSWORD` in SOPS, change them in Postgres, restart both apps at
   a quiet time.
2. **The new app pins its legacy connection.** `web-app/config/database.yml` falls back to `POSTGRES_HOST`,
   `POSTGRES_PORT`, `POSTGRES_USER` and `POSTGRES_PASSWORD` for `LEGACY_BOOKS_HOST`, `LEGACY_BOOKS_PORT`,
   `LEGACY_BOOKS_USER` and `LEGACY_BOOKS_PASSWORD`, and `LEGACY_BOOKS_DATABASE` has its own default
   (`the_greatest_books`). Before `POSTGRES_*` is touched, set **all five** `LEGACY_BOOKS_*` explicitly, in
   `secrets/.env.production` and on each host that runs `web` or `worker`, to today's values. Otherwise moving
   `the_greatest` repoints the legacy connection too.
   **Dev and CI on 18** are merged. The dev database itself must be on 18 before step 7's refresh proof (see
   "Dev database").
   The new app's database variables are already environment-driven and unset means the driver default.

### Phase 1: the new server

3. Build, prove, rebuild (the sections above) with `pg-backup` and `pg-health` running on the real path.
   Before relying on silence alerts, **see both of those checks ping once** (Alerts, below).
   `pg-restore-verified` waits for step 7.

### Phase 2: copy

4. **Old-server restart, a few seconds, at a quiet time Shane picks.** The move requires these on the old
   server: `wal_level=logical`, TLS with a self-signed certificate (`ssl=on`) and `max_slot_wal_keep_size=20GB`,
   plus two `hostssl` rules for the move. One is for the `replicator` role on **both** `the_greatest` and `tgb`, from the new
   server's address only (a subscription's connection matches on the real database name, not on
   `replication`). The other is **temporary**, for `postgres` on the databases the scripts use (`postgres`,
   `template1`, `the_greatest`, `tgb`: `check-schema.sh all` visits every database that accepts connections), from
   the new server's address and the app hosts that run `load-schema.sh`. Step 16 removes both. Restart its
   database container. Without the cap, a stuck slot could fill the old server's disk. How the old server is
   edited is in the private old-site notes. Pass:

   ```bash
   psql … -Atc 'show wal_level'                  # logical
   psql … -Atc 'show max_slot_wal_keep_size'     # 20GB
   psql … -Atc 'show ssl'                        # on
   ```

   and both apps' logs show brief connection errors that end on their own. If either app stays down, stop
   and tell Shane; the rollback is to revert this step's changes and restart again.

   **Then prove the new server's firewall lets the subscription out.** This is the live half of
   `test/firewall-netfilter_test.sh`: `CREATE SUBSCRIPTION` runs inside the container, so its connection passes
   through `DOCKER-USER`. On the new server, inside the container:

   ```bash
   docker compose -f /home/deploy/apps/the-greatest/deployment/postgres/compose.yml exec -T postgres \
     pg_isready -h <old-host> -p <old-port>      # accepting connections, exit 0
   sudo iptables -S DOCKER-USER                  # both port rules carry --ctstate DNAT
   ```

   Then re-run `verify-postgres-lockdown.sh --outside`: 6543 must still be dropped. If `pg_isready` says no
   response, stop before step 5. `sudo iptables -L DOCKER-USER -v -n` shows whether the drop rule's counter
   rises; if it does not, the block is on the old server's side.
5. **Freeze migrations on both apps and tell Shane.** Then for `the_greatest` and `tgb`, in this order:
   `check-schema.sh all` on the source (an `UNEXPECTED` or `MISSING` line stops the move and goes to Shane;
   `postgres` and `template1` must have no functions, triggers, extensions or event triggers), then
   `load-schema.sh DB` (from that database's app host, see "Where each script runs"), then
   `check-schema.sh DB --target`, then
   `create-replication.sh DB` (with `SOURCE_DSN`, `SOURCE_PGPASSWORD` and `REPLICATION_HOST` exported as above).
   **Generate `REPLICATOR_PASSWORD` once** (`export REPLICATOR_PASSWORD=$(openssl rand -hex 32)`) and keep the
   same value for both databases and for the drop: each `create` runs `ALTER ROLE replicator ... PASSWORD`, so a
   fresh value for the second database changes the password the first subscription is already using and breaks
   it. The password sits in `pg_subscription.subconninfo` until the subscription is dropped.
   `create-replication.sh` refuses unless the old server has `wal_level=logical` and a slot cap. The publication
   excludes `pghero_query_stats`, `ol_editions` and `ol_works`, and `ol_editions` and `ol_works` must be empty
   on the source. Pass for each:
   exit 0 and the line `subscription … created`. Watch the old server's disk.
6. **Initial copy.** Pause heavy imports. `wait-catchup.sh DB --initial` (up to 7200 s, `WAIT_TIMEOUT`) exits
   0 when every table is ready. Then, on the new server, `ANALYZE` both (a logical copy carries no planner
   statistics): `$TARGET_PSQL -d the_greatest -c ANALYZE` and the same for `tgb`. A unique-index failure
   during the copy would show a text index corrupted by the old server's library change: fix the row on the
   source and record it.

   **`pg-health` may report `WAL archive stuck over 15 min` during the copy.** The copy writes WAL on the new
   server faster than one archiver pushes it, so a finished file can wait over 15 minutes although nothing is
   wrong. It is lag, not a failure, if `archived_count` keeps rising and `failed_count` stays flat:
   `$TARGET_PSQL -d postgres -c 'select archived_count, failed_count from pg_stat_archiver'`. Leave it; the alert
   clears once the archiver catches up. Watch the disk, which is the real limit: if it passes 80% (the check
   alerts on that too), `ALTER SUBSCRIPTION migration_sub_DB DISABLE` in that database on the new server until archiving
   catches up, then `ENABLE`. A rising `failed_count` is a real failure: treat it as the `pg-health` section says.
7. **The nightly restore check starts and must pass 7 nights in a row before cutover.** New writes will depend
   on this chain alone from the moment of cutover, so it is proven first. **This requirement is not negotiable.**

   (Shane) Set `PGVERIFY_ENABLED=1`, `HC_PGVERIFY` and the other `PGVERIFY_*` values in
   `secrets/home-server.env`, and run `provision`, on `REPO_REF=main`. It creates VM 140 with a 400 GB data disk,
   so check `DATA_STORAGE` has the room first. Until this flag is set provision neither creates the VM nor starts
   its timer, and it refuses a blank `HC_PGVERIFY`.

   **The dump upload goes on now, with the check.** The dumps go to their own R2 bucket, so they cannot collide
   with the old server's dumps in the old S3 bucket, which dev keeps reading until cutover. In the same
   `secrets/home-server.env`: `PGVERIFY_UPLOAD_ENABLED=1`, `PGVERIFY_DUMP_BUCKET`,
   `PGVERIFY_DUMP_ENDPOINT=https://<account id>.r2.cloudflarestorage.com`, `PGVERIFY_DUMP_REGION=auto`, and the
   upload token as `PGVERIFY_DUMP_KEY` and `_KEY_SECRET`. The VM passes the endpoint and region to its `aws`
   container as `AWS_ENDPOINT_URL` and `AWS_DEFAULT_REGION`. Both the run and `provision` refuse an upload with no
   endpoint or one without `https://`. **A failed upload pings `fail`, so it is a failed night and resets the
   7-night count**, like any other failure.

   **Before the 7 nights start, prove the alert,** on the VM (`ssh pve-mini`, then to `10.20.0.20`):

   ```bash
   sudo sed -i.bak 's|^PGVERIFY_REPO_PATH=.*|PGVERIFY_REPO_PATH=/does-not-exist|' /etc/the-greatest/home-server.env
   sudo systemctl start pg-restore-verify.service     # exits non-zero: the repo has no archived WAL
   sudo mv /etc/the-greatest/home-server.env.bak /etc/the-greatest/home-server.env
   ```

   **A test passes only when Shane has seen the alert.** Then start one real run,
   `sudo systemctl start --no-block pg-restore-verify.service`, and wait for its first success ping, which
   clears the alert. **Record that run's restore time on real data from R2**
   (`journalctl -u pg-restore-verify.service` shows when `restoring from an empty data directory` started and
   when Postgres came up), next to the "Prove it" figure, and in the spec's §8.4. A never-pinged check may not
   alert on silence (Alerts, below). The count starts with the next scheduled run.

   **After the first night with the upload on, check it** from the dev machine with the developer refresh token
   (the `r2-dumps` profile, "Dev refresh from R2"): both of that night's dumps must be listed.

   ```bash
   aws --profile r2-dumps --endpoint-url https://<account id>.r2.cloudflarestorage.com \
     s3 ls s3://<dumps bucket>/ | sort | tail -n 2
   ```

   Optionally, prove the whole dev path once by setting the `BACKUP_*` values on the command line. The script
   sources `.env` after the command line, so `.env` wins for anything it sets: comment out `BACKUP_BUCKET` (and
   any other `BACKUP_*`) there for this one run, and put it back afterwards. It replaces the dev database, so it
   needs Shane's go-ahead, and dev must already be on 18 (`pg_restore` 17 cannot read these dumps):

   ```bash
   BACKUP_BUCKET=<dumps bucket> BACKUP_ENDPOINT=https://<account id>.r2.cloudflarestorage.com \
     BACKUP_AWS_PROFILE=r2-dumps bin/refresh-dev-db.sh
   ```

   Count only nights where `pg-restore-verified` shows a success ping that Shane has seen. Any fail ping,
   including a row-count alert, resets the count to zero; the row-count baseline is the previous night, so
   hold heavy book imports while counting.
8. **Compare, at a quiet time, with the important tables named.** Only a frozen source and an idle target
   give a clean row check, and the sites are live here, so the verdict is advisory (the script says so). Name
   the tables that matter, preferring rarely written ones as the proof:

   ```bash
   CHECKSUM_TABLES="public.books_books public.music_albums public.music_songs public.games_games public.users" compare.sh the_greatest
   CHECKSUM_TABLES="public.books public.authors public.user_list_books public.users" compare.sh tgb
   ```

   Without `CHECKSUM_TABLES`, the sample is the `CHECKSUM_COUNT` (5) largest tables. Checksums read every row,
   and each table's duration is printed per side: **time them on real data.** A difference on a table being
   written to (`users`) is expected and not a verdict; a difference on a table nobody wrote is real. Also
   check counts per table and `max(id)`: the script does both. Then **the old site's connection test**, from
   its production server, with a one-off container of the old site's current image and the new server's
   values and `tgb_app`:

   ```bash
   docker compose -f docker-compose.prod.yml run --rm --no-deps \
     -e TGB_DB_HOST=<pg-ipv4> -e TGB_DB_PORT=6543 -e TGB_DB_USERNAME=tgb_app \
     -e TGB_DB_PASSWORD=<tgb_app password> -e TGB_DB_SSLMODE=require \
     worker bin/rails runner '<reads, PgHero live pages if reachable, and a write inside a transaction you roll back>'
   ```

   A problem here costs nothing; at step 15 it could cost the rollback. The new app's equivalent runs from
   its server with `rails runner` using `tgb_reader` via `LEGACY_BOOKS_*`, including the reads `finish_legacy`
   and the Goodreads rake tasks make, which must be confirmed read-only rather than assumed.

### Phase 3: cutover

**The 7 straight passing nights (step 7) must be complete before step 9.** Shane picks a day that is not a
Sunday, starting about 10:30 UTC: after the old dump ends and the new server's 09:00 backup has finished,
never during either. Do one database at a time. Have the timer ready.

**One SOPS PR per database, each holding only that database's variables:** `POSTGRES_*` for `the_greatest`,
`LEGACY_BOOKS_*` for `tgb`. Both must be reviewed and **not yet merged**. A single PR would be merged after the
first database and would deploy the second database's new values to `.env`, while that database still takes
writes on the old server: those writes would be lost. Encrypted files conflict: once the first PR merges,
redo the second one's edit with `sops` on top of `main` and have it checked again before its database's window.
**Hold every other merge to `main` for the window:** a merge deploys, and a deploy overwrites `.env` with
SOPS's values.

9. Confirm no import is running and neither backup is. Remove the old server's backup cron (the last
   pre-cutover dump stays; the rollback is to put the cron back). Stop Sidekiq for the affected app: for
   the new app `docker compose -f docker-compose.prod.yml stop worker`, and
   `docker compose -f docker-compose.prod.yml up -d worker` to start it again at step 15. The old site's
   equivalents use its own service names. Stop the PgHero cron for `tgb`.
10. `set-readonly.sh DB on`. **Start the timer.** It sets `default_transaction_read_only` on the database and
    terminates its sessions; reads keep working, writes error. Exit codes are explained under "Rollback".
11. `wait-catchup.sh DB` (reads the old server's WAL position once and waits for the slot to reach it, 300 s
    by default). It refuses unless the source reports read-only.
12. `sync-sequences.sh DB`. Sets every sequence to the old server's exact value and `is_called`, then reads
    each back and checks it is at or past its column's `max(id)`. **Run it only before the app moves to the
    new server:** after the app writes there, its sequences are ahead, and a rerun refuses (exit 1) rather
    than hand out ids that exist. `--allow-backward` is for when you are certain nothing has written.
13. `compare.sh DB --counts-only`, **with `CHECKSUM_TABLES` unset**: it overrides `--counts-only`, and
    checksums read every row inside the window. Pass: `identical on both servers`, exit 0. **Then record the
    target's write count; the rollback needs it:**
    `$TARGET_PSQL -d DB -Atc 'select sum(n_tup_ins+n_tup_upd+n_tup_del) from pg_stat_user_tables'`.
14. Switch the app. **New app:** edit `.env` on **each host that runs `web` or `worker`**, then
    `docker compose -f docker-compose.prod.yml up -d web worker` there (a deploy takes too long for this
    window). This is a hand edit: **until this database's SOPS PR is merged, any deploy overwrites `.env` and
    points the app back at the old server**, which is why other merges are held. The PR is merged only after
    step 15's checks. For `the_greatest`:
    `POSTGRES_HOST=<pg-ipv4>`, `POSTGRES_PORT=6543`, `POSTGRES_DATABASE=the_greatest`,
    `POSTGRES_USER=the_greatest`, the new password, `POSTGRES_SSLMODE=require`. The five `LEGACY_BOOKS_*` were
    pinned in Phase 0 step 2; check they are still set before saving. For `tgb`: `LEGACY_BOOKS_HOST`,
    `LEGACY_BOOKS_PORT=6543`, `LEGACY_BOOKS_DATABASE=tgb`, `LEGACY_BOOKS_USER=tgb_reader`,
    `LEGACY_BOOKS_PASSWORD`, `LEGACY_BOOKS_SSLMODE=require`. **Old site:** set the `TGB_DB_*` values in its
    `.env` on each host that runs `web`, `worker` or `cable`, and restart them.
15. Check reads and writes. **(Shane) A real sign-in and a real write on each site,** noting how many rows that
    write touched. Stop the timer and record the read-only time. Restart workers. **Then, and only then, merge
    this database's SOPS PR** (it deploys, with the same values the hand edit used), and confirm the app still
    points at the new server afterwards.
16. `create-replication.sh DB drop` (drops the subscription, which removes the slot, and the publication).
    Pass: no replication slot left on the old server and none on the new. After both databases are done, on the
    old server clean up the `replicator` role. `DROP OWNED BY` works per database and both are read-only by now,
    so opt the session out first, in each of `the_greatest` and `tgb`. Use two `-c` flags: a single `-c` with
    both statements runs them in one implicit transaction that is already read-only, and `DROP OWNED` is
    refused (`cannot execute DROP OWNED in a read-only transaction`).

    ```bash
    for db in the_greatest tgb; do
      PGPASSWORD="$SOURCE_PGPASSWORD" psql "$SOURCE_DSN dbname=$db" -X -v ON_ERROR_STOP=1 \
        -c 'SET default_transaction_read_only = off' -c 'DROP OWNED BY replicator'
    done
    PGPASSWORD="$SOURCE_PGPASSWORD" psql "$SOURCE_DSN dbname=postgres" -X -v ON_ERROR_STOP=1 -c 'DROP ROLE replicator;'
    ```

    Then remove both temporary-access rules from the old server (the `replicator` rule and the `postgres` rule
    from step 4, which also admits the app hosts) and reload it, unset `SOURCE_PGPASSWORD` and `REPLICATOR_PASSWORD`, run
    `check-schema.sh all --target`. Then switch dev's `.env` to R2 ("Dev refresh from R2", below): the old server
    stopped writing dumps at step 9, and the R2 dumps bucket has had them since step 7.

**The window.** The local rehearsal (`deployment/postgres/test/local-e2e-test.sh`, 2026-11-06) measured about
15 seconds per database for steps 10 to 13, on tiny data with Docker-run clients. **That does not predict the
real figure.** Catch-up and sequences scale with writes and table count, and the rehearsal had neither. The
real window must be measured at cutover. **If it passes 5 minutes, stop (`set-readonly.sh DB off`) and tell
Shane.** Regenerate the rehearsal figure with `deployment/postgres/test/local-e2e-test.sh`; it prints
`READ-ONLY WINDOW`.

### Phase 4: afterwards

17. Record hourly `pg_stat_statements` totals (time and calls per database) on the new server, in a file outside
    both databases so they never reach dev, and compare a Sunday full backup's hours with the same hours on
    other days. Pass: under 1.5x on two Sundays. If it fails, throttle the full or take it from a replica
    (spec §8.1). No repo code does the recording; use a host cron. `pg_stat_statements` exists only in `tgb`
    (`apply-roles.sh` creates it there), but its view covers every database through `dbid`, so one query in
    `tgb` is enough. The values are cumulative: subtract consecutive rows, and a drop means statistics were
    reset. This command has not been run against the real server; try it by hand once first.

    ```bash
    # /etc/cron.d/pgss-hourly, on the new server
    POSTGRES_SUPERUSER_PASSWORD=unused-by-exec
    0 * * * * root docker compose -f /home/deploy/apps/the-greatest/deployment/postgres/compose.yml exec -T postgres psql -U postgres -d tgb -At -F, -c "select now()::timestamptz(0), d.datname, sum(s.calls), round(sum(s.total_exec_time)) from pg_stat_statements s join pg_database d on d.oid = s.dbid group by d.datname" >> /srv/postgres/state/pgss-hourly.csv
    ```
18. Keep the old server read-only for 14 days, confirm nothing on its data volume is needed, then Shane deletes
    it. Remove `postgres/`, the `db` service and the backup script from the old repo, remove `tgb` from
    `DATABASES` in `pg-restore-verify.sh` when the old site shuts down, and remove
    `deployment/postgres/migration/` (see the last section). Then **retire AWS:** the old dump bucket stopped
    receiving dumps at step 9 and nothing reads it after the dev switch, so delete it and every AWS key, including
    the ones dev machines used for refreshes before cutover. This repo's code needs no AWS after that; check the
    account for anything else before closing it.

## Rollback

| Stage | Roll back with |
|---|---|
| Before step 10 | Nothing changes for the apps. If step 9 was already done, **put back the old server's backup cron it removed** (and the PgHero cron, and restart the stopped workers). To abandon: `create-replication.sh DB drop` for each database (a slot left behind holds WAL, capped at 20GB). The restarted old server can keep its new settings. |
| Steps 10 to 13 (read-only, not switched) | `set-readonly.sh DB off`, restart workers, and **put back the old server's backup cron removed in step 9** (and the PgHero cron). No data is lost. |
| Step 14 done, no real writes | **First re-run step 13's write-count query on the target and compare. Any rise beyond Shane's test write means real writes: fix forward, the next row.** Otherwise `set-readonly.sh DB off` on the old server **before** anything else, because `up -d` runs `db:prepare` and that needs the old server writable. Then point the app's environment back, `up -d`, restart workers, and put back the old backup cron. **Revert this database's SOPS PR if it was merged, or hold it unmerged**, or the next deploy points the app at the new server again. Do not rerun `sync-sequences.sh`. |
| After real writes on the new server | **Fix forward.** The old server is stale from then on. Reverse replication is not built: it is more risk than the case justifies. |

`set-readonly.sh DATABASE on|off`, exit codes:

| Code | Meaning for `on` | Meaning for `off` |
|---|---|---|
| 0 | Read-only set, every older client session ended | Setting removed, sessions ended |
| 1 | Refused before changing anything (a role sets its own `default_transaction_read_only`, or the login cannot see other roles' sessions), or a session would not end: **the window is not closed** | The setting could not be confirmed removed |
| 2 | Could not do it (bad input, failed query) | Same |
| 3 | not used | The setting **is** removed, but a session that started during the window would not end and may stay read-only: **restart the apps that use it** |

`off` is never blocked by the privilege check. Run by a role that cannot see other roles' sessions it still
removes the setting, warns, and exits 0 once it is gone: restart the apps. The setting applies only when a
session starts, which is why `off` terminates sessions again.

## Alerts

All three go through healthchecks.io: a fail ping alerts at once, silence alerts after the period and grace.
Ping URLs are credentials and live in SOPS only.

- **A never-pinged check may not alert on silence.** healthchecks.io may keep a check "new" until its first
  ping. Each of the three must be seen pinging once before silence is relied on: `pg-backup` and `pg-health` under
  "Prove it", `pg-restore-verified` at step 7 of the move.
- **`pg-backup` grace must exceed the longest full backup**, with margin.
- **An alert counts only when Shane has seen it.** In November 2026 an outage alerted correctly for over
  three days, unseen, because the email was filed as a newsletter. Before relying on these there must be a
  Gmail filter that keeps the three senders out of Promotions and Updates, and a phone push channel if the
  plan has one. A test of an alert passes only when Shane says he saw it.

On the server, a convenient handle (compose needs a value for the superuser password even for `exec`):

```bash
export POSTGRES_SUPERUSER_PASSWORD=unused-by-exec
pg() { docker compose -f /home/deploy/apps/the-greatest/deployment/postgres/compose.yml exec -T postgres "$@"; }
pg pgbackrest --stanza=main info
```

### `pg-backup`

**Means:** the daily backup failed, or did not report. Passes only if `backup.sh` exits 0 and `pgbackrest
info` lists a label that was not there before. Messages: `full|diff backup failed (exit N) [class]`;
`[050]` (another pgBackRest run holds the lock: a backup is still running, or a killed one left a process in
the container); `exited 0 but info shows no new backup`; `marked as having errors (page checksum errors)`;
`terminated before finishing`.

**First:** `sudo systemctl status postgres-backup.service` and `sudo journalctl -u postgres-backup.service -n
50`; the details are in `/srv/postgres/state/backup.log` (root only; the ping carries error classes only);
then `pg pgbackrest --stanza=main info`. A `[028]`-style class after a rebuild is a stanza that no longer
matches the cluster (the bootstrap section). Page checksum errors mean possible corruption: tell Shane, do
not just re-run. A 409 or `ObjectLockedByBucketPolicy` in `backup.log` means a lock covers more than the WAL
archive (a backup rewrites its own manifest) or, from `expire`, that the lock is not shorter than retention:
read the backups bucket's lock rule in the dashboard and re-run `setup-r2.sh`. **Silence:** the timer did not run (`systemctl list-timers postgres-backup.timer`; it is
not persistent, so a server that boots late skips the day), or a full outlasted the grace. Start one by hand
with `sudo systemctl start postgres-backup.service` (it can take hours; `TimeoutStartSec=6h`).

### `pg-health`

**Means:** every 15 minutes, no check failed. It fails on: `postgres not answering`; `archive_mode is X, not
on`; `archive_command is not the expected pgbackrest command`; `WAL archive stuck over 15 min` (a finished
WAL file has waited over 15 minutes); `archive failures rose A to B`; `disk N% full` (80% or more); and the
`could not …` forms, because a check that cannot answer is a failure. Archiving can break while the database
answers queries, so this is the check that catches it.

**First:** `pg pgbackrest --stanza=main check` and `pg psql -U postgres -c 'select * from pg_stat_archiver'`.
A bad token, a bucket problem or an R2 outage show as archive failures; fix the cause, and the alert clears on
the next passing run. **Disk is urgent when archiving is stuck:** unarchived WAL stays in `pg_wal` and will
fill the disk. Failures logged before `stanza-create` on a first deploy are normal; the counter's first run
stores a value and passes. Details: `/srv/postgres/state/health.log`.

### `pg-restore-verified`

**Means:** last night's restore of the real backup did not pass, so as of then **the newest backup is
unproven**. Each message names the step: `restore failed`, `recovery did not finish in time`, `latest
replayed transaction is N hours old` (over 26), `recovery stopped short of the archived WAL` (replay did not
reach the archive's newest segment, so recovery ended early or an `archive-get` failed), `database X is
missing`, `core table X is missing|empty`, `amcheck failed in X` (possible index corruption in production:
tell Shane at once), `not enough free disk for tonight's dumps: N GB free, M GB needed`, `pg_dump failed`,
`the dump of X is empty|unreadable`, `upload failed`, and `missing settings`.

**First:** on the VM (`ssh pve-mini`, then to `10.20.0.20`),
`journalctl -u pg-restore-verify.service -n 100`, and check `/mnt/pgverify` is mounted. If the cause is
production's repo (a bad key, a path change), `pg pgbackrest --stanza=main info` on the server. If a restore
failed, a bad night is not a bad backup until the cause is known: the check can fail on its own side (disk
full, a killed run). The VM recovers from an interrupted run by restoring from empty.

**Free disk.** The data disk (400 GB) holds the restored cluster and 26 sets of dumps. Each success ping and
the journal report the free space, and a night with less free than its newest set of dumps fails before
dumping. Grow the disk, or look for dumps of a dropped database (they are no longer pruned).

**Row counts.** A message `dumps completed; row counts moved over 5%: db.table` is a row-count
alert, not a failed restore: the dumps still completed. It means a core table over 10,000 rows (in either
night's count) moved more than 5% since the previous night. **Bulk changes in books data are normal**
(imports, merges, the Goodreads replay, the weekly legacy sync), so first ask whether someone did one. If so,
no action: the baseline is replaced every night, so one change alerts once and clears itself. If nobody
did, treat it as possible data loss: compare the table's count on production now with the last daily dumps
in `/mnt/pgverify/dumps/daily/`, and tell Shane. The alert resets the 7-night count before cutover.

**Silence:** the VM is down or its timer did not run (`Persistent=true`, so a VM that was down at 12:00 UTC
runs on return). A held lock logs and exits without pinging; the next run reports.

## The home VM

`pgverify` (VM 140, `10.20.0.20`, isolated bridge, SSH only from the Proxmox host) runs the nightly check.
Everything about it, including what each run does, the safety by construction and its env keys, is in
`docs/features/home-server.md`, "The Postgres restore check". What the runbook adds:

- It does not exist until `PGVERIFY_ENABLED=1` (step 7): a plain `provision` and `--verify` leave it alone.
- Its key on the repo is read-only and every restore passes `--archive-mode=off`: nothing restored can write
  to production's repo.
- The upload of dumps to the R2 dumps bucket goes on at step 7, with the restore check. A failed upload is a
  failed night. Dev keeps reading the old server's dumps from the old S3 bucket until step 16 switches its `.env`.
- Rebuild the VM with `provision --rebuild pgverify` (the data disk, and so the dumps, is kept).
- Two items from the build to settle when the VM first runs: `provision --verify` and the compile of
  `140.fw` need a real host; and the VM's firewall keeps IPv6 link-local, which should be a deliberate choice.
- When the old site shuts down, remove `tgb` from `DATABASES` in the script and delete its old dumps by hand.

## Routine operations

### Add an app server

```bash
sops secrets/.env.postgres        # add a role database address entry to POSTGRES_CLIENTS
```

Commit, merge, run the workflow. Give the server's IPv4 address: the port binds IPv4 only, and an IPv6 entry
warns and can never connect. A bad entry fails before anything is installed and leaves the live
allowlist alone. Removing an address stops new connections only: the firewall's `ESTABLISHED,RELATED` rule
lets open ones finish; `sudo conntrack -D -s <ip>` cuts them. Run `--inside` from the new server.

### Rotate a password

Put a new one (`openssl rand -hex 32`) in `secrets/.env.postgres`, merge, run the workflow. `apply-roles.sh`
runs `ALTER ROLE` with no restart, and the password never appears in a process's arguments. The app's copy
is in `secrets/.env.production` (or the old site's `.env`) and changes at a different moment, so connections
fail until both sides match: put both in one merge, and run the workflow as soon as the app deploy finishes.

### Upgrade a minor version

Change the `FROM` digest in `deployment/postgres/Dockerfile` (the file says how), run
`deployment/postgres/test/local-e2e-test.sh`, merge. The workflow's `deploy.sh` then **stops with exit 3**
and says a restart is needed, because the image or the Postgres config changed. At a quiet time, re-run it
by hand with `POSTGRES_ALLOW_RESTART=1` in place of `POSTGRES_BOOTSTRAP=restore` in the restore command above. The restart takes
Postgres down for the length of a shutdown checkpoint (the compose grace is 120 s).

### Restore to a chosen moment on a fresh server

1. Build the server (Build, steps 6 and 7) and run the workflow. It installs the config and firewall, then
   **refuses** because the data directory is empty and the repo has a stanza. That is expected.
2. On the server, restore (`PGBACKREST_REPO_PATH` must be the path of the backups; a wrong one reads as "no
   stanza"). This can take hours, so run it where a dropped connection cannot kill it (`nohup`, as under
   "Restore runs over SSH"):

   ```bash
   export POSTGRES_SUPERUSER_PASSWORD=unused-by-exec
   docker compose -f /home/deploy/apps/the-greatest/deployment/postgres/compose.yml run --rm --no-deps -T postgres \
     pgbackrest --stanza=main restore --type=time --target='2026-11-06 10:00:00+00' --target-action=promote
   ```

3. Run the workflow again with no `POSTGRES_BOOTSTRAP`. The data directory is now present, so it starts
   Postgres, applies roles and checks archiving. **Postgres replays WAL up to the chosen moment first, and that
   can outlast the wait.** `deploy.sh` gives it `WAIT_TRIES` (about 10 minutes), then fails with `did not become
   ready` while the container keeps recovering. Nothing is lost: run the workflow again until it ends in
   `deploy: done`, or run `deploy.sh` over SSH with `WAIT_TRIES=4000`. Confirm the data, for instance that a row
   written after the chosen moment is absent. The restore can only go back to a moment inside the 30-day retention.
   The same-server form, which stops Postgres first and needs `--delta`, is under "Prove it".

## Rebuild

The recovery plan when the server is lost or has to be replaced (spec §3): restore plus a rebuild. Writes
since the last archived WAL are gone, at most about 5 minutes with `archive_timeout=300`. Each step needs
Shane's go-ahead. If the old server still answers, stop the apps' writes to it first, because `-replace` destroys
its disk.

1. **Check `PGBACKREST_REPO_PATH` first.** A wrong path on a working bucket reads as "no stanza", and the deploy
   would start an empty database. The value in `secrets/.env.postgres` must equal `PGVERIFY_REPO_PATH` in
   `secrets/home-server.env`, which the nightly restore has been proving: compare the two with `sops -d`. Before
   the VM exists (the "Prove it" rebuild), check it against the pre-production path the first deploy used.
2. **(Shane)** `terraform -chdir=deployment/terraform/postgres apply -replace=linode_instance.postgres`, then read
   the new addresses (`output -raw ipv4`, `output -raw ipv6`).
3. `ssh deploy@<pg-ipv4> cloud-init status --wait`, and confirm the boot firewall is deny-all (Build, step 7).
4. Update `POSTGRES_SSH_HOST` and `POSTGRES_SSH_HOST_FINGERPRINT` (commands in Build, step 7): a rebuild changes
   both, and the workflow refuses to connect until they match.
5. **Restore, over SSH, with `POSTGRES_BOOTSTRAP=restore`:** the commands under "Restore runs over SSH". The
   variable sits on that one command line and nowhere else, so it is unset for every later run. Never put it in
   SOPS. A kill or a failure part way is handled below.
6. **Verify lockdown:** both modes of "Verify", against the new address. Do this before any app points at it.
7. **Point the apps at the new address.** Change `POSTGRES_HOST` and `LEGACY_BOOKS_HOST` in `.env` on each host
   that runs `web` or `worker` and `up -d web worker` there, then put the same values in `secrets/.env.production`
   by PR, or the next deploy points the app back. On the old site, change `TGB_DB_HOST` in `.env` on each host that
   runs `web`, `worker` or `cable`, and restart them. The certificate is new too, which `sslmode=require` does not
   mind.
8. **Allowlists.** `POSTGRES_CLIENTS` names the app servers, so replacing this server changes nothing there. If an
   app server was replaced as well, update it and run the workflow. Anything else that names this server's old
   address, such as an outbound rule on an app host, gets the new one. The home VM reads the bucket, not this
   server, so it needs no change.
9. **Run the workflow once with no `POSTGRES_BOOTSTRAP`.** It must end in `deploy: done`, which proves the
   ordinary path on the rebuilt server.
10. **First backup:** `sudo systemctl start postgres-backup.service`, a new label in `pgbackrest info`, a success
    ping on `pg-backup`, and on `pg-health` within 15 minutes.
11. **Check the restore VM.** The next 12:00 UTC run must ping `pg-restore-verified`. Lost writes can raise a row-
    count alert once; that is expected only if the numbers match what was lost.

### A killed or failed restore

A killed `deploy.sh` leaves a half-restored data directory, and the next deploy does not fix it. Measured on
2026-11-07 with the real `deploy.sh`, compose file and image on a posix repo. pgBackRest writes the largest
files first, `PG_VERSION` near the end and `pg_control` last, so there are two states:

| Killed | `backup.manifest` / `PG_VERSION` | With `POSTGRES_BOOTSTRAP=restore` | With no bootstrap |
|---|---|---|---|
| Part way (the usual case) | present / absent | Exit 1, `pgbackrest restore failed (exit 40) classes: [040]`: the path is not empty | Refused: "the data directory is empty". **That message is misleading here:** it only looks for `PG_VERSION` |
| Near the end | absent / present | Refused: "would overwrite a live database" | Starts Postgres, which restarts in a loop on `could not find pg_control`. The deploy fails with `did not become ready` |

Neither state starts an empty or partial database, because `pg_control` is written last. One command gets out of
both, so `deploy.sh` has no special path for it. On the server:

```bash
export POSTGRES_SUPERUSER_PASSWORD=unused-by-exec
c() { docker compose -f /home/deploy/apps/the-greatest/deployment/postgres/compose.yml "$@"; }
# Killing the client leaves the one-off container running the restore. Remove it, so nothing else is writing.
docker ps -q --filter label=com.docker.compose.project=postgres-server --filter label=com.docker.compose.oneoff=True | xargs -r docker rm -f
c stop postgres
nohup docker compose -f /home/deploy/apps/the-greatest/deployment/postgres/compose.yml run --rm --no-deps -T postgres \
  pgbackrest --stanza=main restore --delta > ~/restore.out 2>&1 &      # checksums what is there, fetches the rest
```

When that exits 0 (`restore.out` can name the bucket, so do not paste it anywhere; remove it afterwards), run the
deploy with **no** `POSTGRES_BOOTSTRAP` and the long wait, as under "Restore runs over SSH" but with
`env WAIT_TRIES=4000` in place of `env POSTGRES_BOOTSTRAP=restore`. The data directory is now present, so it starts
Postgres and replays WAL. It ends in `deploy: done`.

## Dev database (after merge, needs Shane's approval)

Do this soon after the merge: until it is done, any `docker compose up` or `bin/refresh-dev-db.sh` recreates `db`
on 18 with an empty new volume until the refresh ends, while the 17 data sits in its old volume. The dev database
switch stops the shared dev server, so ask first and tell anyone using it. The procedure is in
`docs/dev_setup.md`, "Switching an existing checkout from Postgres 17 to 18"
(`bin/snapshot-dev-db.sh --label pre-pg18`, `docker compose stop db`, `docker compose up -d db`,
`bin/refresh-dev-db.sh --legacy`). **Outstanding, both:**

- `yarn test:e2e` on 18, after confirming port 3000 is yours (AGENTS.md);
- the `--legacy` restore on 18 (about 25 minutes or more).

`pg_restore` 17 cannot read a dump from a newer `pg_dump`, so dev must reach 18 **before** step 7's refresh
proof, and in any case before step 16 switches dev to the R2 dumps.

## Dev refresh from R2 (from step 16)

Until cutover `bin/refresh-dev-db.sh` reads the old server's dumps from the old S3 bucket with the default AWS
credentials, and nothing changes for it. The R2 dumps bucket fills from step 7; step 16 points dev at it. On each
dev machine:

```bash
aws configure --profile r2-dumps    # key id = the developer refresh token's id, secret = SHA-256 of its value, region auto
```

and in the root `.env` (gitignored):

```bash
BACKUP_BUCKET=<the R2 dumps bucket>
BACKUP_ENDPOINT=https://<account id>.r2.cloudflarestorage.com
BACKUP_AWS_PROFILE=r2-dumps
```

The script passes `--endpoint-url` and `--profile` to every `aws` call, and refuses a `BACKUP_ENDPOINT` without
`https://`; unset, it behaves as it always did. The
names are unchanged (`postgres_the_greatest_backup_*`, `postgres_tgb_backup_*`), so it picks the newest the same
way. The token is read-only: a dev machine cannot change or delete a dump.

## Remove the migration scripts

After the old server is deleted (step 18), remove `deployment/postgres/migration/`,
`deployment/postgres/test/migration_test.sh`, `deployment/postgres/test/local-e2e-test.sh`,
`deployment/postgres/test/docker-helpers.sh` and `.github/workflows/postgres-migration-tests.yml`, and drop the
"The move" and "Rollback" sections of this file. Then run the restore-to-a-moment drill once on a fresh
temporary server, and destroy it.

## Gotchas

- Never `systemctl restart postgres-firewall`. Docker requires that unit, so a restart restarts Docker and
  Postgres.
- Never publish a bare `6543:5432`; it makes docker-proxy listen on `[::]`, which `DOCKER-USER` never sees. It
  also means an IPv6 client cannot connect today, by design.
- The firewall's port rules match `--ctstate DNAT` on purpose. Without it they also drop the container's own
  outbound connection to a remote 6543, which is what `CREATE SUBSCRIPTION` makes to the old server.
  `deploy.sh` refuses to run if `POSTGRES_PORT` is set.
- A redeploy never restarts Postgres. Config or image changes exit 3 until `POSTGRES_ALLOW_RESTART=1`.
- The certificate directory is owned by the container's uid (999), because Postgres must read the key. It is
  generated once; the cert is self-signed, so clients use `sslmode=require` and do not verify it.
- `terraform output -raw ipv6` ends in `/128`; strip it before using it by hand.
- This repo is public. Server addresses, bucket names, the Cloudflare account id and ping URLs stay in SOPS,
  and `deploy.sh` keeps pgBackRest and Docker output out of the workflow log on purpose.
- R2 locks: only `<repo path>/archive/main/18-` in the backups bucket, and always shorter than the 30-day
  retention. A lock on backup folders fails every backup with 409; a lock at or past retention fails `expire`.
  A change of `PGBACKREST_REPO_PATH` needs `setup-r2.sh` again, or the new archive is unlocked.
- **A Postgres major-version upgrade moves the WAL archive** from `archive/main/18-…` to `archive/main/<new>-…`.
  Run `setup-r2.sh` with `PG_MAJOR=<new>` once the new archive exists. The script refuses to drop the `18-` rule
  until `R2_REPLACE_LOCK=1` is also set; doing so unlocks the old archive, which then matters only for a restore to
  a moment before the upgrade. `setup-r2.sh --check` shows the rule in force.
- `setup-r2.sh` refuses to drop, narrow, shorten or disable a live lock rule (exit 2, printing the old and new
  prefix and age). Read the output before reaching for `R2_REPLACE_LOCK=1`: an unexpected refusal usually means a
  wrong `PGBACKREST_REPO_PATH` or `R2_LOCK_DAYS` in the shell.
- Two endpoint forms: pgBackRest takes `<account id>.r2.cloudflarestorage.com` with no scheme; the aws CLI
  (`PGVERIFY_DUMP_ENDPOINT`, `BACKUP_ENDPOINT`) takes it with `https://`. `deploy.sh`, provision, the restore
  check and `refresh-dev-db.sh` each refuse the wrong form.
