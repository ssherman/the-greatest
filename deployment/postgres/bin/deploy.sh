#!/usr/bin/env bash
# deployment/postgres/bin/deploy.sh ENV_FILE
# Configures and starts the database server. Run on the server by .github/workflows/deploy-postgres.yml
# as the deploy user (passwordless sudo); ENV_FILE is the decrypted secrets/.env.postgres.
# Safe to repeat. A redeploy never restarts Postgres: when the image or a restart-only setting
# changed it stops (exit 3) and says so. Spec §7.
#
# Optional environment:
#   POSTGRES_BOOTSTRAP=new-cluster|restore   what to do when the data directory is empty and the
#                                            backup repo already holds a stanza (see below)
#   POSTGRES_ALLOW_RESTART=1                 permit the restart a changed image/config needs
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
pg_dir="$(cd "$here/.." && pwd)"
env_file="${1:?usage: deploy.sh ENV_FILE}"
STATE_DIR="${STATE_DIR:-/srv/postgres}"
ETC_DIR="${ETC_DIR:-/etc/postgres-server}"          # the allowlist, where apply-firewall.sh reads it
PG_UID="${PG_UID:-999}" PG_GID="${PG_GID:-999}"     # the postgres user of the image
WAIT_TRIES="${WAIT_TRIES:-200}" WAIT_SLEEP="${WAIT_SLEEP:-3}"   # ~10 minutes for an ordinary start
WAIT_TRIES_RESTORE="${WAIT_TRIES_RESTORE:-4000}"                 # ~3.3 hours after a restore
sudo=(sudo "--preserve-env=ROOT,ALLOWLIST")
if [ "${NO_SUDO:-0}" = 1 ]; then sudo=(); fi
compose=(docker compose -f "$pg_dir/compose.yml")

die() { echo "deploy: $1" >&2; exit "${2:-1}"; }

# This script's output ends up in a public repo's workflow log, and pgBackRest and Docker errors
# carry the bucket, the repo path and endpoints. So their output never reaches ours: run_logged
# keeps it in a root-only file and prints the command's name, its exit code, the bracketed error
# classes ([028], [ProtocolError]) and the file's path. Stdout of the command is left in RUN_OUT for
# callers that parse it; it is not printed either.
LOG_FILE="${STATE_DIR}/state/deploy.log"
RUN_OUT="" RL_MSG=""
# RL_SOFT=1 run_logged ... returns the command's exit code (message in RL_MSG) instead of dying.
run_logged() {   # run_logged DESCRIPTION COMMAND [ARG...]
  local desc="$1" rc=0 classes
  shift
  "$@" >"$work/cmd.out" 2>"$work/cmd.err" </dev/null || rc=$?
  { printf '== %s: %s (exit %s)\n' "$(date -u +%FT%TZ)" "$desc" "$rc"; cat "$work/cmd.out" "$work/cmd.err"; } \
    | "${sudo[@]}" tee -a "$LOG_FILE" >/dev/null
  RUN_OUT="$(cat "$work/cmd.out")"
  if [ "$rc" != 0 ]; then
    classes="$(cat "$work/cmd.out" "$work/cmd.err" | grep -oE '\[([0-9]{3}|[A-Za-z]+Error)\]' | sort -u | tr '\n' ' ' || true)"
    RL_MSG="$desc failed (exit $rc) ${classes:+classes: $classes}- full output is in $LOG_FILE"
    if [ "${RL_SOFT:-0}" = 1 ]; then return "$rc"; fi
    die "$RL_MSG"
  fi
}

set -a
# shellcheck source=/dev/null
. "$env_file"
set +a
required=(POSTGRES_CLIENTS POSTGRES_SUPERUSER_PASSWORD POSTGRES_THE_GREATEST_PASSWORD POSTGRES_TGB_APP_PASSWORD
  POSTGRES_TGB_READER_PASSWORD PGBACKREST_REPO_BUCKET PGBACKREST_REPO_ENDPOINT PGBACKREST_REPO_REGION
  PGBACKREST_REPO_PATH PGBACKREST_REPO_KEY PGBACKREST_REPO_KEY_SECRET PGBACKREST_CIPHER_PASS HC_PG_BACKUP HC_PG_HEALTH)
for v in "${required[@]}"; do
  if [ -z "${!v:-}" ]; then die "$v is missing from $env_file" 2; fi
