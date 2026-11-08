#!/usr/bin/env bash
# Unit test for deployment/postgres/bin/setup-r2.sh against a stubbed curl that plays the Cloudflare API.
# The stub reads the curl config the script passes on stdin with -K - (url, request, data-binary), keeps
# the buckets and their rules under $SANDBOX/api, and answers GETs with what was last PUT.
# shellcheck disable=SC2016  # stub bodies are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

TOKEN=tok_SECRET_value_123
ACCOUNT=0123456789abcdef0123456789abcdef

setup() {
  new_sandbox
  mkdir -p "$SANDBOX/api/buckets" "$SANDBOX/api/bodies" "$SANDBOX/tmp"
  export TMPDIR="$SANDBOX/tmp"
  : >"$SANDBOX/log/requests"
  unset R2_LOCK_DAYS R2_DUMP_EXPIRE_DAYS GET_BUCKET_CODE READBACK_WRONG R2_REPLACE_LOCK PG_MAJOR
  export CF_API_TOKEN="$TOKEN" CF_ACCOUNT_ID="$ACCOUNT" PGBACKREST_REPO_BUCKET=pg-backups \
    PGVERIFY_DUMP_BUCKET=pg-dumps PGBACKREST_REPO_PATH=/prod-repo
  stub curl "$(cat <<'EOF'
cfg="" out=""
while [ $# -gt 0 ]; do
  case "$1" in -K) cfg=$2; shift ;; -o) out=$2; shift ;; esac
  shift
done
# The token must reach curl on stdin, never in a file: read the config from stdin, keep it outside the
# script's TMPDIR, and record any file under that TMPDIR that holds the token right now.
if [ "$cfg" = - ]; then cfg="$SANDBOX/log/cfg.$$"; cat >"$cfg"; else echo "-K $cfg" >>"$SANDBOX/log/config-not-on-stdin"; fi
if grep -rqF "$CF_API_TOKEN" "$TMPDIR" 2>/dev/null; then echo leak >>"$SANDBOX/log/token-on-disk"; fi
val() { sed -n "s/^$1 = \"\(.*\)\"\$/\1/p" "$cfg" | head -1; }
url="$(val url)"; method="$(val request)"; method="${method:-GET}"; body="$(val data-binary)"; body="${body#@}"
grep -q '^header = "Authorization: Bearer ' "$cfg" || { echo "no auth header" >&2; exit 98; }
path="${url#https://api.cloudflare.com/client/v4/accounts/}"
acct="${path%%/*}"; path="/${path#*/}"
echo "$method $path" >>"$SANDBOX/log/requests"
[ "$acct" = "$CF_ACCOUNT_ID" ] || { echo 403; exit 0; }
api="$SANDBOX/api"
reply() { printf '%s' "$2" >"$out"; printf '%s' "$1"; }
case "$method $path" in
  "GET /r2/buckets/"*/lock | "GET /r2/buckets/"*/lifecycle)
    b="${path#/r2/buckets/}"; kind="${b#*/}"; b="${b%%/*}"
    f="$api/buckets/$b.$kind"
    if [ -n "${READBACK_WRONG:-}" ]; then reply 200 '{"success":true,"result":{"rules":[]}}'
    elif [ -f "$f" ]; then reply 200 "{\"success\":true,\"result\":$(cat "$f")}"
    else reply 200 '{"success":true,"result":{"rules":[]}}'; fi ;;
  "PUT /r2/buckets/"*)
    b="${path#/r2/buckets/}"; kind="${b#*/}"; b="${b%%/*}"
    cp "$body" "$api/buckets/$b.$kind"; cp "$body" "$api/bodies/$b.$kind.$(date +%s%N)"
    reply 200 '{"success":true,"result":{}}' ;;
  "GET /r2/buckets/"*)
    b="${path#/r2/buckets/}"
    if [ -n "${GET_BUCKET_CODE:-}" ]; then reply "$GET_BUCKET_CODE" '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}'
    elif [ -f "$api/buckets/$b" ]; then reply 200 "{\"success\":true,\"result\":{\"name\":\"$b\"}}"
    else reply 404 '{"success":false,"errors":[{"code":10006,"message":"The specified bucket does not exist."}]}'; fi ;;
  "POST /r2/buckets")
    name="$(jq -r .name "$body")"; touch "$api/buckets/$name"
    reply 200 "{\"success\":true,\"result\":{\"name\":\"$name\"}}" ;;
  *) reply 400 '{"success":false,"errors":[{"code":1,"message":"unexpected"}]}' ;;
esac
EOF
)"
}
run() { "$BIN/setup-r2.sh" >"$SANDBOX/log/out" 2>&1; }
requests() { cat "$SANDBOX/log/requests"; }
lock_of() { cat "$SANDBOX/api/buckets/$1.lock"; }
lifecycle_of() { cat "$SANDBOX/api/buckets/$1.lifecycle"; }

