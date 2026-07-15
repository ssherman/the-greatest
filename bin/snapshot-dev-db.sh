#!/usr/bin/env bash
#
# snapshot-dev-db.sh — Take a fast local snapshot of the development database.
#
# Why: the books data lives ONLY in development. It is not in production, so
# bin/refresh-dev-db.sh cannot bring it back — rebuilding it means re-running
# `data_migration:all` against the legacy DB, which takes hours.
#
# A snapshot turns that into a ~1 minute restore.
#
# Usage:
#   bin/snapshot-dev-db.sh                 # snapshot -> tmp/db-snapshots/dev-<timestamp>.dump
#   bin/snapshot-dev-db.sh --label pre-migration
#   bin/snapshot-dev-db.sh --restore                  # restore the newest snapshot
#   bin/snapshot-dev-db.sh --restore <file>           # restore a specific one
#   bin/snapshot-dev-db.sh --list
#
# Take one before anything that rewrites bulk data: a data migration, a schema
# change on a big table, or any bulk delete/update.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DB_NAME="${DEV_DB_NAME:-the_greatest_development}"
DB_SERVICE="${DB_SERVICE:-db}"
DB_USER="${DB_USER:-postgres}"
SNAP_DIR="$ROOT/tmp/db-snapshots"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }

MODE=snapshot
LABEL=""
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --restore) MODE=restore; [ $# -gt 1 ] && [ "${2#--}" = "$2" ] && { TARGET="$2"; shift; } ;;
    --list)    MODE=list ;;
    --label)   shift; LABEL="${1:?--label needs a value}" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

docker compose exec -T "$DB_SERVICE" pg_isready -U "$DB_USER" >/dev/null 2>&1 \
  || die "Postgres in the '$DB_SERVICE' container is not accepting connections"

mkdir -p "$SNAP_DIR"

case "$MODE" in
  list)
    ls -lh "$SNAP_DIR"/*.dump 2>/dev/null || say "No snapshots yet."
    ;;

  snapshot)
    STAMP="$(date +%Y%m%d-%H%M%S)"
    NAME="dev-${STAMP}${LABEL:+-$LABEL}.dump"
    say "Snapshotting '${DB_NAME}' -> tmp/db-snapshots/${NAME}"
    docker compose exec -T "$DB_SERVICE" \
      pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc --no-owner --no-privileges \
      > "$SNAP_DIR/$NAME"
    [ -s "$SNAP_DIR/$NAME" ] || { rm -f "$SNAP_DIR/$NAME"; die "pg_dump produced an empty file."; }
    say "Done: $(du -h "$SNAP_DIR/$NAME" | cut -f1)"
    say "Restore with: bin/snapshot-dev-db.sh --restore"
    ;;

  restore)
    if [ -n "$TARGET" ]; then
      DUMP="$TARGET"
    else
      DUMP="$(ls -t "$SNAP_DIR"/*.dump 2>/dev/null | head -1)"
    fi
    [ -n "${DUMP:-}" ] && [ -s "$DUMP" ] || die "No snapshot found in tmp/db-snapshots/."

    say "This will DROP and recreate '${DB_NAME}' from: $(basename "$DUMP")"
    read -r -p "Continue? [y/N] " reply
    case "$reply" in y|Y|yes|YES) ;; *) die "Aborted." ;; esac

    docker compose exec -T "$DB_SERVICE" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS ${DB_NAME};
CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};
SQL

    say "Restoring..."
    IN="/tmp/$(basename "$DUMP")"
    docker compose cp "$DUMP" "${DB_SERVICE}:${IN}"
    docker compose exec -T "$DB_SERVICE" \
      pg_restore -U "$DB_USER" -d "$DB_NAME" --no-owner --no-privileges -j 4 "$IN"
    docker compose exec -T "$DB_SERVICE" rm -f "$IN"

    say "Restored '${DB_NAME}' from $(basename "$DUMP")."
    ;;
esac
