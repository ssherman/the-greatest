#!/usr/bin/env bash
# Tests for deployment/postgres/migration/*.sh against real Postgres: a postgres:17 "old server" shaped
# like production (TLS, wal_level=logical, the extensions, triggers and tables of spec §13.1) and a
# postgres:18 target started from a generated compose file, so apply-roles.sh runs unchanged. Needs
# Docker and pulls postgres:17 and postgres:18 (a minute on a cold machine). Everything it starts
# carries one label and is removed on exit, also on failure or interrupt.
# shellcheck disable=SC2016,SC2155,SC2119,SC2015,SC2001  # SQL in single quotes on purpose; throwaway secrets; style notes in a test

set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=docker-helpers.sh
. "$OS_DIR/test/docker-helpers.sh"
MIG="$OS_DIR/migration"

if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then
  echo "migration_test: Docker is required and is not available" >&2
  exit 1
fi

dk_init
dk_network
dk_shims
echo "# starting the old server and the new server (a few seconds each)"
mk_source "$PROJ-src" || { echo "could not start the source" >&2; exit 1; }
seed_source || { echo "could not seed the source" >&2; exit 1; }
mk_target_compose || { echo "could not start the target" >&2; exit 1; }

export SOURCE_DSN="host=source port=5432 user=postgres sslmode=require" SOURCE_PGPASSWORD="$SRC_PW"
export POSTGRES_THE_GREATEST_PASSWORD="tg-$(openssl rand -hex 8)" POSTGRES_TGB_APP_PASSWORD="app-$(openssl rand -hex 8)" \
  POSTGRES_TGB_READER_PASSWORD="rd-$(openssl rand -hex 8)"
export REPLICATOR_PASSWORD="repl-$(openssl rand -hex 12)" REPLICATION_HOST=source
COMPOSE_FILE="$TARGET_COMPOSE" "$BIN/apply-roles.sh" >"$TMP/apply-roles.out" 2>&1 || { cat "$TMP/apply-roles.out" >&2; echo "apply-roles failed" >&2; exit 1; }

admin() { export TARGET_PSQL="$TARGET_ADMIN"; unset TARGET_DSN TARGET_PGPASSWORD; }
owner() {   # owner DB: the database's owner role over the network, as load-schema.sh is run for real
  unset TARGET_PSQL
  case "$1" in
    tgb) export TARGET_DSN="host=target user=tgb_app sslmode=prefer" TARGET_PGPASSWORD="$POSTGRES_TGB_APP_PASSWORD" ;;
    *) export TARGET_DSN="host=target user=the_greatest sslmode=prefer" TARGET_PGPASSWORD="$POSTGRES_THE_GREATEST_PASSWORD" ;;
  esac
}
tval() { docker compose -f "$TARGET_COMPOSE" exec -T postgres psql -U postgres -X -At -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }
run() { OUT="$("$@" 2>&1)"; RC=$?; }
check() {   # check NAME CONDITION-COMMAND...
  local name="$1"; shift
  if "$@"; then pass "$name"; else fail "$name" "rc=${RC:-?} out=$(printf '%s' "${OUT:-}" | tail -8)"; fi
}
rc_is() { [ "$RC" = "$1" ]; }
out_has() { grep -qE -- "$1" <<<"$OUT"; }

# --- check-schema ----------------------------------------------------------------------------------
admin
run "$MIG/check-schema.sh" tgb
check "a source shaped like production passes check-schema tgb" rc_is 0
run "$MIG/check-schema.sh" the_greatest
check "a source shaped like production passes check-schema the_greatest" rc_is 0
run "$MIG/check-schema.sh" all
check "check-schema all (every connectable database, system ones included) passes on a clean source" rc_is 0
if out_has 'postgres' && out_has 'template1' && out_has 'tgb'; then pass "check-schema all names the databases it looked at"; else fail "check-schema all names databases" "$OUT"; fi

src_sql the_greatest <<<'CREATE FUNCTION sneaky_fn() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;'
run "$MIG/check-schema.sh" the_greatest
if [ "$RC" = 1 ] && out_has 'sneaky_fn'; then pass "t_check_schema_flags_unknown_function"; else fail "t_check_schema_flags_unknown_function" "rc=$RC $OUT"; fi
src_sql the_greatest <<<'DROP FUNCTION sneaky_fn();'

src_sql tgb <<<'CREATE FUNCTION public.sneaky_tgb() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;'
run "$MIG/check-schema.sh" tgb
if [ "$RC" = 1 ] && out_has 'sneaky_tgb' && ! out_has 'authors_search_string_update'; then
  pass "an unknown function in tgb is flagged, the three expected ones are not"; else fail "unknown function in tgb" "rc=$RC $OUT"; fi
src_sql tgb <<<'DROP FUNCTION public.sneaky_tgb();'

src_sql tgb <<<'CREATE TRIGGER sneaky_trg BEFORE INSERT ON tags FOR EACH ROW EXECUTE FUNCTION update_ol_works_search_text();'
run "$MIG/check-schema.sh" tgb
if [ "$RC" = 1 ] && out_has 'sneaky_trg'; then pass "a trigger outside the expected two is flagged by name"; else fail "unknown trigger" "rc=$RC $OUT"; fi
src_sql tgb <<<'DROP TRIGGER sneaky_trg ON tags;'

# What is expected must be there too, and a trigger is table + name + the function it calls.
src_sql tgb <<<'DROP TRIGGER update_book_search_text ON books;'
run "$MIG/check-schema.sh" tgb
if [ "$RC" = 1 ] && out_has 'MISSING in database tgb: trigger books update_book_search_text'; then pass "t_check_schema_flags_a_missing_trigger"; else fail "t_check_schema_flags_a_missing_trigger" "rc=$RC $OUT"; fi
src_sql tgb <<<'CREATE TRIGGER update_book_search_text BEFORE INSERT OR UPDATE ON books FOR EACH ROW EXECUTE FUNCTION update_ol_works_search_text();'
run "$MIG/check-schema.sh" tgb
if [ "$RC" = 1 ] && out_has 'UNEXPECTED in database tgb: trigger books update_book_search_text update_ol_works_search_text' && out_has 'MISSING in database tgb: trigger books update_book_search_text update_book_search_text'; then
  pass "t_check_schema_keys_a_trigger_on_the_function_it_calls: the right name calling the wrong function is unexpected AND missing"; else fail "t_check_schema_keys_a_trigger_on_the_function_it_calls" "rc=$RC $OUT"; fi
