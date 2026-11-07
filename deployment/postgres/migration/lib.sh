#!/usr/bin/env bash
# deployment/postgres/migration/lib.sh -- sourced by the migration scripts; not run.
# Spec: docs/superpowers/specs/2026-11-06-postgres-server-design.md §5.4, §13.
#
# Environment shared by every script (each takes DATABASE as its first argument):
#   SOURCE_DSN / TARGET_DSN        libpq keyword/value strings WITHOUT dbname and WITHOUT a password,
#                                  e.g. "host=old.example user=postgres sslmode=require". The script
#                                  appends dbname=DATABASE. A password in a DSN would sit in `ps`.
#   SOURCE_PGPASSWORD / TARGET_PGPASSWORD   their passwords, handed to libpq by environment.
#   SOURCE_PSQL / TARGET_PSQL      optional, instead of the DSN: a command that runs psql as an admin,
#                                  to which the script appends `-d DATABASE`. The new server's
#                                  superuser exists on its Unix socket inside the container only, so
#                                  its admin steps run as
#                                  TARGET_PSQL="docker compose -f /path/compose.yml exec -T postgres psql -U postgres".
#
# Exit codes: 0 fine, 1 the check ran and found a difference or a problem, 2 the script could not
# do its job (bad input, a query that failed). A failed query is never read as "nothing found".
# shellcheck shell=bash
# shellcheck disable=SC2034  # the SQL fragments and names are used by the scripts that source this

SCRIPT="$(basename "$0")"
EXCLUDED_TABLES=(pghero_query_stats ol_editions ol_works)

die() { echo "$SCRIPT: $1" >&2; exit "${2:-2}"; }

# Names reach SQL and a DSN; real database names here are plain.
check_db_name() {
  [[ "${1:-}" =~ ^[a-z_][a-z0-9_]*$ ]] || die "DATABASE must be a plain lowercase name (got: '${1:-}')"
}

# excluded_sql: 'a','b','c' for use inside IN ( ).
excluded_sql() {
  local out="" t
  for t in "${EXCLUDED_TABLES[@]}"; do out="${out:+$out,}'$t'"; done
  printf '%s' "$out"
}

# side_psql SIDE DATABASE [psql args...]: SQL arrives on stdin or by -c. ON_ERROR_STOP is always on.
side_psql() {
  local db="$2" cmdvar="${1}_PSQL" dsnvar="${1}_DSN" pwvar="${1}_PGPASSWORD" pw
  shift 2
  pw="${!pwvar:-}"
  local -a base
  if [ -n "${!cmdvar:-}" ]; then
    read -ra base <<<"${!cmdvar}"
    "${base[@]}" -d "$db" -X -q -v ON_ERROR_STOP=1 "$@"
  elif [ -n "${!dsnvar:-}" ]; then
    if [ -n "$pw" ]; then
      PGPASSWORD="$pw" psql "${!dsnvar} dbname=$db" -X -q -v ON_ERROR_STOP=1 "$@"
    else
      psql "${!dsnvar} dbname=$db" -X -q -v ON_ERROR_STOP=1 "$@"
    fi
  else
    die "set ${dsnvar} (or ${cmdvar})"
  fi
}
sq() { side_psql SOURCE "$@"; }
tq() { side_psql TARGET "$@"; }

# Tables the migration is about: ordinary tables outside the system schemas, not owned by an
# extension, not on the exclusion list. One schema-qualified name per line.
TABLES_SQL="SELECT format('%I.%I', n.nspname, c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp%'
  AND c.relname NOT IN ($(excluded_sql))
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
ORDER BY 1"

# Sequences, same filter.
SEQUENCES_SQL="SELECT format('%I.%I', n.nspname, c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'S'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp%'
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
ORDER BY 1"

# One publication and one subscription per database.
pub_name() { printf 'migration_pub_%s' "$1"; }
sub_name() { printf 'migration_sub_%s' "$1"; }

# A SQL string literal: quotes doubled, standard_conforming_strings assumed on (every script sets it).
lit() { local s="${1//\'/\'\'}"; printf "'%s'" "$s"; }

# require_source_readonly DB: a new session on the old server must report default_transaction_read_only = on.
# A catch-up or a sequence copy against a writable source proves nothing: the next write moves the target.
# Read in a fresh session, so a role-level setting that overrides the database one shows up as off.
require_source_readonly() {
  local v
  v="$(sq "$1" -At -c 'SHOW default_transaction_read_only' </dev/null)" || die "could not read the old server's read-only state"
  [ "$v" = on ] || die "the old server's $1 is writable (default_transaction_read_only=$v in a new session); run set-readonly.sh $1 on first"
}

# source_readonly_state DB: prints on or off.
source_readonly_state() {
  sq "$1" -At -c 'SHOW default_transaction_read_only' </dev/null || die "could not read the old server's read-only state"
}

# check_excluded_empty DB: the tables that are not replicated (ol_editions, ol_works) must hold no row on the
# old server, or those rows would be left behind silently. pghero_query_stats is deliberately not copied and
# is not checked. Returns 1 and names the tables when one has rows.
check_excluded_empty() {
  local t n bad=""
  for t in ol_editions ol_works; do
    n="$(sq "$1" -At -c "SELECT CASE WHEN to_regclass('$t') IS NULL THEN 0 ELSE (xpath('/row/c/text()', query_to_xml('select count(*) as c from (select 1 from $t limit 1) s', false, true, '')))[1]::text::int END" </dev/null)" \
      || die "could not look at $t on the old server"
    if [ "$n" != 0 ]; then bad="$bad $t"; fi
  done
  if [ -n "$bad" ]; then
    echo "$SCRIPT: these tables are not replicated but hold rows on the old server, so the rows would be lost:$bad" >&2
    return 1
  fi
}

# Keep a statement that carries a secret out of every place a statement is recorded. Needs a
# superuser, so it does nothing for anyone else (a plain role cannot set these).
quiet_session_sql() {
  cat <<'SQL'
SET standard_conforming_strings = on;
SET client_min_messages = warning;
DO $quiet$
BEGIN
  IF current_setting('is_superuser') = 'on' THEN
    SET log_statement = 'none';
    SET log_min_error_statement = 'panic';
    SET log_min_duration_statement = -1;
    SET pg_stat_statements.track = 'none';
  END IF;
END
$quiet$;
SQL
}
