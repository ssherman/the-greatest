#!/usr/bin/env bash
# deployment/postgres/migration/create-replication.sh DATABASE [create|drop]
# Spec §13.2 steps 4-5 and 16. `create` (the default) makes a publication on the old server listing every
# ordinary table except pghero_query_stats, ol_editions and ol_works, a dedicated `replicator` login that can
# read exactly those tables, and a subscription on the new server (which creates the slot, copies the data,
# then follows). `drop` removes the subscription (and with it the slot) and the publication.
#
#   SOURCE_DSN/SOURCE_PSQL   an admin on the old server: it creates the publication and the role
#   TARGET_DSN/TARGET_PSQL   a role on the new server that may create subscriptions: the superuser through
#                            TARGET_PSQL, or an owner role that was granted pg_create_subscription
#   REPLICATOR_PASSWORD      the replicator login's password (set here with ALTER ROLE, so this is the truth)
#   REPLICATION_HOST         how the NEW server reaches the OLD one (an address or name)
#   REPLICATION_PORT         default 5432
#
# The password travels on stdin only: it is never in an argument list, and the session first turns off
# statement logging where the role may (a superuser). It IS stored, readable by superusers, in
# pg_subscription.subconninfo, which is one more reason to drop the subscription at the end.
# Before creating anything it checks what would otherwise break the old site or the copy: wal_level, a
# max_slot_wal_keep_size cap (without one a stuck slot can fill the old server's disk), partitioned tables,
# a published table that has no way to identify its rows (an UPDATE on it would start failing on the live
# site), and a target that is missing a table.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

db="${1:-}"
mode="${2:-create}"
check_db_name "$db"
case "$mode" in create | drop) ;; *) die "usage: create-replication.sh DATABASE [create|drop]" ;; esac
pub="$(pub_name "$db")" sub="$(sub_name "$db")"

if [ "$mode" = drop ]; then
  # DROP SUBSCRIPTION removes the slot on the old server through the stored connection.
  tq "$db" -c "DROP SUBSCRIPTION IF EXISTS $sub" </dev/null
  # By now the old server is read-only (step 10), and DROP PUBLICATION is a write: this session opts out.
  printf 'SET default_transaction_read_only = off;\nDROP PUBLICATION IF EXISTS %s;\n' "$pub" | sq "$db"
  echo "create-replication: $db subscription $sub and publication $pub dropped. The replicator role is kept for the other database; drop it with DROP OWNED BY replicator; DROP ROLE replicator; when both are done."
  exit 0
fi

: "${REPLICATOR_PASSWORD:?set REPLICATOR_PASSWORD}"
: "${REPLICATION_HOST:?set REPLICATION_HOST (how the new server reaches the old one)}"
port="${REPLICATION_PORT:-5432}"
[[ "$port" =~ ^[0-9]+$ ]] || die "REPLICATION_PORT must be a number"
[[ "$REPLICATION_HOST" =~ ^[A-Za-z0-9._:-]+$ ]] || die "REPLICATION_HOST must be a plain host name or address"

# 1. Preconditions on the old server.
wal_level="$(sq "$db" -At -c 'SHOW wal_level' </dev/null)" || die "could not read wal_level"
if [ "$wal_level" != logical ]; then
  echo "create-replication: the old server has wal_level=$wal_level; it needs logical (spec step 4, one restart)" >&2
  exit 1
fi
cap="$(sq "$db" -At -c "SELECT setting FROM pg_settings WHERE name = 'max_slot_wal_keep_size'" </dev/null)" || die "could not read max_slot_wal_keep_size"
if [ "$cap" = -1 ]; then
  echo "create-replication: max_slot_wal_keep_size is unlimited on the old server; a stuck slot could fill its disk. Set it (spec step 4: 20GB)." >&2
  exit 1