done
if [ -n "${POSTGRES_PORT+x}" ]; then
  die "POSTGRES_PORT is set; the firewall covers port 6543 only, so the database port cannot change here" 2
fi
bootstrap="${POSTGRES_BOOTSTRAP:-}"
case "$bootstrap" in
  "" | new-cluster | restore) ;;
  *) die "POSTGRES_BOOTSTRAP must be empty, new-cluster or restore (got: $bootstrap)" 2 ;;
esac
export POSTGRES_HOST_CONFIG_DIR="$STATE_DIR/config" POSTGRES_CERTS_DIR="$STATE_DIR/certs"
umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 1. Validate everything that comes from SOPS before anything is installed. POSTGRES_CLIENTS is
# `role database address` entries separated by semicolons; the firewall allowlist is its unique
# addresses. A bad value must never reach the files the boot unit and Postgres read.
tr ';' '\n' <<<"$POSTGRES_CLIENTS" | tr -d '\r' >"$work/clients"
"$here/render-hba.sh" "$work/clients" >"$work/pg_hba.conf"
sed 's/#.*//' "$work/clients" | awk 'NF && !seen[$3]++ { print $3 }' >"$work/allowlist"
for family in v4 v6; do
  "$here/render-firewall.sh" --family "$family" --allowlist "$work/allowlist" >/dev/null
done
# Only the template's own variables are substituted; passwords travel in the environment.
vars="$(grep -oE '\$\{[A-Z_0-9]+\}' "$pg_dir/config/pgbackrest.conf.tmpl" | sort -u | tr -d '\n')"
envsubst "$vars" <"$pg_dir/config/pgbackrest.conf.tmpl" >"$work/pgbackrest.conf"
# shellcheck disable=SC2016  # a literal ${ is what is being looked for
if grep -q '\${' "$work/pgbackrest.conf"; then die "pgbackrest.conf still has an unfilled variable" 2; fi

# 2. Firewall.
"${sudo[@]}" install -d -m 0755 "$ETC_DIR"
"${sudo[@]}" install -m 0644 "$work/allowlist" "$ETC_DIR/allowlist"
"${sudo[@]}" env ALLOWLIST="${ALLOWLIST:-$ETC_DIR/allowlist}" "$here/install-firewall.sh"

# 3. Host directories, then certificates (first run only; a complete pair is left alone). The state
# directory is created here, readable, because generate-certs.sh would create it closed (0700) and
# the container user has to pass through it to reach the config directory.
"${sudo[@]}" install -d -m 0755 "$STATE_DIR" "$STATE_DIR/config"
"${sudo[@]}" "$here/generate-certs.sh" "$STATE_DIR/certs" "$PG_UID" "$PG_GID"
"${sudo[@]}" install -d -m 0700 "$STATE_DIR/state"    # root only: command output with repo details

# 4. Config the container reads. pg_hba.conf reloads and pgbackrest.conf is read on every run, so
# neither needs a restart. pgbackrest.conf holds the repo keys: 0600, the container user only.
"${sudo[@]}" install -m 0644 -o "$PG_UID" -g "$PG_GID" "$work/pg_hba.conf" "$STATE_DIR/config/pg_hba.conf"
"${sudo[@]}" install -m 0600 -o "$PG_UID" -g "$PG_GID" "$work/pgbackrest.conf" "$STATE_DIR/config/pgbackrest.conf"

# 5. What the server has. Asked of a one-off container, not of Docker's volume path.
# shellcheck disable=SC2016  # the script runs inside the container, which expands $PGDATA
run_logged "docker compose run (image build and data directory check)" "${compose[@]}" run --rm --no-deps -T postgres sh -c \
  'if [ -z "$PGDATA" ]; then echo nopgdata; elif [ -f "$PGDATA/PG_VERSION" ]; then echo present; else echo empty; fi'
data_state="$(tail -n 1 <<<"$RUN_OUT")"
case "$data_state" in
  present | empty) ;;
  *) die "the one-off container ran but did not say whether the data directory is empty (got: '$data_state'); refusing to continue" ;;
esac

