# Postgres server: built from code, moved to 18, backups that prove themselves — design

**Date:** 2026-11-06
**Status:** awaiting Shane's review of this written spec
**Sequence:** second of three, after the OpenSearch server (`2026-10-13-opensearch-server-design.md`, whose patterns
this reuses) and before observability.

Decisions are marked **(Shane)** when he made them and **(my call)** when he has not been asked and can overrule
them. Measured facts are from the live server on 2026-11-06.

This repo is public. Server addresses, bucket names and details of the old server's security state stay in SOPS, the
private old-site repo and private notes. Keep them out of this file, the plan, the runbook, commit messages and PRs.

## 1. Why

Production Postgres runs on a hand-built server from 2023. It holds the only copy of user data for the old books
site and the new app, and music and games are live on it, so a failure is an outage. Four things need to change.

- **Nothing about it is reproducible.** Config lives partly in a repo and partly in hand edits on the server.
- **The access model should be explicit and written down.** On the new server only our app servers can open a
  connection, every connection is encrypted, and each app uses its own least-privilege login. Every role and
  password is created fresh; none is carried over from the old server.
- **Backups hurt the site.** A nightly `pg_dump` runs on the database server and took 49 minutes on 2026-11-06. Old
  site query time in that hour was about double normal on both days measured. The new site's slowdown was not
  measured. A 55 GB stats table has since been truncated, so the remaining cost is not yet known.
- **Backups have already failed silently.** Shane once had a restore script break without anyone noticing and found
  months later that he had no usable backups. Before retention existed he had over 1,000 files in S3 and a large
  bill. Retention is now 3 days, so any problem found on day 4 cannot be recovered. Nothing tests a restore or alerts
  on failure.

## 2. Goals and success test

- `terraform apply` builds the server and one manual workflow configures it, as for OpenSearch.
- Only our app servers can open a connection, always encrypted, each with a least-privilege login. **Decision made
  during implementation:** the port binds IPv4 only, so a client's IPv4 address is what counts: an IPv6 client can
  never connect. `render-hba.sh` warns on one without failing, and the firewall still loads IPv6 rules as a second
  layer, which the outside check probes.
- PostgreSQL 18, pinned, upgraded on purpose **(Shane: 18, not the 19 release candidate)**.
- The move costs minutes of read-only time per site, not an outage **(Shane: minimal downtime preferred, some is
  fine)**.
- Backups cause no site slowdown anyone notices, allow restore to any moment in the last 30 days, and clean up after
  themselves.
- **A backup counts only after it has been restored.** Any failed or missing backup, or failed restore check, sends
  an alert the same day.

**Success test (run, not claimed):**

1. Build, verify, destroy, rebuild and verify again, with no SSH session used to fix anything.
2. Restore a real backup on a freshly built server, to a chosen moment, and confirm the data.
3. Run a deliberately broken backup and a deliberately broken restore check, and receive both alerts.
4. Complete the cutover with the read-only time measured and both sites working.
5. During a real backup after cutover, query times stay within 1.5x of the same hour's normal.

## 3. Non-goals

- A standing replica or automatic failover. Recovery is restore plus a rebuild.
- Connection pooling. Connections today are about 35 against a limit of 200.
- Changing the locale. Both databases stay `en_US.utf8` so sort order does not change.
- Long-term archiving past the home server's monthly dumps (§9).
- Monitoring dashboards. The observability spec adds its agent to this server's cloud-init later.

## 4. Decisions

| Decision | Choice | Why |
|---|---|---|
| OS | Ubuntu 26.04 LTS | Same as OpenSearch |
| Postgres | Official `postgres:18` image at the newest minor on the day, pinned by digest, with pgBackRest at an exact version from the PGDG apt repo in a small `FROM` image. **Decision made during implementation:** PGDG's archive repo is added too, because its current index drops older versions, and `ca-certificates`, which the archive and the bucket's HTTPS endpoint both need **(my call)** | A floating tag has twice caused trouble on the old server: a surprise restart and a silent system library change that affects text sorting |
| Size | Linode 8 GB (4 cores, 160 GB), region `us-central`, as a variable **(my call)** | Same as today; about 24 GB of data once the stats table is gone |
| Storage | Instance disk only, no block storage volume | Portable. The current extra volume holds no live data |
| Terraform | Own root module, own state | As OpenSearch |
| Move method | Logical replication, 17 → 18 **(my call; Shane has seen the trade-off)** | Lowest downtime. A dump and restore would be simpler but read-only for an estimated 30–45 minutes. The data suits replication: §13.1 |
| Encryption | Self-signed certificate on the server, clients use `sslmode=require` | Same accepted gap as OpenSearch: no renewals or hostnames, but no protection against impersonation on the provider's network |
| Port | Keep 6543 **(my call)** | One less client difference. The firewall, not the port number, keeps people out |
| Backup tool | pgBackRest 2.60 or newer **(my call)** | Incremental, encrypted, restore to any moment, built-in retention. Supports 18 since 2.55. Its maintainer announced the end of the project in April 2026, then announced in May that it would continue with new sponsors; if that changes, WAL-G is the fallback |
| Backup storage | Cloudflare R2: a backups bucket for pgBackRest and a dumps bucket for the nightly dumps, with bucket locks **(Shane: R2, 2026-11-07; the two-bucket layout and the numbers are my call)** | No download charge for the nightly restore, one storage provider, and AWS retires after the move. Replaced the first choice, an S3 bucket with versioning. The cost is in §8.2: a compromised server can now destroy the pgBackRest backups, so the worst case is the nightly dump, about a day of writes. pgBackRest on R2 was proven on 2026-11-07 (§8.4) |
| Restore test | A new VM on the home server **(Shane: the home server is dependable enough)** | Also produces the dev dump, so production carries no dump load |
| Deploy | Manual `workflow_dispatch` | Merging to `main` must never restart the database |

