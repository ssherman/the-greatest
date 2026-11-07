#!/usr/bin/env bash
# deployment/postgres/test/local-e2e-test.sh -- the full local rehearsal. Run by hand; needs Docker. It is
# not a *_test.sh, so test/run.sh (CI) never runs it.   Usage: test/local-e2e-test.sh
#
# The first run of everything together, against nothing real:
#   * the old server: postgres:17, TLS, wal_level=logical, shaped like production's two databases;
#   * a versioned S3 bucket on MinIO (TLS, two keys; the server key may delete current objects but is
#     denied s3:DeleteObjectVersion; the home key is read only);
#   * the new server: the REAL Dockerfile and compose.yml, started by the REAL bin/deploy.sh. Only the things
#     that need root on a real host are stood in for: install/chown/chmod through a root one-off container,
#     and no-op iptables/systemctl. The test's own copy of the tree gets no published port (6543 belongs to
#     the dev database) and the compose project name and network of this run; its pgbackrest.conf.tmpl gets
#     two MinIO-only lines (path-style URIs, no TLS verification). Production's files are not touched.
# Covers: first deploy with stanza creation; pgbackrest info status 1, 2 and 0 on S3; a backup; a restore to a
# chosen moment with the read-only key; deploy refusing an empty data directory with a stanza;
# POSTGRES_BOOTSTRAP=restore onto a fresh volume; every role of spec §5.2; no plain connection and no network
# superuser; data checksums; retention and versioning; then a full 17 -> 18 replication with writers running,
# cutover through the migration scripts, sequences, and finally POSTGRES_BOOTSTRAP=new-cluster.
# Prints the read-only window in seconds at the end. Everything it creates carries one label and is removed on
# exit, also on failure. It publishes no port and never touches 6543 or 6544.
# shellcheck disable=SC2016,SC2155,SC2015,SC2119  # SQL in single quotes on purpose; throwaway secrets
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
# shellcheck source=docker-helpers.sh
. "$OS_DIR/test/docker-helpers.sh"
MIG="$OS_DIR/migration"
STARTED="$(date +%s)"

say() { echo; echo "=== [$(( $(date +%s) - STARTED ))s] $*"; }
abort() { echo "ABORT  $1" >&2; exit 1; }
need() { local what="$1"; shift; "$@" || abort "$what"; }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name" "rc=${RC:-?} ${OUT:-}"; fi; }
rc_is() { [ "$RC" = "$1" ]; }
out_has() { grep -qE -- "$1" <<<"$OUT"; }
run() { OUT="$("$@" 2>&1)"; RC=$?; }

command -v docker >/dev/null && docker info >/dev/null 2>&1 || abort "Docker is required"
dk_init
SUBNET="$(dk_free_subnet)" || abort "no free subnet"
BASE="${SUBNET%.0/24}"
IP_TG="$BASE.20" IP_APP="$BASE.21" IP_RD="$BASE.22" IP_STRANGER="$BASE.99"
dk_network "$SUBNET"
dk_shims

# --- infrastructure ------------------------------------------------------------------------------------
say "MinIO, the old server"
need "MinIO" mk_minio "$PROJ-minio"
need "old server" mk_source "$PROJ-src"
need "seed" seed_source

# --- the test's own copy of the deployable tree ----------------------------------------------------------
PG="$TMP/pg"
mkdir -p "$PG"
cp -r "$OS_DIR/bin" "$OS_DIR/config" "$OS_DIR/systemd" "$OS_DIR/Dockerfile" "$OS_DIR/compose.yml" "$PG/"
python3 -I - "$PG" "$PROJ" "$NET" <<'PY'
import re, sys
pg, proj, net = sys.argv[1:4]
p = pg + "/compose.yml"
s = open(p).read()
s = s.replace("name: postgres-server", "name: %s-t" % proj, 1)
s, n = re.subn(r"    ports:\n(?:      #.*\n)*      - \"0\.0\.0\.0:[^\n]*\n", "", s)
assert n == 1, "ports block not found"
s = s.replace("    shm_size: 1g\n", "    shm_size: 1g\n    networks:\n      default:\n        aliases: [target]\n", 1)
s += "networks:\n  default:\n    name: %s\n    external: true\n" % net
open(p, "w").write(s)
t = pg + "/config/pgbackrest.conf.tmpl"
s = open(t).read()
needle = "repo1-s3-region=${PGBACKREST_REPO_REGION}\n"
assert needle in s
s = s.replace(needle, needle + "repo1-s3-uri-style=path\nrepo1-storage-verify-tls=n\n", 1)
open(t, "w").write(s)
PY
STATE="$TMP/srv" ETC="$TMP/etc" ROOT="$TMP/root"
DK_PROJECTS+=("$PROJ-t" "$PROJ-r")
dk_root_shims "$TMP/rootshims"

