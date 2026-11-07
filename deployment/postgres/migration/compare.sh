#!/usr/bin/env bash
# deployment/postgres/migration/compare.sh DATABASE [--counts-only|--checksums]
# Spec §13.2 steps 8 and 13. Compares the old and new server's DATABASE and exits 1 listing every difference:
#   * the row count and max(id) of every ordinary table (the tables the publication holds: everything
#     outside the system schemas except pghero_query_stats, ol_editions and ol_works, which are not compared);
#     max(id) is "-" for a table with no id column, so such a table is still counted;
#   * a table present on one side only, either side;
#   * ol_editions or ol_works holding ANY row on the old server: they are not replicated, so those rows would
#     be lost silently. (pghero_query_stats is deliberately not copied and is not looked at.)
#   * a checksum over the rows of a sample of tables (below).
# Checksums read every row of the sampled tables, so they do NOT belong inside the read-only window:
#   --counts-only   counts and max(id) only. The default when the old server is read-only (cutover, step 13).
#   --checksums     force the sample. The default when the old server is still writable (step 8).
#   CHECKSUM_TABLES (space-separated, schema-qualified like public.users) always wins; otherwise the sample is the
#   CHECKSUM_COUNT (5) largest tables on the old server. Each table's duration is printed per side, so step 8
#   can time it on real data. Both servers are read at the same time.
# The checksum is md5 over per-bucket hashes: each row's text is hashed, the hashes are grouped into 4096 buckets
# by their first three hex digits, sorted with COLLATE "C" inside a bucket and hashed, and the bucket hashes are hashed
# in order. No single aggregate grows with the table (string_agg stops at 1 GB, about 33 million rows), no key or id
# column is needed, and the row is taken as (alias.*)::text under an alias no column is likely to have. The session pins
# TimeZone, DateStyle, IntervalStyle, extra_float_digits and bytea_output so a mismatch is never a formatting difference.
# When the old server is writable the verdict is "not a verdict" (step 8 legitimately runs live): the differences
# are still listed and the exit code still says 1, but the message says so.
# Exit 0 identical, 1 differences, 2 could not compare.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

db="${1:-}"
check_db_name "$db"
mode=auto
case "${2:-}" in "") ;; --counts-only) mode=counts ;; --checksums) mode=sums ;; *) die "usage: compare.sh DATABASE [--counts-only|--checksums]" ;; esac
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

ro_state="$(source_readonly_state "$db")"
if [ "$ro_state" != on ]; then
  echo "NOTE  the old server's $db is writable: this is not a verdict, rows may still be arriving (fine for step 8, never for cutover)"
fi

# One generated query per side: SELECT table, count, max(id) for every table, glued with UNION ALL.
# `\gset` keeps the generated text out of the shell. A table whose id is not an integer type is compared
# as text; max over text is still the same on both sides.
read -r -d '' COUNTS_SQL <<SQL || true
WITH t(name) AS ($TABLES_SQL)
SELECT coalesce(string_agg(
  format('SELECT %L AS t, count(*)::text AS n, coalesce(%s, ''-'') AS m FROM %s',
    t.name,
    CASE WHEN a.attname IS NULL THEN 'NULL::text'
         WHEN a.atttypid IN ('int2'::regtype, 'int4'::regtype, 'int8'::regtype, 'numeric'::regtype) THEN 'max(id)::text'
         ELSE 'max(id::text)' END,
    t.name), ' UNION ALL ' ORDER BY t.name),
  'SELECT NULL::text, NULL::text, NULL::text WHERE false') AS q
FROM t LEFT JOIN pg_attribute a ON a.attrelid = to_regclass(t.name) AND a.attname = 'id' AND NOT a.attisdropped
\gset
:q
SQL

# Sorted on the join field only, in the C locale, exactly as join reads it. Sorting whole lines disagrees
# with join when one table name is a prefix of another (books, books_authors) and join then gives up.
csort() { LC_ALL=C sort -t'|' -k1,1; }

counts() {   # counts SIDE FILE
  # A failed query must stop the script, not become an empty list: pipefail makes the pipeline fail.
  printf '%s\n' "$COUNTS_SQL" | side_psql "$1" "$db" -At -F '|' | csort >"$2" \
    || die "could not read the table counts from the ${1,,} server"
}
counts SOURCE "$work/src"
counts TARGET "$work/tgt"
[ -s "$work/src" ] || die "the old server's $db has no tables to compare"

differences=0
report() { echo "DIFFERENT  $1"; differences=$((differences + 1)); }

echo "table | old count, max(id) | new count, max(id)"
LC_ALL=C join -t'|' -a1 -a2 -e ABSENT -o 0,1.2,1.3,2.2,2.3 "$work/src" "$work/tgt" >"$work/joined"
while IFS='|' read -r tbl sn sm tn tm; do
  if [ "$sn" = ABSENT ]; then
    report "$tbl exists on the new server only"
  elif [ "$tn" = ABSENT ]; then
    report "$tbl exists on the old server only (missing on the new server)"
  elif [ "$sn" != "$tn" ] || [ "$sm" != "$tm" ]; then
    report "$tbl: old count=$sn max(id)=$sm, new count=$tn max(id)=$tm"
  else
    echo "ok         $tbl: $sn rows, max(id) $sm"
  fi
