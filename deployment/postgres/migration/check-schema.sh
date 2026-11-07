#!/usr/bin/env bash
# deployment/postgres/migration/check-schema.sh DATABASE|all [--target]
# Fails on any function, trigger, extension or event trigger outside the expected list (spec §13.1), and on any
# expected one that is missing,
# naming each one. Run it on the source before loading anything: an unknown object stops the move and
# goes to Shane. `postgres` and `template1` must have none: nothing is copied from them, and anything
# found there is unexplained. `all` checks every database that accepts connections, so a stray database is
# checked too (and expected to have none).
#
#   --target   look at the new server (TARGET_DSN or TARGET_PSQL) instead of the old one; spec §5.4's
#              verify step. Connecting to postgres and template1 there needs the superuser, so use TARGET_PSQL.
#
# Expected (§13.1), by database:
#   tgb          extensions btree_gin btree_gist fuzzystrmatch pg_stat_statements pg_trgm unaccent
#                functions  public.authors_search_string_update() public.update_book_search_text()
#                           public.update_ol_works_search_text()
#                triggers   trg_authors_search_update on authors, update_book_search_text on books
#   anything else  nothing. (plpgsql, which every database has, and objects an extension owns, are ignored.)
# Exit 0 clean, 1 findings, 2 could not check (never a pass).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

db="${1:-}"
side=SOURCE
case "${2:-}" in
  "") ;;
  --target) side=TARGET ;;
  *) die "usage: check-schema.sh DATABASE|all [--target]" ;;
esac
[ -n "$db" ] || die "usage: check-schema.sh DATABASE|all [--target]"
if [ "$db" != all ]; then check_db_name "$db"; fi

expected_for() {   # expected_for DB -> the exact lines FIND_SQL prints for the expected objects
  case "$1" in
    tgb)
      printf 'extension|%s|\n' btree_gin btree_gist fuzzystrmatch pg_stat_statements pg_trgm unaccent
      printf 'function|public.%s()|\n' authors_search_string_update update_book_search_text update_ol_works_search_text
      printf 'trigger|authors|trg_authors_search_update|authors_search_string_update\n'
      printf 'trigger|books|update_book_search_text|update_book_search_text\n'
      ;;
  esac
}

FIND_SQL="
SELECT 'extension|' || extname || '|' FROM pg_extension WHERE extname <> 'plpgsql'
UNION ALL
SELECT 'function|' || n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|'
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
UNION ALL
SELECT 'trigger|' || c.relname || '|' || t.tgname || '|' || p.proname
FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_proc p ON p.oid = t.tgfoid
WHERE NOT t.tgisinternal
UNION ALL
SELECT 'event trigger|' || e.evtname || '|' || e.evtfoid::regproc::text FROM pg_event_trigger e
ORDER BY 1"

findings=0
check_one() {   # check_one DB
  local d="$1" out line key
  # A query that fails stops the script (set -e through the assignment): never an empty result.
  out="$(side_psql "$side" "$d" -At -c "$FIND_SQL" </dev/null)" || die "could not query database $d; refusing to call it clean"
  local expected
  expected="$(expected_for "$d")"
  local n=0
  # Both ways. A line is the whole identity: a trigger is table, trigger name AND the function it calls, so a
  # trigger with the right name that calls something else is both unexpected and missing.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    if grep -qxF -- "$line" <<<"$expected"; then continue; fi
    findings=$((findings + 1))
    echo "UNEXPECTED in database $d: $(tr '|' ' ' <<<"${line%|}")"
  done <<<"$out"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if grep -qxF -- "$key" <<<"$out"; then continue; fi
    findings=$((findings + 1))
    echo "MISSING in database $d: $(tr '|' ' ' <<<"${key%|}")"
  done <<<"$expected"
  echo "checked database $d: $n object(s) of interest"
}

if [ "$db" = all ]; then
  # Reach the list through the maintenance database; a database that is listed but cannot be
  # connected to is an error, not a skip.
  list="$(side_psql "$side" postgres -At -c "SELECT datname FROM pg_database WHERE datallowconn ORDER BY 1" </dev/null)" \
    || die "could not list the databases; refusing to call the server clean"
  [ -n "$list" ] || die "the server listed no databases"
  mapfile -t dbs <<<"$list"   # an array, not a read loop: a psql shim would swallow the rest of the list
  for d in "${dbs[@]}"; do check_one "$d"; done
else
  check_one "$db"
fi

if [ "$findings" -gt 0 ]; then
  echo "check-schema: $findings unexpected object(s); do not migrate until Shane has seen them" >&2
  exit 1
fi
echo "check-schema: clean"
