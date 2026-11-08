# Postgres Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible, locked-down PostgreSQL 18 server with proven backups, then move both sites' databases to it with minutes of read-only time.

**Architecture:** One Linode built by Terraform and cloud-init and configured by a manual workflow, on the OpenSearch server's pattern. pgBackRest streams backups to a Cloudflare R2 bucket whose WAL archive is locked for 14 days. A home-server VM restores them nightly, checks them and produces the dev dumps, which it uploads to a second, fully locked R2 bucket from the first night of the restore check; dev switches to that bucket at cutover. Logical replication copies live data from 17 to 18.

**Tech Stack:** PostgreSQL 18 (official image plus PGDG pgBackRest), Docker Compose, Terraform, cloud-init, bash with stub-based tests and shellcheck, SOPS, healthchecks.io, Rails 8.

**Spec:** `docs/superpowers/specs/2026-11-06-postgres-server-design.md`. Read it before any task.

## Global Constraints

- The repo is public. No server addresses, bucket names, ping URLs or details of the old server's security state in code, tests, docs, commits or PRs. Use placeholders and SOPS.
- Never `commit` to `main`, and never push or open a PR without asking Shane. A merge to `main` deploys.
- Part A tasks change code only. They touch no production system. Part B tasks are live and need Shane's go-ahead at the point each says so.
- Shane runs `terraform apply`, `provision` and the one-time R2 setup (`setup-r2.sh` with a temporary account token, then the four bucket-scoped tokens). Agents run everything else over SSH.
- Postgres `18.x` pinned by digest; pgBackRest 2.60 or newer; Ubuntu 26.04; `g6-standard-4`; `us-central`; port 6543 published as `0.0.0.0:6543:5432`, so IPv4 only.
- Databases `the_greatest` and `tgb`, locale `en_US.utf8`. Roles exactly: `postgres`, `the_greatest`, `tgb_app`, `tgb_reader`. Nothing is copied from the old server's `postgres` or `template1` databases, and no old role or password is reused.
- Data mount `/var/lib/postgresql`. `io_method` stays at its default. `archive_timeout=300`. Retention 30 days. R2 lock 14 days, on the backups bucket's WAL archive prefix only and on the whole dumps bucket; the lock always stays below retention.
- A deploy never restarts Postgres unless told to, and never restarts the firewall unit: reapply rules as `deployment/opensearch/bin/install-firewall.sh` does.
- Every failure path pings `fail`, and no failure path pings success. Stubs follow `deployment/opensearch/test/helpers.sh`, including the depth guard. Never send a real ping from a test.
- `deployment/home-server` may have another agent's NIC recovery work in flight. Check `git log origin/main -- deployment/home-server` before Task 9, and rebase rather than overwrite.
- Run `bin/rails test` and `bundle exec standardrb` from `web-app/` for any Ruby change. Run the relevant `test/run.sh` for any shell change.

## Review Focus

1. **WAL archiving breaks while Postgres looks healthy** (bad token, R2 down): `pg-health` must fail within 15 minutes, even though the database answers queries. Test: `t_ready_file_older_than_15_min_fails` in Task 7.
2. **The first restore-check run has no previous night's counts:** it must pass without a row-count alert rather than erroring or dividing by zero. Test: `t_first_run_has_no_baseline` in Task 9.
3. **An IPv6 client address in SOPS:** it must render as a `/128` `hostssl` line and appear in the v6 firewall rules, not fail the deploy or be dropped silently. Test: `t_ipv6_client_renders_128` in Task 4.
4. **Rotating a password by redeploying:** the new password takes effect with no restart and never appears in a process's arguments. Test: `t_password_goes_by_stdin_not_argv` in Task 6.
5. **Two restore checks overlap, or a reboot interrupts one:** the second exits quietly without a false success, and the next run recovers from a half-restored directory. Tests: `t_lock_held_exits_without_ping` and `t_interrupted_restore_recovers` in Task 9.

---

# Part A: code

### Task 1: Development and CI on Postgres 18

**Files:**
- Modify: `docker-compose.yml`, `.github/workflows/ci.yml:38`, `docs/dev_setup.md`, `AGENTS.md` if it names the version
- Check: `bin/refresh-dev-db.sh`, `bin/snapshot-dev-db.sh`, `bin/prune-worktree-test-dbs.sh` for a hardcoded data path or volume name

**Interfaces:** Produces a dev database on 18, in volume `postgresql18-data`, with `pg_restore` 18 available. Later dumps from production require it.