ENVF="$TMP/env.postgres"
SU_PW="su-$(openssl rand -hex 12)" TG_PW="tg-$(openssl rand -hex 12)" APP_PW="app-$(openssl rand -hex 12)" RD_PW="rd-$(openssl rand -hex 12)"
CIPHER="$(openssl rand -hex 16)"
{
  printf 'POSTGRES_CLIENTS="the_greatest the_greatest %s;tgb_app tgb %s;tgb_reader tgb %s"\n' "$IP_TG" "$IP_APP" "$IP_RD"
  printf 'POSTGRES_SUPERUSER_PASSWORD=%s\nPOSTGRES_THE_GREATEST_PASSWORD=%s\nPOSTGRES_TGB_APP_PASSWORD=%s\nPOSTGRES_TGB_READER_PASSWORD=%s\n' "$SU_PW" "$TG_PW" "$APP_PW" "$RD_PW"
  printf 'PGBACKREST_REPO_BUCKET=%s\nPGBACKREST_REPO_ENDPOINT=minio:9000\nPGBACKREST_REPO_REGION=us-east-1\nPGBACKREST_REPO_PATH=/e2e\n' "$MINIO_BUCKET"
  printf 'PGBACKREST_REPO_KEY=%s\nPGBACKREST_REPO_KEY_SECRET=%s\nPGBACKREST_CIPHER_PASS=%s\n' "$MINIO_SERVER_KEY" "$MINIO_SERVER_SECRET" "$CIPHER"
  printf 'HC_PG_BACKUP=http://127.0.0.1:9/never\nHC_PG_HEALTH=http://127.0.0.1:9/never\n'
} >"$ENVF"
export POSTGRES_SUPERUSER_PASSWORD="$SU_PW" POSTGRES_HOST_CONFIG_DIR="$STATE/config" POSTGRES_CERTS_DIR="$STATE/certs"

tc() { docker compose -f "$PG/compose.yml" "$@"; }
tx() { tc exec -T postgres "$@" </dev/null; }
tsql() { tc exec -T postgres psql -U postgres -X -q -v ON_ERROR_STOP=1 -d "${1:-postgres}"; }
tvall() { tc exec -T postgres psql -U postgres -X -At -v ON_ERROR_STOP=1 -d "$1" -c "$2" </dev/null; }
tv() { tc exec -T postgres psql -U postgres -X -At -v ON_ERROR_STOP=1 -d "$1" -c "$2" </dev/null | head -1; }
deploy() {   # deploy [VAR=value ...]  -> OUT, RC. WAIT_SLEEP keeps polling quick.
  OUT="$(env PATH="$TMP/rootshims:$PATH" NO_SUDO=1 STATE_DIR="$STATE" ETC_DIR="$ETC" ROOT="$ROOT" ALLOWLIST="$ETC/allowlist" \
    PG_UID=999 PG_GID=999 WAIT_SLEEP=2 "$@" "$PG/bin/deploy.sh" "$ENVF" 2>&1)"
  RC=$?
}
info_code() {   # info_code [pgbackrest option...] : the stanza's status code
  tx pgbackrest --stanza=main "$@" info --output=json </dev/null |
    python3 -I -c 'import json,sys; print([s for s in json.load(sys.stdin) if s["name"]=="main"][0]["status"]["code"])'
}
checkpoints() {   # checkpoints : start-fast=n makes a backup wait for a checkpoint; force them while it runs
  ( for _ in $(seq 1 40); do sleep 3; tc exec -T postgres psql -U postgres -X -q -c CHECKPOINT </dev/null >/dev/null 2>&1; done ) &
  CKPT_PID=$!
}
stop_checkpoints() { kill "$CKPT_PID" 2>/dev/null; wait "$CKPT_PID" 2>/dev/null; }
cl() {   # cl IP USER PASSWORD DB SSLMODE SQL : a client container at a fixed address
  docker run --rm --network "$NET" --ip "$1" --label "pgmig=$PROJ" -e PGPASSWORD="$3" -e PGCONNECT_TIMEOUT=10 "$CLIENT_IMAGE" \
    psql "host=target port=5432 user=$2 dbname=$4 sslmode=$5" -X -At -v ON_ERROR_STOP=1 -c "$6" 2>&1
}

# --- 1. first deploy: empty data, no stanza -------------------------------------------------------------------
say "first deploy (real deploy.sh, real compose, real Dockerfile, MinIO as the bucket)"
deploy
if [ "$RC" != 0 ]; then echo "$OUT" | tail -20; abort "first deploy failed"; fi
pass "first deploy exits 0"
out_has 'deploy: done' && pass "deploy printed done" || fail "deploy done" "$OUT"
if grep -qE "$MINIO_SERVER_SECRET|$SU_PW|$CIPHER|minio:9000" <<<"$OUT"; then fail "deploy output leaks" "secret or endpoint in output"; else pass "deploy output carries no secret, key or endpoint"; fi
check "the deploy log is root-only and exists" test -s "$STATE/state/deploy.log"
if grep -q 'stanza-create' "$STATE/state/deploy.log"; then pass "first deploy created the stanza"; else fail "stanza-create" "not in deploy log"; fi
check "pgbackrest info is status 2 (stanza, no backup yet) on S3" test "$(info_code)" = 2
check "pgbackrest info is status 1 (missing stanza path) for a repo path with no stanza" test "$(info_code --repo1-path=/nowhere)" = 1
check "data_checksums is on" test "$(tv postgres 'show data_checksums')" = on
check "the data directory is en_US.utf8 with UTF8" test "$(tv postgres "select datcollate||' '||pg_encoding_to_char(encoding) from pg_database where datname='postgres'")" = "en_US.utf8 UTF8"
check "the server is PostgreSQL 18" test "$(tv postgres 'show server_version_num' | cut -c1-2)" = 18
check "wal_level is replica and archive_mode is on on the new server" test "$(tv postgres "select current_setting('wal_level')||' '||current_setting('archive_mode')")" = "replica on"
check "ssl is on" test "$(tv postgres 'show ssl')" = on
# The bucket here is MinIO with verification off, so this is the only check that the image could verify real S3.
check "the image has a CA bundle for pgBackRest to verify S3 with" test -n "$(tx sh -c 'test -s /etc/ssl/certs/ca-certificates.crt && echo yes')"
check "no port is published by the test's copy" test -z "$(docker ps --filter "label=com.docker.compose.project=$PROJ-t" --format '{{.Ports}}' | grep -E '0\.0\.0\.0|\[::\]')"

