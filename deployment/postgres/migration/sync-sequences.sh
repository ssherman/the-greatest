#!/usr/bin/env bash
# deployment/postgres/migration/sync-sequences.sh DATABASE [--allow-backward]
# Spec §13.2 step 12. Logical replication copies no sequences, so at cutover every sequence on the new server
# is set to the old server's exact last_value AND is_called (setval(seq, last_value, is_called)): a sequence
# that was never used, as on an empty table, stays "not called", so its first value is 1 and not 2. Then every
# sequence is read back from the new server and checked to be at or past the max of the column that owns
# it: when called, last_value >= max; when not called, last_value > max (the next value must be fresh).
# A sequence is tied to a column by ownership (serial, identity) or by being the column's DEFAULT nextval();
# one with neither is copied and listed as not verifiable and does not stop the run. A sequence on one side
# only, or one behind its table, is reported by name and the script exits 1. Zero sequences on either side is
# refused: a database with none is more likely a wrong database than a finished one.
# Refuses (exit 2) unless a new session on the old server reports default_transaction_read_only=on, because
# values read from a server that is still being written are not final. Run it after set-readonly.sh on and
# wait-catchup.sh.
# setval is not transactional, so the copy is NOT all-or-nothing: the names are checked first (a sequence the
# new server lacks stops the script before anything is set), but if setval fails part-way the sequences already
# processed keep their new values. Running the script again is safe ONLY BEFORE step 14 (the app still writes to
# the old server), because it sets the same values again. After the app writes to the new server its sequences are
# ahead of the old server's, and a rerun would move them backward and hand out ids that already exist. So the script
# refuses (exit 1, nothing set) when any sequence on the new server is ahead of the old server's, unless
# --allow-backward is given.
# Exit 0 done and verified, 1 a sequence is wrong or missing, 2 could not do it.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

db="${1:-}"
check_db_name "$db"
allow_backward=0
case "${2:-}" in "") ;; --allow-backward) allow_backward=1 ;; *) die "usage: sync-sequences.sh DATABASE [--allow-backward]" ;; esac
require_source_readonly "$db"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 1. The old server's state, from one generated UNION ALL query: name|last_value|is_called.
read -r -d '' SRC_SQL <<SQL || true
SELECT coalesce(string_agg(format('SELECT %L AS s, last_value::text AS v, is_called AS c FROM %s', name, name), ' UNION ALL ' ORDER BY name),
  'SELECT NULL::text, NULL::text, NULL::bool WHERE false') AS q
FROM ($SEQUENCES_SQL) x(name)
\gset
:q
SQL
printf '%s\n' "$SRC_SQL" | sq "$db" -At -F '|' >"$work/source" || die "could not read the sequences from the old server"
n="$(wc -l <"$work/source")"
echo "sync-sequences: $n sequence(s) on the old server"
if [ "$n" = 0 ]; then echo "sync-sequences: the old server's $db has no sequences; refusing (wrong database?)" >&2; exit 1; fi
tq "$db" -At -c "$SEQUENCES_SQL" </dev/null >"$work/target-names" || die "could not list the sequences on the new server"
if [ ! -s "$work/target-names" ]; then echo "sync-sequences: the new server's $db has no sequences; refusing (is the schema loaded?)" >&2; exit 1; fi
missing="$(LC_ALL=C comm -23 <(cut -d'|' -f1 "$work/source" | LC_ALL=C sort) <(LC_ALL=C sort "$work/target-names"))"
if [ -n "$missing" ]; then
  echo "sync-sequences: these sequences exist on the old server but not on the new one; nothing was set: $(tr '\n' ' ' <<<"$missing")" >&2
  exit 1
fi

# 1b. Never move a sequence backward unless told to: the new server may already be serving writes.
printf '%s\n' "$SRC_SQL" | tq "$db" -At -F '|' >"$work/target-before" || die "could not read the sequences from the new server"
backward="$(LC_ALL=C join -t'|' <(LC_ALL=C sort -t'|' -k1,1 "$work/source") <(LC_ALL=C sort -t'|' -k1,1 "$work/target-before") |
  awk -F'|' '{ s = $2 * 2 + ($3 == "t"); t = $4 * 2 + ($5 == "t"); if (t > s) print $1 " (new server t=" $4 "," $5 ", old server " $2 "," $3 ")" }')"