src_sql tgb <<<'DROP TRIGGER update_book_search_text ON books; CREATE TRIGGER update_book_search_text BEFORE INSERT OR UPDATE ON books FOR EACH ROW EXECUTE FUNCTION update_book_search_text();'
src_sql tgb <<<'DROP FUNCTION update_ol_works_search_text();'
run "$MIG/check-schema.sh" tgb
if [ "$RC" = 1 ] && out_has 'MISSING in database tgb: function public.update_ol_works_search_text()'; then pass "t_check_schema_flags_a_missing_function (the one that is expected with no trigger)"; else fail "t_check_schema_flags_a_missing_function" "rc=$RC $OUT"; fi
src_sql tgb <<<'CREATE FUNCTION update_ol_works_search_text() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;'
src_sql tgb <<<'DROP EXTENSION unaccent;'
run "$MIG/check-schema.sh" tgb
if [ "$RC" = 1 ] && out_has 'MISSING in database tgb: extension unaccent'; then pass "t_check_schema_flags_a_missing_extension"; else fail "t_check_schema_flags_a_missing_extension" "rc=$RC $OUT"; fi
src_sql tgb <<<'CREATE EXTENSION unaccent;'
run "$MIG/check-schema.sh" tgb
check "...and tgb is clean again once everything is put back" rc_is 0

src_sql the_greatest <<<'CREATE EXTENSION pg_trgm;'
run "$MIG/check-schema.sh" the_greatest
if [ "$RC" = 1 ] && out_has 'pg_trgm'; then pass "an extension in the_greatest is flagged"; else fail "unknown extension" "rc=$RC $OUT"; fi
src_sql the_greatest <<<'DROP EXTENSION pg_trgm;'

src_sql postgres <<<'CREATE FUNCTION unexpected_fn() RETURNS event_trigger LANGUAGE plpgsql AS $$ BEGIN NULL; END $$;
CREATE EVENT TRIGGER unexpected_evt ON ddl_command_end EXECUTE FUNCTION unexpected_fn();'
run "$MIG/check-schema.sh" tgb
check "an event trigger in the postgres database does not fail a check of tgb alone" rc_is 0
run "$MIG/check-schema.sh" all
if [ "$RC" = 1 ] && out_has 'unexpected_evt' && out_has 'unexpected_fn'; then
  pass "t_check_schema_flags_event_trigger_in_system_db: found by name, with its function"; else fail "t_check_schema_flags_event_trigger_in_system_db" "rc=$RC $OUT"; fi
run "$MIG/check-schema.sh" postgres
if [ "$RC" = 1 ] && out_has 'unexpected_evt'; then pass "check-schema postgres finds it too"; else fail "check-schema postgres" "rc=$RC $OUT"; fi
src_sql postgres <<<'DROP EVENT TRIGGER unexpected_evt; DROP FUNCTION unexpected_fn();'

src_sql template1 <<<'CREATE EXTENSION pg_trgm;'
run "$MIG/check-schema.sh" template1
if [ "$RC" = 1 ] && out_has 'pg_trgm'; then pass "template1 must have none: an extension there is flagged"; else fail "template1" "rc=$RC $OUT"; fi
src_sql template1 <<<'DROP EXTENSION pg_trgm;'

# never fail open
SAVE_DSN="$SOURCE_DSN"
export SOURCE_DSN="host=source port=5999 user=postgres sslmode=require connect_timeout=3"
run "$MIG/check-schema.sh" tgb
if [ "$RC" != 0 ] && [ "$RC" != 1 ]; then pass "a source that cannot be reached is an error (exit $RC), never a pass"; else fail "unreachable source" "rc=$RC $OUT"; fi
export SOURCE_DSN="$SAVE_DSN"
run "$MIG/check-schema.sh" no_such_db
if [ "$RC" != 0 ] && [ "$RC" != 1 ]; then pass "a database that does not exist is an error, never a pass"; else fail "missing database" "rc=$RC $OUT"; fi
run "$MIG/check-schema.sh" 'bad name;'
check "a malformed database name is refused" rc_is 2

# --- load-schema -----------------------------------------------------------------------------------
owner tgb
run "$MIG/load-schema.sh" tgb
check "load-schema tgb succeeds as tgb_app" rc_is 0
owner the_greatest
run "$MIG/load-schema.sh" the_greatest
check "load-schema the_greatest succeeds as the_greatest" rc_is 0
if [ "$(tval tgb "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and pg_get_userbyid(c.relowner)<>'tgb_app'")" = 0 ] \
   && [ "$(tval tgb "select count(*) from pg_class where relnamespace='public'::regnamespace and relkind in ('r','S')")" -gt 10 ]; then
  pass "every tgb table and sequence is owned by tgb_app after a --no-owner load"; else fail "tgb ownership" "$(tval tgb "select relname, pg_get_userbyid(relowner) from pg_class where relnamespace='public'::regnamespace and relkind='r'")"; fi
if [ "$(tval the_greatest "select count(*) from pg_class where relnamespace='public'::regnamespace and relkind in ('r','S') and pg_get_userbyid(relowner)<>'the_greatest'")" = 0 ]; then
  pass "every the_greatest table and sequence is owned by the_greatest"; else fail "the_greatest ownership" "wrong owner"; fi
if [ "$(tval tgb "select count(*) from authors")" = 0 ] && [ "$(tval tgb "select count(*) from pg_proc where proname='authors_search_string_update'")" = 1 ] \
   && [ "$(tval tgb "select count(*) from pg_trigger where not tgisinternal")" = 2 ]; then
  pass "the schema arrived without data, with the function and both triggers"; else fail "schema only" "check target"; fi
if [ "$(tval tgb "select obj_description('authors'::regclass)")" = "People who wrote things" ] \
   && [ "$(tval tgb "select col_description('authors'::regclass, 3)")" = "Maintained by a trigger" ]; then
  pass "table and column comments survive the load"; else fail "comments" "lost"; fi
if [ "$(tval tgb "select count(*) from pg_extension where extname<>'plpgsql'")" = 6 ]; then pass "the six extensions are present (made by apply-roles, untouched by the load)"; else fail "extensions" "$(tval tgb 'select extname from pg_extension')"; fi
owner tgb
run "$MIG/load-schema.sh" tgb
if [ "$RC" != 0 ] && [ "$(tval tgb "select count(*) from pg_class where relnamespace='public'::regnamespace and relkind='r'")" = 9 ]; then
  pass "t_load_schema_stops_on_first_error: a second load fails and leaves the first one intact"; else fail "second load" "rc=$RC $OUT"; fi