- [ ] **Step 1:** Change `docker-compose.yml` to `postgres:18`, mount new named volume `postgresql18-data` at `/var/lib/postgresql`, and keep the old `postgresql-data` volume declared under `volumes:` with a comment that it is the 17 copy, kept until Shane removes it. Change `ci.yml` to `postgres:18`.
- [ ] **Step 2:** Verify the config: `docker compose config | grep -E 'postgres:18|/var/lib/postgresql$'` prints both.
- [ ] **Step 3:** Tell Shane the dev database is about to switch and confirm no other worktree is using it (`docker ps`, `git worktree list`). Run `bin/snapshot-dev-db.sh --label pre-pg18`, stop the 17 container, start 18, and run `bin/refresh-dev-db.sh --legacy`. Expect about 25 minutes or more. Expected: `docker compose exec db psql -U postgres -Atc 'show server_version'` starts with `18.`, and `the_greatest_development` and `the_greatest_books_legacy` have rows.
- [ ] **Step 4:** Run `bin/rails db:test:prepare test`, `bundle exec standardrb` and `yarn test:e2e`, after confirming port 3000 is yours as AGENTS.md describes. Expected: same results as `main`. Pre-existing failures in AGENTS.md or notes stay out of scope; any new failure blocks this plan and goes to Shane.
- [ ] **Step 5:** Update docs and commit: `git commit -m "Dev and CI on Postgres 18"`.

### Task 2: New app reads TLS mode from the environment

**Files:**
- Modify: `web-app/config/database.yml:78-92`, `.env.example`, `deployment/ENV.md`
- Test: `web-app/test/config/database_config_test.rb`

**Interfaces:** Produces `POSTGRES_SSLMODE` and `LEGACY_BOOKS_SSLMODE`. Unset means the driver's default, so the change is safe to merge before the move.

- [ ] **Step 1: Write the failing tests.** Render `config/database.yml` through ERB with a given ENV and `YAML.safe_load(aliases: true)`:
```ruby
test "production primary takes sslmode from POSTGRES_SSLMODE" do
  assert_equal "require", production_config("POSTGRES_SSLMODE" => "require").dig("primary", "sslmode")
end
test "legacy_books takes sslmode from LEGACY_BOOKS_SSLMODE, independent of primary" do
  c = production_config("POSTGRES_SSLMODE" => "require", "LEGACY_BOOKS_SSLMODE" => "prefer")
  assert_equal "prefer", c.dig("legacy_books", "sslmode")
end
test "unset leaves sslmode blank so a connection still works on the old server" do
  assert production_config({}).dig("primary", "sslmode").blank?
end
```
- [ ] **Step 2:** Run `bin/rails test test/config/database_config_test.rb`. Expected: FAIL.
- [ ] **Step 3:** Add `sslmode: <%= ENV["POSTGRES_SSLMODE"] %>` to `primary`, and `LEGACY_BOOKS_SSLMODE` likewise to `legacy_books`. Do not fall back from one to the other. Document both.
- [ ] **Step 4:** Run the test, `bundle exec standardrb` and `bin/rails test`. Expected: PASS. Confirm with `RAILS_ENV=production SECRET_KEY_BASE=x bin/rails runner` only if needed that a blank `sslmode` connects; otherwise a test against the local server with `POSTGRES_SSLMODE` unset is enough.
- [ ] **Step 5:** Commit.

### Task 3: Old site reads its connection from the environment (private repo)

**Files (repo `the-greatest-books`, its own branch and PR):**
- Modify: `admin/config/database.yml`, `docker-compose.prod.yml`, `.github/workflows/deploy.yaml`

**Interfaces:** Produces `TGB_DB_HOST`, `TGB_DB_PORT`, `TGB_DB_USERNAME`, `TGB_DB_PASSWORD`, `TGB_DB_SSLMODE` for the old site. The old repo has no test suite to speak of, so verification is by parsing and by the live checks in Task 13.

- [ ] **Step 1:** Read the production `host`, `port`, `username`, `password` and `sslmode` from those variables. Pass them through to `web`, `worker` and `cable` in the compose file. The `db` service reads its password as `${POSTGRES_PASSWORD}`.
- [ ] **Step 2:** In `deploy.yaml`, delete `docker compose ... pull db` and `up -d db` and pin the `db` image to the digest of the image now running, read from the server with `docker inspect`. Keep `git pull` on the database host.
- [ ] **Step 3:** Verify with `docker compose -f docker-compose.prod.yml config` using a stand-in `.env` with fake values: it must parse, with the connection values coming from that `.env`. `ruby -ryaml -rerb` parsing of `database.yml` with fake env must produce the expected production keys. Say in the PR exactly what was run; do not claim a check that stopped early.
- [ ] **Step 4:** Commit on the branch. Do not merge: Task 13 sets `.env` first, because a merge deploys.

### Task 4: Firewall and `pg_hba` rendering

