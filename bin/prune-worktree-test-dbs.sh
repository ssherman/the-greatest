#!/usr/bin/env bash
#
# prune-worktree-test-dbs.sh — Drop test databases left behind by deleted worktrees.
#
# Why: config/test_database_name.rb names the test primary after the checkout it
# runs in, so every git worktree gets its own `the_greatest_test_<worktree>_wt`
# plus the `_0..N` databases parallelize() fans it out to. Deleting a worktree does not
# delete those, so they accumulate at roughly 500 MB per worktree.
#
# This finds every the_greatest_test* database whose worktree is gone and offers
# to drop it. Databases belonging to a live worktree -- and the main checkout's
# own the_greatest_test -- are never touched.
#
# Usage:
#   bin/prune-worktree-test-dbs.sh           # show what is stale, then confirm
#   bin/prune-worktree-test-dbs.sh --list    # show only, drop nothing
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# A worktree's directory name is its own Compose project, and that project does
# not own the running dev Postgres container. Pin it so the script works when
# invoked from inside a worktree.
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-the-greatest}"

DB_SERVICE="${DB_SERVICE:-db}"
DB_USER="${DB_USER:-postgres}"
MODULE="$ROOT/web-app/config/test_database_name"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }

MODE=prune
while [ $# -gt 0 ]; do
  case "$1" in
    --list)    MODE=list ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

command -v ruby >/dev/null 2>&1 || die "ruby is not on PATH (try: mise exec -- $0)"
[ -f "${MODULE}.rb" ] || die "Missing ${MODULE}.rb — cannot map worktrees to database names."

docker compose exec -T "$DB_SERVICE" pg_isready -U "$DB_USER" </dev/null >/dev/null 2>&1 \
  || die "Postgres in the '$DB_SERVICE' container is not accepting connections"

# Live worktrees -> the database names they own. Derived by calling the same
# module database.yml uses, so the two can never drift apart.
mapfile -t WORKTREE_ROOTS < <(git worktree list --porcelain | awk '/^worktree /{print $2"/web-app"}')
[ ${#WORKTREE_ROOTS[@]} -gt 0 ] || die "git worktree list returned nothing."

mapfile -t LIVE < <(ruby -r "$MODULE" -e 'ARGV.each { |root| puts TestDatabaseName.for(root) }' "${WORKTREE_ROOTS[@]}")

is_live() {
  local base="$1"
  for name in "${LIVE[@]}"; do [ "$name" = "$base" ] && return 0; done
  return 1
}

mapfile -t ALL < <(docker compose exec -T "$DB_SERVICE" psql -U "$DB_USER" -d postgres -Atc \
  "select datname from pg_database where datname like 'the_greatest_test%' order by datname;" \
  </dev/null | tr -d '\r')

STALE=()
for db in "${ALL[@]}"; do
  [ -n "$db" ] || continue
  # Strip the "_0".."_31" parallel worker suffix to get the checkout's base name.
  # A base name ends in "_wt" (or is the main checkout's), never in a digit, so
  # this can never mistake a base name for a worker name.
  is_live "${db%_[0-9]*}" || STALE+=("$db")
done

say "${#LIVE[@]} live worktree(s), ${#ALL[@]} the_greatest_test* database(s)."

if [ ${#STALE[@]} -eq 0 ]; then
  say "Nothing stale. All test databases belong to a live worktree."
  exit 0
fi

printf '\nStale (worktree no longer exists):\n'
IN_LIST="$(printf "'%s'," "${STALE[@]}")"
docker compose exec -T "$DB_SERVICE" psql -U "$DB_USER" -d postgres -c \
  "select datname, pg_size_pretty(pg_database_size(datname)) as size
     from pg_database where datname in (${IN_LIST%,}) order by datname;" </dev/null

[ "$MODE" = "list" ] && exit 0

printf '\n'
# Every `docker compose exec -T` above redirects stdin from /dev/null. Without
# that it forwards this script's stdin to the container and consumes the answer
# to this prompt before read ever sees it.
read -r -p "Drop these ${#STALE[@]} database(s)? [y/N] " reply
case "$reply" in y|Y|yes|YES) ;; *) die "Aborted." ;; esac

for db in "${STALE[@]}"; do
  docker compose exec -T "$DB_SERVICE" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -q -o /dev/null <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE datname = '${db}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${db}";
SQL
  printf '    dropped %s\n' "$db"
done

say "Dropped ${#STALE[@]} stale database(s)."