out_has 'already exists' && pass "...and the error says what failed" || fail "load error text" "$OUT"
if grep -q -- '--no-publications --no-subscriptions' "$TMP/argv.log"; then pass "pg_dump is told --no-publications --no-subscriptions"; else fail "dump flags" "$(grep pg_dump "$TMP/argv.log" | head -2)"; fi

# A dump that is cut short must not be loaded, even when pg_dump exits 0 and the prefix is valid SQL.
src_sql postgres <<<'CREATE DATABASE scratch OWNER tgb_app'
docker exec -i "$SOURCE_CONTAINER" psql -U tgb_app -X -q -v ON_ERROR_STOP=1 -d scratch <<<'CREATE TABLE plain_a (a int); CREATE TABLE plain_b (b int); CREATE TABLE plain_c (c int);'
tval postgres "create database scratch owner tgb_app" >/dev/null
mkdir -p "$TMP/fake"
printf '#!/usr/bin/env bash\n"%s/shims/pg_dump" "$@" | head -n 40\nexit 0\n' "$TMP" >"$TMP/fake/pg_dump"
chmod +x "$TMP/fake/pg_dump"
owner tgb
PATH="$TMP/fake:$PATH" run "$MIG/load-schema.sh" scratch
if [ "$RC" != 0 ] && out_has 'truncated' && [ "$(tval scratch "select count(*) from pg_class where relnamespace='public'::regnamespace")" = 0 ]; then
  pass "t_load_schema_rejects_a_truncated_dump: refused, and nothing was committed"; else fail "truncated dump" "rc=$RC $OUT"; fi
printf '#!/usr/bin/env bash\n"%s/shims/pg_dump" "$@"\nexit 3\n' "$TMP" >"$TMP/fake/pg_dump"
PATH="$TMP/fake:$PATH" run "$MIG/load-schema.sh" scratch
if [ "$RC" != 0 ] && out_has 'pg_dump failed' && [ "$(tval scratch "select count(*) from pg_class where relnamespace='public'::regnamespace")" = 0 ]; then
  pass "a pg_dump that exits non-zero loads nothing"; else fail "failing pg_dump" "rc=$RC $OUT"; fi
run "$MIG/load-schema.sh" scratch
check "the same load with the real pg_dump works (scratch database)" rc_is 0

# --- old site: tgb_app and tgb_reader on the loaded target -------------------------------------------
tgb_as() {   # tgb_as ROLE PASSWORD SQL
  PGPASSWORD="$2" psql "host=target user=$1 sslmode=prefer dbname=tgb" -X -At -v ON_ERROR_STOP=1 -c "$3" 2>&1
}
OUT="$(tgb_as tgb_app "$POSTGRES_TGB_APP_PASSWORD" "insert into authors (name) values ('Écrivain') returning id; insert into ident (v) values ('x'); select nextval('orphan_seq'); update authors set name = 'Écrivain 2' where name = 'Écrivain'; delete from authors where name = 'Écrivain 2'; delete from ident")"; RC=$?
check "tgb_app can read, write and use its sequences on the target after the load" rc_is 0
OUT="$(tgb_as tgb_reader "$POSTGRES_TGB_READER_PASSWORD" "select count(*) from authors; select count(*) from books")"; RC=$?
check "tgb_reader can read" rc_is 0
OUT="$(tgb_as tgb_reader "$POSTGRES_TGB_READER_PASSWORD" "insert into authors (name) values ('x')")"; RC=$?
if [ "$RC" != 0 ] && out_has 'permission denied'; then pass "tgb_reader cannot write"; else fail "reader write" "rc=$RC $OUT"; fi
OUT="$(tgb_as tgb_reader "$POSTGRES_TGB_READER_PASSWORD" "create table reader_made (a int)")"; RC=$?
if [ "$RC" != 0 ]; then pass "tgb_reader cannot create tables"; else fail "reader create" "$OUT"; fi
OUT="$(tgb_as tgb_app "$POSTGRES_TGB_APP_PASSWORD" "create table made_later (a int)")"; RC=$?
check "tgb_app can create tables" rc_is 0
OUT="$(tgb_as tgb_reader "$POSTGRES_TGB_READER_PASSWORD" "select count(*) from made_later")"; RC=$?
check "tgb_reader reads a table created after the grants" rc_is 0
OUT="$(tgb_as tgb_reader "$POSTGRES_TGB_READER_PASSWORD" "insert into made_later values (1)")"; RC=$?
if [ "$RC" != 0 ]; then pass "...and cannot write to it"; else fail "reader write to new table" "$OUT"; fi
OUT="$(tgb_as tgb_app "$POSTGRES_TGB_APP_PASSWORD" "drop table made_later; select count(*) from pg_stat_statements")"; RC=$?
check "tgb_app (a pg_monitor member) reads pg_stat_statements" rc_is 0

# --- create-replication ----------------------------------------------------------------------------
admin
src_sql tgb <<<'CREATE TABLE no_key_table (a int); INSERT INTO no_key_table VALUES (1);'
run "$MIG/create-replication.sh" tgb
if [ "$RC" = 1 ] && out_has 'no_key_table' && [ "$(src_val tgb "select count(*) from pg_publication")" = 0 ]; then
  pass "a published table with no replica identity is refused by name, before anything is created"; else fail "no replica identity" "rc=$RC $OUT"; fi
src_sql tgb <<<'DROP TABLE no_key_table;'
: >"$TMP/argv.log"
run "$MIG/create-replication.sh" tgb
check "create-replication tgb succeeds" rc_is 0
run "$MIG/create-replication.sh" the_greatest
check "create-replication the_greatest succeeds" rc_is 0
pubtables="$(src_val tgb "select tablename from pg_publication_tables where pubname='migration_pub_tgb' order by 1" | tr '\n' ' ')"
if ! grep -qE 'pghero_query_stats|ol_editions|ol_works' <<<"$pubtables" && grep -q 'authors' <<<"$pubtables" && grep -q 'empty_things' <<<"$pubtables" \
   && [ "$(wc -w <<<"$pubtables")" = 6 ]; then
  pass "t_publication_excludes_listed_tables: $pubtables"; else fail "t_publication_excludes_listed_tables" "$pubtables"; fi