## 5. Security

### 5.1 Firewall

The same design as OpenSearch §5.1: rules in `DOCKER-USER` for IPv4 and IPv6, matching the original port, installed
by a oneshot unit ordered before Docker, closed if the allowlist is missing or empty, and a renderer that fails the
deploy on bad input. `ufw` allows SSH only, with SSH keys only, fail2ban and unattended upgrades.

**Decision made during implementation:** both port rules also match conntrack state DNAT, so they apply only to
connections through the published port. This server has a container that connects out to a remote 6543 (`CREATE
SUBSCRIPTION` to the old server), and that traffic is forwarded through `DOCKER-USER` too. OpenSearch's copy has no
such traffic and stays as it is. Tested against real netfilter; real Docker daemon behaviour is proved on the server.

### 5.2 Logins

`POSTGRES_*` values live in a new `secrets/.env.postgres` with its own SOPS rule. Passwords are new, generated with
`openssl rand -hex 32`, and are never the old ones.

| Role | Can do | Used by |
|---|---|---|
| `postgres` | Superuser, Unix socket inside the container only, never over the network | Setup, pgBackRest, break-glass |
| `the_greatest` | Owns database `the_greatest`, no superuser | New app |
| `tgb_app` | Owns all objects in `tgb`, member of `pg_monitor` for PgHero, no superuser | Old site |
| `tgb_reader` | `SELECT` only on `tgb` | New app's `legacy_books` connection, read-only in code (`LegacyBooks::Record`) |

`pg_hba.conf` is rendered from SOPS values at deploy time, using one line per role, database and client address,
with `hostssl` and `scram-sha-256`. Each login works only from its own server and only on its own database. No `host`
(unencrypted) rule exists and no network rule names `all`. The local socket uses `peer`. The launch's separate worker
server is a SOPS edit and a workflow run.

### 5.3 Encryption

The first deploy generates a self-signed certificate into a host directory with 10-year validity. Later
deploys leave it alone. `ssl=on`, TLS 1.2 minimum.

**Decision made during implementation:** the directory is owned by the container's uid (999) with mode 0700, not
root-only, because Postgres refuses a key it does not own and has to read it.

### 5.4 What gets copied

Table data and a reviewed schema only, from `the_greatest` and `tgb`. Nothing is taken from the `postgres` or `template1`
databases, and a verify step confirms on the new server that all four databases have only the expected event triggers
(none), functions and extensions. Roles, role memberships, grants and ownership are not copied:
`pg_dump --schema-only --no-owner --no-privileges`. Before loading, compare functions, triggers and extensions
against the expected list (§13.1). An unknown object stops the migration and goes to Shane.

## 6. Postgres configuration

Keep Shane's tuning, which suits this size: `shared_buffers=2GB`, `effective_cache_size=6GB`, `work_mem=5242kB`,
`maintenance_work_mem=512MB`, `max_connections=200`, `wal_buffers=16MB`, `checkpoint_completion_target=0.9`,
`max_wal_size=4GB`, `min_wal_size=1GB`, `random_page_cost=1.1`, `effective_io_concurrency=200`,
`default_statistics_target=100`, the parallel settings, `shm_size: 1g`, and `pg_stat_statements` preloaded. The same
settings exist in both `postgresql.conf` and `postgresql.auto.conf` on the old server. The new server has only a
repo-owned config file and an empty auto file.

Add:

- `wal_level=replica`, `archive_mode=on`, and `archive_command` through pgBackRest.
- `archive_timeout=300`, so at most about 5 minutes of writes are lost if the server is destroyed **(Shane)**. Without it, a WAL file is only archived when it fills, and at quiet hours that can take a long time.
- `max_worker_processes=8`, because the subscription needs workers alongside parallel queries.
- `log_connections=on`, `log_disconnections=on`, `log_min_duration_statement=1000`, `log_lock_waits=on`,
  `track_io_timing=on`. Connection logs are what let access history be reconstructed later. Docker
  log rotation must keep at least 30 days or about 2 GB, whichever comes first **(my call)**.