**Files:**
- Create: `deployment/postgres/bin/{render-firewall,apply-firewall,install-firewall,render-hba}.sh`, `deployment/postgres/systemd/postgres-firewall.service`, `deployment/postgres/.shellcheckrc`
- Test: `deployment/postgres/test/{helpers.sh,run.sh,render-firewall_test.sh,apply-firewall_test.sh,install-firewall_test.sh,render-hba_test.sh}`
- Modify: `.github/workflows/ci.yml` (a `postgres` job shaped like `opensearch`)

**Interfaces:**
- Produces `render-hba.sh CLIENTS_FILE` printing `pg_hba.conf`; `CLIENTS_FILE` has one `role database address` per line.
- Produces `install-firewall.sh` (as root; `ROOT` prefix for tests; `ALLOWLIST` default `/etc/postgres-server/allowlist`).
- Lib path `/usr/local/lib/postgres-firewall`.

- [ ] **Step 1:** Copy the OpenSearch firewall scripts and tests with `PORT=6543` and renamed paths and unit. Do not build a shared library: the spec says not to unless simple, and these run at boot.
- [ ] **Step 2: Write the failing `render-hba_test.sh`:**
  - `t_one_line_per_client`: three clients give exactly three `hostssl <db> <role> <ip>/32 scram-sha-256` lines.
  - `t_ipv6_client_renders_128`: an IPv6 client gets `/128`.
  - `t_no_plain_host_rule`: output has no line starting `host ` or `hostnossl`.
  - `t_no_all_on_network_rule`: no `hostssl` line has `all` in the database or role column.
  - `t_local_is_peer`: exactly one local rule, `local all postgres peer`.
  - `t_rejects`: exit 2, printing nothing, for each of an empty file, CIDR input, `0.0.0.0`, role `postgres`, an unknown role, a role with the wrong database (allowed pairs: `the_greatest the_greatest`, `tgb_app tgb`, `tgb_reader tgb`).
- [ ] **Step 3:** Run `deployment/postgres/test/run.sh`. Expected: `render-hba` tests FAIL; copied firewall tests PASS.
- [ ] **Step 4:** Implement `render-hba.sh`, validating addresses with Python `ipaddress` as `render-firewall.sh` does.
- [ ] **Step 5:** Run it again. Expected: all pass, shellcheck clean. Commit.

### Task 5: Image, compose and Postgres configuration

**Files:**
- Create: `deployment/postgres/{Dockerfile,compose.yml}`, `deployment/postgres/config/postgresql.conf`, `deployment/postgres/config/pgbackrest.conf.tmpl`, `deployment/postgres/bin/generate-certs.sh`
- Test: `deployment/postgres/test/{compose_test.sh,config_test.sh,generate-certs_test.sh}`

**Interfaces:**
- Produces compose service `postgres`, project name `postgres-server`, container `postgres-server-postgres-1`, volume `postgres-data`.
- Paths on the host: `/srv/postgres/certs`, `/srv/postgres/config/pg_hba.conf`, `/srv/postgres/config/pgbackrest.conf`.
- Stanza `main`.

- [ ] **Step 1: Write the failing tests:**
  - `compose_test`: `docker compose config` shows the mount target `/var/lib/postgresql`, port `0.0.0.0:6543` to `5432`, `shm_size` 1g, `restart: unless-stopped`, log rotation `max-size: 100m` and `max-file: 20`. The Dockerfile `FROM` matches `postgres:18\.[0-9]+.*@sha256:`.
  - `config_test`: `postgresql.conf` contains every value in spec §6 exactly, including `archive_timeout = 300`, `ssl = on`, `ssl_min_protocol_version = 'TLSv1.2'`, `log_connections = on`, `shared_preload_libraries = 'pg_stat_statements'`, `max_worker_processes = 8`, and no `io_method` line. `pgbackrest.conf.tmpl` has `repo1-retention-full-type=time`, `repo1-retention-full=30`, `repo1-cipher-type=aes-256-cbc`, `compress-type=zst`, `process-max=1`, `start-fast=n`.
  - `generate-certs_test`: creates key and cert on first run with 10-year validity and key mode 0600; a second run leaves them byte-identical.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Compose starts Postgres with `-c config_file=/etc/postgresql/postgresql.conf -c hba_file=/etc/postgresql-host/pg_hba.conf` from read-only directory mounts, because a single-file mount keeps the old inode. Init args: `--locale=en_US.UTF-8 --encoding=UTF8 --data-checksums`. Check `apt-cache` in the build for a PGDG pgBackRest matching the image's Debian release. Pin it.
- [ ] **Step 4:** Run. Expected: PASS. Run `docker compose build` and `docker run --rm <image> sh -c 'pgbackrest version; postgres --version'`. Expected: 2.60 or newer, and 18.x. Commit.

### Task 6: Roles and the deploy script