if [ "$(src_val the_greatest "select count(*) from pg_publication_tables where pubname='migration_pub_the_greatest'")" = 4 ]; then
  pass "the_greatest publishes all four of its tables"; else fail "the_greatest publication" "wrong count"; fi
if ! grep -qF "$REPLICATOR_PASSWORD" "$TMP/argv.log" && ! grep -qF "$REPLICATOR_PASSWORD" <<<"$OUT"; then
  pass "the replicator password reaches no command line and no output"; else fail "password in argv" "$(grep -F "$REPLICATOR_PASSWORD" "$TMP/argv.log" | head -2)"; fi
conninfo="$(tval tgb "select subconninfo from pg_subscription where subname='migration_sub_tgb'")"
if grep -q 'sslmode=require' <<<"$conninfo" && grep -q 'user=replicator' <<<"$conninfo"; then pass "the subscription connects with sslmode=require as replicator"; else fail "conninfo" "$(sed 's/password=[^ ]*/password=<hidden>/' <<<"$conninfo")"; fi
if [ "$(src_val tgb "select count(*) from pg_replication_slots where slot_name='migration_sub_tgb'")" = 1 ]; then pass "the slot was created by the subscription"; else fail "slot" "missing"; fi
if [ "$(src_val postgres "select rolreplication and rolcanlogin and not rolsuper from pg_roles where rolname='replicator'")" = t ]; then pass "replicator is a login with REPLICATION and nothing more"; else fail "replicator role" "wrong attributes"; fi
if [ "$(src_val tgb "select has_table_privilege('replicator','pghero_query_stats','select')")" = f ]; then pass "replicator cannot read an excluded table"; else fail "replicator grants" "can read excluded"; fi
run "$MIG/create-replication.sh" tgb
if [ "$RC" != 0 ] && out_has 'already exists'; then pass "a second create-replication refuses instead of touching the first"; else fail "second create" "rc=$RC $OUT"; fi

run "$MIG/wait-catchup.sh" tgb --initial
check "wait-catchup --initial returns once the copy has finished (tgb)" rc_is 0
run "$MIG/wait-catchup.sh" the_greatest --initial
check "wait-catchup --initial returns once the copy has finished (the_greatest)" rc_is 0

# the search-text triggers did not fire on apply: the target holds the source's value
if [ "$(src_val tgb "select md5(string_agg(search_string, ',' order by id)) from authors")" = "$(tval tgb "select md5(string_agg(search_string, ',' order by id)) from authors")" ]; then
  pass "the search-text trigger did not fire on apply: the target holds the source's values"; else fail "trigger on apply" "values differ"; fi

# --- wait-catchup ------------------------------------------------------------------------------------
sub_errors() { tval tgb "select apply_error_count from pg_stat_subscription_stats where subname = 'migration_sub_tgb'"; }
wait_for() {   # wait_for SECONDS COMMAND... : poll until the command succeeds
  local n="$1"; shift
  for _ in $(seq 1 "$n"); do "$@" && return 0; sleep 1; done
  return 1
}
errors_rose() { [ "$(sub_errors)" -gt 0 ]; }
run "$MIG/wait-catchup.sh" tgb
if [ "$RC" = 2 ] && out_has 'writable'; then pass "t_wait_catchup_refuses_a_writable_source: exit 2, says why"; else fail "t_wait_catchup_refuses_a_writable_source" "rc=$RC $OUT"; fi

# A connection blip last night: one apply error, healed. The cumulative counter stays above zero for good.
tval tgb "insert into tags (name, note) values ('blip', 'target')" >/dev/null
src_sql tgb <<<"insert into tags (name, note) values ('blip', 'source')"
wait_for 40 errors_rose
check "(setup) the apply worker hit a unique violation and counted an error" errors_rose
tval tgb "delete from tags where name = 'blip'" >/dev/null
"$MIG/set-readonly.sh" tgb on >/dev/null 2>&1
run "$MIG/wait-catchup.sh" tgb
if [ "$RC" = 0 ] && [ "$(sub_errors)" -gt 0 ]; then pass "t_wait_catchup_ignores_healed_old_errors: succeeds with a cumulative error count of $(sub_errors)"; else fail "t_wait_catchup_ignores_healed_old_errors" "rc=$RC $OUT"; fi
"$MIG/set-readonly.sh" tgb off >/dev/null 2>&1

# An error that keeps happening WHILE waiting fails at once.
tval tgb "insert into tags (name, note) values ('blip2', 'target')" >/dev/null
src_sql tgb <<<"insert into tags (name, note) values ('blip2', 'source')"
"$MIG/set-readonly.sh" tgb on >/dev/null 2>&1
WAIT_TIMEOUT=90 run "$MIG/wait-catchup.sh" tgb
if [ "$RC" = 1 ] && out_has 'new apply/sync error'; then pass "t_wait_catchup_fails_on_a_rising_error_count: a retry error raised while waiting fails fast"; else fail "t_wait_catchup_fails_on_a_rising_error_count" "rc=$RC $OUT"; fi
tval tgb "delete from tags where name = 'blip2'" >/dev/null
run "$MIG/wait-catchup.sh" tgb
check "...and succeeds once the cause is removed" rc_is 0
"$MIG/set-readonly.sh" tgb off >/dev/null 2>&1

# The timeout: nothing wrong, but the target is held back (a session on the target holds a lock on tags, so the
# apply worker waits without erroring).
( docker compose -f "$TARGET_COMPOSE" exec -T postgres psql -U postgres -X -q -d "dbname=tgb application_name=lockholder" -c "begin; lock table tags in access exclusive mode; select pg_sleep(120)" >/dev/null 2>&1 & )
holder_up() { [ "$(tval tgb "select count(*) from pg_stat_activity where application_name = 'lockholder'")" = 1 ]; }
wait_for 20 holder_up
src_sql tgb <<<"insert into tags (name, note) values ('slow', 'source')"
"$MIG/set-readonly.sh" tgb on >/dev/null 2>&1
WAIT_TIMEOUT=6 run "$MIG/wait-catchup.sh" tgb
if [ "$RC" = 1 ] && out_has 'timed out'; then pass "t_wait_catchup_times_out: exit 1 'timed out' when the target does not catch up"; else fail "t_wait_catchup_times_out" "rc=$RC $OUT"; fi
tval tgb "select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'lockholder'" >/dev/null
run "$MIG/wait-catchup.sh" tgb
check "...and succeeds when the lock is released" rc_is 0
"$MIG/set-readonly.sh" tgb off >/dev/null 2>&1
src_sql tgb <<<"delete from tags where name in ('blip', 'blip2', 'slow')"
tags_settled() { [ "$(tval tgb "select count(*) from tags")" = 2 ]; }
wait_for 30 tags_settled
check "(cleanup) the deletes replicated, tags is back to two rows" tags_settled