# --- creates both buckets when absent, and sets every rule --------------------------------------
setup
if run; then pass "a first run exits 0"; else fail "first run" "$(cat "$SANDBOX/log/out")"; fi
if [ "$(grep -c '^POST /r2/buckets$' "$SANDBOX/log/requests")" = 2 ] && [ -f "$SANDBOX/api/buckets/pg-backups" ] &&
  [ -f "$SANDBOX/api/buckets/pg-dumps" ]; then
  pass "t_creates_missing_buckets: both buckets are created"; else fail "creates buckets" "$(requests)"; fi
if [ "$(lock_of pg-backups | jq -c '.rules')" = '[{"id":"wal-archive","enabled":true,"prefix":"prod-repo/archive/main/18-","condition":{"type":"Age","maxAgeSeconds":1209600}}]' ]; then
  pass "t_backups_lock_is_wal_archive_only: 14 days on <path>/archive/main/18-, no leading slash"
else fail "backups lock" "$(lock_of pg-backups)"; fi
if [ "$(lock_of pg-dumps | jq -c '.rules')" = '[{"id":"all-dumps","enabled":true,"prefix":"","condition":{"type":"Age","maxAgeSeconds":1209600}}]' ]; then
  pass "t_dumps_lock_is_whole_bucket: 14 days on every object"
else fail "dumps lock" "$(lock_of pg-dumps)"; fi
if [ "$(lifecycle_of pg-backups | jq -c '.rules')" = '[{"id":"abort-incomplete-multipart","enabled":true,"conditions":{"prefix":""},"abortMultipartUploadsTransition":{"condition":{"type":"Age","maxAge":604800}}}]' ]; then
  pass "t_backups_lifecycle: aborts incomplete multipart uploads after 7 days, deletes nothing"
else fail "backups lifecycle" "$(lifecycle_of pg-backups)"; fi
if [ "$(lifecycle_of pg-dumps | jq -c '.rules')" = '[{"id":"expire-dumps","enabled":true,"conditions":{"prefix":""},"deleteObjectsTransition":{"condition":{"type":"Age","maxAge":2592000}},"abortMultipartUploadsTransition":{"condition":{"type":"Age","maxAge":604800}}}]' ]; then
  pass "t_dumps_lifecycle: deletes objects after 30 days, aborts multipart after 7"
else fail "dumps lifecycle" "$(lifecycle_of pg-dumps)"; fi
if grep -q '^GET /r2/buckets/pg-backups/lock$' "$SANDBOX/log/requests" && grep -q '^GET /r2/buckets/pg-backups/lifecycle$' "$SANDBOX/log/requests" &&
  grep -q '^GET /r2/buckets/pg-dumps/lock$' "$SANDBOX/log/requests" && grep -q '^GET /r2/buckets/pg-dumps/lifecycle$' "$SANDBOX/log/requests"; then
  pass "t_reads_every_rule_back"; else fail "read back" "$(requests)"; fi
if ! grep -qF "$TOKEN" "$CALLS" && ! grep -qF "$ACCOUNT" "$CALLS" && ! grep -qF "$TOKEN" "$SANDBOX/log/out" &&
  ! grep -qF "$ACCOUNT" "$SANDBOX/log/out"; then
  pass "t_token_and_account_never_in_argv_or_output"; else fail "secret leaked" "$(cat "$CALLS" "$SANDBOX/log/out")"; fi
if [ -z "$(ls -A "$SANDBOX/tmp")" ]; then
  pass "the temp dir is removed"; else fail "temp dir left" "$(ls -A "$SANDBOX/tmp")"; fi
if [ ! -e "$SANDBOX/log/config-not-on-stdin" ] && [ ! -e "$SANDBOX/log/token-on-disk" ]; then
  pass "t_token_never_on_disk: curl gets its config on stdin (-K -)"
else fail "token on disk" "$(cat "$SANDBOX/log/config-not-on-stdin" "$SANDBOX/log/token-on-disk" 2>&1)"; fi
if tail -n 1 "$SANDBOX/log/out" | grep -qx 'setup-r2: done'; then pass "ends in setup-r2: done"; else fail "last line" "$(tail -n 3 "$SANDBOX/log/out")"; fi

# --- a second run creates nothing and leaves the same rules ------------------------------------
cp "$SANDBOX/api/buckets/pg-backups.lock" "$SANDBOX/first.lock"
: >"$SANDBOX/log/requests"
if run && ! grep -q '^POST' "$SANDBOX/log/requests" && cmp -s "$SANDBOX/first.lock" "$SANDBOX/api/buckets/pg-backups.lock"; then
  pass "t_rerun_is_idempotent: no create, same rules"; else fail "rerun" "$(requests; cat "$SANDBOX/log/out")"; fi

