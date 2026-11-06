#!/usr/bin/env bash
# Unit test for deployment/opensearch/bin/deploy.sh. Docker, systemctl and iptables are stubbed;
# certificates are real (openssl), hashing is faked.
# shellcheck disable=SC2016  # stub bodies and bcrypt strings are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
cat >"$SANDBOX/bin/fakehash" <<'EOF'
#!/usr/bin/env bash
printf '$2y$12$%s\n' "$(command -p cat | command -p sha256sum | command -p head -c 53)"
EOF
chmod +x "$SANDBOX/bin/fakehash"
stub systemctl ''
stub iptables-restore 'command -p cat >"$SANDBOX/log/v4.rules"'
stub ip6tables-restore 'command -p cat >/dev/null'
stub docker 'case "$*" in *curl*) printf 401 ;; esac'
OS_UID="$(id -u)" OS_GID="$(id -g)"
export NO_SUDO=1 OS_UID OS_GID HASH_CMD=fakehash ROOT="$SANDBOX/root"
export STATE_DIR="$SANDBOX/srv" ETC_DIR="$SANDBOX/etc" ALLOWLIST="$SANDBOX/etc/allowlist"
env_file="$SANDBOX/env"
write_env() {   # write_env ALLOWED_IPS [APP_PASSWORD]
  printf 'OPENSEARCH_ALLOWED_IPS="%s"\nOPENSEARCH_ADMIN_PASSWORD=%s\nOPENSEARCH_APP_PASSWORD=%s\nOPENSEARCH_LEGACY_PASSWORD=%s\n' \
    "$1" "$(openssl rand -hex 32)" "${2-$(openssl rand -hex 32)}" "$(openssl rand -hex 32)" >"$env_file"
}
line_no() { grep -nE "$1" "$CALLS" | head -1 | cut -d: -f1; }

# --- first deploy -------------------------------------------------------------------------
write_env "203.0.113.10, 203.0.113.11"
"$BIN/deploy.sh" "$env_file" >"$SANDBOX/log/out" 2>&1; rc=$?
if [ "$rc" = 0 ]; then pass "first deploy exits 0"; else fail "first deploy exits 0" "rc=$rc $(tail -5 "$SANDBOX/log/out")"; fi
if [ "$(cat "$ETC_DIR/allowlist")" = $'203.0.113.10\n203.0.113.11' ]; then
  pass "a comma-and-space list becomes one address per line"; else fail "allowlist file" "$(cat "$ETC_DIR/allowlist" 2>&1)"; fi
if grep -q -- '-s 203.0.113.11/32 -j RETURN' "$SANDBOX/log/v4.rules"; then pass "the allowlist is applied"; else fail "the allowlist is applied" "no rule"; fi
if [ -f "$STATE_DIR/certs/node.pem" ] && [ -f "$STATE_DIR/security/internal_users.yml" ] && [ -f "$STATE_DIR/security/roles.yml" ]; then
  pass "certificates and the security directory are in place"; else fail "certs and security dir" "$(ls -R "$STATE_DIR" 2>&1)"; fi
if called 'compose .* up -d --force-recreate$'; then pass "first deploy force-recreates"; else fail "first deploy force-recreates" "$(cat "$CALLS")"; fi
if called 'securityadmin.sh'; then pass "the security config is loaded"; else fail "the security config is loaded" "$(cat "$CALLS")"; fi
fw="$(line_no '^iptables-restore')" up="$(line_no 'compose .* up -d')"
if [ -n "$fw" ] && [ -n "$up" ] && [ "$fw" -lt "$up" ]; then pass "the firewall goes up before OpenSearch"; else fail "firewall before OpenSearch" "fw=$fw up=$up"; fi

# --- second deploy, nothing changed ---------------------------------------------------------
before="$(sha256sum "$STATE_DIR/certs/node.pem")"
: >"$CALLS"
write_env "203.0.113.10 203.0.113.11"
"$BIN/deploy.sh" "$env_file" >"$SANDBOX/log/out" 2>&1; rc=$?
if [ "$rc" = 0 ] && called 'compose .* up -d$' && ! called 'force-recreate'; then
  pass "an unchanged redeploy does not restart OpenSearch"; else fail "unchanged redeploy" "rc=$rc $(cat "$CALLS")"; fi
if [ "$(sha256sum "$STATE_DIR/certs/node.pem")" = "$before" ]; then pass "certificates are kept"; else fail "certificates are kept" "regenerated"; fi

# --- a bad allowlist leaves the running one alone -------------------------------------------
: >"$CALLS"
write_env "203.0.113.10 nope"
"$BIN/deploy.sh" "$env_file" >"$SANDBOX/log/out" 2>&1; rc=$?
if [ "$rc" != 0 ] && [ "$(cat "$ETC_DIR/allowlist")" = $'203.0.113.10\n203.0.113.11' ] && ! called 'compose|restore'; then
  pass "a bad allowlist fails before touching anything"; else fail "a bad allowlist" "rc=$rc $(cat "$CALLS")"; fi

# --- a missing password stops everything -----------------------------------------------------
: >"$CALLS"
write_env "203.0.113.10" ""
"$BIN/deploy.sh" "$env_file" >"$SANDBOX/log/out" 2>&1; rc=$?
if [ "$rc" = 2 ] && ! called '.'; then pass "a missing password stops the deploy before anything runs"; else fail "missing password" "rc=$rc $(cat "$CALLS")"; fi

# --- a port override would open a port the firewall does not cover ------------------------------
: >"$CALLS"
write_env "203.0.113.10"
echo 'OPENSEARCH_PORT=9201' >>"$env_file"
"$BIN/deploy.sh" "$env_file" >"$SANDBOX/log/out" 2>&1; rc=$?
if [ "$rc" = 2 ] && ! called '.'; then pass "OPENSEARCH_PORT in the env file is refused"; else fail "port in env file" "rc=$rc $(cat "$CALLS")"; fi
: >"$CALLS"
write_env "203.0.113.10"
OPENSEARCH_PORT=9201 "$BIN/deploy.sh" "$env_file" >"$SANDBOX/log/out" 2>&1; rc=$?
if [ "$rc" = 2 ] && ! called '.'; then pass "OPENSEARCH_PORT in the caller's environment is refused"; else fail "port in caller env" "rc=$rc $(cat "$CALLS")"; fi

if ! "$BIN/deploy.sh" >/dev/null 2>&1; then pass "no ENV_FILE argument is refused"; else fail "no ENV_FILE argument is refused" "exit 0"; fi
finish