# --- compare -----------------------------------------------------------------------------------------
run "$MIG/compare.sh" tgb
check "compare tgb: identical after the copy" rc_is 0
run "$MIG/compare.sh" the_greatest
check "compare the_greatest: identical after the copy" rc_is 0
run "$MIG/compare.sh" tgb
if out_has 'public.tags' && out_has 'public.authors' && out_has 'public.empty_things' && ! out_has 'ol_works|pghero'; then
  pass "compare lists every published table (one has no id column) and none of the excluded ones"; else fail "compare table list" "$OUT"; fi

# Drop the subscriptions: the negative tests below change target rows.
run "$MIG/create-replication.sh" tgb drop
check "create-replication drop removes the subscription" rc_is 0
# Step 16 happens after step 10: the old server is read-only when the publication is dropped.
"$MIG/set-readonly.sh" the_greatest on >/dev/null 2>&1
run "$MIG/create-replication.sh" the_greatest drop
check "t_drop_works_while_the_source_is_read_only: step 16 drops the publication on a read-only database" rc_is 0
"$MIG/set-readonly.sh" the_greatest off >/dev/null 2>&1
if [ "$(tval tgb "select count(*) from pg_subscription")" = 0 ] && [ "$(src_val tgb "select count(*) from pg_replication_slots")" = 0 ] \
   && [ "$(src_val tgb "select count(*) from pg_publication")" = 0 ]; then
  pass "no subscription, slot or publication is left behind"; else fail "drop leftovers" "left"; fi

# Count and max(id) alone, with the checksum sample switched off, one at a time.
row5="$(src_val tgb "select format('%L, %L, %L', id, name, search_string) from authors where id = 5")"
tval tgb "set session_replication_role = replica; delete from authors where id = 5" >/dev/null
CHECKSUM_COUNT=0 run "$MIG/compare.sh" tgb
if [ "$RC" = 1 ] && out_has 'public.authors: old count=3000 max\(id\)=3000, new count=2999 max\(id\)=3000'; then pass "a differing count with the same max(id) is reported"; else fail "count only" "rc=$RC $OUT"; fi
tval tgb "set session_replication_role = replica; insert into authors (id, name, search_string) values ($row5)" >/dev/null
tval tgb "set session_replication_role = replica; update authors set id = 9999999 where id = 3000" >/dev/null
CHECKSUM_COUNT=0 run "$MIG/compare.sh" tgb
if [ "$RC" = 1 ] && out_has 'public.authors: old count=3000 max\(id\)=3000, new count=3000 max\(id\)=9999999'; then
  pass "a differing max(id) with the same count is reported (t_compare_detects_count_and_max_id_differences)"; else fail "max id only" "rc=$RC $OUT"; fi
tval tgb "set session_replication_role = replica; update authors set id = 3000 where id = 9999999" >/dev/null
CHECKSUM_COUNT=0 run "$MIG/compare.sh" tgb
check "...and compare is clean again once both are put back" rc_is 0

tval tgb "delete from books where id = 6000" >/dev/null
run "$MIG/compare.sh" tgb
if [ "$RC" = 1 ] && out_has 'public.books' && out_has '6000'; then pass "t_compare_detects_count_and_max_id_differences (count and max id)"; else fail "t_compare_detects_count_and_max_id_differences" "rc=$RC $OUT"; fi
tval tgb "insert into books (id, title) values (6000, 'back')" >/dev/null
run "$MIG/compare.sh" tgb
if [ "$RC" = 1 ] && out_has 'public.books'; then pass "a restored row with different content is caught by the checksum although count and max id match"; else fail "checksum" "rc=$RC $OUT"; fi
# put the identical row back from the source's text, with the target's triggers off for that session
src_row="$(src_val tgb "select format('%L, %L, %L, %L', id, title, search_text, author_id) from books where id = 6000")"
tval tgb "set session_replication_role = replica; delete from books where id = 6000; insert into books (id, title, search_text, author_id) values ($src_row)" >/dev/null
tval tgb "insert into authors (id, name, search_string) values (9999999, 'x', 'y')" >/dev/null
run "$MIG/compare.sh" tgb
if [ "$RC" = 1 ] && out_has '9999999' && out_has 'public.authors'; then pass "a larger max(id) on one side is reported"; else fail "max id only" "rc=$RC $OUT"; fi
tval tgb "delete from authors where id = 9999999" >/dev/null
tval tgb "create table only_here (id int); create table books_authors (id int)" >/dev/null
run "$MIG/compare.sh" tgb
if [ "$RC" = 1 ] && out_has 'only_here exists on the new server only' && out_has 'public.books_authors exists on the new server only' && ! out_has 'not in sorted order'; then
  pass "t_compare_lists_tables_whose_names_share_a_prefix: a target-only table, books_authors, next to books"; else fail "t_compare_lists_tables_whose_names_share_a_prefix" "rc=$RC $OUT"; fi
tval tgb "drop table books_authors" >/dev/null
src_sql tgb <<<'CREATE TABLE books_authors (id serial PRIMARY KEY)'
run "$MIG/compare.sh" tgb
if [ "$RC" = 1 ] && out_has 'public.books_authors exists on the old server only' && ! out_has 'not in sorted order'; then
  pass "...and the same table missing from the target"; else fail "source-only books_authors" "rc=$RC $OUT"; fi