- Data checksums, which the 18 `initdb` turns on by default. Verify this rather than assume it.

The `postgres:18` image stores data in `/var/lib/postgresql/18/docker` and declares its volume at
`/var/lib/postgresql`. Mount the parent. Mounting the old `/data` path puts data in the wrong place. `io_method` stays
at its default `worker`: `io_uring` needs a seccomp change for an unproven gain.

## 7. Build and deploy

```
deployment/terraform/postgres/       main.tf variables.tf cloud-init.yaml terraform.tfvars.example
deployment/postgres/
  Dockerfile  compose.yml  config/postgresql.conf  config/pgbackrest.conf.tmpl
  bin/deploy.sh  render-firewall.sh  render-hba.sh  generate-certs.sh  apply-roles.sh
  bin/backup.sh  check-backup-health.sh  setup-r2.sh (run once by Shane, §8.2)
  systemd/postgres-firewall.service  postgres-backup.{service,timer}  postgres-backup-health.{service,timer}
  test/run.sh  test/*_test.sh  test/local-e2e-test.sh
deployment/home-server/guest/pg-restore-verify.sh  (plus unit, timer, VM entry)
deployment/scripts/verify-postgres-lockdown.sh
secrets/.env.postgres
.github/workflows/deploy-postgres.yml
```

Share the firewall renderer with OpenSearch if that is simple; otherwise copy it. A shared abstraction is not a goal.

`deploy.sh` is safe to repeat: write the allowlist, reapply the firewall rules, generate certificates if absent, render
`pg_hba.conf`, `docker compose up -d`, apply roles idempotently, `pg_ctl reload`. Reapply the rules as
`deployment/opensearch/bin/install-firewall.sh` does. Do not restart the firewall unit: `docker.service` requires it, so
a restart would take Docker and Postgres down with it. A deploy must never restart Postgres unless the image or a
restart-only setting changed; when one did, it stops and prints that a manual restart is needed.

**A deploy must never start an empty database against a real backup repo.** A rebuilt server has a new system
identifier, so pgBackRest refuses the existing stanza, and a replacement server that started empty would look healthy
while holding no data. When the data directory is empty and the repo already holds a stanza, `deploy.sh` refuses to
start Postgres unless told explicitly: `POSTGRES_BOOTSTRAP=restore` or `POSTGRES_BOOTSTRAP=new-cluster`. Before cutover,
the build and rebuild test in §2 use a separate pre-production repo path, deleted when the test is done, so production's
path is only ever written by the real server.

**Who runs what (Shane, standing preference):** agents run everything on live servers over SSH, including step 4's
restart and the cutover, with Shane choosing the window. Shane runs `terraform apply`, `provision` and the one-time R2
setup (`setup-r2.sh` with a temporary account token, then the bucket-scoped tokens, §8.2), because agents are blocked
from those or lack the rights, and does the real sign-in and write check in step 15.
Agents have access to the private old-site repo.

## 8. Backups

### 8.1 What runs

- **Continuous:** every completed WAL file goes to the R2 backups bucket through `archive_command`.
- **Weekly full, daily differential** at 09:00 UTC, the site's quietest time, with `process-max=1`, `start-fast=n` and
  `compress-type=zst` **(my call)**. A differential copies only changed files. The Sunday full is the heaviest job
  and is what the 1.5x test in §2 measures. If it fails that test, the fallback is throttling or running it from a
  replica at that point, not before.
- **Retention:** `repo1-retention-full-type=time`, 30 days **(my call)**. pgBackRest expires old backups and WAL
  itself, so nothing depends on someone remembering. My estimate is a few dollars a month; confirm from the real bill.
- **Encrypted** with `repo1-cipher-type=aes-256-cbc`. The passphrase is in SOPS, so a restore needs only the repo and
  the age key.
- No backup writes to local disk, so the disk cannot fill from backups.
- **The move to R2 changed none of this, and none of `backup.sh` or `pg-health`.** pgBackRest reaches R2 through
  the same S3 settings, with R2's endpoint and region `auto`.

### 8.2 Buckets, locks and tokens (R2)

**Why R2 and not S3 (Shane, 2026-11-07).** The nightly restore (§9) downloads a backup and its WAL every night, and
on S3 every one of those downloads is billed; R2 charges nothing for them. The site's other object storage is already
on Cloudflare, so this keeps one provider, and AWS can be retired once the old server is gone (§13.2, step 18). The
first draft chose S3 because it had versioning and R2 had no proven pgBackRest use. R2 has no versioning, but it has
bucket locks, and pgBackRest on R2 is now proven (§8.4).

**Two buckets** (my call):

