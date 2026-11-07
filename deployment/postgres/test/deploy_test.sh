#!/usr/bin/env bash
# Unit test for deployment/postgres/bin/deploy.sh. Docker, systemctl and iptables are stubbed;
# certificates and envsubst are real. The stub answers from files under $SANDBOX/state, so each
# scenario sets what the server "has": the data directory, the backup repo, a running container.
# shellcheck disable=SC2016  # stub bodies are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
# A copy of the deployable tree, so a test can change postgresql.conf without touching the repo.
mkdir -p "$SANDBOX/pg"
cp -r "$OS_DIR/bin" "$OS_DIR/config" "$OS_DIR/systemd" "$OS_DIR/Dockerfile" "$OS_DIR/compose.yml" "$SANDBOX/pg/"
BIN="$SANDBOX/pg/bin"
mkdir -p "$SANDBOX/state"

stub systemctl ''
stub iptables-restore 'command -p cat >"$SANDBOX/log/v4.rules"'
stub ip6tables-restore 'command -p cat >/dev/null'
stub docker 'st="$SANDBOX/state"
case "$*" in
  *pg_is_in_recovery*) echo f ;;
  *pg_isready*) if [ -e "$st/notready" ]; then exit 1; fi ;;
  *"stanza=main check"*)   # check_rc holds one exit code per line; each call consumes one, the last repeats
    cat "$st/check_out"; rc="$(head -n 1 "$st/check_rc")"
    if [ "$(wc -l <"$st/check_rc")" -gt 1 ]; then sed -i 1d "$st/check_rc"; fi
    exit "$rc" ;;
  *" up -d"*) cat "$st/up_out"; exit "$(cat "$st/up_rc")" ;;
  *" ps "*) if [ "$(cat "$st/ps_rc")" = 0 ]; then cat "$st/running"; else echo "ps failed: SECRETBUCKET" >&2; exit 1; fi ;;
  *PG_VERSION*) cat "$st/data"; cat "$st/data_err" >&2; exit "$(cat "$st/data_rc")" ;;
  *psql*) command -p cat >>"$SANDBOX/log/sql" ;;
  *PG_VERSION*) cat "$st/data" ;;
  *"info --output=json"*) cat "$st/info"; exit "$(cat "$st/info_rc")" ;;
  *" ps "*) cat "$st/running" ;;
esac'

PG_UID="$(id -u)" PG_GID="$(id -g)"
export NO_SUDO=1 PG_UID PG_GID ROOT="$SANDBOX/root" WAIT_SLEEP=0
export STATE_DIR="$SANDBOX/srv" ETC_DIR="$SANDBOX/etc" ALLOWLIST="$SANDBOX/etc/allowlist"
env_file="$SANDBOX/env"