src_sql tgb <<<'DROP TABLE books_authors'
tval tgb "drop table only_here; drop table tags" >/dev/null
run "$MIG/compare.sh" tgb
if [ "$RC" = 1 ] && out_has 'public.tags'; then pass "a table missing from the target is a difference"; else fail "source-only table" "rc=$RC $OUT"; fi
tval tgb "create table tags (name text primary key, note text, n bigint default nextval('default_seq')); insert into tags values ('a','x',1), ('b','y',2); insert into ol_works (data) values ('{}')" >/dev/null
run "$MIG/compare.sh" tgb
if [ "$RC" = 0 ]; then pass "rows in an excluded table on the TARGET do not matter; pghero_query_stats (rows on the source, not copied) does not fail compare"; else fail "excluded tables on target" "rc=$RC $OUT"; fi
tval tgb "delete from ol_works" >/dev/null
src_sql tgb <<<"insert into ol_works (data) values ('{}')"
run "$MIG/compare.sh" tgb
if [ "$RC" = 1 ] && out_has 'ol_works' && out_has 'would be lost'; then pass "t_compare_fails_on_rows_in_an_unreplicated_table: a row in the source's ol_works fails compare, by name"; else fail "t_compare_fails_on_rows_in_an_unreplicated_table" "rc=$RC $OUT"; fi
run "$MIG/create-replication.sh" tgb
if [ "$RC" = 1 ] && out_has 'ol_works' && [ "$(src_val tgb "select count(*) from pg_publication")" = 0 ]; then
  pass "t_create_replication_refuses_rows_in_an_unreplicated_table: refused before anything was created"; else fail "t_create_replication_refuses_rows_in_an_unreplicated_table" "rc=$RC $OUT"; fi
src_sql tgb <<<"delete from ol_works"
run "$MIG/compare.sh" tgb
check "...and compare is clean again once the row is gone" rc_is 0
if out_has 'not a verdict'; then pass "compare says 'not a verdict' while the old server is writable"; else fail "writable note" "$OUT"; fi

# Checksum robustness: a table with columns named x and cs__row, and a timestamptz, on servers with different time zones.
src_sql tgb <<<"CREATE TABLE colx (x text, cs__row text, at timestamptz, iv interval); INSERT INTO colx VALUES ('a', 'b', '2026-01-02 03:04:05+00', '1 day 2 hours');"
tval tgb "create table colx (x text, cs__row text, at timestamptz, iv interval); insert into colx values ('a', 'b', '2026-01-02 03:04:05+00', '1 day 2 hours'); alter database tgb set timezone to 'Asia/Tokyo'; alter database tgb set datestyle to 'German'; alter database tgb set intervalstyle to 'sql_standard'" >/dev/null
CHECKSUM_TABLES="public.colx" run "$MIG/compare.sh" tgb
if [ "$RC" = 0 ] && out_has 'public.colx: checksum'; then pass "t_compare_checksum_ignores_session_formatting: identical rows match although the target database has another TimeZone, DateStyle and IntervalStyle"; else fail "t_compare_checksum_ignores_session_formatting" "rc=$RC $OUT"; fi
tval tgb "update colx set x = 'changed'" >/dev/null
CHECKSUM_TABLES="public.colx" run "$MIG/compare.sh" tgb
if [ "$RC" = 1 ] && out_has 'public.colx: checksum differs'; then pass "t_compare_checksum_sees_a_column_named_x: a change in column x changes the checksum (a table with a column named like the alias)"; else fail "t_compare_checksum_sees_a_column_named_x" "rc=$RC $OUT"; fi
if out_has 'took [0-9.]+s old'; then pass "each checksum prints how long it took"; else fail "checksum timing" "$OUT"; fi
tval tgb "drop table colx; alter database tgb reset timezone; alter database tgb reset datestyle; alter database tgb reset intervalstyle" >/dev/null
src_sql tgb <<<"DROP TABLE colx"

# --- sync-sequences -----------------------------------------------------------------------------------
tval tgb "select setval('authors_id_seq', 5)" >/dev/null
run "$MIG/sync-sequences.sh" tgb
if [ "$RC" = 2 ] && out_has 'writable' && [ "$(tval tgb "select last_value from authors_id_seq")" = 5 ]; then
  pass "t_sync_sequences_refuses_a_writable_source: exit 2, and nothing was set"; else fail "t_sync_sequences_refuses_a_writable_source" "rc=$RC $OUT"; fi
"$MIG/set-readonly.sh" tgb on >/dev/null 2>&1
"$MIG/set-readonly.sh" the_greatest on >/dev/null 2>&1
run "$MIG/compare.sh" tgb --counts-only
if ! out_has 'checksum [0-9a-f]' && ! out_has 'not a verdict'; then pass "compare on a read-only source takes no checksums and carries no 'not a verdict' note"; else fail "readonly compare" "$OUT"; fi
run "$MIG/sync-sequences.sh" tgb
check "sync-sequences tgb succeeds" rc_is 0
state() { tval tgb "select last_value || ',' || is_called from $1"; }
src_state() { src_val tgb "select last_value || ',' || is_called from $1"; }
mismatch=""
for s in authors_id_seq books_id_seq ident_id_seq empty_things_id_seq orphan_seq writes_id_seq pghero_query_stats_id_seq ol_works_id_seq ol_editions_id_seq; do
  [ "$(state "$s")" = "$(src_state "$s")" ] || mismatch="$mismatch $s($(state "$s") vs $(src_state "$s"))"
done
if [ -z "$mismatch" ]; then pass "every sequence has the source's exact last_value and is_called"; else fail "sequence values" "$mismatch"; fi
if [ "$(state empty_things_id_seq)" = "1,false" ] && [ "$(state ol_editions_id_seq)" = "1,false" ]; then
  pass "t_empty_table_sequence_keeps_is_called_false"; else fail "t_empty_table_sequence_keeps_is_called_false" "$(state empty_things_id_seq)"; fi
if [ "$(state orphan_seq)" = "1,true" ]; then pass "a sequence nothing owns is still copied, and does not crash the check"; else fail "orphan sequence" "$(state orphan_seq)"; fi
if out_has 'orphan_seq'; then pass "...and is reported as not verifiable"; else fail "orphan report" "$OUT"; fi
OUT="$(tval tgb "insert into empty_things (label) values ('first') returning id" | head -1)"
if [ "$OUT" = 1 ]; then pass "the first insert into the empty table gets id 1, not 2"; else fail "first id" "$OUT"; fi
tval tgb "delete from empty_things" >/dev/null
run "$MIG/sync-sequences.sh" tgb
if [ "$RC" = 1 ] && out_has 'AHEAD' && out_has 'empty_things_id_seq' && [ "$(state empty_things_id_seq)" = "1,true" ]; then
  pass "t_sync_sequences_refuses_to_move_a_sequence_backward: the new server's sequence is ahead, nothing was set"; else fail "t_sync_sequences_refuses_to_move_a_sequence_backward" "rc=$RC $OUT"; fi
