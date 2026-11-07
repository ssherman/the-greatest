# deployment/postgres/test/docker-helpers.sh -- sourced by migration_test.sh and local-e2e-test.sh.
# Throwaway Docker resources for the migration tests: a network, a postgres:17 "old server" shaped
# like production's two databases, and psql/pg_dump shims that run in a client container on that
# network. Everything carries the label pgmig=$PROJ, and dk_cleanup removes by label, so a failed or
# interrupted run leaves nothing behind. Never touches ports 6543/6544 or any container it did not
# start: nothing here publishes a port.
# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by the files that source this

# Pinned by digest (read from the registry on 2026-11-07): the tests must not change under a floating tag.
# postgres:18 is the digest the Dockerfile pins as 18.6-trixie. To update, pull the tag, copy the digest from
# `docker inspect --format '{{index .RepoDigests 0}}'`, and change both lines.
SRC_IMAGE="${SRC_IMAGE:-postgres:17@sha256:7f29c02ba9eeff4de9a9f414d803faa0e6fe5e8d15ebe217e3e418c82e652b35}"
CLIENT_IMAGE="${CLIENT_IMAGE:-postgres:18@sha256:e3d24f6906d0760bf4da0dae872415391ededefad23fd471c47dc53b0ddf3c42}"
TGT_IMAGE="${TGT_IMAGE:-postgres:18@sha256:e3d24f6906d0760bf4da0dae872415391ededefad23fd471c47dc53b0ddf3c42}"
DK_PROJECTS=()      # compose project names to remove at the end
DK_TMP_ROOT_FILES=0 # set to 1 when a root helper has created files in $TMP that this user cannot remove

