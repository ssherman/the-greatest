#!/usr/bin/env bash
# Spec §6 and §8.1 values, exactly, in postgresql.conf and pgbackrest.conf.tmpl.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
pg="$OS_DIR/config/postgresql.conf"
br="$OS_DIR/config/pgbackrest.conf.tmpl"
want_pg=(
  "shared_buffers = 2GB" "effective_cache_size = 6GB" "work_mem = 5242kB" "maintenance_work_mem = 512MB"
  "max_connections = 200" "wal_buffers = 16MB" "checkpoint_completion_target = 0.9" "max_wal_size = 4GB"
  "min_wal_size = 1GB" "random_page_cost = 1.1" "effective_io_concurrency = 200" "default_statistics_target = 100"
  "shared_preload_libraries = 'pg_stat_statements'" "wal_level = replica" "archive_mode = on"
  "archive_command = 'pgbackrest --stanza=main archive-push %p'" "archive_timeout = 300" "max_worker_processes = 8"
  "log_connections = on" "log_disconnections = on" "log_min_duration_statement = 1000" "log_lock_waits = on"
  "track_io_timing = on" "ssl = on" "ssl_min_protocol_version = 'TLSv1.2'"
  "ssl_cert_file = '/etc/postgresql-certs/server.pem'" "ssl_key_file = '/etc/postgresql-certs/server-key.pem'"
  "listen_addresses = '*'" "port = 5432"
  "max_parallel_workers = 4" "max_parallel_workers_per_gather = 2" "max_parallel_maintenance_workers = 2"
)
for l in "${want_pg[@]}"; do
  if grep -qxF "$l" "$pg"; then pass "postgresql.conf: $l"; else fail "postgresql.conf: $l" "line missing"; fi
done
if ! grep -qE '^\s*io_method' "$pg"; then pass "no io_method line"; else fail "no io_method line" "present"; fi
if grep -qE '^max_parallel_workers_per_gather = ' "$pg"; then pass "parallel settings present"; else fail "parallel settings" "missing"; fi
want_br=(
  "repo1-retention-full-type=time" "repo1-retention-full=30" "repo1-cipher-type=aes-256-cbc" "compress-type=zst"
  "process-max=1" "start-fast=n" "repo1-type=s3" "[main]" "pg1-path=/var/lib/postgresql/18/docker"
)
for l in "${want_br[@]}"; do
  if grep -qxF "$l" "$br"; then pass "pgbackrest.conf.tmpl: $l"; else fail "pgbackrest.conf.tmpl: $l" "line missing"; fi
done
# R2 takes the default (virtual-host) URI style; that is what was proven on real R2 on 2026-11-07.
if ! grep -qE '^\s*repo1-s3-uri-style' "$br"; then pass "no uri-style line"; else fail "no uri-style line" "present"; fi
for v in PGBACKREST_REPO_BUCKET PGBACKREST_REPO_ENDPOINT PGBACKREST_REPO_REGION PGBACKREST_REPO_PATH PGBACKREST_REPO_KEY PGBACKREST_REPO_KEY_SECRET PGBACKREST_CIPHER_PASS; do
  if grep -qF "\${$v}" "$br"; then pass "placeholder $v"; else fail "placeholder $v" "missing"; fi
done
finish