run "$MIG/sync-sequences.sh" tgb --allow-backward
if [ "$RC" = 0 ] && [ "$(state empty_things_id_seq)" = "1,false" ]; then pass "--allow-backward does it, on purpose"; else fail "--allow-backward" "rc=$RC $OUT"; fi
tval tgb "insert into books (id, title) values (5000000, 'huge')" >/dev/null
run "$MIG/sync-sequences.sh" tgb --allow-backward
if [ "$RC" = 1 ] && out_has 'books_id_seq' && out_has '5000000'; then pass "a sequence behind its table's max(id) fails the verification, by name"; else fail "behind max" "rc=$RC $OUT"; fi
tval tgb "delete from books where id = 5000000" >/dev/null
run "$MIG/sync-sequences.sh" tgb --allow-backward
check "...and passes again once the table is consistent" rc_is 0
run "$MIG/sync-sequences.sh" the_greatest
check "sync-sequences the_greatest succeeds" rc_is 0
OUT="$(tval tgb "insert into tags (name, note, n) values ('big', 'x', 100) returning n" | head -1)"
run "$MIG/sync-sequences.sh" tgb --allow-backward
if [ "$RC" = 1 ] && out_has 'default_seq' && out_has 'tags.n'; then pass "t_sync_sequences_verifies_a_sequence_used_as_a_column_default: default_seq is behind tags.n, by name"; else fail "t_sync_sequences_verifies_a_sequence_used_as_a_column_default" "rc=$RC $OUT"; fi
tval tgb "delete from tags where name = 'big'" >/dev/null
"$MIG/set-readonly.sh" scratch on >/dev/null 2>&1
run "$MIG/sync-sequences.sh" scratch
if [ "$RC" = 1 ] && out_has 'no sequences'; then pass "t_sync_sequences_refuses_zero_sequences: a database with none is refused"; else fail "t_sync_sequences_refuses_zero_sequences" "rc=$RC $OUT"; fi
tval tgb "drop sequence orphan_seq" >/dev/null
run "$MIG/sync-sequences.sh" tgb --allow-backward
if [ "$RC" = 1 ] && out_has 'orphan_seq' && out_has 'nothing was set'; then pass "a sequence missing on the new server stops the script before anything is set"; else fail "missing sequence" "rc=$RC $OUT"; fi
"$MIG/set-readonly.sh" tgb off >/dev/null 2>&1
"$MIG/set-readonly.sh" the_greatest off >/dev/null 2>&1

# --- the trigger fires on a normal write on the target ---------------------------------------------------
OUT="$(tval tgb "insert into authors (name) values ('Zoé') returning search_string")"
if grep -qE '^zoe @20' <<<"$OUT"; then pass "after cutover the search-text trigger fires on the target and unaccent works"; else fail "trigger fires on target" "$OUT"; fi
OUT="$(tval tgb "select max(id) from authors")"
if [ "$OUT" -gt 3000 ]; then pass "a write on the target gets a fresh id that does not collide"; else fail "fresh id" "$OUT"; fi

# --- set-readonly ----------------------------------------------------------------------------------
sess() {   # sess APPNAME: a long session on the source, opened over the network as the superuser, in the background
  ( PGPASSWORD="$SRC_PW" psql "host=source user=postgres sslmode=require dbname=tgb application_name=$1" -X -At -c "select pg_sleep(120)" >/dev/null 2>&1 & )
}
n_sessions() { src_val postgres "select count(*) from pg_stat_activity where application_name='$1'"; }
src_sql tgb <<<'CREATE TABLE ro_probe (id serial PRIMARY KEY)'
run "$MIG/set-readonly.sh" tgb on
check "set-readonly on succeeds" rc_is 0
if [ "$(src_val tgb "select count(*) from pg_db_role_setting s join pg_database d on d.oid=s.setdatabase where d.datname='tgb' and s.setrole=0 and 'default_transaction_read_only=on' = any(s.setconfig)")" = 1 ]; then
  pass "default_transaction_read_only=on is set on the database"; else fail "read-only set" "not set"; fi
OUT="$(PGPASSWORD="$SRC_PW" psql "host=source user=postgres sslmode=require dbname=tgb" -X -At -c "insert into ro_probe default values" 2>&1)"; RC=$?
if [ "$RC" != 0 ] && out_has 'read-only transaction'; then pass "a new session cannot write while read-only is on"; else fail "write during window" "rc=$RC $OUT"; fi
sess window_session
for _ in $(seq 1 20); do [ "$(n_sessions window_session)" = 1 ] && break; sleep 0.5; done
if [ "$(n_sessions window_session)" = 1 ]; then pass "a session opened during the window is running (and read-only)"; else fail "window session" "not started"; fi
run "$MIG/set-readonly.sh" tgb off
check "set-readonly off succeeds" rc_is 0
for _ in $(seq 1 20); do [ "$(n_sessions window_session)" = 0 ] && break; sleep 0.5; done
if [ "$(n_sessions window_session)" = 0 ]; then pass "t_readonly_off_terminates_sessions: the session opened during the window is gone"; else fail "t_readonly_off_terminates_sessions" "still running"; fi
OUT="$(PGPASSWORD="$SRC_PW" psql "host=source user=postgres sslmode=require dbname=tgb" -X -At -c "insert into ro_probe default values returning id" 2>&1)"; RC=$?
check "after off, a new session can write" rc_is 0
if [ "$(src_val tgb "select count(*) from pg_db_role_setting s join pg_database d on d.oid=s.setdatabase where d.datname='tgb'")" = 0 ]; then
  pass "off removes the setting rather than setting it to off"; else fail "setting removed" "still there"; fi

sess on_session
for _ in $(seq 1 20); do [ "$(n_sessions on_session)" = 1 ] && break; sleep 0.5; done
run "$MIG/set-readonly.sh" tgb on
if [ "$RC" = 0 ] && [ "$(n_sessions on_session)" = 0 ]; then pass "on terminates the database's existing sessions"; else fail "on terminates sessions" "rc=$RC $OUT sessions=$(n_sessions on_session)"; fi
"$MIG/set-readonly.sh" tgb off >/dev/null 2>&1

src_sql postgres <<<'ALTER ROLE tgb_app IN DATABASE tgb SET default_transaction_read_only = off;'
run "$MIG/set-readonly.sh" tgb on
if [ "$RC" = 1 ] && out_has 'tgb_app' && [ "$(src_val tgb "select count(*) from pg_db_role_setting s join pg_database d on d.oid=s.setdatabase where d.datname='tgb' and s.setrole=0")" = 0 ]; then
  pass "a per-role override of read-only is refused by name, and nothing was changed"; else fail "role override" "rc=$RC $OUT"; fi