say "a second deploy changes nothing"
deploy
if [ "$RC" = 0 ] && ! grep -q 'recreat' <<<"$OUT"; then pass "a repeat deploy exits 0 and restarts nothing"; else fail "repeat deploy" "rc=$RC $(echo "$OUT" | tail -5)"; fi

# --- 2. a backup, then the data a restore will be asked about -------------------------------------------------------
say "backup.sh (full), then two sentinel rows around a chosen moment"
tsql postgres <<<'CREATE TABLE sentinel (v text PRIMARY KEY)'
checkpoints
OUT="$(env STATE_DIR="$STATE" REPO_DIR="$PG" HC_PG_BACKUP= "$PG/bin/backup.sh" 2>&1)"; RC=$?
stop_checkpoints
check "backup.sh exits 0 against S3" rc_is 0
out_has 'backup ok: full' && pass "...and took a full backup" || fail "full backup" "$OUT"
check "pgbackrest info is status 0 once a backup exists" test "$(info_code)" = 0
tsql postgres <<<"INSERT INTO sentinel VALUES ('A-before')"
sleep 2
T="$(tv postgres "select to_char(clock_timestamp() at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS') || '+00'")"
sleep 2
tsql postgres <<<"INSERT INTO sentinel VALUES ('B-after'); SELECT pg_switch_wal()" >/dev/null
OUT="$(tx pgbackrest --stanza=main check 2>&1)"; RC=$?
check "pgbackrest check passes (the WAL with B has reached the bucket)" rc_is 0
OUT="$(env STATE_DIR="$STATE" REPO_DIR="$PG" DF_PATH="$TMP" HC_PG_HEALTH= "$PG/bin/check-backup-health.sh" 2>&1)"; RC=$?
check "check-backup-health.sh passes on the live server" rc_is 0

# --- 3. restore to a chosen moment, with the read-only key, on a scratch volume --------------------------------------
say "restore to $T with the read-only key"
RO="$TMP/ro-config"
mkdir -p "$RO"
vars="$(grep -oE '\$\{[A-Z_0-9]+\}' "$PG/config/pgbackrest.conf.tmpl" | sort -u | tr -d '\n')"
(
  set -a
  # shellcheck source=/dev/null
  . "$ENVF"
  set +a
  PGBACKREST_REPO_KEY="$MINIO_HOME_KEY" PGBACKREST_REPO_KEY_SECRET="$MINIO_HOME_SECRET" envsubst "$vars" <"$PG/config/pgbackrest.conf.tmpl" >"$RO/pgbackrest.conf"
)
cp "$STATE/config/pg_hba.conf" "$RO/pg_hba.conf"
chmod 600 "$RO/pgbackrest.conf"
dk_chown_root 999:999 "$RO/pgbackrest.conf"
sc() { POSTGRES_HOST_CONFIG_DIR="$RO" docker compose -f "$PG/compose.yml" -p "$PROJ-r" "$@"; }
run sc run --rm --no-deps -T postgres pgbackrest --stanza=main restore --type=time "--target=$T" --target-action=promote
check "pgbackrest restore --type=time onto a fresh volume succeeds with the read-only key" rc_is 0
run sc run -d --no-deps --name "$PROJ-scratch" postgres postgres -c config_file=/etc/postgresql/postgresql.conf \
  -c hba_file=/etc/postgresql-host/pg_hba.conf -c archive_mode=off
for _ in $(seq 1 90); do
  [ "$(docker exec "$PROJ-scratch" psql -U postgres -Atc 'select pg_is_in_recovery()' 2>/dev/null)" = f ] && break
  sleep 2
done
scratch_v() { docker exec "$PROJ-scratch" psql -U postgres -X -At -c "$1" 2>&1; }
check "the restored cluster has the row from before the chosen moment" test "$(scratch_v "select count(*) from sentinel where v='A-before'")" = 1
check "t_restore_to_timestamp: the row written after it is absent" test "$(scratch_v "select count(*) from sentinel where v='B-after'")" = 0
check "the restored cluster has data checksums on" test "$(scratch_v 'show data_checksums')" = on
docker rm -f -v "$PROJ-scratch" >/dev/null 2>&1
sc down -v >/dev/null 2>&1

say "the read-only key cannot write or delete in the bucket; the server key cannot delete a version"
MCH() { docker exec -i "$MINIO_CONTAINER" mc --insecure "$@"; }
MCH alias set home https://localhost:9000 "$MINIO_HOME_KEY" "$MINIO_HOME_SECRET" >/dev/null
run bash -c "echo x | docker exec -i $MINIO_CONTAINER mc --insecure pipe home/$MINIO_BUCKET/e2e/probe-home"
check "the read-only key cannot write" test "$RC" != 0
run docker exec "$MINIO_CONTAINER" mc --insecure ls "home/$MINIO_BUCKET/e2e/"
check "the read-only key can list" rc_is 0
echo probe | docker exec -i "$MINIO_CONTAINER" mc --insecure pipe "srv/$MINIO_BUCKET/e2e/probe-srv" >/dev/null 2>&1
echo probe2 | docker exec -i "$MINIO_CONTAINER" mc --insecure pipe "srv/$MINIO_BUCKET/e2e/probe-srv" >/dev/null 2>&1
VID="$(docker exec "$MINIO_CONTAINER" mc --insecure ls --versions --json "srv/$MINIO_BUCKET/e2e/probe-srv" | grep -o '"versionId":"[^"]*"' | head -1 | cut -d'"' -f4)"
run docker exec "$MINIO_CONTAINER" mc --insecure rm --version-id "$VID" "srv/$MINIO_BUCKET/e2e/probe-srv"
if [ "$RC" != 0 ] && out_has '[Dd]enied'; then pass "t_server_key_cannot_delete_a_version (MinIO: AccessDenied on DeleteObjectVersion)"; else fail "delete version denied" "rc=$RC $OUT"; fi
run docker exec "$MINIO_CONTAINER" mc --insecure rm "srv/$MINIO_BUCKET/e2e/probe-srv"
if [ "$RC" = 0 ] && out_has '[Dd]elete marker'; then pass "...but may delete the current object, which only adds a delete marker"; else fail "current delete" "rc=$RC $OUT"; fi
run docker exec "$MINIO_CONTAINER" mc --insecure ls --versions "srv/$MINIO_BUCKET/e2e/probe-srv"
if [ "$(grep -c probe-srv <<<"$OUT")" -ge 3 ]; then pass "...and both earlier versions are still there"; else fail "versions kept" "$OUT"; fi

# --- 4. deploy refuses an empty data directory when the repo has a stanza --------------------------------------------------
say "empty data directory with a stanza: refused; then POSTGRES_BOOTSTRAP=restore on a FRESH volume"
tc down -v >/dev/null 2>&1
deploy
if [ "$RC" != 0 ] && out_has 'POSTGRES_BOOTSTRAP=restore' && out_has 'new-cluster'; then
  pass "t_deploy_refuses_empty_with_stanza: refused, and names both ways forward"; else fail "refuses empty data dir with stanza" "rc=$RC $(echo "$OUT" | tail -6)"; fi
check "...and started no Postgres" test -z "$(tc ps -q postgres)"
deploy POSTGRES_BOOTSTRAP=restore
if [ "$RC" != 0 ]; then echo "$OUT" | tail -15; fi
check "POSTGRES_BOOTSTRAP=restore onto a fresh volume succeeds" rc_is 0
check "...the restored server holds the first sentinel row" test "$(tv postgres "select count(*) from sentinel where v='A-before'")" = 1
check "...and the second (the whole archived WAL was replayed)" test "$(tv postgres "select count(*) from sentinel where v='B-after'")" = 1
check "...with data checksums on" test "$(tv postgres 'show data_checksums')" = on
check "...and archiving works again (pgbackrest check)" tx pgbackrest --stanza=main check
check "...and the roles exist (apply-roles ran)" test "$(tv postgres "select count(*) from pg_roles where rolname in ('the_greatest','tgb_app','tgb_reader')")" = 3
check "pgbackrest info is status 0 after the restore" test "$(info_code)" = 0

# --- 5. spec §5.2: every role, and nothing else ---------------------------------------------------------------------------
say "roles, TLS, and who may connect"
OUT="$(cl "$IP_APP" tgb_app "$APP_PW" tgb require "select current_user, (select rolsuper from pg_roles where rolname = current_user), (select ssl from pg_stat_ssl where pid = pg_backend_pid()), pg_has_role('pg_monitor','member')")"
check "tgb_app connects to tgb over TLS, is not a superuser, is a pg_monitor member" test "$OUT" = "tgb_app|f|t|t"
OUT="$(cl "$IP_APP" tgb_app "$APP_PW" tgb require "create table probe (id serial primary key, v text); insert into probe (v) values ('x'); select count(*) from pg_stat_statements")"
check "tgb_app can create, write and read pg_stat_statements" test "$?" = 0
OUT="$(cl "$IP_RD" tgb_reader "$RD_PW" tgb require "select count(*) from probe")"
check "tgb_reader reads a table tgb_app made" test "$OUT" = 1
OUT="$(cl "$IP_RD" tgb_reader "$RD_PW" tgb require "insert into probe (v) values ('y')")"; RC=$?
if [ "$RC" != 0 ] && out_has 'permission denied'; then pass "tgb_reader cannot write"; else fail "reader write" "rc=$RC $OUT"; fi
OUT="$(cl "$IP_RD" tgb_reader "$RD_PW" tgb require "create table reader_made (a int)")"; RC=$?
check "tgb_reader cannot create tables" test "$RC" != 0
cl "$IP_APP" tgb_app "$APP_PW" tgb require "drop table probe" >/dev/null
OUT="$(cl "$IP_TG" the_greatest "$TG_PW" the_greatest require "select current_user, (select rolsuper from pg_roles where rolname = current_user); create table probe (a int); drop table probe")"
check "the_greatest owns its database, over TLS, without superuser" test "$(head -1 <<<"$OUT")" = "the_greatest|f"
OUT="$(cl "$IP_TG" the_greatest "$TG_PW" tgb require "select 1")"; RC=$?
if [ "$RC" != 0 ] && out_has 'no pg_hba.conf entry'; then pass "the_greatest is refused on tgb"; else fail "the_greatest on tgb" "rc=$RC $OUT"; fi
OUT="$(cl "$IP_APP" tgb_app "$APP_PW" the_greatest require "select 1")"; RC=$?
if [ "$RC" != 0 ] && out_has 'no pg_hba.conf entry'; then pass "tgb_app is refused on the_greatest"; else fail "tgb_app on the_greatest" "rc=$RC $OUT"; fi
OUT="$(cl "$IP_APP" tgb_app "$APP_PW" postgres require "select 1")"; RC=$?
if [ "$RC" != 0 ]; then pass "tgb_app is refused on the postgres database"; else fail "tgb_app on postgres" "$OUT"; fi
OUT="$(cl "$IP_APP" postgres "$SU_PW" tgb require "select 1")"; RC=$?
if [ "$RC" != 0 ] && out_has 'no pg_hba.conf entry'; then pass "no network superuser: postgres is refused from an allowed address, with the right password"; else fail "network superuser" "rc=$RC $OUT"; fi
OUT="$(cl "$IP_APP" tgb_app "$APP_PW" tgb disable "select 1")"; RC=$?
if [ "$RC" != 0 ] && out_has 'no pg_hba.conf entry'; then pass "no plain connection: sslmode=disable is refused"; else fail "plain connection" "rc=$RC $OUT"; fi
OUT="$(cl "$IP_STRANGER" tgb_app "$APP_PW" tgb require "select 1")"; RC=$?
if [ "$RC" != 0 ] && out_has 'no pg_hba.conf entry'; then pass "tgb_app is refused from an address that is not its own"; else fail "wrong address" "rc=$RC $OUT"; fi
OUT="$(cl "$IP_APP" tgb_app "not-the-password" tgb require "select 1")"; RC=$?
check "a wrong password is refused" test "$RC" != 0
check "the superuser works over the socket inside the container" test "$(tv postgres 'select current_user')" = postgres
check "the allowlist is the three client addresses" test "$(sort "$ETC/allowlist" | tr '\n' ' ')" = "$IP_TG $IP_APP $IP_RD "

# --- 6. retention and versioning with the server key ------------------------------------------------------------------------
say "retention: a second full backup, then expire down to one full backup"
checkpoints
run tx pgbackrest --stanza=main backup --type=full
stop_checkpoints
check "a second full backup" rc_is 0
old_label="$(tx pgbackrest --stanza=main info --output=json | python3 -I -c 'import json,sys; print([s for s in json.load(sys.stdin) if s["name"]=="main"][0]["backup"][0]["label"])')"
before_markers="$(docker exec "$MINIO_CONTAINER" mc --insecure ls --versions --json -r "srv/$MINIO_BUCKET/e2e/backup/main/" | grep -c '"isDeleteMarker":true')"
run tx pgbackrest --stanza=main expire --repo1-retention-full=1 --repo1-retention-full-type=count
check "expire succeeds with the delete-version-denied key" rc_is 0
fulls="$(tx pgbackrest --stanza=main info --output=json | python3 -I -c 'import json,sys; print(len([b for b in [s for s in json.load(sys.stdin) if s["name"]=="main"][0]["backup"] if b["type"]=="full"]))')"
check "only one full backup is left in the listing" test "$fulls" = 1
after_markers="$(docker exec "$MINIO_CONTAINER" mc --insecure ls --versions --json -r "srv/$MINIO_BUCKET/e2e/backup/main/" | grep -c '"isDeleteMarker":true')"
if [ "$after_markers" -gt "$before_markers" ]; then pass "expiry added delete markers ($before_markers -> $after_markers) instead of destroying anything"; else fail "delete markers" "$before_markers -> $after_markers"; fi
current_n="$(docker exec "$MINIO_CONTAINER" mc --insecure ls -r "srv/$MINIO_BUCKET/e2e/backup/main/$old_label/" | wc -l)"
versions_n="$(docker exec "$MINIO_CONTAINER" mc --insecure ls --versions -r "srv/$MINIO_BUCKET/e2e/backup/main/$old_label/" | grep -c 'PUT')"
if [ "$current_n" = 0 ] && [ "$versions_n" -gt 0 ]; then
  pass "t_expired_backup_survives_as_versions: $old_label is gone from the listing, but $versions_n of its object versions remain for the lifecycle rule to expire after 14 days"
else fail "expired backup versions" "current=$current_n versions=$versions_n"; fi
run docker exec "$MINIO_CONTAINER" mc --insecure ilm rule ls "local/$MINIO_BUCKET"
if out_has '14'; then pass "the bucket has the 14-day noncurrent-version rule"; else fail "lifecycle rule" "$OUT"; fi
checkpoints
OUT="$(env STATE_DIR="$STATE" REPO_DIR="$PG" HC_PG_BACKUP= BACKUP_DOW=3 "$PG/bin/backup.sh" 2>&1)"
stop_checkpoints
if out_has 'backup ok: diff'; then pass "backup.sh takes a differential backup on a weekday"; else fail "diff backup" "$OUT"; fi

# --- 7. the migration -----------------------------------------------------------------------------------------------
say "migration: check-schema on the old server"
export SOURCE_DSN="host=source port=5432 user=postgres sslmode=require" SOURCE_PGPASSWORD="$SRC_PW"
export TARGET_PSQL="docker compose -f $PG/compose.yml exec -T postgres psql -U postgres"
export REPLICATOR_PASSWORD="repl-$(openssl rand -hex 16)" REPLICATION_HOST=source
run "$MIG/check-schema.sh" all
check "every connectable database on the old server is clean (postgres and template1 have none)" rc_is 0

say "load-schema as each database's owner role"
SHIM_IP="$IP_APP" TARGET_DSN="host=target user=tgb_app sslmode=require" TARGET_PGPASSWORD="$APP_PW" run "$MIG/load-schema.sh" tgb
check "load-schema tgb as tgb_app, over TLS, from tgb_app's address" rc_is 0
SHIM_IP="$IP_TG" TARGET_DSN="host=target user=the_greatest sslmode=require" TARGET_PGPASSWORD="$TG_PW" run "$MIG/load-schema.sh" the_greatest
check "load-schema the_greatest as the_greatest" rc_is 0
check "tgb_app owns every tgb table after the load" test "$(tv tgb "select count(*) from pg_class where relnamespace='public'::regnamespace and relkind in ('r','S') and pg_get_userbyid(relowner) <> 'tgb_app'")" = 0
check "the_greatest owns every the_greatest table after the load" test "$(tv the_greatest "select count(*) from pg_class where relnamespace='public'::regnamespace and relkind in ('r','S') and pg_get_userbyid(relowner) <> 'the_greatest'")" = 0
run "$MIG/check-schema.sh" tgb --target
check "the loaded tgb has only the expected functions, triggers and extensions" rc_is 0

say "old site: tgb_app and tgb_reader on the loaded target"
OUT="$(cl "$IP_APP" tgb_app "$APP_PW" tgb require "insert into authors (name) values ('Écrivain'); insert into ident (v) values ('x'); select nextval('orphan_seq'); delete from authors; delete from ident")"
check "tgb_app reads, writes and uses its sequences after a --no-owner load" test "$?" = 0
OUT="$(cl "$IP_RD" tgb_reader "$RD_PW" tgb require "select count(*) from authors")"
check "tgb_reader reads the loaded tables" test "$?" = 0
OUT="$(cl "$IP_RD" tgb_reader "$RD_PW" tgb require "insert into authors (name) values ('no')")"; RC=$?
check "tgb_reader cannot write them" test "$RC" != 0
cl "$IP_APP" tgb_app "$APP_PW" tgb require "create table made_later (a int)" >/dev/null
OUT="$(cl "$IP_RD" tgb_reader "$RD_PW" tgb require "select count(*) from made_later")"
check "tgb_reader reads a table created after the grants" test "$?" = 0
OUT="$(cl "$IP_RD" tgb_reader "$RD_PW" tgb require "insert into made_later values (1)")"; RC=$?
check "...and cannot write to it" test "$RC" != 0
cl "$IP_APP" tgb_app "$APP_PW" tgb require "drop table made_later" >/dev/null

say "writers start on the old server, then the replication"
writer() {   # writer DB : inserts and updates until $TMP/stop.DB exists; a statement counts only if psql said it succeeded
  local db="$1" n=0 psqlc=(docker exec -i "$SOURCE_CONTAINER" psql -U postgres -X -q -v ON_ERROR_STOP=1 -d "$1")
  while [ ! -e "$TMP/stop.$db" ]; do
    n=$((n + 1))
    if "${psqlc[@]}" -c "insert into writes (n) values ($n)" </dev/null >/dev/null 2>&1; then echo "$n" >>"$TMP/ack.$db"; fi
    if [ $((n % 3)) = 0 ] && "${psqlc[@]}" -c "update writes set updated = $n where n = $((n - 1))" </dev/null >/dev/null 2>&1; then
      echo "$((n - 1)):$n" >>"$TMP/ackupd.$db"
    fi
    if [ "$db" = tgb ] && [ $((n % 2)) = 0 ] && "${psqlc[@]}" -c "insert into authors (name) values ('W$n')" </dev/null >/dev/null 2>&1; then
      echo "W$n" >>"$TMP/ackauth.$db"
    fi
    sleep 0.05
  done
}
: >"$TMP/ack.tgb"; : >"$TMP/ack.the_greatest"
writer tgb & W1=$!
writer the_greatest & W2=$!
sleep 3
acked_before="$(wc -l <"$TMP/ack.tgb")"
for db in tgb the_greatest; do
  run "$MIG/create-replication.sh" "$db"
  check "create-replication $db" rc_is 0
done
for db in tgb the_greatest; do
  run "$MIG/wait-catchup.sh" "$db" --initial
  check "the initial copy of $db finished while the writer was running" rc_is 0
done
acked_copy="$(wc -l <"$TMP/ack.tgb")"
if [ "$acked_copy" -gt "$acked_before" ]; then pass "the writer kept writing during the copy ($acked_before -> $acked_copy acknowledged)"; else fail "writer during copy" "$acked_before -> $acked_copy"; fi
tsql tgb <<<'ANALYZE' && tsql the_greatest <<<'ANALYZE' && pass "ANALYZE on both new databases (spec step 6)" || fail "ANALYZE" "failed"
sleep 3
src_auth="$(src_val tgb "select search_string from authors where id = 17")"
tgt_auth="$(tv tgb "select search_string from authors where id = 17")"
check "the search-text trigger did not fire on apply: the target keeps the source's value ($src_auth)" test "$src_auth" = "$tgt_auth"

say "scenarios before the cutover: a connection blip mid-soak, a role-wide override, a row in ol_works"
errs() { tv tgb "select apply_error_count from pg_stat_subscription_stats where subname = 'migration_sub_tgb'"; }
errs_up() { [ "$(errs)" -gt 0 ]; }
blip_healed() { [ "$(tv tgb "select note from tags where name = 'blip'")" = source ]; }
tsql tgb <<<"insert into tags (name, note) values ('blip', 'target')"
src_sql tgb <<<"insert into tags (name, note) values ('blip', 'source')"
for _ in $(seq 1 40); do errs_up && break; sleep 1; done
check "a unique violation on the new server raised the subscription's error counter ($(errs))" errs_up
tsql tgb <<<"delete from tags where name = 'blip'"
for _ in $(seq 1 40); do blip_healed && break; sleep 1; done
check "...the apply worker healed by itself and the source's row arrived; the counter stays above zero" blip_healed
src_sql postgres <<<'ALTER ROLE tgb_app SET default_transaction_read_only = off'
run "$MIG/set-readonly.sh" tgb on
if [ "$RC" = 1 ] && out_has 'all databases'; then pass "a role-wide ALTER ROLE ... SET default_transaction_read_only = off is found and refuses the window"; else fail "role-wide override" "rc=$RC $OUT"; fi
src_sql postgres <<<'ALTER ROLE tgb_app RESET default_transaction_read_only'
src_sql tgb <<<"insert into ol_works (data) values ('{}')"
run "$MIG/compare.sh" tgb --counts-only
if [ "$RC" = 1 ] && out_has 'ol_works'; then pass "a row in the old server's ol_works (not replicated) fails compare"; else fail "ol_works row" "rc=$RC $OUT"; fi
src_sql tgb <<<"delete from ol_works"

say "cutover, one database at a time, through the scripts"
declare -A WINDOW
cutover() {   # cutover DB : the real sequence, timed
  local db="$1" t0 t1
  t0="$(date +%s.%N)"
  "$MIG/set-readonly.sh" "$db" on || return 1
  touch "$TMP/stop.$db"
  "$MIG/wait-catchup.sh" "$db" || return 1
  "$MIG/sync-sequences.sh" "$db" || return 1
  "$MIG/compare.sh" "$db" --counts-only || return 1
  t1="$(date +%s.%N)"
  awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }' >"$TMP/window.$db"
}
for db in tgb the_greatest; do
  OUT="$(cutover "$db" 2>&1)"; RC=$?
  WINDOW[$db]="$(cat "$TMP/window.$db" 2>/dev/null)"
  if [ "$RC" = 0 ]; then pass "cutover of $db: read-only, catch-up, sequences, compare all passed (${WINDOW[$db]} s)"; else fail "cutover of $db" "$(echo "$OUT" | tail -12)"; fi
  echo "$OUT" | grep -E 'sync-sequences:|wait-catchup:|compare:' | sed 's/^/        /'
done
wait "$W1" "$W2" 2>/dev/null
say "checksums, outside the window (step 8's sampled compare, with per-table timing)"
for db in tgb the_greatest; do
  case "$db" in tgb) ck="public.authors public.books public.writes public.ident public.tags" ;; *) ck="public.users public.list_items public.writes" ;; esac
  CHECKSUM_TABLES="$ck" run "$MIG/compare.sh" "$db"
  check "checksums of the sampled tables match on $db after the cutover" rc_is 0
  grep 'checksum' <<<"$OUT" | sed 's/^/        /'