| Bucket | Written by | Lock | Lifecycle |
|---|---|---|---|
| Backups | The production server (pgBackRest) | Objects under `<repo path>/archive/main/18-` (the WAL archive) for 14 days | Abort incomplete multipart uploads after 7 days. No expiry rule: pgBackRest expires |
| Dumps | The home VM (§9, the nightly `pg_dump` files) | Every object, 14 days | Delete objects after 30 days; abort incomplete multipart uploads after 7 days |

An R2 lock refuses both delete and overwrite of a locked object (`ObjectLockedByBucketPolicy`), whoever asks. Two
limits come from how pgBackRest uses the bucket, both measured on real R2:

- **Only the WAL archive can be locked in the backups bucket.** pgBackRest rewrites the manifest inside each backup's
  folder while it backs up, so a lock on backup folders makes every backup fail with 409 after minutes of retries.
  The archive's prefix carries the Postgres major version (`18-`), so a major upgrade needs `setup-r2.sh` run again
  with `PG_MAJOR` set to the new version.
- **The lock must be shorter than retention.** `expire` fails with 409 on an object that is still locked, so the
  14-day lock sits below the 30-day retention. `setup-r2.sh` refuses a lock that is not shorter than either the
  retention or the dump expiry.

`deployment/postgres/bin/setup-r2.sh` creates both buckets if absent, sets the locks and lifecycle rules, and reads
every rule back. It is safe to repeat. Shane runs it once with a temporary account API token and then deletes that
token. Bucket names and the repo path come from SOPS, never from the code.

**Tokens, each scoped to one bucket** (my call):

| Token | Permission | Bucket |
|---|---|---|
| Server | Object Read & Write | Backups |
| Home VM restore | Object Read | Backups |
| Home VM upload | Object Read & Write | Dumps |
| Developer refresh | Object Read | Dumps |

Each is used through R2's S3 API: the access key id is the token's id and the secret is the SHA-256 of the token's
value. None of these four can change a bucket's settings, locks or lifecycle rules; the temporary account token that
could is deleted after setup. Creating the tokens is a one-time dashboard step for Shane, in the runbook.

**That covers these four tokens.** The account holds other Cloudflare tokens that Shane manages himself; they are outside this design, and he decided (2026-11-07) not to audit them as part of it.

`setup-r2.sh` also guards the live lock against itself: every run replaces the rules, so before any change it reads
the current lock rules and refuses (exit 2) if one would be dropped, narrowed, shortened or disabled, unless
`R2_REPLACE_LOCK=1` is set for a deliberate change. `setup-r2.sh --check` only reads and compares **(my call)**.

**What a compromised production server can and cannot destroy (the trade-off).** The server's token must be able to
delete, because pgBackRest's `expire` deletes. So the server can delete or overwrite every full and differential
backup, and any WAL older than 14 days. It cannot touch WAL from the last 14 days, but WAL without a base backup
restores nothing. **The backups bucket is therefore not protected against its own server.** What is:

- the dumps bucket, which the server holds no token for and whose objects are locked for 14 days. A dump is written
  once and never rewritten, so a whole-bucket lock works there;
- the home VM's own disk (14 daily and 12 monthly dumps), which no production token reaches.

In that worst case the restore comes from the newest nightly dump, so **up to about a day of writes is lost**,
against about 5 minutes when the repo is intact (`archive_timeout=300`). With S3 versioning, deleted backups would
have stayed recoverable for 14 days and the worst case would have stayed at minutes. That is the cost of R2: no
download charges and one provider, against a worse outcome in the one case where the server itself is compromised.
The home VM's restore token is read-only, so a restore there still cannot write to the production repo.

**The old AWS bucket until cutover.** The old server keeps writing its nightly dumps to its existing S3 bucket until
cutover, and `bin/refresh-dev-db.sh` keeps reading them there. The home VM uploads to the R2 dumps bucket from the
first night of the restore check (§13.2, step 7) **(Shane, 2026-11-07)**: it is a separate bucket, so the two sources
never share a name, and starting early proves the upload before cutover. At cutover (step 16) dev refresh switches to
the R2 bucket (`BACKUP_ENDPOINT`, `BACKUP_AWS_PROFILE`). AWS and its keys are retired after the old server is
deleted.

### 8.3 Alerts

healthchecks.io, the same approach as the home server (`hc_ping` in `deployment/home-server/guest/lib.sh`). URLs are in
SOPS. An alert fires on a reported failure and on silence.

| Check | Schedule | Passes only if |
|---|---|---|
| `pg-backup` | Daily | The backup exits 0 and `pgbackrest info` shows the new one |
| `pg-health` | Every 15 min | No finished WAL file has waited over 15 minutes to archive, no archive failures since last run, disk under 80%, and `archive_mode` is `on` with the expected `archive_command` |
| `pg-restore-verified` | Daily | Every step in §9 passed |

