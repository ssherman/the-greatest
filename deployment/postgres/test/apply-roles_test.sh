#!/usr/bin/env bash
# Unit test for deployment/postgres/bin/apply-roles.sh. Docker is stubbed and the SQL it would send to
# psql is captured, so these check what the script asks for. The rights each role really ends up with
# are checked against a throwaway container (see the Task 6 report; test/local-e2e-test.sh later).
# shellcheck disable=SC2016,SC2155  # stub bodies are single-quoted on purpose; the exports are never checked for failure
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
stub docker 'command -p cat >>"$SANDBOX/log/sql"'
export POSTGRES_THE_GREATEST_PASSWORD="tg-$(openssl rand -hex 8)"
export POSTGRES_TGB_APP_PASSWORD="app-$(openssl rand -hex 8)"
export POSTGRES_TGB_READER_PASSWORD="it's \"odd\" \\ $(openssl rand -hex 4)"
sql="$SANDBOX/log/sql"
has() { grep -qE "$1" "$sql"; }

"$BIN/apply-roles.sh" >"$SANDBOX/log/out" 2>&1; rc=$?
if [ "$rc" = 0 ]; then pass "apply-roles exits 0"; else fail "apply-roles exits 0" "rc=$rc $(cat "$SANDBOX/log/out")"; fi
if called 'docker compose .* exec -T postgres psql -U postgres' && ! called 'PASSWORD'; then
  pass "SQL goes to psql as postgres over the socket, by stdin"; else fail "psql invocation" "$(cat "$CALLS")"; fi

# --- no role is a superuser ----------------------------------------------------------------------
if ! grep -E 'SUPERUSER' "$sql" | grep -vqE 'NOSUPERUSER'; then
  pass "no role is granted SUPERUSER"; else fail "no SUPERUSER grant" "$(grep SUPERUSER "$sql")"; fi
for r in the_greatest tgb_app tgb_reader; do
  if has "ALTER ROLE $r WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD"; then
    pass "$r is a plain login role"; else fail "$r attributes" "missing"; fi
done

# --- passwords are quoted, and kept out of every log ------------------------------------------------
if has "PASSWORD '$POSTGRES_THE_GREATEST_PASSWORD'" && has "PASSWORD '$POSTGRES_TGB_APP_PASSWORD'"; then
  pass "passwords appear as SQL literals on stdin"; else fail "password literals" "$(grep PASSWORD "$sql")"; fi
if grep -qF "PASSWORD 'it''s \"odd\" \\ " "$sql"; then pass "a quote in a password is doubled"; else fail "quote doubling" "$(grep tgb_reader "$sql")"; fi
first_pw="$(grep -nE 'PASSWORD' "$sql" | head -1 | cut -d: -f1)"
for guc in "pg_stat_statements.track = 'none'" "log_min_error_statement = 'panic'" "log_statement = 'none'"; do
  # these must come before the first password, or the statement is recorded with it
  at="$(grep -nF "SET $guc" "$sql" | head -1 | cut -d: -f1)"
  if [ -n "$at" ] && [ "$at" -lt "$first_pw" ]; then pass "SET $guc comes before any password"; else fail "SET $guc" "at=$at first_pw=$first_pw"; fi
done

# --- databases and ownership ------------------------------------------------------------------------
if has 'CREATE DATABASE the_greatest OWNER the_greatest' && has 'CREATE DATABASE tgb OWNER tgb_app'; then
  pass "each database is created with its owner"; else fail "databases" "$(grep DATABASE "$sql")"; fi
if has 'ALTER DATABASE tgb OWNER TO tgb_app' && has 'ALTER SCHEMA public OWNER TO tgb_app'; then
  pass "tgb_app owns database tgb and schema public"; else fail "tgb_app ownership" "missing"; fi
if has 'REVOKE ALL ON DATABASE tgb FROM PUBLIC' && has 'REVOKE ALL ON DATABASE the_greatest FROM PUBLIC'; then
  pass "PUBLIC has no rights on either database"; else fail "PUBLIC revoked" "missing"; fi

# --- tgb_app: monitoring ----------------------------------------------------------------------------
if has 'GRANT pg_monitor TO tgb_app'; then pass "tgb_app is a pg_monitor member"; else fail "pg_monitor" "missing"; fi

# --- tgb_reader: read only --------------------------------------------------------------------------
if has 'GRANT CONNECT ON DATABASE tgb TO tgb_reader' && has 'GRANT USAGE ON SCHEMA public TO tgb_reader' \
   && has 'GRANT SELECT ON ALL TABLES IN SCHEMA public TO tgb_reader'; then
  pass "tgb_reader gets CONNECT, USAGE and SELECT"; else fail "reader grants" "$(grep tgb_reader "$sql")"; fi
if has 'ALTER DEFAULT PRIVILEGES FOR ROLE tgb_app IN SCHEMA public GRANT SELECT ON TABLES TO tgb_reader'; then
  pass "tables tgb_app creates later are readable too"; else fail "default privileges" "missing"; fi
if ! grep -E 'GRANT .*(INSERT|UPDATE|DELETE|ALL PRIVILEGES|CREATE)' "$sql" | grep -q tgb_reader; then
  pass "tgb_reader is granted nothing that writes"; else fail "reader writes" "$(grep tgb_reader "$sql")"; fi

# --- extensions: exactly the promised ones, in tgb only -------------------------------------------------
exts="$(grep -oE 'CREATE EXTENSION IF NOT EXISTS [a-z_]+' "$sql" | awk '{print $NF}' | sort | tr '\n' ' ')"
if [ "$exts" = "btree_gin btree_gist fuzzystrmatch pg_stat_statements pg_trgm unaccent " ]; then
  pass "exactly the six tgb extensions are created"; else fail "extension list" "$exts"; fi
if ! awk '/^\\connect/{db=$2} /CREATE EXTENSION/{print db}' "$sql" | grep -vqx 'tgb'; then
  pass "extensions are created inside tgb only"; else fail "extension database" "$(grep -n connect "$sql")"; fi

# --- re-running: only the passwords change --------------------------------------------------------------
if ! grep -E '^(CREATE ROLE|CREATE DATABASE|DROP|TRUNCATE)' "$sql" | grep -q .; then
  pass "no unconditional CREATE or DROP"; else fail "unconditional create" "$(grep -E '^(CREATE ROLE|CREATE DATABASE)' "$sql")"; fi
if grep -qE 'WHERE NOT EXISTS' "$sql" && grep -q '\\gexec' "$sql"; then pass "roles and databases are created only if absent"; else fail "conditional create" "missing"; fi

# --- missing passwords ----------------------------------------------------------------------------------
for v in POSTGRES_THE_GREATEST_PASSWORD POSTGRES_TGB_APP_PASSWORD POSTGRES_TGB_READER_PASSWORD; do
  : >"$CALLS"; : >"$sql"
  out="$(env -u "$v" "$BIN/apply-roles.sh" 2>&1)"; rc=$?
  if [ "$rc" != 0 ] && grep -q "$v" <<<"$out" && ! [ -s "$sql" ]; then pass "$v missing: named, nothing sent"; else fail "$v missing" "rc=$rc $out"; fi
done
finish