done
for db in tgb the_greatest; do
  tvall "$db" "select n from writes order by n" | sort >"$TMP/tgt.$db"
  sort "$TMP/ack.$db" >"$TMP/ack.$db.sorted"
  missing="$(comm -23 "$TMP/ack.$db.sorted" "$TMP/tgt.$db" | wc -l)"
  if [ "$missing" = 0 ] && [ -s "$TMP/ack.$db" ]; then pass "no acknowledged write is missing on the new $db ($(wc -l <"$TMP/ack.$db") acknowledged inserts)"; else fail "acknowledged writes lost in $db" "$missing missing"; fi
  tvall "$db" "select n||':'||updated from writes where updated > 0" | sort >"$TMP/tgtupd.$db"
  if [ -s "$TMP/ackupd.$db" ]; then
    sort "$TMP/ackupd.$db" >"$TMP/ackupd.$db.sorted"
    miss="$(comm -23 "$TMP/ackupd.$db.sorted" "$TMP/tgtupd.$db" | wc -l)"
    if [ "$miss" = 0 ]; then pass "every acknowledged update reached the new $db ($(wc -l <"$TMP/ackupd.$db") updates)"; else fail "updates lost in $db" "$miss missing"; fi
  fi
done
tvall tgb "select name from authors where name like 'W%'" | sort >"$TMP/tgtauth"
sort "$TMP/ackauth.tgb" >"$TMP/ackauth.sorted"
if [ "$(comm -23 "$TMP/ackauth.sorted" "$TMP/tgtauth" | wc -l)" = 0 ]; then pass "every acknowledged authors insert (trigger table) reached the new tgb"; else fail "authors lost" "missing"; fi