**Decision made during implementation:** `pg-health` also checks `archive_mode` and `archive_command`, read from the
running server. With archiving switched off, or a command that succeeds without pushing, no `.ready` file appears
and the failure counter stays flat, so the other checks would stay green: the exact failure this spec exists to
prevent.

**Decision made during implementation:** the stored failure count is kept with `pg_stat_archiver.stats_reset`. A restore
restarts Postgres and the counter, and a lower count was once read as a reset, hiding 3 real failures (2026-11-08). When
`stats_reset` has changed the baseline is 0, so any failure since the reset alerts.

Each must be tested failing as well as passing (§2, step 3), because the failure this replaces was silence. A test
passes only when Shane has actually seen the alert, not when healthchecks.io has sent it: in November 2026 a home server
outage alerted correctly for over three days, unseen, because the email was filed as a newsletter. Before Phase 3 these
checks need a Gmail filter that keeps them out of Promotions and Updates, and a phone push channel if the healthchecks.io
plan includes one.

### 8.4 Proven on real R2 (2026-11-07)

Run against a real R2 bucket with this repo's image and `pgbackrest.conf.tmpl`, before any server existed:

- pgBackRest 2.60 works on R2 with endpoint `<account id>.r2.cloudflarestorage.com`, region `auto`, the default URI
  style (no `repo1-s3-uri-style` line) and keys from an R2 token. `stanza-create`, `check`, a full, a differential, WAL
  archiving and a restore with WAL replay all passed, and the restored rows matched.
- A bucket lock refuses delete **and** overwrite of a locked object (`ObjectLockedByBucketPolicy`).
- A lock on backup folders makes every backup fail with 409 after minutes of retries, because pgBackRest rewrites
  each backup's manifest while it runs. Hence the WAL-archive-only lock in §8.2.
- `expire` fails with 409 on objects still inside a lock. Hence lock (14 days) below retention (30 days).
- A tiny restore took about 3.5 minutes, nearly all of it per-request latency rather than data, and a full backup waits
  for a spread checkpoint (`start-fast=n`) before it copies anything. Neither says how long real data takes: the real
  figures are measured on the server (runbook, "Prove it", and the first real night at step 7).

Then `setup-r2.sh` and the dump upload, against throwaway buckets deleted afterwards:

- `setup-r2.sh` created both buckets, set both buckets' locks and lifecycle rules and read them back; the read-back
  shapes it assumes are the real API's. A second run was a clean, verified no-op.
- The pinned `amazon/aws-cli` image, with `AWS_ENDPOINT_URL` and region `auto`, uploaded a 120 MB multipart file to
  the locked dumps bucket. A delete of it was refused with `ObjectLockedByBucketPolicy`, and `aws s3 ls` listed it.

## 9. Nightly restore test and dev dump (home server)

A new VM (next free VMID; 4 cores, 8 GB, 400 GB on `rpool2`: the restored data plus 26 sets of dumps at about 7.6 GB
each, **decision made during implementation**) with the same pinned Postgres image, created only once
`PGVERIFY_ENABLED=1` is set at step 7 and refusing a blank alert URL, no inbound exposure, `archive_mode=off` and `max_logical_replication_workers=0`, so a restored subscription cannot try to connect
anywhere. A timer starts after the backup window. Steps, stopping at the first failure except where noted:

1. Restore the latest backup with `pgbackrest restore --delta`, and from an empty directory on Sundays **(my call)**.
   R2 charges nothing for the download, but every object is a request with its own latency, and delta fetches only
   what changed, which keeps the nightly run short.
2. Start Postgres and let it finish recovery.
3. Check that it is real:
   - the latest replayed transaction is under 26 hours old;
   - replay reached the archive's newest WAL segment, read from `pgbackrest info` before the restore (**decision
     made during implementation**): recovery that ends early finishes on a new timeline and would otherwise pass
     every other check. The server's `restore_command` also aborts recovery on any `archive-get` read error rather
     than treating it as the end of WAL;
   - both databases exist, and a fixed list of core tables is not empty;
   - `pg_amcheck` passes on those tables' indexes. Remove `amcheck` afterwards so it does not reach dumps.
   - **Row counts, which alert but do not stop the run:** a core table over 10,000 rows in either night's count (a
     big table that became tiny is the move to catch, **decision made during implementation**) that moved more than 5%
     since the previous night makes the run report failure at the end, naming the table. Bulk changes in books data are
     normal, so the night's dumps still complete, and the baseline is always the previous night, so one real change
     causes one alert and clears itself.
4. Fail clearly if free disk is under one night's dumps (the newest set on disk). `pg_dump -Fc --no-subscriptions` each database, and confirm with `pg_restore --list` that each dump is readable and
   non-empty.
