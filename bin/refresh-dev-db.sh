#!/usr/bin/env bash
#
# refresh-dev-db.sh — Replace the local development database(s) with the latest
# production backups from S3.
#
# What it does:
#   1. Finds the newest NON-EMPTY backup in S3 for each database you asked for:
#        the_greatest_development  <- postgres_the_greatest_backup_*.sql.gz  (default)
#        the_greatest_books_legacy <- postgres_tgb_backup_*.sql.gz           (--legacy)
#   2. Downloads them.
#   3. Validates each is a real, non-empty PostgreSQL dump BEFORE touching any DB.
#      (These "*.sql.gz" files are actually pg_dump custom-format dumps, not gzip.)
#   4. Drops & recreates each local database, pg_restores into it, then ANALYZEs
#      it so the planner has statistics (pg_restore leaves them empty).
#   5. Runs `bin/rails db:migrate` to apply any migrations newer than the dump
#      (main database only).
#
# The restore runs INSIDE the `db` docker-compose container so the pg_restore
# version always matches the postgres:17 server and the dump format.
#
# Sizes: the main dump is ~400 MB and restores in a minute or two. The legacy
# dump is ~5 GB, restores to ~65 GB, and takes ~25 minutes — which is why it is
# opt-in. On macOS make sure Docker Desktop's disk image limit has room for it.
#
# Usage:
#   bin/refresh-dev-db.sh                # main DB only; prompts before wiping
#   bin/refresh-dev-db.sh --legacy       # main + legacy books DB
#   bin/refresh-dev-db.sh --legacy-only  # legacy books DB only; main untouched
#   bin/refresh-dev-db.sh -y             # skip the confirmation prompt
#   bin/refresh-dev-db.sh --no-migrate
#   KEEP_DUMP=1 bin/refresh-dev-db.sh    # don't delete the downloaded files
#
set -euo pipefail

# --- options -----------------------------------------------------------------
ASSUME_YES=0
RUN_MIGRATE=1
DO_MAIN=1
DO_LEGACY=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes)        ASSUME_YES=1 ;;
    --no-migrate)    RUN_MIGRATE=0 ;;
    --legacy)        DO_LEGACY=1 ;;
    --legacy-only)   DO_LEGACY=1; DO_MAIN=0 ;;
    -h|--help)       awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^#( |$)/, ""); print }' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --- locate repo root (this script lives in <root>/bin) ----------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- config (override via env if needed) -------------------------------------
# Load BACKUP_BUCKET (and any other overrides) from the gitignored .env so the
# private bucket name is never committed to this open-source repo.
if [ -f "$ROOT/.env" ]; then
  set -a; . "$ROOT/.env"; set +a
fi

BUCKET="${BACKUP_BUCKET:?Set BACKUP_BUCKET in .env (see .env.example)}"
PREFIX="${BACKUP_PREFIX:-postgres_the_greatest_backup_}"
LEGACY_PREFIX="${LEGACY_BACKUP_PREFIX:-postgres_tgb_backup_}"
DB_NAME="${DEV_DB_NAME:-the_greatest_development}"
LEGACY_DB_NAME="${LEGACY_DB_NAME:-the_greatest_books_legacy}"
DB_SERVICE="${DB_SERVICE:-db}"          # docker-compose service name
DB_USER="${DB_USER:-postgres}"
JOBS="${RESTORE_JOBS:-4}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }

command -v aws            >/dev/null || die "aws CLI not found on PATH"
command -v docker         >/dev/null || die "docker not found on PATH"
docker compose version    >/dev/null 2>&1 || die "'docker compose' not available"

# --- helpers -----------------------------------------------------------------
# Run a command inside the db container. --interactive=false matters: exec
# attaches stdin by default and swallows it, which would eat the answer to the
# confirmation prompt below whenever this script is fed through a pipe.
dbx() { docker compose exec -T --interactive=false "$DB_SERVICE" "$@"; }

# Newest non-empty key in the bucket listing whose name starts with $1.
latest_key() {
  printf '%s\n' "$LISTING" \
    | awk -v p="$1" '$4 ~ ("^" p) && ($3+0) > 0 { print $4 }' \
    | sort \
    | tail -1
}

# Size of key $1 in whole megabytes, from the same listing.
key_size_mb() {
  printf '%s\n' "$LISTING" | awk -v k="$1" '$4 == k { printf "%.0f", $3 / 1048576 }'
}

# Download S3 key $1 to $2, then refuse to go on unless it is a pg_dump archive.
fetch_and_validate() {
  local key="$1" dest="$2" desc
  say "Downloading ${key}..."
  aws s3 cp "s3://${BUCKET}/${key}" "$dest"
  [ -s "$dest" ] || die "Downloaded file is empty — refusing to wipe any local DB."
  desc="$(file -b "$dest")"
  case "$desc" in
    *"PostgreSQL custom database dump"*) say "Validated: $desc" ;;
    *) die "${key} is not a PostgreSQL custom dump (got: $desc). Refusing to proceed." ;;
  esac
}