**Files:**
- Create: `deployment/postgres/bin/{deploy,apply-roles}.sh`, `deployment/postgres/.env.postgres.example`
- Test: `deployment/postgres/test/{deploy_test,apply-roles_test}.sh`

**Interfaces:**
- `deploy.sh ENV_FILE`. Required: `POSTGRES_CLIENTS` (semicolon-separated `role database address`), `POSTGRES_SUPERUSER_PASSWORD`, `POSTGRES_THE_GREATEST_PASSWORD`, `POSTGRES_TGB_APP_PASSWORD`, `POSTGRES_TGB_READER_PASSWORD`, `PGBACKREST_REPO_BUCKET`, `PGBACKREST_REPO_ENDPOINT`, `PGBACKREST_REPO_REGION`, `PGBACKREST_REPO_PATH`, `PGBACKREST_REPO_KEY`, `PGBACKREST_REPO_KEY_SECRET`, `PGBACKREST_CIPHER_PASS`, `HC_PG_BACKUP`, `HC_PG_HEALTH`.
- Optional: `POSTGRES_BOOTSTRAP=new-cluster|restore`, `POSTGRES_ALLOW_RESTART=1`.
- `apply-roles.sh` reads passwords from the environment and sends SQL to `psql` on stdin.

- [ ] **Step 1: Write the failing tests:**
  - `t_empty_data_with_stanza_refuses`: empty data directory, repo holds a stanza, no bootstrap value: non-zero exit, message names `POSTGRES_BOOTSTRAP`, no `up` called.
  - `t_empty_data_no_stanza_creates`: `up` then `stanza-create`.
  - `t_bootstrap_restore_restores_before_start`: `pgbackrest restore` called before `up`.
  - `t_existing_data_unchanged_no_restart`: no `--force-recreate`, no `restart`, `pg_ctl reload` called.
  - `t_config_changed_stops_and_says_so`: fingerprint of image and `postgresql.conf` changed while running: exit 3, printed message, no recreate. With `POSTGRES_ALLOW_RESTART=1`: recreate.
  - `t_never_restarts_firewall_unit`: no `systemctl restart`.
  - `t_bad_clients_fails_before_changes`: invalid `POSTGRES_CLIENTS` exits before any install or `up`.
  - `t_missing_var_names_it`: each required variable, removed in turn, fails with its name.
  - `t_password_goes_by_stdin_not_argv`: no stub's logged arguments contain the test password.
  - `t_rotation_needs_no_restart`: a changed password re-runs `ALTER ROLE` with no `up --force-recreate`.
  - `apply-roles`: SQL contains no `SUPERUSER` grant for app roles; `tgb_reader` gets `CONNECT`, `USAGE` and `SELECT` plus `ALTER DEFAULT PRIVILEGES FOR ROLE tgb_app ... GRANT SELECT`; `tgb_app` gets `pg_monitor` and owns schema `public` and database `tgb`; re-running is a no-op apart from `ALTER ROLE ... PASSWORD`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement following `deployment/opensearch/bin/deploy.sh`'s shape, and create `tgb`'s expected extensions in `apply-roles.sh` as `postgres`. Stanza presence comes from `docker compose run --rm --no-deps postgres pgbackrest --stanza=main info --output=json`. Treat an unreadable repo as failure, never as "no stanza".
- [ ] **Step 4:** Run. Expected: PASS. Commit.

### Task 7: Backups and health checks

**Files:**
- Create: `deployment/postgres/bin/{backup,check-backup-health}.sh`, `deployment/postgres/systemd/postgres-backup.{service,timer}`, `deployment/postgres/systemd/postgres-backup-health.{service,timer}`
- Modify: `deployment/postgres/bin/deploy.sh` (install and enable the units)
- Test: `deployment/postgres/test/{backup_test,check-backup-health_test}.sh`

**Interfaces:** `backup.sh` picks `full` on Sundays (UTC) and `diff` otherwise; the first run of a new stanza is full. Timer `*-*-* 09:00:00 UTC`; health every 15 minutes.

- [ ] **Step 1: Write the failing tests:**
  - `t_sunday_is_full`, `t_weekday_is_diff`.
  - `t_success_pings_only_after_info_shows_new_label`.
  - `t_backup_exit_nonzero_pings_fail_not_success`.
  - `t_exit_zero_but_no_new_label_pings_fail`: a backup that claims success and produced nothing.
  - `t_ready_file_older_than_15_min_fails`, `t_ready_file_newer_passes`.
  - `t_archive_failure_count_increase_fails`, with the count stored between runs under `/srv/postgres/state`; `t_first_run_no_stored_count_passes`.
  - `t_disk_at_80_percent_fails`.
  - `t_postgres_down_fails`: not a false pass.
  - `t_ping_url_never_logged`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Copy `hc_ping`'s behaviour from `deployment/home-server/guest/lib.sh`: an undeliverable ping is logged, never fatal.