# dk_init: names, temp directory and the cleanup trap. Call first.
dk_init() {
  PROJ="pgmig$(date +%s)$RANDOM"
  NET="$PROJ-net"
  TMP="$(mktemp -d)"
  chmod 755 "$TMP"
  SRC_PW="src-$(openssl rand -hex 8)"
  trap dk_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

dk_cleanup() {
  trap - EXIT INT TERM
  local ids p
  jobs -p | xargs -r kill 2>/dev/null
  ids="$(docker ps -aq --filter "label=pgmig=$PROJ" 2>/dev/null)"
  # shellcheck disable=SC2086  # ids is a list of container ids
  if [ -n "$ids" ]; then docker rm -f -v $ids >/dev/null 2>&1; fi
  for p in "${DK_PROJECTS[@]}"; do
    ids="$(docker ps -aq --filter "label=com.docker.compose.project=$p" 2>/dev/null)"
    # shellcheck disable=SC2086
    if [ -n "$ids" ]; then docker rm -f -v $ids >/dev/null 2>&1; fi
    docker rmi "$p-postgres" >/dev/null 2>&1
    docker volume ls -q --filter "label=com.docker.compose.project=$p" 2>/dev/null | xargs -r docker volume rm -f >/dev/null 2>&1
    docker network ls -q --filter "label=com.docker.compose.project=$p" 2>/dev/null | xargs -r docker network rm >/dev/null 2>&1
  done
  docker volume ls -q --filter "label=pgmig=$PROJ" 2>/dev/null | xargs -r docker volume rm -f >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  if [ -n "${TMP:-}" ]; then
    # Files made by a root helper (container-owned certificates, config) need a root helper to go.
    if ! rm -rf "$TMP" 2>/dev/null; then
      docker run --rm -v "$TMP:/x" --entrypoint find alpine:3 /x -mindepth 1 -delete >/dev/null 2>&1
      rm -rf "$TMP"
    fi
  fi
}

# dk_network [SUBNET]: a user-defined network; with a subnet, containers can be given fixed addresses.
dk_network() {
  if [ -n "${1:-}" ]; then
    docker network create --label "pgmig=$PROJ" --subnet "$1" "$NET" >/dev/null
  else
    docker network create --label "pgmig=$PROJ" "$NET" >/dev/null
  fi
}

# dk_free_subnet: a /24 in 10.x that no existing Docker network uses; prints it.
dk_free_subnet() {
  local used n s
  used="$(docker network ls -q | xargs -r docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null)"
  for _ in $(seq 1 30); do
    n=$((RANDOM % 200 + 20))
    s="10.$n.$((RANDOM % 250)).0/24"
    if ! grep -qF "10.$n." <<<"$used"; then echo "$s"; return 0; fi
  done
  return 1
}

# dk_shims: psql and pg_dump on PATH that run inside a client container on $NET. The argument list
# of every call goes to $TMP/argv.log, which is how a test proves a secret never reached argv.
dk_shims() {
  local t
  mkdir -p "$TMP/shims"
  : >"$TMP/argv.log"
  local ip_opt
  for t in psql pg_dump; do
    # SHIM_IP (psql only) gives the client container a fixed address on the network, for the e2e
    # test whose pg_hba admits each role from one address.
    ip_opt=""
    # shellcheck disable=SC2016  # expanded when the shim runs, not now
    if [ "$t" = psql ]; then ip_opt='${SHIM_IP:+--ip "$SHIM_IP"}'; fi
    cat >"$TMP/shims/$t" <<EOF
#!/usr/bin/env bash
printf '%q ' $t "\$@" >>"$TMP/argv.log"; echo >>"$TMP/argv.log"
exec docker run --rm -i --network "$NET" $ip_opt --label "pgmig=$PROJ" -e PGPASSWORD -e PGCONNECT_TIMEOUT=15 $CLIENT_IMAGE $t "\$@"
EOF
    chmod +x "$TMP/shims/$t"
  done
  export PATH="$TMP/shims:$PATH"
}

# dk_wait_ready CONTAINER: pg_isready and a real query, twice in a row (the image's init runs a
# temporary server first).
dk_wait_ready() {
  local streak=0 i
  for i in $(seq 1 120); do
    if docker exec "$1" psql -U postgres -Atc 'select 1' >/dev/null 2>&1; then streak=$((streak + 1)); else streak=0; fi
    if [ "$streak" -ge 2 ]; then return 0; fi
    sleep 1
  done
  echo "dk_wait_ready: $1 did not become ready" >&2
  docker logs --tail 20 "$1" >&2
  return 1
}

# mk_source NAME: the old server. postgres:17, TLS with a self-signed certificate, wal_level=logical,
# max_slot_wal_keep_size as spec step 4 sets it, en_US.utf8, and a pg_hba that accepts only hostssl.
mk_source() {
  cat >"$TMP/source-start.sh" <<'EOF'
#!/usr/bin/env bash
set -e
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=source" -keyout /tmp/srv.key -out /tmp/srv.crt 2>/dev/null
chown postgres:postgres /tmp/srv.key /tmp/srv.crt
chmod 600 /tmp/srv.key
exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tmp/srv.crt -c ssl_key_file=/tmp/srv.key \
  -c wal_level=logical -c max_slot_wal_keep_size=20GB -c listen_addresses='*' -c max_connections=100
EOF
  docker run -d --name "$1" --network "$NET" --network-alias source --label "pgmig=$PROJ" \
    -e POSTGRES_PASSWORD="$SRC_PW" -e POSTGRES_INITDB_ARGS="--locale=en_US.utf8 --encoding=UTF8" \
    -v "$TMP/source-start.sh:/start.sh:ro" --entrypoint bash "$SRC_IMAGE" /start.sh >/dev/null || return 1
  dk_wait_ready "$1" || return 1
  docker exec -i "$1" bash -c 'cat > "$PGDATA/pg_hba.conf"' <<'EOF'
local all all trust
hostssl all all all scram-sha-256
host all all all reject
EOF
  docker exec "$1" psql -U postgres -Atc 'select pg_reload_conf()' >/dev/null
  SOURCE_CONTAINER="$1"
}

# src_sql [DB]: SQL on stdin, run in the source container over its socket as the superuser.
src_sql() { docker exec -i "$SOURCE_CONTAINER" psql -U postgres -X -q -v ON_ERROR_STOP=1 -d "${1:-postgres}"; }
src_val() { docker exec -i "$SOURCE_CONTAINER" psql -U postgres -X -At -v ON_ERROR_STOP=1 -d "${1:?db}" -c "$2"; }

# seed_source: production's shape (spec §13.1), small. tgb: the six extensions, two search-text
# triggers whose value changes on every call (so a trigger that fired on the target would show), the
# update_ol_works_search_text function with no trigger, two empty tables without a primary key named
# ol_editions and ol_works, pghero_query_stats with rows, an empty table with a sequence, an identity
# table, a table without an id column, a sequence nothing owns, and comments. the_greatest: plain tables,
# no triggers, no extensions.
seed_source() {
  src_sql postgres <<'SQL'
CREATE ROLE tgb_app LOGIN;
CREATE ROLE tgb_reader LOGIN;
CREATE ROLE the_greatest LOGIN;
CREATE DATABASE tgb OWNER tgb_app;
CREATE DATABASE the_greatest OWNER the_greatest;
SQL
  src_sql tgb <<'SQL'
CREATE EXTENSION btree_gin; CREATE EXTENSION btree_gist; CREATE EXTENSION fuzzystrmatch;
CREATE EXTENSION pg_stat_statements; CREATE EXTENSION pg_trgm; CREATE EXTENSION unaccent;
ALTER SCHEMA public OWNER TO tgb_app;
SQL
  # Objects are created as their real owners, over the socket (trust).
  docker exec -i "$SOURCE_CONTAINER" psql -U tgb_app -X -q -v ON_ERROR_STOP=1 -d tgb <<'SQL'
CREATE TABLE authors (id bigserial PRIMARY KEY, name text NOT NULL, search_string text);
COMMENT ON TABLE authors IS 'People who wrote things';
COMMENT ON COLUMN authors.search_string IS 'Maintained by a trigger';
CREATE FUNCTION authors_search_string_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.search_string := lower(unaccent(NEW.name)) || ' @' || clock_timestamp()::text; RETURN NEW; END $$;
CREATE TRIGGER trg_authors_search_update BEFORE INSERT OR UPDATE ON authors
  FOR EACH ROW EXECUTE FUNCTION authors_search_string_update();
CREATE TABLE books (id bigserial PRIMARY KEY, title text NOT NULL, search_text text, author_id bigint REFERENCES authors (id));
CREATE FUNCTION update_book_search_text() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.search_text := lower(NEW.title) || ' @' || clock_timestamp()::text; RETURN NEW; END $$;
CREATE TRIGGER update_book_search_text BEFORE INSERT OR UPDATE ON books
  FOR EACH ROW EXECUTE FUNCTION update_book_search_text();
CREATE FUNCTION update_ol_works_search_text() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RETURN NEW; END $$;
CREATE TABLE ol_editions (id bigserial, data jsonb);
CREATE TABLE ol_works (id bigserial, data jsonb);
CREATE TABLE pghero_query_stats (id bigserial PRIMARY KEY, query text, calls bigint);
CREATE TABLE empty_things (id bigserial PRIMARY KEY, label text);
CREATE TABLE ident (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, v text);
CREATE TABLE tags (name text PRIMARY KEY, note text);
CREATE SEQUENCE orphan_seq;
CREATE SEQUENCE default_seq;
CREATE TABLE writes (id bigserial PRIMARY KEY, n bigint NOT NULL, updated int NOT NULL DEFAULT 0);
INSERT INTO authors (name) SELECT 'Author ' || g FROM generate_series(1, 3000) g;
INSERT INTO books (title, author_id) SELECT 'Book ' || g, 1 + (g % 3000) FROM generate_series(1, 6000) g;
INSERT INTO pghero_query_stats (query, calls) SELECT 'select ' || g, g FROM generate_series(1, 50) g;
INSERT INTO ident (v) SELECT 'v' || g FROM generate_series(1, 20) g;
INSERT INTO tags VALUES ('a', 'x'), ('b', 'y');
ALTER TABLE tags ADD COLUMN n bigint DEFAULT nextval('default_seq');
SELECT nextval('orphan_seq') \g /dev/null
SQL
  docker exec -i "$SOURCE_CONTAINER" psql -U the_greatest -X -q -v ON_ERROR_STOP=1 -d the_greatest <<'SQL'
CREATE TABLE users (id bigserial PRIMARY KEY, email text NOT NULL UNIQUE, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE lists (id bigserial PRIMARY KEY, name text NOT NULL);
CREATE TABLE list_items (id bigserial PRIMARY KEY, list_id bigint NOT NULL REFERENCES lists (id), position int NOT NULL);
CREATE TABLE writes (id bigserial PRIMARY KEY, n bigint NOT NULL, updated int NOT NULL DEFAULT 0);
INSERT INTO users (email) SELECT 'user' || g || '@example.invalid' FROM generate_series(1, 5000) g;
INSERT INTO lists (name) SELECT 'List ' || g FROM generate_series(1, 200) g;
INSERT INTO list_items (list_id, position) SELECT 1 + (g % 200), g FROM generate_series(1, 4000) g;
SQL
}

# mk_target_compose: the migration test's "new server": postgres:18 from a generated compose file with
# a service named postgres, so apply-roles.sh (which drives `docker compose exec postgres psql`) runs
# unchanged. Sets TARGET_COMPOSE and TARGET_ADMIN (the psql command for admin steps).
mk_target_compose() {
  local p="$PROJ-t"
  DK_PROJECTS+=("$p")
  TARGET_COMPOSE="$TMP/target-compose.yml"
  cat >"$TARGET_COMPOSE" <<EOF
name: $p
services:
  postgres:
    image: $TGT_IMAGE
    environment:
      POSTGRES_PASSWORD: \${POSTGRES_SUPERUSER_PASSWORD}
      POSTGRES_INITDB_ARGS: "--locale=en_US.utf8 --encoding=UTF8 --data-checksums"
    command: postgres -c max_logical_replication_workers=8 -c max_worker_processes=16 -c shared_preload_libraries=pg_stat_statements
    networks:
      default:
        aliases: [target]
networks:
  default:
    name: $NET
    external: true
EOF
  POSTGRES_SUPERUSER_PASSWORD="su-$(openssl rand -hex 8)"
  export POSTGRES_SUPERUSER_PASSWORD
  docker compose -f "$TARGET_COMPOSE" up -d >/dev/null 2>&1 || return 1
  local cid
  cid="$(docker compose -f "$TARGET_COMPOSE" ps -q postgres)"
  dk_wait_ready "$cid" || return 1
  TARGET_ADMIN="docker compose -f $TARGET_COMPOSE exec -T postgres psql -U postgres"
}

# dk_chown_root OWNER:GROUP PATH: chown a file under $TMP through a root one-off container. deploy.sh runs
# as root on the server (`install -o 999`, `chown`); here nobody is root, so the e2e test wraps those two.
dk_chown_root() {
  docker run --rm -v "$TMP:/tmpx" --entrypoint chown alpine:3 "$1" "/tmpx/${2#"$TMP"/}" >/dev/null
}

# dk_root_shims DIR: `install`, `chown` and `chmod` that stand in for root, plus no-op firewall and systemd
# tools, for the e2e test's real deploy.sh run. A file given -o/-g is chowned by a root one-off container;
# a directory stays ours (mode 0700 becomes 0755 so the container user can still pass through it).
dk_root_shims() {
  local d="$1"
  mkdir -p "$d"
  cat >"$d/install" <<EOF
#!/usr/bin/env bash
args=(); owner=""; grp=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o) owner="\$2"; shift 2 ;; -g) grp="\$2"; shift 2 ;; *) args+=("\$1"); shift ;; esac
done
/usr/bin/install "\${args[@]}" || exit \$?
if [ -n "\$owner\$grp" ]; then
  dest="\${args[\${#args[@]}-1]}"
  if [ -f "\$dest" ]; then
    docker run --rm -v "$TMP:/tmpx" --entrypoint chown alpine:3 "\${owner:-0}:\${grp:-0}" "/tmpx/\${dest#$TMP/}" >/dev/null || exit 1
  fi