if [ -n "$backward" ] && [ "$allow_backward" != 1 ]; then
  echo "sync-sequences: these sequences are AHEAD on the new server; setting them would hand out ids that may already exist. Nothing was set. Use --allow-backward only if you are sure nothing has written to the new server:" >&2
  echo "$backward" >&2
  exit 1
fi

# 2. Set them on the new server (not transactional; see the header).
{
  while IFS='|' read -r name value called; do
    case "$called" in t) c=true ;; f) c=false ;; *) die "unexpected is_called for $name: '$called'" ;; esac
    [[ "$value" =~ ^-?[0-9]+$ ]] || die "unexpected last_value for $name: '$value'"
    printf 'SELECT setval(%s, %s, %s);\n' "$(lit "$name")" "$value" "$c"
  done <"$work/source"
} >"$work/setval.sql"
tq "$db" -o /dev/null <"$work/setval.sql" || die "setval failed on the new server; some sequences may already have been set (setval is not transactional). Fix the cause and run this script again; it is safe to repeat"

# 3. Verify, reading back from the new server: name|owning table.column|max|last_value|is_called.
read -r -d '' VERIFY_SQL <<SQL || true
WITH q(name) AS ($SEQUENCES_SQL), s AS (
  SELECT q.name AS seq, coalesce(d.refobjid, ad.adrelid) AS tbl, coalesce(d.refobjsubid, ad.adnum) AS attnum
  FROM q LEFT JOIN pg_depend d ON d.classid = 'pg_class'::regclass AND d.objid = to_regclass(q.name)
       AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')
  LEFT JOIN pg_depend dd ON dd.classid = 'pg_attrdef'::regclass AND dd.refclassid = 'pg_class'::regclass
       AND dd.refobjid = to_regclass(q.name)
  LEFT JOIN pg_attrdef ad ON ad.oid = dd.objid)
SELECT coalesce(string_agg(
  CASE WHEN s.tbl IS NULL
    THEN format('SELECT %L AS seq, NULL::text AS owner, NULL::numeric AS mx, last_value, is_called FROM %s', s.seq, s.seq)
    ELSE format('SELECT %L, %L, (SELECT max(%I) FROM %s)::numeric, last_value, is_called FROM %s',
                s.seq, format('%s.%I', s.tbl::regclass, a.attname), a.attname, s.tbl::regclass, s.seq) END,
  ' UNION ALL ' ORDER BY s.seq),
  'SELECT NULL::text, NULL::text, NULL::numeric, NULL::bigint, NULL::bool WHERE false') AS q
FROM s LEFT JOIN pg_attribute a ON a.attrelid = s.tbl AND a.attnum = s.attnum
\gset
:q
SQL
printf '%s\n' "$VERIFY_SQL" | tq "$db" -At -F '|' >"$work/target" || die "could not read the sequences back from the new server"

bad=0 verified=0 unowned=()
while IFS='|' read -r seq owner mx last called; do
  if ! cut -d'|' -f1 "$work/source" | grep -qxF -- "$seq"; then
    echo "WRONG  $seq exists on the new server only"; bad=$((bad + 1)); continue
  fi
  if [ -z "$owner" ]; then unowned+=("$seq"); continue; fi
  verified=$((verified + 1))
  [ -n "$mx" ] || continue   # an empty table: any value is fine
  if [ "$called" = t ]; then ok=$((last >= mx)); else ok=$((last > mx)); fi
  if [ "$ok" != 1 ]; then
    echo "WRONG  $seq is behind $owner: last_value=$last is_called=$called but max=$mx"
    bad=$((bad + 1))
  fi
done <"$work/target"
for s in ${unowned[@]+"${unowned[@]}"}; do echo "note   $s has no owning column and is no column's default: copied, not verified"; done

if [ "$bad" -gt 0 ]; then
  echo "sync-sequences: $bad sequence(s) wrong in $db; do not cut over" >&2
  exit 1
fi
echo "sync-sequences: $db: $n sequence(s) set to the old server's values; $verified verified against their columns, ${#unowned[@]} not verifiable"