- [ ] **Step 4:** Run. Expected: PASS. Commit.

### Task 8: Terraform, cloud-init, workflow, lockdown check

**Files:**
- Create: `deployment/terraform/postgres/{main.tf,variables.tf,cloud-init.yaml,terraform.tfvars.example}`, `.github/workflows/deploy-postgres.yml`, `deployment/scripts/verify-postgres-lockdown.sh`, `secrets/.env.postgres`
- Modify: `.sops.yaml`, `deployment/postgres/test/run.sh`
- Test: `deployment/postgres/test/verify-lockdown_test.sh`

**Interfaces:**
- Terraform: resource `linode_instance.postgres`, default label `thegreatest-postgres`.
- GitHub secrets: `POSTGRES_SSH_HOST`, `POSTGRES_SSH_HOST_FINGERPRINT`, reuse `DEPLOY_SSH_KEY` and `AGE_PRIVATE_KEY`.
- Verify modes:
  - `--outside` with `PG_IPV4`, `PG_IPV6`.
  - `--inside ROLE DATABASE` with `PG_IPV4` and `PGPASSWORD`.

- [ ] **Step 1:** Copy the OpenSearch module, removing `vm.max_map_count`, and copy the workflow with renamed secrets and `deployment/postgres/bin/deploy.sh`. Cloud-init installs the firewall before Docker and stops on failure, exactly as OpenSearch's does. `install -d -m 0750 /srv/postgres`.
- [ ] **Step 2: Write the failing `verify-lockdown_test.sh`,** using stubs as OpenSearch's does:
  - `--outside`: passes only on a drop on 6543 with the port-22 control connecting; fails on a refused connection, on a TCP connection, or on a failed control.
  - `--inside`: passes only if `sslmode=disable` is refused, `sslmode=require` connects, the login is refused on the other database, and `select rolsuper` is false.
- [ ] **Step 3:** Run. Expected: FAIL. Implement. Run again. Expected: PASS.
- [ ] **Step 4:** Validate: `terraform -chdir=deployment/terraform/postgres init -backend=false && terraform -chdir=deployment/terraform/postgres validate`; `actionlint` if available. Shane provides real values for `secrets/.env.postgres` in Task 12; commit it with generated passwords and blank bucket and hc values now, or leave creation to Task 12 if the age key is unavailable. Commit.

### Task 9: Nightly restore check on the home server

**Files:**
- Create: `deployment/home-server/guest/pg-restore-verify.sh`, `deployment/home-server/guest/systemd/pg-restore-verify.{service,timer}`, `deployment/home-server/compose.pgverify.yml`
- Modify: `deployment/home-server/lib/vm.sh`, `deployment/home-server/provision`, `deployment/home-server/guest/{install-units,deploy,compose}.sh`, `deployment/home-server/lib/verify.sh`
- Test: `deployment/home-server/test/pg_restore_verify_test.sh`, plus additions to `render_test.sh`, `timers_test.sh`, `provision_test.sh`

**Interfaces:**
- VM role `pgverify`: `VMID=140 NAME=pgverify CORES=4 MEM=8192 OSDISK=32 DATADISK=400`, created only with `PGVERIFY_ENABLED=1` and refusing a blank `HC_PGVERIFY`, on the isolated `vmbr1` with `ip=10.20.0.20/24,gw=10.20.0.1`, like `fetcher`. Confirm `lib/host.sh` allows outbound HTTPS from it and nothing inbound.
- Env for this VM only: `HC_PGVERIFY`, `HC_PGVERIFY_DEPLOY`, `PGVERIFY_REPO_*` (read-only key), `PGVERIFY_CIPHER_PASS`, `PGVERIFY_DUMP_BUCKET`, `PGVERIFY_DUMP_REGION` (`auto`), `PGVERIFY_DUMP_ENDPOINT` (the R2 endpoint, passed to the `aws` container as `AWS_ENDPOINT_URL`; required when upload is on), `PGVERIFY_DUMP_KEY`, `PGVERIFY_DUMP_KEY_SECRET`, `PGVERIFY_UPLOAD_ENABLED` (default `0`).
- No heartbeat unit for this role: it runs no always-on service, and `pg-restore-verified` is its alert.
- Timer `*-*-* 12:00:00 UTC`. Dumps in `/mnt/pgverify/dumps/{daily,monthly}`.
- Core tables: `the_greatest`: `users`, `books_books`, `music_albums`, `music_songs`, `games_games`, `user_list_items`. `tgb`: `users`, `books`, `authors`, `user_list_books`.

