#!/usr/bin/env bash
# deployment/postgres/bin/setup-r2.sh -- one-time (and safe to repeat) setup of the two R2 buckets the
# Postgres backups use. Run by Shane from the dev machine with a temporary account API token, never on a
# server. Spec: docs/superpowers/specs/2026-11-06-postgres-server-design.md §8.2. Runbook:
# docs/features/postgres-server.md, "Build", step 2.
#
# Usage: setup-r2.sh            create, set, read back
#        setup-r2.sh --check    read only: report whether both buckets and all their rules are as this
#                               script would set them (exit 0 if so, 1 if not); creates and changes nothing
#
#   backups bucket (PGBACKREST_REPO_BUCKET): pgBackRest's repo.
#     lock: objects under <repo path>/archive/main/<PG_MAJOR>- cannot be deleted or overwritten for 14
#           days. PG_MAJOR (default 18) is the archive id's major version: a major upgrade changes it.
#           ONLY the WAL archive: pgBackRest rewrites the manifest inside each backup folder while it
#           backs up, so a lock there makes every backup fail with 409.
#     lifecycle: abort incomplete multipart uploads after 7 days. No expiry: pgBackRest expires.
#   dumps bucket (PGVERIFY_DUMP_BUCKET): the home VM's nightly pg_dump files, written once.
#     lock: every object, 14 days.
#     lifecycle: delete objects after 30 days, abort incomplete multipart uploads after 7 days.
#
# The lock must stay below the repo's retention (repo1-retention-full in config/pgbackrest.conf.tmpl):
# pgBackRest's expire fails with 409 on an object still inside a lock. It must also stay below the dump
# expiry. The script refuses otherwise.
#
# Environment (never arguments, never printed):
#   CF_API_TOKEN     an account API token that can edit R2 (temporary: delete it afterwards)
#   CF_ACCOUNT_ID    the Cloudflare account id (32 hex digits)
#   PGBACKREST_REPO_BUCKET, PGBACKREST_REPO_PATH   from secrets/.env.postgres
#   PGVERIFY_DUMP_BUCKET                           from secrets/home-server.env
# Optional: R2_LOCK_DAYS (14), R2_DUMP_EXPIRE_DAYS (30), PG_MAJOR (18).
#
# The lock guard. A lock PUT replaces the bucket's lock rules, so a run with a different
# PGBACKREST_REPO_PATH, R2_LOCK_DAYS or PG_MAJOR would silently move or shorten the live lock. Before
# every lock PUT the current rules are read; if any enabled rule would be dropped, narrowed, shortened or
# disabled, the script refuses (exit 2) and prints the old and new prefix and age. R2_REPLACE_LOCK=1
# allows it, for a deliberate change only (the runbook's pre-production path switch, a major upgrade).
#
# The bucket-scoped tokens the server, the home VM and developers use are created by hand afterwards;
# this script makes none.
#
# Each lock and lifecycle PUT replaces the bucket's whole rule set. Every rule is read back and compared
# with what was sent. Exit 0 on success (last line `setup-r2: done`), 1 on an API failure or a rule that
# does not read back, 2 on bad input (before any request) or a refused lock change.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$here/../config/pgbackrest.conf.tmpl"
API=https://api.cloudflare.com/client/v4

usage() { echo "usage: setup-r2.sh [--check]" >&2; exit 2; }
CHECK=0
[ "$#" -le 1 ] || usage
case "${1:-}" in
  "") ;;
  --check) CHECK=1 ;;
  *) usage ;;
esac

LOCK_DAYS="${R2_LOCK_DAYS:-14}"
DUMP_EXPIRE_DAYS="${R2_DUMP_EXPIRE_DAYS:-30}"
PG_MAJOR="${PG_MAJOR:-18}"
ABORT_MULTIPART_DAYS=7
DAY=86400

say() { echo "setup-r2: $*"; }
die() { echo "setup-r2: $1" >&2; exit "${2:-1}"; }

# --- Input, all checked before any request ------------------------------------------------------
for tool in curl jq; do command -v "$tool" >/dev/null || die "$tool is not installed" 2; done
missing=()
for name in CF_API_TOKEN CF_ACCOUNT_ID PGBACKREST_REPO_BUCKET PGVERIFY_DUMP_BUCKET PGBACKREST_REPO_PATH; do
  if [ -z "${!name:-}" ]; then missing+=("$name"); fi
done
[ "${#missing[@]}" = 0 ] || die "missing from the environment: ${missing[*]}" 2

