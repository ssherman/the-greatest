#!/usr/bin/env bash
# deployment/postgres/bin/setup-r2.sh -- one-time (and safe to repeat) setup of the two R2 buckets the
# Postgres backups use. Run by Shane from the dev machine with a temporary account API token, never on a
# server. Spec: docs/superpowers/specs/2026-11-06-postgres-server-design.md §8.2. Runbook:
# docs/features/postgres-server.md, "Build", step 2.
#
#   backups bucket (PGBACKREST_REPO_BUCKET): pgBackRest's repo.
#     lock: objects under <repo path>/archive/main/18- cannot be deleted or overwritten for 14 days.
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
# Optional: R2_LOCK_DAYS (14), R2_DUMP_EXPIRE_DAYS (30).
#
# The bucket-scoped tokens the server, the home VM and developers use are created by hand afterwards;
# this script makes none.
#
# Each lock and lifecycle PUT replaces the bucket's whole rule set. Every rule is read back and compared
# with what was sent. Exit 0 on success (last line `setup-r2: done`), 1 on an API failure or a rule that
# does not read back, 2 on bad input (before any request).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$here/../config/pgbackrest.conf.tmpl"
API=https://api.cloudflare.com/client/v4

LOCK_DAYS="${R2_LOCK_DAYS:-14}"
DUMP_EXPIRE_DAYS="${R2_DUMP_EXPIRE_DAYS:-30}"
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

# The token and account id go into a curl config file, inside double quotes: nothing that could end the
# string or start a new option is allowed.
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
WAL_PREFIX="$repo_path/archive/main/18-"

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
tmp="$(mktemp -d "${TMPDIR:-/tmp}/setup-r2.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"

# api METHOD PATH [BODY_FILE]: prints the HTTP status; the response body is in $tmp/resp. The URL (which
# holds the account id) and the token go to curl in a config file, so neither is in any process's
# arguments.
api() {
  local method=$1 path=$2 body=${3:-}
  (
    umask 077
    {
      printf 'url = "%s/accounts/%s%s"\n' "$API" "$CF_ACCOUNT_ID" "$path"
      printf 'request = "%s"\n' "$method"
      printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN"
      printf 'header = "Content-Type: application/json"\n'
      if [ -n "$body" ]; then printf 'data-binary = "@%s"\n' "$body"; fi
    } >"$tmp/curl.cfg"
  )
  : >"$tmp/resp"
  local code
  # On a connection failure curl exits non-zero and -w prints 000, which expect_ok reports.
  code="$(curl -sS --max-time 60 -K "$tmp/curl.cfg" -o "$tmp/resp" -w '%{http_code}')" || true
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

# put_rules <bucket> <lock|lifecycle> <label> <rules json>: replace the rules, read them back, compare.
# The comparison is on the fields that matter, normalised, so a field the API adds does not fail it and
# a rule it drops or changes does.
put_rules() {
  local bucket=$1 kind=$2 label=$3 rules=$4 code want have norm
  jq -n --argjson rules "$rules" '{rules: $rules}' >"$tmp/body.json"
  code="$(api PUT "/r2/buckets/$bucket/$kind" "$tmp/body.json")"
  expect_ok "$code" "setting the $label bucket's $kind rules"
  code="$(api GET "/r2/buckets/$bucket/$kind")"
  expect_ok "$code" "reading back the $label bucket's $kind rules"
  if [ "$kind" = lock ]; then
    norm='[.[] | {id, enabled, prefix: (.prefix // ""), type: .condition.type, age: .condition.maxAgeSeconds}] | sort_by(.id)'
  else
    norm='[.[] | {id, enabled, prefix: (.conditions.prefix // ""),
      abort: .abortMultipartUploadsTransition.condition.maxAge, delete: .deleteObjectsTransition.condition.maxAge}] | sort_by(.id)'
  fi
  want="$(jq -c "$norm" <<<"$rules")"
  have="$(jq -c ".result.rules // [] | $norm" "$tmp/resp" 2>/dev/null)" || have=""
  [ "$want" = "$have" ] || die "the $label bucket's $kind rules do not match what was set; check them in the dashboard"
  say "$label bucket $kind rules set and read back"
}

# --- Do it -------------------------------------------------------------------------------------------
ensure_bucket "$PGBACKREST_REPO_BUCKET" backups
ensure_bucket "$PGVERIFY_DUMP_BUCKET" dumps

lock_s=$((LOCK_DAYS * DAY))
abort_s=$((ABORT_MULTIPART_DAYS * DAY))
expire_s=$((DUMP_EXPIRE_DAYS * DAY))

put_rules "$PGBACKREST_REPO_BUCKET" lock backups "$(jq -nc --arg p "$WAL_PREFIX" --argjson s "$lock_s" \
  '[{id: "wal-archive", enabled: true, prefix: $p, condition: {type: "Age", maxAgeSeconds: $s}}]')"
put_rules "$PGBACKREST_REPO_BUCKET" lifecycle backups "$(jq -nc --argjson a "$abort_s" \
  '[{id: "abort-incomplete-multipart", enabled: true, conditions: {prefix: ""},
     abortMultipartUploadsTransition: {condition: {type: "Age", maxAge: $a}}}]')"
put_rules "$PGVERIFY_DUMP_BUCKET" lock dumps "$(jq -nc --argjson s "$lock_s" \
  '[{id: "all-dumps", enabled: true, prefix: "", condition: {type: "Age", maxAgeSeconds: $s}}]')"
put_rules "$PGVERIFY_DUMP_BUCKET" lifecycle dumps "$(jq -nc --argjson e "$expire_s" --argjson a "$abort_s" \
  '[{id: "expire-dumps", enabled: true, conditions: {prefix: ""},
     deleteObjectsTransition: {condition: {type: "Age", maxAge: $e}},
     abortMultipartUploadsTransition: {condition: {type: "Age", maxAge: $a}}}]')"

say "backups: WAL archive locked ${LOCK_DAYS}d (retention ${retention}d), multipart aborted after ${ABORT_MULTIPART_DAYS}d"
say "dumps: every object locked ${LOCK_DAYS}d, deleted after ${DUMP_EXPIRE_DAYS}d"
say "done"