# --- read-back that does not match fails --------------------------------------------------------
setup; export READBACK_WRONG=1
if ! run && grep -q 'do not match what was set' "$SANDBOX/log/out"; then pass "t_readback_mismatch_fails"; else fail "readback mismatch" "$(cat "$SANDBOX/log/out")"; fi

# --- an API error on the bucket lookup stops before any change ----------------------------------
setup; export GET_BUCKET_CODE=403
if ! run && ! grep -qE '^(PUT|POST)' "$SANDBOX/log/requests" && grep -q 'Authentication error' "$SANDBOX/log/out"; then
  pass "t_api_error_stops_before_changes: names the API's error"; else fail "api error" "$(requests; cat "$SANDBOX/log/out")"; fi

# --- the lock must stay below retention and the dump expiry -------------------------------------
setup; export R2_LOCK_DAYS=30
if ! run && [ ! -s "$SANDBOX/log/requests" ] && grep -q 'retention' "$SANDBOX/log/out"; then
  pass "t_lock_not_below_retention_refuses (30 >= 30)"; else fail "lock vs retention" "$(cat "$SANDBOX/log/out")"; fi
setup; export R2_LOCK_DAYS=14 R2_DUMP_EXPIRE_DAYS=14
if ! run && [ ! -s "$SANDBOX/log/requests" ]; then pass "t_lock_not_below_dump_expiry_refuses"; else fail "lock vs dump expiry" "$(cat "$SANDBOX/log/out")"; fi

# --- every setting is required, and named when missing ------------------------------------------
for v in CF_API_TOKEN CF_ACCOUNT_ID PGBACKREST_REPO_BUCKET PGVERIFY_DUMP_BUCKET PGBACKREST_REPO_PATH; do
  setup; unset "$v"
  if ! run && [ ! -s "$SANDBOX/log/requests" ] && grep -q "$v" "$SANDBOX/log/out"; then
    pass "t_missing_var_names_it: $v"; else fail "missing $v" "$(cat "$SANDBOX/log/out")"; fi
done

# --- the lock guard: a live lock is never silently moved, narrowed, shortened or dropped ---------
# preset_lock <bucket> <rules json>: the bucket exists and already carries these lock rules.
preset_lock() { touch "$SANDBOX/api/buckets/$1"; printf '{"rules":%s}' "$2" >"$SANDBOX/api/buckets/$1.lock"; }
age_rule() { printf '{"id":"%s","enabled":%s,"prefix":"%s","condition":{"type":"Age","maxAgeSeconds":%s}}' "$1" "$2" "$3" "$4"; }
D14=1209600
no_lock_put() { ! grep -q "^PUT " "$SANDBOX/log/requests"; }  # a refusal changes no rule in either bucket
refused() { # refused <bucket>: exit 2, that bucket's lock left as it was, old and new printed
  local rc
  run; rc=$?
  [ "$rc" = 2 ] && no_lock_put "$1" && grep -q 'now: ' "$SANDBOX/log/out" && grep -q 'would become: ' "$SANDBOX/log/out"
}

setup; preset_lock pg-backups "[$(age_rule wal-archive true pre-prod/archive/main/18- $D14)]"
if refused pg-backups && grep -q 'pre-prod/archive/main/18-' "$SANDBOX/log/out" && grep -q 'prod-repo/archive/main/18-' "$SANDBOX/log/out"; then
  pass "t_guard_refuses_moving_the_lock: a changed repo path, old and new prefix printed"
else fail "guard moved" "$(requests; cat "$SANDBOX/log/out")"; fi
setup; preset_lock pg-backups "[$(age_rule wal-archive true pre-prod/archive/main/18- $D14)]"; export R2_REPLACE_LOCK=1
if run && grep -q 'R2_REPLACE_LOCK=1' "$SANDBOX/log/out" &&
  [ "$(lock_of pg-backups | jq -r '.rules[0].prefix')" = prod-repo/archive/main/18- ]; then
  pass "t_guard_override: R2_REPLACE_LOCK=1 moves it and says so"
else fail "guard override" "$(cat "$SANDBOX/log/out")"; fi
setup; preset_lock pg-backups "[$(age_rule wal-archive true prod-repo/archive/main/18- 1728000)]"
if refused pg-backups && grep -q '20 days' "$SANDBOX/log/out" && grep -q '14 days' "$SANDBOX/log/out"; then
  pass "t_guard_refuses_shortening (20 days to 14)"; else fail "guard shorten" "$(cat "$SANDBOX/log/out")"; fi