- [ ] **Step 1: Write the failing tests**, against stubbed `pgbackrest`, compose, `psql`, `pg_amcheck`, `pg_dump`, `pg_restore`, `aws` and `curl`:
  - Happy path sequence: `start`, restore, checks, dumps, success ping last.
  - `t_restore_fail_pings_fail`.
  - `t_replay_over_26h_old_pings_fail`.
  - `t_core_table_empty_stops_before_dumps`.
  - `t_amcheck_fail_pings_fail`.
  - `t_amcheck_removed_before_dump`: `DROP EXTENSION amcheck` precedes `pg_dump`.
  - `t_row_count_move_finishes_dumps_then_pings_fail_naming_table`.
  - `t_small_table_move_ignored`: under 10,000 rows.
  - `t_first_run_has_no_baseline`.
  - `t_baseline_is_previous_night_even_after_alert`: one real change alerts once.
  - `t_dump_uses_no_subscriptions`.
  - `t_empty_dump_pings_fail`, `t_unreadable_dump_pings_fail`.
  - `t_upload_off_by_default`, `t_upload_on_uses_existing_names`: `postgres_the_greatest_backup_<ts>.sql.gz`, `postgres_tgb_backup_<ts>.sql.gz`.
  - `t_prune_keeps_14_daily_12_monthly`.
  - `t_sunday_restore_starts_from_empty`, `t_weekday_uses_delta`.
  - `t_lock_held_exits_without_ping`.
  - `t_interrupted_restore_recovers`: a leftover marker file forces a from-empty restore.
  - `t_workers_disabled`: Postgres starts with `archive_mode=off` and `max_logical_replication_workers=0`.
  - In `render_test.sh`: `pgverify` env has only its own values, and other roles get none of them.
- [ ] **Step 2:** Run `deployment/home-server/test/run.sh`. Expected: new tests FAIL.
- [ ] **Step 3:** Implement. Use `flock` on the role's lock file. Each `the_greatest` and `tgb` list lives in one array. Count with `reltuples` only if an exact `count(*)` proves too slow in Task 15; start with exact counts.
- [ ] **Step 4:** Run. Expected: PASS, including every existing role's tests. Commit.

### Task 10: Migration tools and the full local rehearsal

**Files:**
- Create: `deployment/postgres/migration/{check-schema,load-schema,create-replication,compare,sync-sequences,set-readonly}.sh`, `deployment/postgres/test/local-e2e-test.sh`
- Test: `deployment/postgres/test/migration_test.sh`

**Interfaces:** All read `SOURCE_DSN` and `TARGET_DSN`. Each takes `DATABASE` first.
- `check-schema.sh DB`: fails on any function, trigger, extension or event trigger outside the expected list in spec §13.1. Also run against `postgres` and `template1`, which must have none.
- `load-schema.sh DB`: `pg_dump --schema-only --no-owner --no-privileges` piped to target as the database's owner role.
- `create-replication.sh DB`: excludes `pghero_query_stats`, `ol_editions`, `ol_works`.
- `compare.sh DB`: exit 1 listing any table whose count or `max(id)` differs, plus sample checksums.
- `sync-sequences.sh DB`: exact source values, preserving `is_called`; then verifies each is at or past its table's `max(id)`.
- `set-readonly.sh DB on|off`: sets it and terminates the database's sessions, both ways.

- [ ] **Step 1: Write the failing `migration_test.sh`:**
  - `t_check_schema_flags_unknown_function`, `t_check_schema_flags_event_trigger_in_system_db`.
  - `t_publication_excludes_listed_tables`.
  - `t_compare_detects_count_and_max_id_differences`.
  - `t_empty_table_sequence_keeps_is_called_false`.
  - `t_readonly_off_terminates_sessions`: sessions opened during the window stay read-only otherwise.
- [ ] **Step 2:** Run. Expected: FAIL. Implement. Run. Expected: PASS.
- [ ] **Step 3: Write `local-e2e-test.sh`,** by hand, needing Docker: `postgres:17` as source, the real image and compose as target, and MinIO as the bucket (plain, unversioned: a stand-in for the R2 backups bucket). R2's lock behaviour is not modelled here; it is proven on real R2, spec §8.4. Asserts:
  - each role per spec §5.2;
  - no plain connection, no network superuser;
  - `show data_checksums` is `on`;
  - a backup, a restore to a chosen timestamp where a later row is absent, and a key without `s3:DeleteObjectVersion` semantics where MinIO allows it;
  - `deploy.sh` refusing an empty directory with a stanza;
  - a full replication with a writer loop running, cutover via the scripts, and every sequence correct;
  - a `tgb`-shaped trigger keeping the source's search text.
- [ ] **Step 4:** Run it. Expected: all PASS, and it prints the read-only window in seconds. Record that in the runbook. If it exceeds 5 minutes, stop and tell Shane.
- [ ] **Step 5:** Commit.