# Drop and recreate database $1, restore dump $2 into it, then ANALYZE it.
restore_db() {
  local db="$1" dump="$2" in_container
  in_container="/tmp/$(basename "$dump")"

  say "Dropping & recreating '${db}'..."
  dbx psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
         WHERE datname = '${db}' AND pid <> pg_backend_pid();" \
    -c "DROP DATABASE IF EXISTS ${db};" \
    -c "CREATE DATABASE ${db} OWNER ${DB_USER};"

  # Parallel (-j) needs a seekable file, so copy the dump into the container.
  say "Restoring '${db}' with ${JOBS} jobs (a minute or two; ~25 minutes for legacy)..."
  docker compose cp "$dump" "${DB_SERVICE}:${in_container}"
  dbx pg_restore -U "$DB_USER" -d "$db" \
                 --no-owner --no-privileges --clean --if-exists \
                 -j "$JOBS" "$in_container"
  dbx rm -f "$in_container"

  # pg_restore leaves the planner without statistics; until autovacuum gets
  # round to it, the first queries against a 65 GB legacy DB crawl.
  say "Analyzing '${db}'..."
  dbx vacuumdb -U "$DB_USER" -d "$db" --analyze-only -j "$JOBS"
}

# bin/rails under the Ruby that web-app/.ruby-version asks for. mise only swaps
# Ruby into PATH when an interactive shell cd's into web-app/; this script is
# neither, so without `mise exec` bin/rails runs under whatever `ruby` the caller
# had — which has none of the gems. ANNOTATERB_SKIP_ON_DB_TASKS: a restore never
# changes the schema, and annotaterb's post-migrate hook would otherwise connect
# to every database in database.yml, including a legacy one that may not exist.
run_rails() {
  (
    cd "$ROOT/web-app" || exit 1
    export ANNOTATERB_SKIP_ON_DB_TASKS=1
    if command -v mise >/dev/null 2>&1; then
      mise exec -- bin/rails "$@"
    else
      bin/rails "$@"
    fi
  )
}

# --- make sure the db container is up ----------------------------------------
if ! docker compose ps --status running --services 2>/dev/null | grep -qx "$DB_SERVICE"; then
  say "Starting '$DB_SERVICE' container..."
  docker compose up -d "$DB_SERVICE"
  # wait for postgres to accept connections
  for _ in $(seq 1 30); do
    if dbx pg_isready -U "$DB_USER" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
fi
dbx pg_isready -U "$DB_USER" >/dev/null 2>&1 \
  || die "Postgres in '$DB_SERVICE' is not accepting connections"

# --- pick the backups --------------------------------------------------------
say "Listing s3://${BUCKET} ..."
LISTING="$(aws s3 ls "s3://${BUCKET}/")"

MAIN_KEY=""
LEGACY_KEY=""
TARGETS=""
if [ "$DO_MAIN" -eq 1 ]; then
  MAIN_KEY="$(latest_key "$PREFIX")"
  [ -n "$MAIN_KEY" ] || die "No non-empty backup found matching '${PREFIX}*'. \
Production backup job may still be broken — check S3."
  say "Selected for '${DB_NAME}': ${MAIN_KEY} ($(key_size_mb "$MAIN_KEY") MB)"
  TARGETS="${DB_NAME}"
fi
if [ "$DO_LEGACY" -eq 1 ]; then
  LEGACY_KEY="$(latest_key "$LEGACY_PREFIX")"
  [ -n "$LEGACY_KEY" ] || die "No non-empty backup found matching '${LEGACY_PREFIX}*' — check S3."
  say "Selected for '${LEGACY_DB_NAME}': ${LEGACY_KEY} ($(key_size_mb "$LEGACY_KEY") MB)"
  TARGETS="${TARGETS:+${TARGETS}, }${LEGACY_DB_NAME}"
fi

# --- confirm -----------------------------------------------------------------
# Asked before the download so a long legacy run can be left unattended; the
# validation below still happens before anything is dropped.
if [ "$ASSUME_YES" -ne 1 ]; then
  warn "This will DROP and recreate: ${TARGETS}"
  read -r -p "Continue? [y/N] " reply || die "No answer on stdin — pass -y to skip the prompt."
  case "$reply" in y|Y|yes|YES) ;; *) die "Aborted." ;; esac
fi

# --- download + VALIDATE everything before we wipe anything ------------------
MAIN_DUMP=""
LEGACY_DUMP=""
cleanup() {
  [ "${KEEP_DUMP:-0}" = "1" ] && return 0
  [ -n "$MAIN_DUMP" ]   && rm -f "$MAIN_DUMP"
  [ -n "$LEGACY_DUMP" ] && rm -f "$LEGACY_DUMP"
  return 0
}
trap cleanup EXIT

if [ -n "$MAIN_KEY" ]; then
  MAIN_DUMP="$ROOT/${MAIN_KEY}"
  fetch_and_validate "$MAIN_KEY" "$MAIN_DUMP"
fi
if [ -n "$LEGACY_KEY" ]; then
  LEGACY_DUMP="$ROOT/${LEGACY_KEY}"
  fetch_and_validate "$LEGACY_KEY" "$LEGACY_DUMP"
fi

# --- drop / restore ----------------------------------------------------------
if [ -n "$MAIN_DUMP" ]; then
  restore_db "$DB_NAME" "$MAIN_DUMP"
fi
if [ -n "$LEGACY_DUMP" ]; then
  restore_db "$LEGACY_DB_NAME" "$LEGACY_DUMP"
fi

# --- migrate -----------------------------------------------------------------
if [ "$DO_MAIN" -eq 1 ] && [ "$RUN_MIGRATE" -eq 1 ] && [ -x "$ROOT/web-app/bin/rails" ]; then
  say "Running pending migrations..."
  run_rails db:migrate || warn "db:migrate failed — run it manually from web-app/."
fi

say "Done. Refreshed: ${TARGETS}."
