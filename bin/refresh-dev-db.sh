#!/usr/bin/env bash
#
# refresh-dev-db.sh — Replace the local development database with the latest
# production backup of "the_greatest" from S3.
#
# What it does:
#   1. Finds the newest NON-EMPTY postgres_the_greatest_backup_*.sql.gz in S3
#      (ignores the old "tgb" site backups entirely).
#   2. Downloads it.
#   3. Validates it is a real, non-empty PostgreSQL dump BEFORE touching your DB.
#      (These "*.sql.gz" files are actually pg_dump custom-format dumps, not gzip.)
#   4. Drops & recreates the local dev database, then pg_restores into it.
#   5. Runs `bin/rails db:migrate` to apply any migrations newer than the dump.
#
# The restore runs INSIDE the `db` docker-compose container so the pg_restore
# version always matches the postgres:17 server and the dump format.
#
# Usage:
#   bin/refresh-dev-db.sh            # prompts before wiping the local DB
#   bin/refresh-dev-db.sh -y         # skip the confirmation prompt
#   bin/refresh-dev-db.sh --no-migrate
#   KEEP_DUMP=1 bin/refresh-dev-db.sh   # don't delete the downloaded file
#
set -euo pipefail

# --- config (override via env if needed) -------------------------------------
# Load BACKUP_BUCKET (and any other overrides) from the gitignored .env so the
# private bucket name is never committed to this open-source repo.
_root_for_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$_root_for_env/.env" ]; then
  set -a; . "$_root_for_env/.env"; set +a
fi

BUCKET="${BACKUP_BUCKET:?Set BACKUP_BUCKET in .env (see .env.example)}"
PREFIX="${BACKUP_PREFIX:-postgres_the_greatest_backup_}"
DB_NAME="${DEV_DB_NAME:-the_greatest_development}"
DB_SERVICE="${DB_SERVICE:-db}"          # docker-compose service name
DB_USER="${DB_USER:-postgres}"
JOBS="${RESTORE_JOBS:-4}"

ASSUME_YES=0
RUN_MIGRATE=1
for arg in "$@"; do
  case "$arg" in
    -y|--yes)        ASSUME_YES=1 ;;
    --no-migrate)    RUN_MIGRATE=0 ;;
    -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --- locate repo root (this script lives in <root>/bin) ----------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }

command -v aws            >/dev/null || die "aws CLI not found on PATH"
command -v docker         >/dev/null || die "docker not found on PATH"
docker compose version    >/dev/null 2>&1 || die "'docker compose' not available"

# --- make sure the db container is up ----------------------------------------
if ! docker compose ps --status running --services 2>/dev/null | grep -qx "$DB_SERVICE"; then
  say "Starting '$DB_SERVICE' container..."
  docker compose up -d "$DB_SERVICE"
  # wait for postgres to accept connections
  for _ in $(seq 1 30); do
    if docker compose exec -T "$DB_SERVICE" pg_isready -U "$DB_USER" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
fi
docker compose exec -T "$DB_SERVICE" pg_isready -U "$DB_USER" >/dev/null 2>&1 \
  || die "Postgres in '$DB_SERVICE' is not accepting connections"

# --- find the latest non-empty the_greatest backup --------------------------
say "Finding latest non-empty '${PREFIX}*' backup in s3://${BUCKET} ..."
KEY="$(aws s3 ls "s3://${BUCKET}/" \
        | awk -v p="$PREFIX" '$4 ~ ("^" p) && ($3+0) > 0 { print $3, $4 }' \
        | sort -k2 \
        | tail -1 \
        | awk '{print $2}')"

[ -n "$KEY" ] || die "No non-empty backup found matching '${PREFIX}*'. \
Production backup job may still be broken — check S3."

SIZE_H="$(aws s3 ls "s3://${BUCKET}/${KEY}" | awk '{print $3}')"
say "Selected: ${KEY} (${SIZE_H} bytes)"

# --- download ----------------------------------------------------------------
DUMP="$ROOT/${KEY}"
cleanup() { [ "${KEEP_DUMP:-0}" = "1" ] || rm -f "$DUMP"; }
trap cleanup EXIT

say "Downloading..."
aws s3 cp "s3://${BUCKET}/${KEY}" "$DUMP"

# --- VALIDATE before we wipe anything ----------------------------------------
[ -s "$DUMP" ] || die "Downloaded file is empty — refusing to wipe local DB."
DESC="$(file -b "$DUMP")"
case "$DESC" in
  *"PostgreSQL custom database dump"*) say "Validated: $DESC" ;;
  *) die "Downloaded file is not a PostgreSQL custom dump (got: $DESC). Refusing to proceed." ;;
esac

# --- confirm -----------------------------------------------------------------
if [ "$ASSUME_YES" -ne 1 ]; then
  warn "This will DROP and recreate the local database '${DB_NAME}'."
  read -r -p "Continue? [y/N] " reply
  case "$reply" in y|Y|yes|YES) ;; *) die "Aborted." ;; esac
fi

# --- drop / recreate ---------------------------------------------------------
say "Dropping & recreating '${DB_NAME}'..."
docker compose exec -T "$DB_SERVICE" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
 WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS ${DB_NAME};
CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};
SQL

# --- restore (stream the dump into the container) ----------------------------
# Parallel (-j) needs a seekable file, so copy the dump into the container.
say "Restoring (this can take a minute)..."
IN_CONTAINER="/tmp/${KEY}"
docker compose cp "$DUMP" "${DB_SERVICE}:${IN_CONTAINER}"
docker compose exec -T "$DB_SERVICE" \
  pg_restore -U "$DB_USER" -d "$DB_NAME" \
             --no-owner --no-privileges --clean --if-exists \
             -j "$JOBS" "$IN_CONTAINER"
docker compose exec -T "$DB_SERVICE" rm -f "$IN_CONTAINER"

# --- migrate -----------------------------------------------------------------
if [ "$RUN_MIGRATE" -eq 1 ] && [ -x "$ROOT/web-app/bin/rails" ]; then
  say "Running pending migrations..."
  ( cd "$ROOT/web-app" && bin/rails db:migrate ) || warn "db:migrate failed — run it manually."
fi

say "Done. Local '${DB_NAME}' refreshed from ${KEY}."