5. **From the first night (step 7) onwards**, upload the dumps to the R2 dumps bucket (§8.2) with the existing
   `postgres_*_backup_*.sql.gz` names, using the upload token, which reaches that bucket only. The `aws` container
   gets the bucket's endpoint as `AWS_ENDPOINT_URL` (`PGVERIFY_DUMP_ENDPOINT`) and region `auto`. The bucket's lock
   keeps each dump for 14 days against delete or overwrite, and its lifecycle rule deletes it after 30.
   `bin/refresh-dev-db.sh` reads the same names, from that bucket once `.env` sets `BACKUP_ENDPOINT` and
   `BACKUP_AWS_PROFILE`, which happens at cutover (step 16); until then dev reads the old server's dumps from the old
   S3 bucket. The upload is part of the night: a failed upload pings `fail` and resets the 7-night count
   **(Shane, 2026-11-07: upload from step 7, not from cutover)**.
6. Keep 14 daily and 12 monthly dumps on the home server's disk, pruned by the script. Production holds no key that
   reaches them, so this is a copy production cannot modify. It holds real user data, so the VM has no
   inbound services.
7. Ping `pg-restore-verified` only after all of the above, and report failure if any row-count alert was raised.

When the old site shuts down, remove `tgb` from the list. Nothing else changes.

## 10. Development and CI move first

`pg_restore` cannot read a dump from a newer `pg_dump`, so dev and CI must reach 18 before production's dumps do. This
is also the cheapest compatibility test.

- CI: `.github/workflows/ci.yml` to `postgres:18`.
- Dev: `docker-compose.yml` to `postgres:18`, with the new mount path and a **new named volume**. The old volume stays
  until Shane removes it: the dev database is not disposable. Fill the new one with `bin/refresh-dev-db.sh --legacy`,
  which loads today's 17 dumps into 18.
- Full `bin/rails test`, `standardrb` and `yarn test:e2e` on 18 before anything else happens. Shane's Mac setup follows
  the same steps.
- Update `docs/dev_setup.md` and `AGENTS.md` if they name the version.

## 11. App changes

- **New app:** `web-app/config/database.yml` production reads `sslmode` from `POSTGRES_SSLMODE`, and `legacy_books` from
  `LEGACY_BOOKS_SSLMODE`. Unset means the driver's default, so it can merge before the move. Add both to `.env.example`
  and `deployment/ENV.md`.
- **Old site (private repo):**
  - `admin/config/database.yml` production reads host, port, username, password and `sslmode` from the environment.
  - `docker-compose.prod.yml` takes the same connection values from the environment.
  - Stop the `pghero:capture_query_stats` cron at cutover **(my call)**: the table will not be copied, and capture
    resets statistics, which `tgb_app` should not be able to do. PgHero's live pages keep working through `pg_monitor`.
- Both must go live with the same values as today before the move, so cutover changes only environment values.

The old site cannot run in development, and the move changes its login and connection settings. So it is
tested from its production server before cutover: step 8 runs a one-off container of the old site's current image with
the new server's values and `tgb_app`, and runs representative reads, PgHero's live pages if reachable, and a write in
a transaction that is rolled back. A problem here costs nothing. At step 15 it could cost the rollback.

## 12. Verification

- **CI:** `deployment/postgres/test/run.sh` joins "Shell tests and shellcheck". **Decision made during
  implementation:** the tests that need Docker (`run.sh --docker`, which includes the migration scripts against real
  Postgres 17 and 18 containers) run in their own path-filtered workflow, `postgres-migration-tests.yml`, and do not
  gate deploys: `ci.yml` gates the web image build, and a one-time migration's Docker Hub-dependent test must not block
  every deploy. The cost is that a broken script on `main` goes unnoticed until the next change under
  `deployment/postgres/`.
  - The firewall renderer accepts good input and rejects empty, malformed, scoped or wildcard input.
  - `firewall-netfilter_test.sh` (`run.sh --docker`) loads the rendered rules, allowlist and deny-all, into real
    netfilter shaped like Docker's published port: the container's outbound connection to a remote 6543 connects, an
    allowlisted client connects, another client is blocked, on IPv4 and IPv6.
  - The `pg_hba` renderer emits only `hostssl` lines, one per role, database and address, and never `all` on a network
    rule.
  - Backup and restore scripts, with stubbed tools, ping `fail` and never success when any step fails. Each failure
    mode gets a test that fails if the alert stops firing.
  - Pruning keeps exactly the expected files.
- **Local end-to-end** (manual, the real compose file plus a local bucket):
  - each role can do what §5.2 says and is refused otherwise;
  - `tgb_reader` cannot write;
  - no network superuser login, and no unencrypted connection;
  - back up, restore, and restore to a chosen moment;
  - a full 17 → 18 replication and cutover run with writes happening, with sequences correct at the end.
- **On the real server:** `verify-postgres-lockdown.sh` checks from outside (refused or timed out on IPv4 and IPv6) and
  from each app server (TLS required, each login limited to its own database). Include the reboot probe from the
  OpenSearch work: the port never answers from outside while the server boots.

## 13. The move

The old server stays up and unchanged except as noted. Do not merge to the old repo in a way that touches the database
during any of this.