SECRETS=()
mk() { printf -v "$1" '%s' "$(openssl rand -hex 32)"; SECRETS+=("${!1}"); }
CLIENTS='the_greatest the_greatest 203.0.113.10;tgb_app tgb 203.0.113.11;tgb_reader tgb 203.0.113.10'
write_env() {   # write_env [VAR=value ...]  -- later lines win, so extra arguments override
  local S_SU S_TG S_KEY S_CIPHER
  mk S_SU; mk S_TG; mk S_APP; mk S_RD; mk S_KEY; mk S_KEYSECRET; mk S_CIPHER
  {
    printf 'POSTGRES_CLIENTS="%s"\n' "$CLIENTS"
    printf 'POSTGRES_SUPERUSER_PASSWORD=%s\n' "$S_SU"
    printf 'POSTGRES_THE_GREATEST_PASSWORD=%s\n' "$S_TG"
    printf 'POSTGRES_TGB_APP_PASSWORD=%s\n' "$S_APP"
    printf 'POSTGRES_TGB_READER_PASSWORD=%s\n' "$S_RD"
    printf 'PGBACKREST_REPO_BUCKET=example-bucket\nPGBACKREST_REPO_ENDPOINT=s3.example.invalid\n'
    printf 'PGBACKREST_REPO_REGION=us-east-1\nPGBACKREST_REPO_PATH=/test\n'
    printf 'PGBACKREST_REPO_KEY=%s\n' "$S_KEY"
    printf 'PGBACKREST_REPO_KEY_SECRET=%s\n' "$S_KEYSECRET"
    printf 'PGBACKREST_CIPHER_PASS=%s\n' "$S_CIPHER"
    printf 'HC_PG_BACKUP=https://hc.example.invalid/backup\nHC_PG_HEALTH=https://hc.example.invalid/health\n'
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } >"$env_file"
}
STANZA_OK='[{"name":"main","status":{"code":0,"message":"ok"}}]'
STANZA_NEW='[{"name":"main","status":{"code":2,"message":"no valid backups"}}]'
STANZA_NONE='[{"name":"main","status":{"code":1,"message":"missing stanza path"}}]'
scenario() {   # scenario DATA(empty|present) INFO_JSON INFO_RC RUNNING
  printf '%s\n' "$1" >"$SANDBOX/state/data"
  printf '%s\n' "$2" >"$SANDBOX/state/info"
  printf '%s\n' "$3" >"$SANDBOX/state/info_rc"
  printf '%s' "$4" >"$SANDBOX/state/running"
  # everything else answers "fine" until a test overrides it
  for f in ps_rc check_rc up_rc data_rc; do echo 0 >"$SANDBOX/state/$f"; done
  rm -f "$SANDBOX/state/notready"
  for f in check_out up_out data_err; do : >"$SANDBOX/state/$f"; done
  : >"$CALLS"; : >"$SANDBOX/log/sql"
}
run_deploy() { "$BIN/deploy.sh" "$env_file" >"$SANDBOX/log/out" 2>&1; rc=$?; }
line_no() { grep -nE "$1" "$CALLS" | head -1 | cut -d: -f1; }
before() {   # before A B: A is called, B is called, and A comes first
  local a b; a="$(line_no "$1")" b="$(line_no "$2")"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
out() { cat "$SANDBOX/log/out"; }

# --- first deploy: empty data, no stanza --------------------------------------------------------------
write_env
scenario empty "$STANZA_NONE" 0 ""
run_deploy
if [ "$rc" = 0 ]; then pass "first deploy exits 0"; else fail "first deploy exits 0" "rc=$rc $(out | tail -5)"; fi
if before 'compose .* up -d' 'stanza-create'; then pass "t_empty_data_no_stanza_creates: up, then stanza-create"; else fail "t_empty_data_no_stanza_creates" "$(cat "$CALLS")"; fi
if [ "$(cat "$ETC_DIR/allowlist")" = $'203.0.113.10\n203.0.113.11' ]; then
  pass "the allowlist is the unique client addresses"; else fail "allowlist" "$(cat "$ETC_DIR/allowlist" 2>&1)"; fi
if grep -q -- '-s 203.0.113.11/32 -j RETURN' "$SANDBOX/log/v4.rules"; then pass "the allowlist is applied"; else fail "allowlist applied" "no rule"; fi
if before '^iptables-restore' 'compose .* up -d'; then pass "the firewall goes up before Postgres"; else fail "firewall first" "$(cat "$CALLS")"; fi
if [ -s "$STATE_DIR/certs/server.pem" ]; then pass "certificates are generated"; else fail "certificates" "$(ls -R "$STATE_DIR" 2>&1)"; fi
hba="$STATE_DIR/config/pg_hba.conf"
if grep -q '^hostssl tgb tgb_reader 203.0.113.10/32 scram-sha-256$' "$hba" && [ -r "$hba" ]; then pass "pg_hba.conf is rendered and readable"; else fail "pg_hba.conf" "$(cat "$hba" 2>&1)"; fi
conf="$STATE_DIR/config/pgbackrest.conf"
if [ "$(stat -c '%a %u:%g' "$conf")" = "600 $PG_UID:$PG_GID" ]; then pass "pgbackrest.conf is 0600 and owned by the container user"; else fail "pgbackrest.conf mode" "$(stat -c '%a %u:%g' "$conf")"; fi
if grep -q '^repo1-s3-bucket=example-bucket$' "$conf" && grep -q "^repo1-s3-key-secret=$S_KEYSECRET\$" "$conf" && ! grep -q '\${' "$conf"; then
  pass "pgbackrest.conf is fully rendered"; else fail "pgbackrest.conf content" "$(sed 's/=.*key.*/=<hidden>/' "$conf")"; fi
if [ "$(( $(stat -c '%a' "$STATE_DIR/config") % 10 ))" -ge 5 ] || [ "$(stat -c '%u' "$STATE_DIR/config")" = "$PG_UID" ]; then
  pass "the config directory can be entered by the container user"; else fail "config dir" "$(stat -c '%a %u' "$STATE_DIR/config")"; fi
if [ -s "$STATE_DIR/config.sha256" ] && ! out | grep -qi 'restart'; then pass "first deploy stores a fingerprint without calling it a change"; else fail "first fingerprint" "$(out)"; fi
if ! called 'force-recreate' && ! called 'systemctl (restart|try-restart|reload-or-restart)'; then
  pass "t_never_restarts_firewall_unit: no restart of the unit, no recreate"; else fail "no restarts" "$(cat "$CALLS")"; fi
if grep -q 'PASSWORD' "$SANDBOX/log/sql" && called 'pg_ctl reload'; then pass "roles are applied and the config reloaded"; else fail "roles and reload" "$(cat "$CALLS")"; fi

# --- t_password_goes_by_stdin_not_argv --------------------------------------------------------------------
leaked=0
for s in "${SECRETS[@]}"; do if grep -qF "$s" "$CALLS"; then leaked=1; fi; done
if [ "$leaked" = 0 ]; then pass "t_password_goes_by_stdin_not_argv: no secret in any command's arguments"; else fail "secret in argv" "$(grep -F -f <(printf '%s\n' "${SECRETS[@]}") "$CALLS" | sed 's/[0-9a-f]\{64\}/<secret>/g')"; fi
if grep -qF "$S_APP" "$SANDBOX/log/sql"; then pass "...and the role passwords did reach psql by stdin"; else fail "stdin" "not in sql"; fi

# --- the backup and health jobs are installed ----------------------------------------------------------------------
bk="$ETC_DIR/backup.env"
if [ -f "$bk" ] && [ "$(stat -c %a "$bk")" = 600 ] && grep -q '^HC_PG_BACKUP=https://hc.example.invalid/backup$' "$bk" \
   && grep -q '^HC_PG_HEALTH=https://hc.example.invalid/health$' "$bk" && grep -q "^REPO_DIR=$SANDBOX/pg\$" "$bk"; then
  pass "t_deploy_installs_backup_units: backup.env is 0600 with both URLs and the compose directory"; else fail "t_deploy_installs_backup_units" "$(sed 's/=.*/=<hidden>/' "$bk" 2>&1)"; fi
if [ -x "$ROOT/usr/local/lib/postgres-backup/backup.sh" ] && [ -f "$ROOT/etc/systemd/system/postgres-backup.timer" ] \
   && called '^systemctl enable --now postgres-backup.timer postgres-backup-health.timer$'; then
  pass "t_deploy_installs_backup_units: scripts, units and both timers"; else fail "t_deploy_installs_backup_units" "$(cat "$CALLS")"; fi
if ! called 'systemctl (start|restart|try-restart|reload-or-restart)'; then pass "t_deploy_starts_no_backup: no unit is started or restarted"; else fail "t_deploy_starts_no_backup" "$(grep systemctl "$CALLS")"; fi

# --- t_existing_data_unchanged_no_restart ------------------------------------------------------------------
scenario present "$STANZA_OK" 0 "abc123"
run_deploy
if [ "$rc" = 0 ] && ! called 'force-recreate' && ! called ' restart' && called 'pg_ctl reload' && called 'up -d --no-recreate'; then
  pass "t_existing_data_unchanged_no_restart"; else fail "t_existing_data_unchanged_no_restart" "rc=$rc $(cat "$CALLS")"; fi
if ! called 'pgbackrest .*(stanza-create|stanza-upgrade| restore)'; then pass "an existing stanza is left alone"; else fail "stanza untouched" "$(cat "$CALLS")"; fi

# --- t_rotation_needs_no_restart -------------------------------------------------------------------------------
old_app="$S_APP"
write_env
scenario present "$STANZA_OK" 0 "abc123"
run_deploy
if [ "$rc" = 0 ] && grep -qF "ALTER ROLE tgb_app" "$SANDBOX/log/sql" && ! grep -qF "$old_app" "$SANDBOX/log/sql" \
   && ! called 'force-recreate'; then
  pass "t_rotation_needs_no_restart: new passwords applied, nothing recreated"; else fail "t_rotation_needs_no_restart" "rc=$rc $(out | tail -3)"; fi

# --- t_config_changed_stops_and_says_so ---------------------------------------------------------------------
echo "# changed" >>"$SANDBOX/pg/config/postgresql.conf"
scenario present "$STANZA_OK" 0 "abc123"
run_deploy
if [ "$rc" = 3 ] && out | grep -q 'POSTGRES_ALLOW_RESTART' && ! called 'compose .* up' && ! called 'force-recreate'; then
  pass "t_config_changed_stops_and_says_so: exit 3, says why, starts nothing"; else fail "config changed stops" "rc=$rc $(out | tail -4) $(cat "$CALLS")"; fi
scenario present "$STANZA_OK" 0 "abc123"
POSTGRES_ALLOW_RESTART=1 run_deploy
if [ "$rc" = 0 ] && called 'up -d --build --force-recreate'; then pass "with POSTGRES_ALLOW_RESTART=1 it recreates"; else fail "allow restart" "rc=$rc $(out | tail -4) $(cat "$CALLS")"; fi
scenario present "$STANZA_OK" 0 "abc123"
run_deploy
if [ "$rc" = 0 ] && ! called 'force-recreate'; then pass "after the restart the fingerprint matches again"; else fail "fingerprint updated" "rc=$rc $(out | tail -3)"; fi
echo "# changed again" >>"$SANDBOX/pg/Dockerfile"
scenario present "$STANZA_OK" 0 ""
run_deploy
if [ "$rc" = 0 ] && called 'compose .* up -d --build'; then pass "a change while Postgres is stopped just starts the new build"; else fail "stopped + changed" "rc=$rc $(out | tail -3) $(cat "$CALLS")"; fi
echo "# compose changed" >>"$SANDBOX/pg/compose.yml"
scenario present "$STANZA_OK" 0 "abc123"
run_deploy
if [ "$rc" = 3 ]; then pass "a compose.yml change counts as a restart-only change"; else fail "compose.yml fingerprint" "rc=$rc"; fi
POSTGRES_ALLOW_RESTART=1 run_deploy >/dev/null 2>&1

# --- no fingerprint on an already-running server (adopting it) ------------------------------------------------
rm -f "$STATE_DIR/config.sha256"
scenario present "$STANZA_OK" 0 "abc123"
run_deploy
if [ "$rc" = 0 ] && [ -s "$STATE_DIR/config.sha256" ] && ! called 'force-recreate'; then pass "a missing fingerprint is stored, not treated as a change"; else fail "adopt" "rc=$rc $(out | tail -3)"; fi

# --- t_empty_data_with_stanza_refuses ---------------------------------------------------------------------------
scenario empty "$STANZA_OK" 0 ""
run_deploy
if [ "$rc" != 0 ] && out | grep -q 'POSTGRES_BOOTSTRAP' && ! called 'compose .* up' && ! called 'stanza-'; then
  pass "t_empty_data_with_stanza_refuses: names POSTGRES_BOOTSTRAP, starts nothing"; else fail "t_empty_data_with_stanza_refuses" "rc=$rc $(out | tail -3) $(cat "$CALLS")"; fi
scenario empty "$STANZA_NEW" 0 ""
run_deploy
if [ "$rc" != 0 ] && ! called 'compose .* up'; then pass "a stanza with no backups yet still counts as a stanza"; else fail "stanza without backups" "rc=$rc"; fi

# --- t_bootstrap_restore_restores_before_start ---------------------------------------------------------------------
scenario empty "$STANZA_OK" 0 ""
POSTGRES_BOOTSTRAP=restore run_deploy
if [ "$rc" = 0 ] && before 'run --rm --no-deps -T postgres pgbackrest .*restore' 'compose .* up -d'; then
  pass "t_bootstrap_restore_restores_before_start"; else fail "t_bootstrap_restore_restores_before_start" "rc=$rc $(out | tail -3) $(cat "$CALLS")"; fi
if ! called 'stanza-create|stanza-upgrade'; then pass "a restore leaves the stanza alone"; else fail "restore stanza" "$(cat "$CALLS")"; fi
scenario empty "$STANZA_NONE" 0 ""
POSTGRES_BOOTSTRAP=restore run_deploy
if [ "$rc" != 0 ] && ! called 'compose .* up' && ! called ' restore'; then pass "restore with no stanza refuses: nothing to restore"; else fail "restore no stanza" "rc=$rc $(cat "$CALLS")"; fi
scenario present "$STANZA_OK" 0 "abc123"
POSTGRES_BOOTSTRAP=restore run_deploy
if [ "$rc" != 0 ] && ! called ' restore' && ! called 'compose .* up'; then pass "restore into a non-empty data directory refuses"; else fail "restore non-empty" "rc=$rc $(cat "$CALLS")"; fi

# --- new-cluster ---------------------------------------------------------------------------------------------------
scenario empty "$STANZA_OK" 0 ""
POSTGRES_BOOTSTRAP=new-cluster run_deploy
if [ "$rc" = 0 ] && out | grep -qi 'NEW, EMPTY' && out | grep -q '30-day retention' && before 'compose .* up -d' 'stanza-upgrade'; then
  pass "new-cluster over an existing stanza starts empty, says so, and upgrades the stanza"; else fail "new-cluster" "rc=$rc $(out | tail -4) $(cat "$CALLS")"; fi
# interrupted bootstrap: the first check fails (stanza describes the old cluster), upgrade fixes it
scenario present "$STANZA_OK" 0 "abc123"
printf '1\n0\n' >"$SANDBOX/state/check_rc"
POSTGRES_BOOTSTRAP=new-cluster run_deploy
first_check="$(line_no 'stanza=main check')" upg="$(line_no 'stanza-upgrade')" last_check="$(grep -n 'stanza=main check' "$CALLS" | tail -1 | cut -d: -f1)"
if [ "$rc" = 0 ] && [ -n "$upg" ] && [ "$first_check" -lt "$upg" ] && [ "$upg" -lt "$last_check" ] && ! called 'pgbackrest .* restore' && ! called 'stanza-create'; then
  pass "an interrupted new-cluster retry still recovers: failing check, stanza-upgrade, passing check"; else fail "new-cluster retry" "rc=$rc $(out | tail -3) $(cat "$CALLS")"; fi
# a leftover value on a healthy cluster
scenario present "$STANZA_OK" 0 "abc123"
POSTGRES_BOOTSTRAP=new-cluster run_deploy
if [ "$rc" != 0 ] && out | grep -q 'Unset POSTGRES_BOOTSTRAP' && ! called 'stanza-upgrade' && ! called 'pg_ctl reload'; then
  pass "a leftover new-cluster on a healthy cluster refuses and says to unset it"; else fail "sticky new-cluster" "rc=$rc $(out | tail -3) $(cat "$CALLS")"; fi
scenario empty "$STANZA_NONE" 0 ""
POSTGRES_BOOTSTRAP=new-cluster run_deploy
if [ "$rc" = 0 ] && called 'stanza-create'; then pass "new-cluster with no stanza behaves like a first deploy"; else fail "new-cluster no stanza" "rc=$rc $(out | tail -3)"; fi
scenario empty "$STANZA_NONE" 0 ""
POSTGRES_BOOTSTRAP=sometimes run_deploy
if [ "$rc" = 2 ] && out | grep -q 'POSTGRES_BOOTSTRAP' && ! called '.'; then pass "any other POSTGRES_BOOTSTRAP value is rejected before anything runs"; else fail "bad bootstrap" "rc=$rc $(cat "$CALLS")"; fi

# --- the three stanza answers --------------------------------------------------------------------------------------
scenario present "$STANZA_OK" 0 "abc123"; run_deploy
rc_present="$rc"
scenario present "$STANZA_NONE" 0 "abc123"; run_deploy
if [ "$rc_present" = 0 ] && [ "$rc" = 0 ] && called 'stanza-create'; then
  pass "stanza present and stanza absent are both told apart (existing data, absent: created)"; else fail "present vs none" "present=$rc_present none=$rc"; fi
for bad in "0|[]" "0|[{\"name\":\"other\",\"status\":{\"code\":1,\"message\":\"x\"}}]" "1|ERROR: [056]: unable to list" "0|not json at all" "0|[{\"name\":\"main\",\"status\":{\"code\":99,\"message\":\"other\"}}]" "0|"; do
  scenario empty "${bad#*|}" "${bad%%|*}" ""
  run_deploy
  if [ "$rc" != 0 ] && ! called 'compose .* up' && ! called 'stanza-' && out | grep -qi 'backup repo'; then
    pass "t_stanza_failure_stops: '${bad#*|}' (exit ${bad%%|*}) is not read as no stanza"; else fail "stanza failure" "rc=$rc $(out | tail -3) $(cat "$CALLS")"; fi
done
scenario present "ERROR" 1 "abc123"; run_deploy
if [ "$rc" != 0 ] && ! called 'compose .* up'; then pass "a failing repo also stops a deploy with existing data"; else fail "failure with data" "rc=$rc"; fi
scenario "neither" "$STANZA_NONE" 0 ""; run_deploy
if [ "$rc" != 0 ] && ! called 'compose .* up'; then pass "an unreadable data-directory check stops the deploy"; else fail "data check failure" "rc=$rc"; fi

# --- the restart gate fails closed when `ps` fails ------------------------------------------------------------------
echo "# changed for ps test" >>"$SANDBOX/pg/Dockerfile"
scenario present "$STANZA_OK" 0 "abc123"
echo 1 >"$SANDBOX/state/ps_rc"
run_deploy
if [ "$rc" != 0 ] && ! called 'compose .* up' && ! called 'force-recreate'; then
  pass "t_ps_failure_stops: a failing ps neither recreates nor starts anything"; else fail "ps failure" "rc=$rc $(out | tail -3) $(cat "$CALLS")"; fi
scenario present "$STANZA_OK" 0 "abc123"
POSTGRES_ALLOW_RESTART=1 run_deploy

# --- a green deploy means archiving works ----------------------------------------------------------------------------
scenario present "$STANZA_OK" 0 "abc123"
run_deploy
if [ "$rc" = 0 ] && called 'stanza=main check'; then pass "check runs on an ordinary deploy"; else fail "check on every deploy" "rc=$rc"; fi
if [ "$(grep -c 'pg_isready' "$CALLS")" -ge 2 ]; then pass "readiness has to pass twice"; else fail "ready twice" "$(grep -c pg_isready "$CALLS")"; fi
scenario present "$STANZA_OK" 0 "abc123"
echo 1 >"$SANDBOX/state/check_rc"
echo "ERROR: [028]: backup and archive info files exist but do not match the database (s3://SECRETBUCKET/secret/path)" >"$SANDBOX/state/check_out"
run_deploy
if [ "$rc" != 0 ] && out | grep -q 'check' && out | grep -q '\[028\]' && out | grep -q 'NOT working' && before 'pg_ctl reload' 'stanza=main check'; then
  pass "t_check_failure_fails_the_deploy: names check and [028], and runs after roles and reload"; else fail "check failure" "rc=$rc $(out | tail -3)"; fi
if ! out | grep -q 'SECRETBUCKET'; then pass "t_no_repo_details_in_output: the bucket is not in deploy.sh's output"; else fail "bucket leaked" "$(out)"; fi
if grep -q 'SECRETBUCKET' "$STATE_DIR/state/deploy.log" && [ "$(stat -c %a "$STATE_DIR/state")" = 700 ]; then
  pass "the full output is kept in a 0700 directory"; else fail "log file" "$(ls -la "$STATE_DIR/state" 2>&1)"; fi
scenario empty "$STANZA_NONE" 0 ""
echo 1 >"$SANDBOX/state/check_rc"; echo "[028] s3://SECRETBUCKET" >"$SANDBOX/state/check_out"
run_deploy
if [ "$rc" != 0 ]; then pass "check also fails a first deploy"; else fail "check on first deploy" "rc=$rc"; fi
scenario empty "$STANZA_NONE" 0 ""
run_deploy
if before 'stanza-create' 'stanza=main check'; then pass "check comes after stanza-create"; else fail "check order" "$(cat "$CALLS")"; fi

# --- log wording is neutral on success; timeouts and restores ---------------------------------------------------------
scenario present "$STANZA_OK" 0 "abc123"; run_deploy
if grep -q 'pgbackrest check (exit 0)' "$STATE_DIR/state/deploy.log"; then pass "a passing check is logged neutrally"; else fail "neutral log" "$(grep 'check' "$STATE_DIR/state/deploy.log" | tail -2)"; fi
scenario present "$STANZA_OK" 0 "abc123"; touch "$SANDBOX/state/notready"
WAIT_TRIES=2 WAIT_TRIES_RESTORE=5 run_deploy
if [ "$rc" != 0 ] && out | grep -q 'docker compose' && out | grep -q 'logs' && [ "$(grep -c pg_isready "$CALLS")" = 2 ]; then
  pass "a readiness timeout points at docker compose logs"; else fail "timeout message" "rc=$rc $(out | tail -2) n=$(grep -c pg_isready "$CALLS")"; fi
scenario empty "$STANZA_OK" 0 ""; touch "$SANDBOX/state/notready"
POSTGRES_BOOTSTRAP=restore WAIT_TRIES=2 WAIT_TRIES_RESTORE=5 run_deploy
if [ "$rc" != 0 ] && [ "$(grep -c pg_isready "$CALLS")" = 5 ] && out | grep -q 'starting restore'; then
  pass "a restore announces itself and waits on the longer limit"; else fail "restore wait" "rc=$rc n=$(grep -c pg_isready "$CALLS") $(out | tail -3)"; fi

# --- no pgBackRest or Docker output reaches deploy.sh's output ---------------------------------------------------------
leak_case() {   # leak_case DESCRIPTION  (state already set up by the caller)
  run_deploy
  if [ "$rc" != 0 ] && ! out | grep -q 'SECRETBUCKET'; then pass "t_no_repo_details_in_output: $1"; else fail "$1" "rc=$rc $(out | tail -4)"; fi
}
scenario empty "[ProtocolError] unable to list s3://SECRETBUCKET/p" 1 ""; leak_case "pgbackrest info failure"
scenario present "$STANZA_OK" 0 "abc"; echo 1 >"$SANDBOX/state/up_rc"; echo "pull access denied for SECRETBUCKET" >"$SANDBOX/state/up_out"; leak_case "docker compose up failure"
scenario present "$STANZA_OK" 0 "abc"; echo 1 >"$SANDBOX/state/ps_rc"; leak_case "docker compose ps failure"
scenario present "$STANZA_OK" 0 "abc"; echo 17 >"$SANDBOX/state/data_rc"; echo "build failed SECRETBUCKET" >"$SANDBOX/state/data_err"
leak_case "image build failure"
if out | grep -qi 'image build' && out | grep -q 'exit 17' && ! out | grep -q 'could not tell'; then
  pass "a failed build is reported as a failed build, not as an unreadable data directory"; else fail "build failure message" "$(out)"; fi

# --- die does not print its exit code ----------------------------------------------------------------------------------
write_env; grep -v '^HC_PG_HEALTH=' "$env_file" >"$env_file.new"; mv "$env_file.new" "$env_file"
run_deploy
if ! out | grep -qE ' 2$'; then pass "the missing-variable message does not end in an exit code"; else fail "die prints code" "$(out)"; fi
write_env

# --- t_bad_clients_fails_before_changes -----------------------------------------------------------------------------
cp "$ETC_DIR/allowlist" "$SANDBOX/allowlist.before"
for bad in "tgb_app tgb nope" "tgb_app the_greatest 203.0.113.10" "tgb_app tgb 203.0.113.10/24" "root tgb 203.0.113.10" "tgb_app tgb" ""; do
  CLIENTS="$bad"; write_env; scenario present "$STANZA_OK" 0 "abc123"
  run_deploy
  if [ "$rc" != 0 ] && ! called '.' && cmp -s "$ETC_DIR/allowlist" "$SANDBOX/allowlist.before"; then
    pass "t_bad_clients_fails_before_changes: '$bad'"; else fail "bad clients '$bad'" "rc=$rc $(cat "$CALLS")"; fi
done
CLIENTS='the_greatest the_greatest 203.0.113.10;tgb_app tgb 203.0.113.11;tgb_reader tgb 203.0.113.10'

# --- t_missing_var_names_it -------------------------------------------------------------------------------------------
required="POSTGRES_CLIENTS POSTGRES_SUPERUSER_PASSWORD POSTGRES_THE_GREATEST_PASSWORD POSTGRES_TGB_APP_PASSWORD POSTGRES_TGB_READER_PASSWORD PGBACKREST_REPO_BUCKET PGBACKREST_REPO_ENDPOINT PGBACKREST_REPO_REGION PGBACKREST_REPO_PATH PGBACKREST_REPO_KEY PGBACKREST_REPO_KEY_SECRET PGBACKREST_CIPHER_PASS HC_PG_BACKUP HC_PG_HEALTH"
for v in $required; do
  write_env; grep -v "^$v=" "$env_file" >"$env_file.new"; mv "$env_file.new" "$env_file"
  scenario present "$STANZA_OK" 0 "abc123"
  run_deploy
  if [ "$rc" = 2 ] && out | grep -q "$v" && ! called '.'; then pass "t_missing_var_names_it: $v"; else fail "missing $v" "rc=$rc $(out | tail -2) $(cat "$CALLS")"; fi
done
write_env "POSTGRES_TGB_APP_PASSWORD="
scenario present "$STANZA_OK" 0 "abc123"; run_deploy
if [ "$rc" = 2 ] && out | grep -q POSTGRES_TGB_APP_PASSWORD; then pass "an empty value counts as missing"; else fail "empty value" "rc=$rc"; fi

# --- the port is not configurable here ----------------------------------------------------------------------------------
write_env "POSTGRES_PORT=6544"
scenario present "$STANZA_OK" 0 "abc123"; run_deploy
if [ "$rc" = 2 ] && out | grep -q POSTGRES_PORT && ! called '.'; then pass "POSTGRES_PORT is refused: the firewall covers one port"; else fail "port override" "rc=$rc"; fi

if ! "$BIN/deploy.sh" >/dev/null 2>&1; then pass "no ENV_FILE argument is refused"; else fail "no ENV_FILE argument is refused" "exit 0"; fi
finish