done <"$work/joined"

# Tables that are not replicated must be empty on the old server.
if ! excl_out="$(check_excluded_empty "$db" 2>&1)"; then
  report "${excl_out#"$SCRIPT: "}"
fi

# Checksums.
sample=()
if [ -n "${CHECKSUM_TABLES:-}" ]; then
  read -ra sample <<<"$CHECKSUM_TABLES"
elif [ "$mode" = sums ] || { [ "$mode" = auto ] && [ "$ro_state" != on ]; }; then
  mapfile -t sample < <(awk -F'|' '$2 > 0 { print $2 "|" $1 }' "$work/src" | LC_ALL=C sort -t'|' -k1,1nr -k2,2 | head -n "${CHECKSUM_COUNT:-5}" | cut -d'|' -f2)
fi
if [ "$mode" = counts ] && [ -z "${CHECKSUM_TABLES:-}" ]; then sample=(); fi

checksum_side() {   # checksum_side SIDE : writes "table|md5" lines to $work/sum.SIDE and "table|seconds" to $work/dur.SIDE
  local side="$1" t sql t0 t1
  : >"$work/sum.$side"; : >"$work/dur.$side"; : >"$work/err.$side"
  for t in "${sample[@]}"; do
    sql="SET TimeZone = 'UTC'; SET DateStyle = 'ISO, MDY'; SET IntervalStyle = 'postgres'; SET extra_float_digits = 1; SET bytea_output = 'hex';
SELECT '$t', md5(coalesce(string_agg(b::text || ':' || bh, ',' ORDER BY b), ''))
FROM (SELECT b, md5(string_agg(h, '' ORDER BY h COLLATE \"C\")) AS bh
      FROM (SELECT h, ('x' || substr(h, 1, 3))::bit(12)::int AS b
            FROM (SELECT md5((\"cs__row\".*)::text) AS h FROM $t AS \"cs__row\") r0) r
      GROUP BY b) g;"
    t0="$(date +%s.%N)"
    if ! printf '%s\n' "$sql" | side_psql "$side" "$db" -At -F '|' >>"$work/sum.$side" 2>>"$work/err.$side"; then
      echo "$t|ERROR" >>"$work/sum.$side"
    fi
    t1="$(date +%s.%N)"
    awk -v n="$t" -v a="$t0" -v b="$t1" 'BEGIN { printf "%s|%.1f\n", n, b - a }' >>"$work/dur.$side"
  done
}
if [ "${#sample[@]}" -gt 0 ]; then
  for t in "${sample[@]}"; do [[ "$t" =~ ^[A-Za-z0-9_\".]+$ ]] || die "unsafe table name in the checksum sample: $t"; done
  checksum_side SOURCE &
  p1=$!
  checksum_side TARGET &
  p2=$!
  wait "$p1" "$p2" || true
  # psql's own error text may name a table; this script runs by hand, not in a public log, so show it.
  for side in SOURCE TARGET; do
    if [ -s "$work/err.$side" ]; then echo "compare: psql said on the ${side,,} server:" >&2; sed 's/^/    /' "$work/err.$side" >&2; fi
  done
  csort <"$work/sum.SOURCE" >"$work/sum.SOURCE.s"
  csort <"$work/sum.TARGET" >"$work/sum.TARGET.s"
  LC_ALL=C join -t'|' -a1 -a2 -e ABSENT -o 0,1.2,2.2 "$work/sum.SOURCE.s" "$work/sum.TARGET.s" >"$work/sumj"
  while IFS='|' read -r tbl a b; do
    d_old="$(grep -F "$tbl|" "$work/dur.SOURCE" | head -1 | cut -d'|' -f2)" d_new="$(grep -F "$tbl|" "$work/dur.TARGET" | head -1 | cut -d'|' -f2)"
    if [ "$a" = ERROR ] || [ "$b" = ERROR ] || [ "$a" = ABSENT ] || [ "$b" = ABSENT ]; then
      report "$tbl: the checksum could not be computed on both servers (old: $a, new: $b)"
    elif [ "$a" = "$b" ]; then
      echo "ok         $tbl: checksum $a (took ${d_old:-?}s old, ${d_new:-?}s new)"
    else
      report "$tbl: checksum differs (old $a, new $b; took ${d_old:-?}s old, ${d_new:-?}s new)"
    fi
  done <"$work/sumj"
fi

if [ "$differences" -gt 0 ]; then
  echo "compare: $db has $differences difference(s)$([ "$ro_state" = on ] || echo ' (old server writable: not a verdict)')" >&2
  exit 1
fi
echo "compare: $db is identical on both servers ($(wc -l <"$work/src") tables, checksums on ${#sample[@]})$([ "$ro_state" = on ] || echo ' (old server writable: not a verdict)')"