src_sql postgres <<<'ALTER ROLE tgb_app IN DATABASE tgb RESET default_transaction_read_only;'
# A non-superuser sees only its own sessions in pg_stat_activity (backend_type and backend_start read as NULL for
# the rest), so it must be refused unless it holds pg_read_all_stats and pg_signal_backend.
NS_PW="ns-$(openssl rand -hex 8)"
src_sql postgres <<<"ALTER ROLE tgb_app PASSWORD '$NS_PW'; ALTER ROLE tgb_reader PASSWORD '$NS_PW'"
ns_run() { SOURCE_DSN="host=source port=5432 user=tgb_app sslmode=require" SOURCE_PGPASSWORD="$NS_PW" run "$MIG/set-readonly.sh" "$@"; }
( PGPASSWORD="$NS_PW" psql "host=source user=tgb_reader sslmode=require dbname=tgb application_name=other_role" -X -At -c "select pg_sleep(120)" >/dev/null 2>&1 & )
for _ in $(seq 1 20); do [ "$(n_sessions other_role)" = 1 ] && break; sleep 0.5; done
ns_run tgb on
if [ "$RC" = 1 ] && out_has 'pg_signal_backend' && [ "$(n_sessions other_role)" = 1 ] \
   && [ "$(src_val tgb "select count(*) from pg_db_role_setting s join pg_database d on d.oid=s.setdatabase where d.datname='tgb'")" = 0 ]; then
  pass "t_readonly_refuses_a_non_superuser: exit 1, nothing changed, the other role's session untouched"; else fail "t_readonly_refuses_a_non_superuser" "rc=$RC $OUT"; fi
src_sql postgres <<<'GRANT pg_read_all_stats, pg_signal_backend TO tgb_app'
ns_run tgb on
if [ "$RC" = 0 ] && [ "$(n_sessions other_role)" = 0 ]; then pass "t_readonly_works_for_a_role_with_pg_read_all_stats_and_pg_signal_backend: another role's session was seen and ended"; else fail "non-superuser with the two roles" "rc=$RC $OUT sessions=$(n_sessions other_role)"; fi
ns_run tgb off
check "...and the same role can open the window again with off" rc_is 0
src_sql postgres <<<'REVOKE pg_read_all_stats, pg_signal_backend FROM tgb_app'

# The rollback is never blocked: without the privileges, `off` still removes the setting, with a warning.
src_sql postgres <<<'GRANT pg_read_all_stats, pg_signal_backend TO tgb_app'
ns_run tgb on
src_sql postgres <<<'REVOKE pg_read_all_stats, pg_signal_backend FROM tgb_app'
ns_run tgb off
if [ "$RC" = 0 ] && out_has 'WARNING' && out_has 'restart the apps' \
   && [ "$(src_val tgb "select count(*) from pg_db_role_setting s join pg_database d on d.oid=s.setdatabase where d.datname='tgb'")" = 0 ]; then
  pass "t_readonly_off_is_not_blocked_for_a_role_without_the_privileges: setting removed, warns, exit 0"; else fail "t_readonly_off_is_not_blocked_for_a_role_without_the_privileges" "rc=$RC $OUT"; fi

# A session that cannot be ended (stopped with SIGSTOP, so it never handles the SIGTERM) must fail the script.
( PGPASSWORD="$SRC_PW" psql "host=source user=postgres sslmode=require dbname=tgb application_name=frozen" -X -At -c "select pg_sleep(120)" >/dev/null 2>&1 & )
for _ in $(seq 1 20); do [ "$(n_sessions frozen)" = 1 ] && break; sleep 0.5; done
frozen_pid="$(src_val postgres "select pid from pg_stat_activity where application_name = 'frozen'")"
docker exec "$SOURCE_CONTAINER" bash -c "kill -STOP $frozen_pid"
SET_READONLY_PASSES=3 run "$MIG/set-readonly.sh" tgb on
if [ "$RC" = 1 ] && out_has '1 client session\(s\) that started before the change are still connected' && out_has 'NOT closed'; then
  pass "t_readonly_fails_when_a_session_will_not_go: exit 1 and the message says the window is not closed"; else fail "t_readonly_fails_when_a_session_will_not_go" "rc=$RC $OUT"; fi
# `off` with a session that will not end: the setting is reset, exit 3, and the message does not say the window is open.
SET_READONLY_PASSES=3 run "$MIG/set-readonly.sh" tgb off
if [ "$RC" = 3 ] && out_has 'REMOVED' && out_has 'Restart the apps' && ! out_has 'NOT closed' \
   && [ "$(src_val tgb "select count(*) from pg_db_role_setting s join pg_database d on d.oid=s.setdatabase where d.datname='tgb'")" = 0 ]; then
  pass "t_readonly_off_with_a_stuck_session_exits_3: the setting is removed, the message says so plainly"; else fail "t_readonly_off_with_a_stuck_session_exits_3" "rc=$RC $OUT"; fi
docker exec "$SOURCE_CONTAINER" bash -c "kill -CONT $frozen_pid"
for _ in $(seq 1 20); do [ "$(n_sessions frozen)" = 0 ] && break; sleep 0.5; done

# A server whose DateStyle is not ISO must not break the window.
src_sql postgres <<<"ALTER DATABASE tgb SET datestyle TO 'German, DMY'"
run "$MIG/set-readonly.sh" tgb on
check "t_readonly_works_with_a_non_iso_datestyle: on succeeds" rc_is 0
run "$MIG/set-readonly.sh" tgb off
check "...and off succeeds" rc_is 0
src_sql postgres <<<"ALTER DATABASE tgb RESET datestyle"

src_sql postgres <<<'ALTER ROLE tgb_app SET default_transaction_read_only = off;'
run "$MIG/set-readonly.sh" tgb on
if [ "$RC" = 1 ] && out_has 'tgb_app' && out_has 'all databases' && [ "$(src_val tgb "select count(*) from pg_db_role_setting s join pg_database d on d.oid=s.setdatabase where d.datname='tgb' and s.setrole=0")" = 0 ]; then
  pass "t_readonly_refuses_a_role_wide_override: ALTER ROLE ... SET (all databases) is found, named, and nothing was changed"; else fail "t_readonly_refuses_a_role_wide_override" "rc=$RC $OUT"; fi
src_sql postgres <<<'ALTER ROLE tgb_app RESET default_transaction_read_only;'
run "$MIG/set-readonly.sh" tgb sideways
check "an argument other than on or off is refused" rc_is 2

finish