### 13.1 Why replication fits (measured 2026-11-06, re-measure on the day)

`the_greatest`: 103 tables, all with primary keys, no triggers, materialized views, generated columns, large objects
or extensions. `tgb`: two empty tables without primary keys, which are excluded; two search-text triggers (`authors`,
`books`), which do not fire on a subscriber by default, so the source's values are copied; expected extensions
`btree_gin`, `btree_gist`, `fuzzystrmatch`, `pg_stat_statements`, `pg_trgm`, `unaccent`. Expected functions in `tgb`:
`authors_search_string_update`, `update_book_search_text`, `update_ol_works_search_text`; none in `the_greatest`.

Limits to plan around: replication does not copy schema changes or sequences. So no migrations run from step 5 to
cutover on either app, and sequences are set by hand at cutover.

### 13.2 Order

**Phase 0, prerequisites**

1. Old repo: pin `postgres:17` to the current digest and remove the `pull db` and `up -d db` steps from its deploy
   workflow, so a merge there cannot restart production Postgres during the move.
2. Dev and CI on 18 (§10). Apps' environment-driven config live (§11).

**Phase 1, new server**

3. Build, verify, destroy, rebuild, verify (§2). Buckets, their locks and lifecycle rules, and the tokens created
   (§8.2). Using a small sentinel table and the pre-production repo path (§7), prove a backup, a restore to a chosen
   moment, that the lock refuses a delete of a fresh WAL object, and the `pg-backup` and `pg-health` alerts firing,
   then drop the sentinel table. `setup-r2.sh` runs again with the real repo path and `R2_REPLACE_LOCK=1` when the path
   switches, because the lock's prefix follows it. R2 locks are bucket rules, so that replacement unlocks the
   pre-production prefix at once, and the pre-production archive is then deleted. The daily restore check and its alert start at step 7, once real data
   and its VM exist; `pg-backup` and `pg-health` run from here on the real repo path.

**Phase 2, copy** (sites unaffected except one brief restart)

4. Old server settings for the move: `wal_level=logical`, TLS with a self-signed certificate,
   `max_slot_wal_keep_size=20GB`, and a `hostssl` rule for a `replicator` role limited to the new server's address. This
   is one restart of a few seconds, at a quiet time, with both apps reconnecting on their own. **Decision made during
   implementation:** the `replicator` rule covers both `the_greatest` and `tgb`, because a subscription's connection
   matches on the real database name. A second, temporary `hostssl` rule admits `postgres` from the new server's address
   and from the app hosts that run `load-schema.sh` on `postgres`, `template1`, `the_greatest` and `tgb`, because the
   migration scripts reach the old server as an admin over the network (`check-schema.sh all` visits every database that
   accepts connections, and `load-schema.sh` runs from the app host whose owner login the new server admits). Without
   the cap, a stuck slot could fill the old server's disk; with it, replication breaks and is restarted instead. Then
   prove from inside the new server's container that it reaches the old server's port (§5.1).
5. Freeze migrations on both apps, for at least 8 days (steps 5 to 7 and the cutover; a failed night at step 7 restarts
   the count, and a merged migration runs itself through `db:prepare`). Load the checked schema into each new database (§5.4). Create publications listing
   every table except `pghero_query_stats` and the two empty `tgb` tables, then subscriptions with `sslmode=require`.
6. Wait for the initial copy and for lag near zero. Pause any heavy imports while it copies. Run `ANALYZE` on both new
   databases, because logical copies carry no planner statistics and a cold planner would make the first hour after
   cutover slow.
7. Turn on the daily restore check (§9) with `PGVERIFY_ENABLED=1`. Before the nights start, a deliberately broken run
   must raise the `pg-restore-verified` alert and a real run must give its first ping. **Cutover needs 7 straight
   passing nights on real data.** New writes will depend on this chain alone from the moment of cutover, so it has to be
   proven before then, not after. The dump upload to the R2 dumps bucket (§9 step 5) goes on with it, so each of the 7
   nights includes a successful upload; after the first, the developer token must list both dumps, and an optional
   one-off dev refresh from R2 proves the whole path (dev must be on 18 by then).
8. Compare both sides: row counts per table, `max(id)`, and checksums on a sample of important tables. A unique-index
   failure during copy would show a text index corrupted by the old server's silent library change. Fix the row on the
   source and record it. Run the old site's connection test (§11).