# Three answers, and only two of them are about the stanza: present, none, or "could not read the
# repo". The third stops the deploy; it must never be read as "none", which would create a stanza
# over a repo that could not be looked at. Only an explicit `main` entry with code 1 ("missing
# stanza path") means none; 0 is ok; 2 is a stanza with no backup yet. Anything else, including an
# empty list or no `main` entry, is not understood and fails closed.
run_logged "pgbackrest info (reading the backup repo)" "${compose[@]}" run --rm --no-deps -T postgres pgbackrest --stanza=main info --output=json
stanza_state="$(python3 -I -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
    assert isinstance(data, list)
except Exception:
    sys.exit(1)
mine = [s for s in data if isinstance(s, dict) and s.get("name") == "main"]
if not mine:
    sys.exit(1)
code = mine[0].get("status", {}).get("code")
if code in (0, 2):
    print("present")
elif code == 1:
    print("none")
else:
    sys.exit(1)
' <<<"$RUN_OUT")" || die "the backup repo answered, but not with a stanza state this script understands (details in $LOG_FILE); refusing to continue"

# 6. The bootstrap rules. A new server must never start empty against a real repo by accident.
restore=0 create_stanza=0 upgrade_stanza=0 retry_new_cluster=0
case "$data_state:$stanza_state" in
  empty:present)
    case "$bootstrap" in
      restore) restore=1 ;;
      new-cluster)
        upgrade_stanza=1
        echo "deploy: POSTGRES_BOOTSTRAP=new-cluster: the backup repo already holds a stanza. This starts a NEW, EMPTY" >&2
        echo "deploy: cluster and registers it with pgbackrest stanza-upgrade. Nothing is restored. The old backups are" >&2
        echo "deploy: kept under the old database id only until the 30-day retention rule expires them." >&2
        ;;
      *) die "the data directory is empty and the backup repo already holds a stanza. Set POSTGRES_BOOTSTRAP=restore to restore it, or POSTGRES_BOOTSTRAP=new-cluster to start a new, empty cluster on purpose" ;;
    esac ;;
  empty:none)
    if [ "$bootstrap" = restore ]; then die "POSTGRES_BOOTSTRAP=restore but the backup repo holds no stanza: there is nothing to restore"; fi
    create_stanza=1 ;;
  present:*)
    if [ "$bootstrap" = restore ]; then die "POSTGRES_BOOTSTRAP=restore but the data directory is not empty; it would overwrite a live database. Unset POSTGRES_BOOTSTRAP"; fi
    if [ "$stanza_state" = none ]; then create_stanza=1; fi
    # A new-cluster deploy that was interrupted leaves present:present with the stanza not yet
    # registered for the new cluster. stanza-upgrade is idempotent, so a retry runs it again.
    if [ "$bootstrap" = new-cluster ] && [ "$stanza_state" = present ]; then retry_new_cluster=1; fi ;;
esac

# 7. Restart gate. The fingerprint covers what is read only at start: the image's build inputs, the
# Postgres config and the compose definition. Certificates, pg_hba.conf and pgbackrest.conf are not
# in it: they reload or are read per run. The first deploy has no fingerprint; it stores one and is
# not a change.
fingerprint="$(cat "$pg_dir/Dockerfile" "$pg_dir/config/postgresql.conf" "$pg_dir/compose.yml" | sha256sum | cut -d' ' -f1)"
previous="$("${sudo[@]}" cat "$STATE_DIR/config.sha256" 2>/dev/null || true)"
# A failing `ps` must stop the deploy: reading it as "not running" would let a changed fingerprint
# recreate a live database without consent.
run_logged "docker compose ps (is Postgres running)" "${compose[@]}" ps --status running -q postgres
running="$RUN_OUT"
up=(up -d --no-recreate)    # never recreate by accident; a compose change alone cannot restart it
if [ -n "$previous" ] && [ "$previous" != "$fingerprint" ]; then
  if [ -n "$running" ]; then
    if [ "${POSTGRES_ALLOW_RESTART:-0}" = 1 ]; then
      up=(up -d --build --force-recreate)
    else
      echo "deploy: the image or the Postgres config changed and Postgres is running. A restart is needed and this" >&2
      echo "deploy: script will not do it unasked. Choose a quiet moment and re-run with POSTGRES_ALLOW_RESTART=1." >&2
      exit 3
    fi
  else
    up=(up -d --build)
  fi
fi

# 8. Start. A restore runs before Postgres exists; everything else waits for it.
if [ "$restore" = 1 ]; then
  echo "deploy: starting restore from the backup repo; this can run for a long time" >&2
  run_logged "pgbackrest restore" "${compose[@]}" run --rm --no-deps -T postgres pgbackrest --stanza=main restore
  WAIT_TRIES="$WAIT_TRIES_RESTORE"   # archive recovery after a restore can take far longer than a start