### Task 11: Runbook

**Files:**
- Create: `docs/features/postgres-server.md`
- Modify: `deployment/ENV.md`, `deployment/README.md`, `docs/features/home-server.md`, `.env.example`

- [ ] **Step 1:** Write the runbook per spec §15, with Part B's steps as the source of truth for the move, and one section per alert saying what it means and what to do. Use placeholders for all addresses and bucket names.
- [ ] **Step 2:** Grep the whole branch for anything public-unsafe: `git diff origin/main --name-only | xargs grep -nE '[0-9]{1,3}(\.[0-9]{1,3}){3}'`, and review each hit. `10.20.0.x` and documentation addresses are fine. Commit.
- [ ] **Step 3:** Ask Shane to approve pushing and opening the PR. Merging deploys the web app, and Task 2 is safe with its variables unset.

---

# Part B: live steps

Each of these touches production. Ask Shane before starting each one, and report exact outputs. Follow `docs/features/postgres-server.md`.

### Task 12: Buckets, tokens and alerts (Shane, with agent support)

- [ ] **Step 1 (Shane, R2):** Create a temporary account API token that can edit R2. Run `deployment/postgres/bin/setup-r2.sh` with `CF_API_TOKEN`, `CF_ACCOUNT_ID`, `PGBACKREST_REPO_BUCKET`, `PGVERIFY_DUMP_BUCKET` and the **pre-production** `PGBACKREST_REPO_PATH` in the environment (runbook, "Build", step 2). Expected: last line `setup-r2: done`. Then create the four bucket-scoped tokens per spec §8.2 (server: Object Read & Write on backups; home VM restore: Object Read on backups; home VM upload: Object Read & Write on dumps; developer refresh: Object Read on dumps), and delete the temporary token. No AWS console step remains.
- [ ] **Step 2 (Shane):** Create healthchecks.io checks `pg-backup` (1 day, 2 hours grace), `pg-health` (15 minutes, 15 minutes grace), `pg-restore-verified` (1 day, 2 hours grace). Add the Gmail filter so they stay out of Promotions and Updates, and a phone push channel if the plan includes one.
- [ ] **Step 3:** Put all values in `secrets/.env.postgres` and `secrets/home-server.env`: endpoints `<account id>.r2.cloudflarestorage.com` for pgBackRest (no scheme) and `https://<account id>.r2.cloudflarestorage.com` for `PGVERIFY_DUMP_ENDPOINT`, region `auto`, key id = token id, secret = SHA-256 of the token value. Generate passwords with `openssl rand -hex 32`. Use a pre-production `PGBACKREST_REPO_PATH` for Task 14.

### Task 13: Old server prerequisites

- [ ] **Step 1:** Put the `TGB_DB_*` values in the old site's server `.env` with today's values, and confirm with a diff against a backup copy. Then Shane merges the Task 3 PR. Expected: old site works, database container not restarted (`docker inspect` start time unchanged).
- [ ] **Step 2:** Optional, Shane decides: rotate the old server's `postgres` and `the_greatest` passwords as routine housekeeping, if the move is more than a few weeks away. Change `.env` on the old site, the new app's `LEGACY_BOOKS_PASSWORD` and `POSTGRES_PASSWORD` in SOPS, change them in Postgres, restart both apps at a quiet time.

### Task 14: Build, prove, rebuild (spec §2 steps 1–3)

- [ ] **Step 1 (Shane):** `terraform apply`. Add host and fingerprint secrets.
- [ ] **Step 2:** Run `deploy-postgres`. Add the new server's address to no old allowlist yet. Run `verify-postgres-lockdown.sh --outside`, then `--inside` from both app servers with each login, plus the reboot probe from the OpenSearch runbook: no answer from outside while it boots.
- [ ] **Step 3:** On the pre-production path: sentinel table, backup, restore to a chosen moment on the same server, confirm, and record how long the restore took. Prove the lock: with the server's token, deleting the newest WAL object under `<path>/archive/main/18-` must fail with `ObjectLockedByBucketPolicy` (runbook, "Prove it"). Break a backup deliberately, and **Shane confirms he saw the `pg-backup` and `pg-health` alerts**. The restore check's alert is Task 15 Step 4.
- [ ] **Step 4:** Destroy and rebuild with no SSH fixes, following the runbook's "Rebuild", and verify again. Drop the sentinel table. Switch `PGBACKREST_REPO_PATH` to the real one and **re-run `setup-r2.sh` with it and `R2_REPLACE_LOCK=1`** (Shane, temporary token again), so the lock covers the real WAL archive. R2 locks are bucket rules, so this unlocks the pre-production prefix at once: delete the whole pre-production repo path, archive included, and confirm with `setup-r2.sh --check`. `pg-backup` and `pg-health` run on the real path from here; backups and `pg-health` are unchanged by R2.