setup; preset_lock pg-backups "[$(age_rule everything true '' $D14)]"
if refused pg-backups; then pass "t_guard_refuses_narrowing (whole bucket to the WAL prefix)"; else fail "guard narrow" "$(cat "$SANDBOX/log/out")"; fi
setup; preset_lock pg-dumps "[$(age_rule all-dumps true '' 1728000)]"
if refused pg-dumps; then pass "t_guard_covers_the_dumps_bucket too"; else fail "guard dumps" "$(cat "$SANDBOX/log/out")"; fi
setup; preset_lock pg-backups "[$(age_rule wal-archive true prod-repo/archive/main/18- $D14)]"; export PG_MAJOR=19
if refused pg-backups && grep -q 'prod-repo/archive/main/19-' "$SANDBOX/log/out"; then
  pass "t_guard_refuses_a_major_version_switch without R2_REPLACE_LOCK"; else fail "guard major" "$(cat "$SANDBOX/log/out")"; fi
setup; export PG_MAJOR=19
if run && [ "$(lock_of pg-backups | jq -r '.rules[0].prefix')" = prod-repo/archive/main/19- ]; then
  pass "t_pg_major_sets_the_prefix"; else fail "pg major prefix" "$(cat "$SANDBOX/log/out")"; fi
setup; preset_lock pg-backups "[$(age_rule wal-archive true prod-repo/archive/main/18- 604800)]"
if run && [ "$(lock_of pg-backups | jq -r '.rules[0].condition.maxAgeSeconds')" = "$D14" ]; then
  pass "t_guard_allows_lengthening (7 days to 14)"; else fail "guard lengthen" "$(cat "$SANDBOX/log/out")"; fi
setup; preset_lock pg-backups "[$(age_rule old-off false somewhere/else 1728000)]"
if run; then pass "t_guard_ignores_a_rule_that_is_already_disabled"; else fail "guard disabled old" "$(cat "$SANDBOX/log/out")"; fi
setup; preset_lock pg-backups "[$(age_rule wal-archive true prod-repo/archive/main/18- $D14),$(age_rule extra true other/ $D14)]"
if refused pg-backups && grep -q 'other/' "$SANDBOX/log/out"; then
  pass "t_guard_refuses_dropping_an_extra_rule"; else fail "guard extra" "$(cat "$SANDBOX/log/out")"; fi

# --- --check reads and compares, and changes nothing ----------------------------------------------
check_run() { "$BIN/setup-r2.sh" --check >"$SANDBOX/log/out" 2>&1; }
no_writes() { ! grep -qE '^(PUT|POST)' "$SANDBOX/log/requests"; }
setup
if check_run; then fail "check with nothing set up" "exit 0"; else
  if [ "$?" = 1 ] && no_writes && grep -q 'MISSING' "$SANDBOX/log/out"; then pass "t_check_missing_buckets_exit_1_without_creating"
  else fail "check missing" "$(requests; cat "$SANDBOX/log/out")"; fi
fi
run >/dev/null; : >"$SANDBOX/log/requests"
if check_run && no_writes && grep -q 'check: all as expected' "$SANDBOX/log/out"; then
  pass "t_check_after_setup_passes_read_only"; else fail "check passes" "$(requests; cat "$SANDBOX/log/out")"; fi
printf '{"rules":[%s]}' "$(age_rule all-dumps true '' 604800)" >"$SANDBOX/api/buckets/pg-dumps.lock"; : >"$SANDBOX/log/requests"
check_run; rc=$?
if [ "$rc" = 1 ] && no_writes && grep -q 'dumps bucket lock rules DIFFER' "$SANDBOX/log/out"; then
  pass "t_check_reports_a_changed_rule_exit_1"; else fail "check differs" "rc=$rc $(requests; cat "$SANDBOX/log/out")"; fi
if "$BIN/setup-r2.sh" --bogus >/dev/null 2>&1; then fail "unknown option" "exit 0"; else pass "an unknown option is refused"; fi

# --- bad input is refused before any request -----------------------------------------------------
bad_input() { # bad_input <label> <var> <value>
  setup; export "$2=$3"
  if ! run && [ ! -s "$SANDBOX/log/requests" ]; then pass "refuses $1"; else fail "refuses $1" "$(requests; cat "$SANDBOX/log/out")"; fi
}
bad_input "a repo path of /" PGBACKREST_REPO_PATH /
bad_input "a relative repo path" PGBACKREST_REPO_PATH prod-repo
bad_input "a repo path with .." PGBACKREST_REPO_PATH /a/../b
bad_input "an account id that is not 32 hex digits" CF_ACCOUNT_ID not-an-account
bad_input "a token with a quote" CF_API_TOKEN 'abc"def'
bad_input "an invalid bucket name" PGVERIFY_DUMP_BUCKET Bad_Bucket
bad_input "one bucket for both jobs" PGVERIFY_DUMP_BUCKET pg-backups
finish