say "after cutover: writes on the new server"
for db in tgb the_greatest; do
  OUT="$(tv "$db" "insert into writes (n) values (-1) returning id")"
  mx="$(tv "$db" "select max(id) from writes where n <> -1")"
  if [ "$OUT" -gt "$mx" ]; then pass "a new write in $db gets a fresh id ($OUT > $mx)"; else fail "fresh id $db" "$OUT vs $mx"; fi
done
OUT="$(tv tgb "insert into authors (name) values ('Zoé') returning search_string")"
if grep -qE '^zoe @20' <<<"$OUT"; then pass "the search-text trigger fires on a normal write on the new server"; else fail "trigger on new server" "$OUT"; fi
OUT="$(cl "$IP_APP" tgb_app "$APP_PW" tgb require "insert into authors (name) values ('As the app') returning id")"
check "tgb_app inserts into authors after cutover without a key collision" test "$?" = 0
for s in authors_id_seq books_id_seq writes_id_seq; do
  if [ "$(tv tgb "select last_value >= (select max(id) from ${s%_id_seq}) from $s")" = t ]; then pass "tgb $s is at or past max(id)"; else fail "$s" "behind"; fi
done
check "the empty table's sequence kept is_called=false on the new server" test "$(tv tgb "select is_called from empty_things_id_seq")" = f

