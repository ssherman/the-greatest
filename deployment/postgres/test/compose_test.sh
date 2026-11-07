#!/usr/bin/env bash
# Checks on deployment/postgres/compose.yml and the Dockerfile. Needs `docker compose config` (no daemon).
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
compose="$OS_DIR/compose.yml"
rendered="$(POSTGRES_SUPERUSER_PASSWORD=x docker compose -f "$compose" config 2>&1)"
chk() { if grep -qE "$2" <<<"$rendered"; then pass "$1"; else fail "$1" "no match for $2"; fi; }
chk "project name postgres-server" '^name: postgres-server$'
chk "data mounted at the parent /var/lib/postgresql" 'target: /var/lib/postgresql$'
chk "named volume postgres-data" 'source: postgres-data$'
chk "bound to 0.0.0.0" 'host_ip: 0\.0\.0\.0'
chk "published 6543" 'published: "6543"'
chk "target 5432" 'target: 5432$'
chk "stop_grace_period 120s (a clean shutdown checkpoint outlasts Docker's 10 s)" 'stop_grace_period: "?(120s|2m0s)"?$'
chk "shm_size 1g" 'shm_size: "?(1g|1073741824)"?$'
chk "restart unless-stopped" 'restart: unless-stopped'
chk "log max-size 100m" 'max-size: 100m'
chk "log max-file 20" 'max-file: "20"'
chk "config_file flag" 'config_file=/etc/postgresql/postgresql\.conf'
chk "hba_file flag" 'hba_file=/etc/postgresql-host/pg_hba\.conf'
chk "data checksums at init" 'POSTGRES_INITDB_ARGS:.*--data-checksums'
chk "superuser password from the environment" 'POSTGRES_PASSWORD: x'
chk "pgbackrest reads the rendered host config" 'PGBACKREST_CONFIG: /etc/postgresql-host/pgbackrest\.conf'
chk "runs as the image's postgres user" '^    user: "?999:999"?$'
chk "initdb locale is en_US.utf8" 'POSTGRES_INITDB_ARGS:.*--locale=en_US\.utf8( |")'
chk "initdb encoding is UTF8" 'POSTGRES_INITDB_ARGS:.*--encoding=UTF8'
if ! grep -qE 'en_US\.UTF-8' <<<"$rendered"; then pass "no en_US.UTF-8 spelling"; else fail "locale spelling" "en_US.UTF-8 present"; fi
hc="$(grep -E '^\s+- pg_isready' <<<"$rendered")"
if grep -q 'pg_isready -U postgres' <<<"$hc" && ! grep -qE -- ' -h' <<<"$hc"; then
  pass "healthcheck probes the socket (no -h)"; else fail "healthcheck" "$hc"; fi
chk "certs mounted" 'target: /etc/postgresql-certs'
ro="$(grep -c 'read_only: true' <<<"$rendered")"
if [ "$ro" = 3 ]; then pass "all three host/config mounts are read-only"; else fail "read-only mounts" "count=$ro"; fi
ports="$(sed -n '/^    ports:/,/^    [a-z]/p' "$compose" | grep -E '^\s+- ')"
if [ -n "$ports" ] && ! grep -vqE '^\s+- "0\.0\.0\.0:' <<<"$ports"; then pass "ports are IPv4 only"; else fail "IPv4-only ports" "$ports"; fi
if grep -qE '^FROM postgres:18\.[0-9]+.*@sha256:[0-9a-f]{64}' "$OS_DIR/Dockerfile"; then
  pass "Dockerfile FROM pins a 18.x tag with a digest"; else fail "Dockerfile FROM" "$(grep ^FROM "$OS_DIR/Dockerfile")"; fi
# PGDG's current index drops older versions, so an exact pin needs the archive repo to stay installable.
if grep -qE 'apt-archive\.postgresql\.org/pub/repos/apt +trixie-pgdg-archive +main' "$OS_DIR/Dockerfile"; then
  pass "Dockerfile adds PGDG's archive repo for trixie"; else fail "Dockerfile archive repo" "not found"; fi
if grep -q 'apt-get update --error-on=any' "$OS_DIR/Dockerfile"; then pass "an unreachable apt source fails the build"; else fail "apt-get update --error-on=any" "not found"; fi
# The base image has no CA bundle, and without one pgBackRest cannot verify the S3 endpoint at all.
if grep -q 'install -y --no-install-recommends ca-certificates' "$OS_DIR/Dockerfile"; then pass "the image installs a CA bundle"; else fail "ca-certificates" "not found"; fi
if grep -qE 'pgbackrest=[0-9][^ ]*' "$OS_DIR/Dockerfile"; then pass "pgBackRest is pinned to an exact version"; else fail "pgBackRest pin" "not found"; fi
if grep -q 'apt-mark hold libc6 locales libicu76' "$OS_DIR/Dockerfile"; then pass "the sort-order libraries are held"; else fail "apt-mark hold" "not found"; fi
finish