### Task 15: Copy and prove (spec Phase 2)

- [ ] **Step 1:** Shane approves a restart time. Old server settings for the move: `wal_level=logical`, TLS with a self-signed certificate, `max_slot_wal_keep_size=20GB`, a `replicator` role with a `hostssl` rule on both databases from the new server's address, and a temporary `hostssl` rule for `postgres` from the new server's address and the app hosts that run `load-schema.sh`. Restart. Expected: both apps reconnect by themselves; check for errors in both logs. Then prove from inside the new server's container that `pg_isready` reaches the old server's port, and that `--outside` still passes.
- [ ] **Step 2:** Freeze migrations on both apps, for at least 8 days, and tell Shane. `check-schema`, `load-schema` (from each database's app host), `create-replication` for each database. Watch `pg_stat_subscription` and the old server's disk.
- [ ] **Step 3:** When lag is near zero: `ANALYZE` both, `compare` both, record the results. Any unique-index failure: fix the row on the source and record it.
- [ ] **Step 4 (Shane):** Set `PGVERIFY_ENABLED=1` and `provision` to create VM 140, on `REPO_REF=main`. Before the nights start, break a restore check deliberately (**Shane confirms he saw the alert**) and see one real run's first success ping. Record that run's restore time from R2 on real data, from the journal. **The dump upload goes on now too:** `PGVERIFY_UPLOAD_ENABLED=1`, `PGVERIFY_DUMP_BUCKET`, `PGVERIFY_DUMP_ENDPOINT=https://<account id>.r2.cloudflarestorage.com`, `PGVERIFY_DUMP_REGION=auto` and the upload token in `secrets/home-server.env`, in the same `provision`. After the first night, `aws s3 ls` with the developer refresh token must list both dumps; optionally, one dev refresh from R2 with `BACKUP_*` on the command line, on Shane's say-so, with dev already on 18. A failed upload pings `fail` and resets the count. **Cutover needs 7 straight passing nights.**
- [ ] **Step 5:** Old site connection test from its production server (spec §11), using a one-off container and a rolled-back write. New app's equivalent, with `rails runner` and `tgb_reader` reads, including `finish_legacy` and the Goodreads rake tasks' reads.

### Task 16: Cutover (spec Phase 3)

Shane picks the day: not a Sunday, starting about 10:30 UTC. Have one SOPS PR per database reviewed and ready, each holding only that database's variables. Do one database at a time.

- [ ] **Step 1:** Confirm no import is running and that neither backup is. Remove the old server's backup cron (the old S3 bucket gets no new dumps from here; dev keeps the last one until Step 7). Stop Sidekiq and the PgHero cron for the affected app.
- [ ] **Step 2:** `set-readonly DB on`. Start the timer.
- [ ] **Step 3:** Wait for the subscription to reach the source's current LSN. `sync-sequences DB`. `compare DB`. Record the target's write count for the rollback. Any failure: `set-readonly DB off`, restart workers, stop.
- [ ] **Step 4:** Switch the app: new app `.env` then `docker compose up -d web worker`; old site `.env` then restart `web worker cable`. For `tgb`, also `LEGACY_BOOKS_*`. Set `POSTGRES_SSLMODE=require` and friends.
- [ ] **Step 5 (Shane):** Real sign-in and a real write on each site. Stop the timer and report the read-only time. Restart workers.
- [ ] **Step 6:** Shane merges this database's SOPS PR, and only this one, or the next deploy points the app back. Drop the subscription. Repeat for the other database.
- [ ] **Step 7:** Switch dev's `.env` to R2 (`BACKUP_BUCKET`, `BACKUP_ENDPOINT`, `BACKUP_AWS_PROFILE` in the root `.env`, with the developer refresh token in that profile); the dumps bucket has had the dumps since Task 15 Step 4. Confirm with a real `bin/refresh-dev-db.sh` on Shane's say-so.

### Task 17: Afterwards (spec Phase 4)

- [ ] **Step 1:** Record hourly `pg_stat_statements` totals to a file outside both databases. After two Sundays, compare the full backup's hours to the same hours on other days. Pass is under 1.5x. Report; if it fails, apply spec §8.1's fallback.
- [ ] **Step 2:** After 14 days, confirm with Shane that nothing on the old server's data volume is needed. Shane deletes it. Remove `postgres/`, the `db` service and backup scripts from the old repo. Remove `deployment/postgres/migration/`. Then retire AWS: the old dump bucket and every AWS key (the old server's and dev refresh's).
- [ ] **Step 3:** Run the restore-to-a-moment drill from the runbook once on a fresh temporary server, then destroy it.