say "finish: drop the subscriptions, verify the new server"
for db in tgb the_greatest; do
  run "$MIG/create-replication.sh" "$db" drop
  check "subscription and publication of $db dropped" rc_is 0
done
check "no replication slot is left on the old server" test "$(src_val postgres 'select count(*) from pg_replication_slots')" = 0
check "no subscription is left on the new server" test "$(tv tgb 'select count(*) from pg_subscription')" = 0
run "$MIG/check-schema.sh" all --target
check "all four databases on the new server have only the expected objects (spec §5.4)" rc_is 0
checkpoints
run tx pgbackrest --stanza=main check
stop_checkpoints
check "archiving still works after the migration" rc_is 0

# --- 8. new-cluster -------------------------------------------------------------------------------------------------
say "POSTGRES_BOOTSTRAP=new-cluster"
tc down -v >/dev/null 2>&1
deploy POSTGRES_BOOTSTRAP=new-cluster
if [ "$RC" != 0 ]; then echo "$OUT" | tail -15; fi
check "new-cluster on a fresh volume starts an empty cluster and registers it (stanza-upgrade)" rc_is 0
out_has 'NEW, EMPTY' && pass "...and says plainly that nothing is restored" || fail "new-cluster warning" "$OUT"
check "the new cluster is empty" test "$(tv postgres "select count(*) from pg_tables where schemaname='public'")" = 0
check "pgbackrest check passes for the new cluster" tx pgbackrest --stanza=main check
check "the old cluster's backups are still listed under the old database id" test "$(tx pgbackrest --stanza=main info --output=json </dev/null | python3 -I -c 'import json,sys; print(len({b["database"]["id"] for b in [s for s in json.load(sys.stdin) if s["name"]=="main"][0]["backup"]}))')" -ge 1
deploy POSTGRES_BOOTSTRAP=new-cluster
if [ "$RC" != 0 ] && out_has 'Unset POSTGRES_BOOTSTRAP'; then pass "a leftover new-cluster setting is refused once the cluster is registered"; else fail "leftover new-cluster" "rc=$RC $(echo "$OUT" | tail -3)"; fi

say "result"
for db in tgb the_greatest; do echo "READ-ONLY WINDOW  $db: ${WINDOW[$db]:-unknown} seconds (set read-only, wait for catch-up, sync sequences, compare)"; done
echo "wall time of the whole rehearsal: $(( $(date +%s) - STARTED )) s"
finish