**Phase 3, cutover** (both databases in one window, one at a time so a problem is seen once; `tgb` or `the_greatest`
first is the builder's call). Start about 10:30 UTC on a day other than Sunday, after the old dump ends and the new
server's backup has finished, and never during either.

9. Remove the old server's backup cron, so no dump is killed mid-run and no frozen dumps reach the bucket. Keep the last
   dump from before cutover. Stop Sidekiq for the affected app, and the PgHero cron for `tgb`. No imports in progress:
   check first.
10. Make the source read-only: `ALTER DATABASE … SET default_transaction_read_only=on`, then terminate its sessions. Reads
    keep working, so public pages still serve; writes error briefly.
11. Wait until the subscription has applied everything up to the source's current position.
12. Set every sequence on the new side from the source, and verify each is at or past its table's `max(id)`.
13. Repeat the row count comparison, and record the target's write count
    (`select sum(n_tup_ins+n_tup_upd+n_tup_del) from pg_stat_user_tables`) for §14.
14. Change the app's environment and restart it:
    - **New app:** edit `.env` on the server and `docker compose up -d web worker`, because a deploy takes too long for
      this window. Switching `tgb` also means changing `LEGACY_BOOKS_*`.
    - **Old site:** edit `.env` on its server and restart `web worker cable`.
15. Check the site reads and writes, then restart workers. Shane does a real sign-in and a real write on each site.
    Only then merge this database's PR that puts the same values in `secrets/.env.production`, or the next deploy will
    overwrite `.env` and point the app back at the old server. **Decision made during implementation:** there is one PR
    per database, each holding only that database's variables, reviewed in advance. A single PR merged after the first
    database would move the second app connection while its database still takes writes on the old server, and lose
    those writes.
16. Drop the subscription. Once both databases are done, switch dev's `.env` to the R2 dumps bucket, which has had
    the dumps since step 7 (§8.2). **Decision made during
    implementation:** also drop the `replicator` role (`DROP OWNED BY` in each database with the session opted out of
    read-only, then `DROP ROLE`) and remove both temporary `hostssl` rules from step 4, including the app hosts' access.

Target: under 5 minutes per database, measured. If the rehearsal in §12 shows more, tell Shane before scheduling.

**Phase 4, afterwards**

17. Record hourly `pg_stat_statements` totals (time and calls per database) on the new server, and compare a Sunday full
    backup's hours with the same hours on other days. That is the 1.5x test in §2, and it decides whether §8.1's
    fallback is needed. Keep the snapshots outside both databases, so they never reach dev. Stop when the test has
    passed on two Sundays.
18. Keep the old server read-only for 14 days **(my call)**, confirm nothing on its data volume is still needed, then
    Shane deletes it. Remove `postgres/`, the `db` service and the backup script from the old repo. Then retire AWS:
    the old dump bucket and every AWS key, including the one dev refresh used before cutover. This repo's code needs no AWS after that (`aws-sdk-s3` in the Gemfile
    talks to R2); check the AWS account for anything else before closing it.

## 14. Rollback

- **Before step 14:** remove read-only on the source, then terminate its sessions again and restart workers. The setting
  applies only when a session starts, so connections opened during the window stay read-only until they are replaced. No
  data lost, no user-visible change beyond the failed writes.
- **After the app is on the new server but before it has real writes:** first compare the target's write count with
  the one recorded at step 13. Any rise beyond Shane's test write means real writes: fix forward. Otherwise remove
  read-only on the source **before** `up -d`, because `up -d` runs `db:prepare`, then point the app back. Revert that
  database's SOPS PR if it was merged.
- **After real writes:** fix forward. The old server is out of date from that moment and only serves as a reference.
  Reverse replication is not built: it is more risk than the case justifies, since the rehearsal, the row checks and a
  verified restore all come first.

## 15. Documentation

- New runbook `docs/features/postgres-server.md`: build, deploy, verify, add an app server, rotate a password, upgrade a
  minor version, restore to a chosen moment on a fresh server, rebuild from a backup, what each alert means and what to
  do about it.
- `deployment/ENV.md`, `deployment/README.md`, `docs/features/home-server.md`, `.env.example`.
- These steps live in the runbook, not `docs/launch-todo.md`: the move does not depend on the launch.

## 16. Check during implementation

- The exact newest 18.x image and pgBackRest version on the day, and that PGDG's package matches the image's Debian
  release.
- ~~pgBackRest's current docs for versioned S3 buckets~~ Replaced by R2, proven on 2026-11-07 (§8.4). Still to measure
  on real data: a restore's duration from R2, and `--delta` from object storage.
- That `archive_command` failures surface in `pg-health` and cannot quietly fill `pg_wal`.
- The right `max_logical_replication_workers` and `max_sync_workers_per_subscription` for a two-database copy on 4
  cores, and whether dropping non-key indexes during the copy is worth its complexity. Default to not doing it.
- Whether any table stores third-party secrets in plain text. Report what is found; rotating those is not part of
  this build.
- That `tgb_reader` covers every legacy read path, including `finish_legacy` and the Goodreads rake tasks, which must be
  confirmed read-only rather than assumed.
- Which of the old site's scheduled jobs write to `tgb`, so step 9 stops all of them.
- That Rails' reconnect behaviour during step 4's restart causes only brief errors on both apps.
- The home server's current free disk and next free VMID.