fi
partitioned="$(sq "$db" -At -c "SELECT format('%I.%I', n.nspname, c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'p' AND n.nspname NOT IN ('pg_catalog', 'information_schema')" </dev/null)" || die "could not look for partitioned tables"
if [ -n "$partitioned" ]; then
  echo "create-replication: partitioned tables are not handled by this script: $(tr '\n' ' ' <<<"$partitioned")" >&2
  exit 1
fi
check_excluded_empty "$db" || { echo "create-replication: nothing was created" >&2; exit 1; }
mapfile -t tables < <(sq "$db" -At -c "$TABLES_SQL" </dev/null)
[ "${#tables[@]}" -gt 0 ] || die "the old server's $db has no tables to publish"

noident="$(sq "$db" -At -c "
SELECT format('%I.%I', n.nspname, c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE format('%I.%I', n.nspname, c.relname) = ANY (string_to_array(\$list\$$(IFS=,; echo "${tables[*]}")\$list\$, ','))
  AND NOT (
    (c.relreplident = 'd' AND EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary))
    OR c.relreplident = 'f'
    OR (c.relreplident = 'i' AND EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisreplident)))" </dev/null)" \
  || die "could not check the tables' replica identity"
if [ -n "$noident" ]; then
  echo "create-replication: these tables have no primary key or replica identity; once published, an UPDATE or DELETE on them would fail on the live site: $(tr '\n' ' ' <<<"$noident")" >&2
  echo "create-replication: nothing was created" >&2
  exit 1
fi
exists="$(sq "$db" -At -c "SELECT count(*) FROM pg_publication WHERE pubname = '$pub'" </dev/null)" || die "could not look for an existing publication"
if [ "$exists" != 0 ]; then
  echo "create-replication: publication $pub already exists on the old server; run 'create-replication.sh $db drop' first if it is stale" >&2
  exit 1
fi

# 2. The new server must already have every table (load-schema.sh), or the copy fails per table.
mapfile -t have < <(tq "$db" -At -c "$TABLES_SQL" </dev/null)
# Byte order for both sort and comm: under en_US.UTF-8 on the new server's Ubuntu they disagree about names
# with underscores, so comm called sort's own output unsorted and the check failed on matching lists.
missing="$(LC_ALL=C comm -23 <(printf '%s\n' "${tables[@]}" | LC_ALL=C sort) <(printf '%s\n' "${have[@]}" | LC_ALL=C sort) | tr '\n' ' ')"
if [ -n "${missing// /}" ]; then
  echo "create-replication: the new server's $db lacks: $missing(run load-schema.sh first)" >&2
  exit 1
fi

# 3. The old server: the replicator login, its read rights on exactly the published tables, the publication.
tablelist="$(IFS=,; echo "${tables[*]}")"
schemas="$(printf '%s\n' "${tables[@]}" | sed 's/\..*//' | sort -u | tr '\n' ',' | sed 's/,$//')"
{
  quiet_session_sql
  printf "SELECT 'CREATE ROLE replicator' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') \\\\gexec\n"
  printf "ALTER ROLE replicator WITH LOGIN REPLICATION NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD %s;\n" "$(lit "$REPLICATOR_PASSWORD")"
  # The old the_greatest database has CONNECT revoked from PUBLIC (only its owner may connect), so the
  # subscription was refused with "permission denied for database". DROP OWNED BY at step 16 revokes this too.
  printf 'GRANT CONNECT ON DATABASE %s TO replicator;\n' "$db"
  printf 'GRANT USAGE ON SCHEMA %s TO replicator;\n' "$schemas"
  printf 'GRANT SELECT ON %s TO replicator;\n' "$tablelist"
  printf 'CREATE PUBLICATION %s FOR TABLE %s;\n' "$pub" "$tablelist"
} | sq "$db"

# 4. The new server: the subscription. sslmode=require; the conninfo is a string inside a string, so
# backslash and quote are escaped for libpq first and the quote doubled for SQL after.
conn_escape() { local s="${1//\\/\\\\}"; printf '%s' "${s//\'/\\\'}"; }
conninfo="host=$REPLICATION_HOST port=$port dbname=$db user=replicator sslmode=require password='$(conn_escape "$REPLICATOR_PASSWORD")'"
{
  quiet_session_sql
  printf 'CREATE SUBSCRIPTION %s CONNECTION %s PUBLICATION %s WITH (copy_data = true, create_slot = true, slot_name = %s);\n' \
    "$sub" "$(lit "$conninfo")" "$pub" "$(lit "$sub")"
} | tq "$db"

echo "create-replication: $db publication $pub (${#tables[@]} tables) and subscription $sub created. The copy has started; wait-catchup.sh $db --initial waits for it."