fi
run_logged "docker compose ${up[*]}" "${compose[@]}" "${up[@]}"
printf '%s\n' "$fingerprint" | "${sudo[@]}" tee "$STATE_DIR/config.sha256" >/dev/null

# Ready means ready twice, a few seconds apart: on a first start the image's entrypoint runs a
# temporary server for init, and a single pass can land on it just before it shuts down.
ready_probe() {
  "${compose[@]}" exec -T postgres pg_isready -U postgres </dev/null >/dev/null 2>&1 \
    && [ "$("${compose[@]}" exec -T postgres psql -U postgres -Atc 'SELECT pg_is_in_recovery()' </dev/null 2>/dev/null || true)" = f ]
}
ready=0 streak=0
for _ in $(seq 1 "$WAIT_TRIES"); do
  if ready_probe; then streak=$((streak + 1)); else streak=0; fi
  if [ "$streak" -ge 2 ]; then ready=1; break; fi
  sleep "$WAIT_SLEEP"
done
if [ "$ready" != 1 ]; then die "Postgres did not become ready (or is still in recovery) in time; look at 'docker compose -f $pg_dir/compose.yml logs postgres' on the server"; fi

if [ "$create_stanza" = 1 ]; then
  run_logged "pgbackrest stanza-create" "${compose[@]}" exec -T postgres pgbackrest --stanza=main stanza-create
fi
# A leftover POSTGRES_BOOTSTRAP=new-cluster must not stay green forever: with a healthy, registered
# cluster it is wrong to keep it, so `check` decides. Passing means nothing is left to bootstrap.
# Failing means an interrupted bootstrap (the stanza still describes the old cluster), and the
# idempotent stanza-upgrade finishes it.
if [ "$retry_new_cluster" = 1 ]; then
  if RL_SOFT=1 run_logged "pgbackrest check (is the new cluster already registered)" "${compose[@]}" exec -T postgres pgbackrest --stanza=main check; then
    die "POSTGRES_BOOTSTRAP=new-cluster is still set, but this cluster is already registered with the backup repo and archiving works. Unset POSTGRES_BOOTSTRAP; it is for a one-time bootstrap only"
  fi
  upgrade_stanza=1
  echo "deploy: POSTGRES_BOOTSTRAP=new-cluster with existing data and a failing check: finishing the interrupted bootstrap with stanza-upgrade, restoring nothing." >&2
fi
if [ "$upgrade_stanza" = 1 ]; then
  run_logged "pgbackrest stanza-upgrade" "${compose[@]}" exec -T postgres pgbackrest --stanza=main stanza-upgrade
fi

# 9. Roles and grants (picks up password rotations too), then reload so pg_hba.conf takes effect.
# These come before the final check, so a slow or failing check cannot hold up an urgent password
# or pg_hba.conf change.
COMPOSE_FILE="$pg_dir/compose.yml" run_logged "apply-roles" "$here/apply-roles.sh"
run_logged "pg_ctl reload" "${compose[@]}" exec -T postgres pg_ctl reload

# 10. A green deploy must mean archiving works. `check` forces a WAL switch and waits for it to
# reach the repo, which fails (for one, with [028]) when the stanza does not match this cluster.
if ! RL_SOFT=1 run_logged "pgbackrest check" "${compose[@]}" exec -T postgres pgbackrest --stanza=main check; then
  die "$RL_MSG. Archiving is NOT working, so backups would be unusable. Roles and pg_hba.conf were applied before this check."
fi

# 11. The scheduled backup and its health check. Installed last: a deploy that fails above leaves
# the previous jobs in place, and the timers are only enabled, never started or restarted, so a
# deploy cannot trigger a backup. The ping URLs are credentials: root-only file, not in the units.
printf 'HC_PG_BACKUP=%s\nHC_PG_HEALTH=%s\nREPO_DIR=%s\n' "$HC_PG_BACKUP" "$HC_PG_HEALTH" "$pg_dir" >"$work/backup.env"
"${sudo[@]}" env BACKUP_ENV_DEST="$ETC_DIR/backup.env" "$here/install-backup.sh" "$work/backup.env"
echo "deploy: done"