fi
EOF
  cat >"$d/chown" <<EOF
#!/usr/bin/env bash
# chown OWNER:GROUP PATH -- directories are left to us
if [ -f "\$2" ]; then
  exec docker run --rm -v "$TMP:/tmpx" --entrypoint chown alpine:3 "\$1" "/tmpx/\${2#$TMP/}"
fi
exit 0
EOF
  cat >"$d/chmod" <<EOF
#!/usr/bin/env bash
if [ "\$1" = 0700 ] && [ -d "\$2" ]; then exec /bin/chmod 0755 "\$2"; fi
exec /bin/chmod "\$@"
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' >"$d/systemctl"
  printf '#!/usr/bin/env bash\ncat >/dev/null\n' >"$d/iptables-restore"
  printf '#!/usr/bin/env bash\ncat >/dev/null\n' >"$d/ip6tables-restore"
  chmod +x "$d"/*
}

# mk_minio NAME: an S3 server with TLS (pgBackRest needs https) and a plain (unversioned) bucket, standing in
# for the R2 backups bucket, with two keys:
#   pgserver  list/read/write/delete (spec §8.2's server token: Object Read & Write)
#   pghome    read only (the home VM's restore token)
# R2's bucket locks have no MinIO equivalent here; they were proven on real R2 (spec §8.4). Sets MINIO_*
# variables. MinIO has no
# image under minio/minio any more; the community build pgsty/minio is pinned by digest.
MINIO_IMAGE="${MINIO_IMAGE:-pgsty/minio@sha256:b6bfe7239bfc83fb90d31612d9704d86039dd714f7904b3f1ad68f211e602372}"
mc() { docker exec -i "$MINIO_CONTAINER" mc --insecure "$@"; }
mk_minio() {
  MINIO_CONTAINER="$1"
  MINIO_BUCKET=pgtest
  MINIO_SERVER_KEY=pgserver
  MINIO_SERVER_SECRET="srv$(openssl rand -hex 12)"
  MINIO_HOME_KEY=pghome
  MINIO_HOME_SECRET="home$(openssl rand -hex 12)"
  local root_pw certs="$TMP/minio-certs" i
  root_pw="root$(openssl rand -hex 12)"
  mkdir -p "$certs"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=minio -addext "subjectAltName=DNS:minio,DNS:localhost" \
    -keyout "$certs/private.key" -out "$certs/public.crt" 2>/dev/null
  chmod 644 "$certs"/*
  docker run -d --name "$1" --network "$NET" --network-alias minio --label "pgmig=$PROJ" \
    -e MINIO_ROOT_USER=root -e MINIO_ROOT_PASSWORD="$root_pw" -v "$certs:/certs:ro" \
    "$MINIO_IMAGE" server /data --certs-dir /certs >/dev/null || return 1
  for i in $(seq 1 40); do
    if docker exec "$1" curl -ks -o /dev/null -w '%{http_code}' https://localhost:9000/minio/health/live | grep -q 200; then break; fi
    sleep 0.5
  done
  mc alias set local https://localhost:9000 root "$root_pw" >/dev/null || return 1
  mc mb "local/$MINIO_BUCKET" >/dev/null || return 1
  mc admin policy create local srvpol /dev/stdin >/dev/null <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::$MINIO_BUCKET"]},
 {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":["arn:aws:s3:::$MINIO_BUCKET/*"]}]}
EOF
  mc admin policy create local homepol /dev/stdin >/dev/null <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::$MINIO_BUCKET"]},
 {"Effect":"Allow","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::$MINIO_BUCKET/*"]}]}
EOF
  mc admin user add local "$MINIO_SERVER_KEY" "$MINIO_SERVER_SECRET" >/dev/null || return 1
  mc admin policy attach local srvpol --user "$MINIO_SERVER_KEY" >/dev/null || return 1
  mc admin user add local "$MINIO_HOME_KEY" "$MINIO_HOME_SECRET" >/dev/null || return 1
  mc admin policy attach local homepol --user "$MINIO_HOME_KEY" >/dev/null || return 1
  mc alias set srv https://localhost:9000 "$MINIO_SERVER_KEY" "$MINIO_SERVER_SECRET" >/dev/null || return 1
}