# The token and account id go into curl's config (on its stdin), inside double quotes: nothing that
# could end the string or start a new option is allowed.
[[ "$CF_API_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]] || die "CF_API_TOKEN has characters an API token does not have" 2
[[ "$CF_ACCOUNT_ID" =~ ^[0-9a-f]{32}$ ]] || die "CF_ACCOUNT_ID is not 32 hex digits" 2
for name in PGBACKREST_REPO_BUCKET PGVERIFY_DUMP_BUCKET; do
  [[ "${!name}" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || die "$name is not a valid R2 bucket name" 2
done
[ "$PGBACKREST_REPO_BUCKET" != "$PGVERIFY_DUMP_BUCKET" ] ||
  die "PGBACKREST_REPO_BUCKET and PGVERIFY_DUMP_BUCKET are the same bucket; they need different rules" 2

# pgBackRest's repo1-path=/x stores keys under x/ (no leading slash), so that is the lock's prefix.
repo_path="$PGBACKREST_REPO_PATH"
[[ "$repo_path" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "PGBACKREST_REPO_PATH must be an absolute path of letters, digits and . _ / -" 2
case "$repo_path" in *..* | *//*) die "PGBACKREST_REPO_PATH must not contain .. or //" 2 ;; esac
repo_path="${repo_path#/}"
repo_path="${repo_path%/}"
[ -n "$repo_path" ] || die "PGBACKREST_REPO_PATH must not be /" 2
[[ "$PG_MAJOR" =~ ^[1-9][0-9]*$ ]] || die "PG_MAJOR must be a Postgres major version number" 2
# pgBackRest's archive id is <major>-<n> (18-1, then 18-2 after a stanza-upgrade), under archive/<stanza>.
WAL_PREFIX="$repo_path/archive/main/$PG_MAJOR-"

for name in LOCK_DAYS DUMP_EXPIRE_DAYS; do
  [[ "${!name}" =~ ^[1-9][0-9]*$ ]] || die "$name must be a positive whole number of days" 2
done
retention="$(sed -n 's/^repo1-retention-full=\([0-9][0-9]*\)$/\1/p' "$TEMPLATE")"
grep -qx 'repo1-retention-full-type=time' "$TEMPLATE" && [ -n "$retention" ] ||
  die "could not read a time-based repo1-retention-full from $TEMPLATE" 2
[ "$LOCK_DAYS" -lt "$retention" ] ||
  die "the lock ($LOCK_DAYS days) must be shorter than the backup retention ($retention days), or expire fails on locked objects" 2
[ "$LOCK_DAYS" -lt "$DUMP_EXPIRE_DAYS" ] ||
  die "the lock ($LOCK_DAYS days) must be shorter than the dump expiry ($DUMP_EXPIRE_DAYS days)" 2

# --- The API ---------------------------------------------------------------------------------------
# Holds request bodies and responses only; the token never touches disk.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/setup-r2.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"

# api METHOD PATH [BODY_FILE]: prints the HTTP status; the response body is in $tmp/resp. The URL (which
# holds the account id) and the token reach curl as its config on stdin (-K -): printf is a builtin, so
# neither is in any process's arguments, and nothing writes them to a file.
api() {
  local method=$1 path=$2 body=${3:-} code
  : >"$tmp/resp"
  # On a connection failure curl exits non-zero and -w prints 000, which expect_ok reports.
  code="$(
    {
      printf 'url = "%s/accounts/%s%s"\n' "$API" "$CF_ACCOUNT_ID" "$path"
      printf 'request = "%s"\n' "$method"
      printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN"
      printf 'header = "Content-Type: application/json"\n'
      if [ -n "$body" ]; then printf 'data-binary = "@%s"\n' "$body"; fi
    } | curl -sS --max-time 60 -K - -o "$tmp/resp" -w '%{http_code}'
  )" || true
  echo "${code:-000}"
}
# api_errors: the API's own error codes and messages, nothing else from the response.
api_errors() { jq -r '[.errors[]? | "\(.code) \(.message)"] | join("; ")' "$tmp/resp" 2>/dev/null || true; }
# expect_ok <status> <what>: a 2xx with success true, or die naming the step and the API's error.
expect_ok() {
  local code=$1 what=$2
  if [[ "$code" =~ ^2 ]] && jq -e '.success == true' "$tmp/resp" >/dev/null 2>&1; then return 0; fi
  die "$what failed (HTTP $code): $(api_errors)"
}

# ensure_bucket <name> <label>: create it unless it exists. A 404 is the only "absent".
ensure_bucket() {
  local name=$1 label=$2 code
  code="$(api GET "/r2/buckets/$name")"
  if [ "$code" = 404 ]; then
    jq -n --arg name "$name" '{name: $name}' >"$tmp/body.json"
    code="$(api POST /r2/buckets "$tmp/body.json")"
    expect_ok "$code" "creating the $label bucket"
    say "$label bucket created"
  else
    expect_ok "$code" "looking up the $label bucket"
    say "$label bucket exists"
  fi
}

# normalise <lock|lifecycle>: a jq program over a rules array keeping the fields that matter, so a field
# the API adds does not fail a comparison and a rule it drops or changes does.
normalise() {
  if [ "$1" = lock ]; then
    echo '[.[] | {id, enabled, prefix: (.prefix // ""), type: .condition.type, age: .condition.maxAgeSeconds}] | sort_by(.id)'
  else
    echo '[.[] | {id, enabled, prefix: (.conditions.prefix // ""),
      abort: .abortMultipartUploadsTransition.condition.maxAge, delete: .deleteObjectsTransition.condition.maxAge}] | sort_by(.id)'
  fi
}

# read_rules <bucket> <lock|lifecycle> <label>: prints the bucket's current rules array.
read_rules() {
  local code
  code="$(api GET "/r2/buckets/$1/$2")"
  expect_ok "$code" "reading the $3 bucket's $2 rules"
  jq -c '.result.rules // []' "$tmp/resp"
}

# guard_lock <bucket> <label> <new rules>: refuse (exit 2) when an enabled lock rule now in place would be
# dropped, narrowed, shortened or disabled. An old rule counts as kept when an enabled new rule covers its
# prefix (the old prefix starts with the new one) for at least as long. Indefinite outlasts any age; a
# Date lock is never treated as covered.
# shellcheck disable=SC2016 # a jq program: its $old and $new are jq variables
GUARD_JQ='
  def age: if .condition.type == "Age" then .condition.maxAgeSeconds
           elif .condition.type == "Indefinite" then infinite else null end;
  def show: "prefix \"\(.prefix // "")\", "
    + (if .condition.type == "Age" then "\(.condition.maxAgeSeconds / 86400) days" else .condition.type end)
    + (if .enabled then "" else " (disabled)" end);
  [$old[] | select(.enabled) | . as $o | ($o | age) as $oa
    | select([$new[] | . as $n | select($n.enabled and (($o.prefix // "") | startswith($n.prefix // ""))
               and $oa != null and ($n | age) >= $oa)] | length == 0)
    | "  now:          " + ($o | show)] as $lost
  | if ($lost | length) == 0 then empty
    else $lost + ["  would become: " + (if ($new | length) == 0 then "no rules" else [$new[] | show] | join("; ") end)]
      | join("\n") end'
guard_lock() {
  local bucket=$1 label=$2 new=$3 old lost
  old="$(read_rules "$bucket" lock "$label")"
  lost="$(jq -nr --argjson old "$old" --argjson new "$new" "$GUARD_JQ")"
  [ -n "$lost" ] || return 0
  if [ "${R2_REPLACE_LOCK:-0}" = 1 ]; then
    say "R2_REPLACE_LOCK=1: replacing the $label bucket's lock although it drops or weakens a rule:"
    echo "$lost"
    return 0
  fi
  echo "setup-r2: refusing to drop, narrow, shorten or disable the $label bucket's lock:" >&2
  echo "$lost" >&2
  die "set R2_REPLACE_LOCK=1 only when this change is deliberate (docs/features/postgres-server.md)" 2
}

# put_rules <bucket> <lock|lifecycle> <label> <rules json>: replace the rules, read them back, compare.
# Locks are put only after guard_lock has passed for both buckets.
put_rules() {
  local bucket=$1 kind=$2 label=$3 rules=$4 code want have norm
  jq -n --argjson rules "$rules" '{rules: $rules}' >"$tmp/body.json"
  code="$(api PUT "/r2/buckets/$bucket/$kind" "$tmp/body.json")"
  expect_ok "$code" "setting the $label bucket's $kind rules"
  norm="$(normalise "$kind")"
  want="$(jq -c "$norm" <<<"$rules")"
  have="$(read_rules "$bucket" "$kind" "$label" | jq -c "$norm")" || have=""
  [ "$want" = "$have" ] || die "the $label bucket's $kind rules do not match what was set; check them in the dashboard"
  say "$label bucket $kind rules set and read back"
}

# --check: report only.
check_ok=1
check_bucket() { # check_bucket <name> <label>: 0 when it exists
  local code
  code="$(api GET "/r2/buckets/$1")"
  if [ "$code" = 404 ]; then check_ok=0; say "$2 bucket is MISSING"; return 1; fi
  expect_ok "$code" "looking up the $2 bucket"
  say "$2 bucket exists"
}
check_rules() { # check_rules <bucket> <kind> <label> <rules json>
  local bucket=$1 kind=$2 label=$3 rules=$4 norm want have
  norm="$(normalise "$kind")"
  want="$(jq -c "$norm" <<<"$rules")"
  have="$(read_rules "$bucket" "$kind" "$label" | jq -c "$norm")"
  if [ "$want" = "$have" ]; then
    say "$label bucket $kind rules: as expected"
  else
    check_ok=0
    say "$label bucket $kind rules DIFFER"
    echo "  have: $have"
    echo "  want: $want"
  fi
}

# --- The rules -----------------------------------------------------------------------------------------
lock_s=$((LOCK_DAYS * DAY))
abort_s=$((ABORT_MULTIPART_DAYS * DAY))
expire_s=$((DUMP_EXPIRE_DAYS * DAY))
backups_lock="$(jq -nc --arg p "$WAL_PREFIX" --argjson s "$lock_s" \
  '[{id: "wal-archive", enabled: true, prefix: $p, condition: {type: "Age", maxAgeSeconds: $s}}]')"
backups_lifecycle="$(jq -nc --argjson a "$abort_s" \
  '[{id: "abort-incomplete-multipart", enabled: true, conditions: {prefix: ""},
     abortMultipartUploadsTransition: {condition: {type: "Age", maxAge: $a}}}]')"
dumps_lock="$(jq -nc --argjson s "$lock_s" \
  '[{id: "all-dumps", enabled: true, prefix: "", condition: {type: "Age", maxAgeSeconds: $s}}]')"
dumps_lifecycle="$(jq -nc --argjson e "$expire_s" --argjson a "$abort_s" \
  '[{id: "expire-dumps", enabled: true, conditions: {prefix: ""},
     deleteObjectsTransition: {condition: {type: "Age", maxAge: $e}},
     abortMultipartUploadsTransition: {condition: {type: "Age", maxAge: $a}}}]')"

if [ "$CHECK" = 1 ]; then
  if check_bucket "$PGBACKREST_REPO_BUCKET" backups; then
    check_rules "$PGBACKREST_REPO_BUCKET" lock backups "$backups_lock"
    check_rules "$PGBACKREST_REPO_BUCKET" lifecycle backups "$backups_lifecycle"
  fi
  if check_bucket "$PGVERIFY_DUMP_BUCKET" dumps; then
    check_rules "$PGVERIFY_DUMP_BUCKET" lock dumps "$dumps_lock"
    check_rules "$PGVERIFY_DUMP_BUCKET" lifecycle dumps "$dumps_lifecycle"
  fi
  if [ "$check_ok" = 1 ]; then say "check: all as expected"; exit 0; fi
  say "check: differences found"
  exit 1
fi

ensure_bucket "$PGBACKREST_REPO_BUCKET" backups
ensure_bucket "$PGVERIFY_DUMP_BUCKET" dumps
# Both guards before any rule changes, so a refusal leaves every rule as it was.
guard_lock "$PGBACKREST_REPO_BUCKET" backups "$backups_lock"
guard_lock "$PGVERIFY_DUMP_BUCKET" dumps "$dumps_lock"
put_rules "$PGBACKREST_REPO_BUCKET" lock backups "$backups_lock"
put_rules "$PGBACKREST_REPO_BUCKET" lifecycle backups "$backups_lifecycle"
put_rules "$PGVERIFY_DUMP_BUCKET" lock dumps "$dumps_lock"
put_rules "$PGVERIFY_DUMP_BUCKET" lifecycle dumps "$dumps_lifecycle"

say "backups: WAL archive locked ${LOCK_DAYS}d (retention ${retention}d), multipart aborted after ${ABORT_MULTIPART_DAYS}d"
say "dumps: every object locked ${LOCK_DAYS}d, deleted after ${DUMP_EXPIRE_DAYS}d"
say "done"
