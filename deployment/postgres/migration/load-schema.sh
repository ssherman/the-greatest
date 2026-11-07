#!/usr/bin/env bash
# deployment/postgres/migration/load-schema.sh DATABASE
# Loads the source's schema, and only the schema, into the new server's database, as that database's
# OWNER role: `pg_dump --schema-only --no-owner --no-privileges --no-publications --no-subscriptions`,
# then psql. Spec §5.4.
#   SOURCE_DSN / SOURCE_PGPASSWORD   a role that can read the schema
#   TARGET_DSN / TARGET_PGPASSWORD   the owner of the target database (tgb_app for tgb, the_greatest
#                                    for the_greatest). This script deliberately ignores TARGET_PSQL:
#                                    loading as the superuser would make the superuser the owner.
#
# Because the load runs as the owner and the dump carries no ownership, the owner ends up owning every
# object, and the default privileges apply-roles.sh set for tgb_app give tgb_reader SELECT on each table.
# The new server's roles and grants are never copied from the old one. Publications and subscriptions
# are not dumped: this script's whole point is to create the only ones that should exist (create-replication.sh).
#
# The dump's `CREATE EXTENSION IF NOT EXISTS` lines are kept: apply-roles.sh already made the extensions,
# so they do nothing but print a notice, and a missing extension still fails the load loudly. The
# `COMMENT ON EXTENSION` lines are removed, because an extension is owned by the superuser that created
# it and the owner role may not comment on it. Filtering is used rather than --no-comments, which would
# also drop every table and column comment.
#
# All or nothing, in two steps. 1) The dump is saved to a file first, and the load does not start unless
# pg_dump exited 0 AND the file ends with pg_dump's own "dump complete" line: a dump cut short (a dropped
# connection, a killed pg_dump) can otherwise be a prefix that is valid SQL, and a pipe would load and commit
# that prefix. 2) psql runs the file as ONE transaction (--single-transaction) with ON_ERROR_STOP, so the first
# SQL error rolls everything back and the target is as it was.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

db="${1:-}"
check_db_name "$db"
[ -n "${SOURCE_DSN:-}" ] || die "set SOURCE_DSN"
[ -n "${TARGET_DSN:-}" ] || die "set TARGET_DSN (the database's owner role; TARGET_PSQL is not used here)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

src_pw="${SOURCE_PGPASSWORD:-}" tgt_pw="${TARGET_PGPASSWORD:-}"
dump() {
  if [ -n "$src_pw" ]; then
    PGPASSWORD="$src_pw" pg_dump --schema-only --no-owner --no-privileges --no-publications --no-subscriptions "$SOURCE_DSN dbname=$db"
  else
    pg_dump --schema-only --no-owner --no-privileges --no-publications --no-subscriptions "$SOURCE_DSN dbname=$db"
  fi
}
load() {   # the SQL arrives on stdin: psql may run in a client container that cannot see our files
  if [ -n "$tgt_pw" ]; then
    PGPASSWORD="$tgt_pw" psql "$TARGET_DSN dbname=$db" -X -q --single-transaction -v ON_ERROR_STOP=1 -f -
  else
    psql "$TARGET_DSN dbname=$db" -X -q --single-transaction -v ON_ERROR_STOP=1 -f -
  fi
}

dump >"$work/dump.sql" </dev/null || die "pg_dump failed; nothing was loaded"
if ! tail -n 20 "$work/dump.sql" | grep -q '^-- PostgreSQL database dump complete'; then
  die "the dump does not end with pg_dump's completion line (truncated?); nothing was loaded"
fi
sed '/^COMMENT ON EXTENSION /d' "$work/dump.sql" >"$work/load.sql"
load <"$work/load.sql" || die "the load failed; the single transaction was rolled back, the target is unchanged" 1
echo "load-schema: $db schema loaded as the owner role"
