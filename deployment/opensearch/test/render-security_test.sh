#!/usr/bin/env bash
# Unit test for deployment/opensearch/bin/render-security.sh and the security/ files it ships.
# Hashing is faked: a bcrypt-shaped string derived from the password, so no Java or Docker.
# shellcheck disable=SC2016  # stub bodies and bcrypt strings are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
cat >"$SANDBOX/bin/fakehash" <<'EOF'
#!/usr/bin/env bash
pw="$(command -p cat)"
printf '$2y$12$%s\n' "$(printf %s "$pw" | command -p sha256sum | command -p head -c 53)"
EOF
chmod +x "$SANDBOX/bin/fakehash"
expected_hash() { printf '$2y$12$%s' "$(printf %s "$1" | sha256sum | head -c 53)"; }
admin_pw="$(openssl rand -hex 32)" app_pw="$(openssl rand -hex 32)" legacy_pw="$(openssl rand -hex 32)"
render() {   # render OUT_DIR [VAR=value ...]
  local out="$1"; shift
  env HASH_CMD=fakehash OPENSEARCH_ADMIN_PASSWORD="$admin_pw" OPENSEARCH_APP_PASSWORD="$app_pw" \
    OPENSEARCH_LEGACY_PASSWORD="$legacy_pw" "$@" "$BIN/render-security.sh" "$out"
}
out="$SANDBOX/security"
users="$out/internal_users.yml"

render "$out" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && [ -f "$users" ]; then pass "renders internal_users.yml"; else fail "renders internal_users.yml" "rc=$rc"; fi
hash_of_user() { grep -A1 -x "$1:" "$users" | sed -n 's/^  hash: "\(.*\)"$/\1/p'; }
if [ "$(hash_of_user admin)" = "$(expected_hash "$admin_pw")" ] && [ "$(hash_of_user the_greatest_app)" = "$(expected_hash "$app_pw")" ] \
  && [ "$(hash_of_user tgb_legacy)" = "$(expected_hash "$legacy_pw")" ]; then
  pass "each user gets the hash of its own password"; else fail "each user gets its own hash" "$(cat "$users")"; fi
if ! grep -rqF -e "$admin_pw" -e "$app_pw" -e "$legacy_pw" "$out"; then
  pass "no plain password reaches the directory"; else fail "no plain password reaches the directory" "found one"; fi
if [ "$(grep -E '^[a-z_]+:$' "$users" | grep -v '^_meta:$' | tr '\n' ' ')" = "admin: the_greatest_app: tgb_legacy: " ]; then
  pass "exactly admin, the_greatest_app, tgb_legacy (no demo users)"; else fail "exactly three users" "$(grep -E '^[a-z_]+:$' "$users")"; fi
for u in admin the_greatest_app tgb_legacy; do
  if grep -A3 -x "$u:" "$users" | grep -qx '  reserved: true'; then pass "$u is reserved (cannot change its own password)"
  else fail "$u is reserved" "$(cat "$users")"; fi
done
if ! grep -q '@[A-Z_]*_HASH@' "$users"; then pass "no placeholder left"; else fail "no placeholder left" "$(cat "$users")"; fi
for f in config roles roles_mapping action_groups tenants nodes_dn allowlist audit; do
  if [ -f "$out/$f.yml" ]; then pass "$f.yml is copied"; else fail "$f.yml is copied" "missing"; fi
done
if [ ! -e "$out/internal_users.yml.tmpl" ]; then pass "the template is not copied"; else fail "the template is not copied" "present"; fi

# The shipped roles and mappings: each site sees only its own indexes.
roles="$OS_DIR/security/roles.yml" mapping="$OS_DIR/security/roles_mapping.yml"
if grep -A3 -x 'the_greatest_app:' "$roles" | grep -qxF '    - index_patterns: ["books_*_production", "music_*_production", "games_*_production"]'; then
  pass "the_greatest_app: only the new app's index patterns"; else fail "the_greatest_app patterns" "$(cat "$roles")"; fi
if grep -A3 -x 'tgb_legacy:' "$roles" | grep -qxF '    - index_patterns: ["books", "authors"]'; then
  pass "tgb_legacy: only the old site's indexes"; else fail "tgb_legacy patterns" "$(cat "$roles")"; fi
if ! grep -qE 'index_patterns:.*"\*"' "$roles"; then pass "no role matches every index"; else fail "no role matches every index" "wildcard"; fi
if [ "$(grep -oE 'users: \[[^]]*\]' "$mapping" | tr '\n' ' ')" = 'users: ["admin"] users: ["the_greatest_app"] users: ["tgb_legacy"] ' ]; then
  pass "mappings name only our three users"; else fail "mappings" "$(cat "$mapping")"; fi
if grep -q 'anonymous_auth_enabled: false' "$OS_DIR/security/config.yml"; then pass "no anonymous access"; else fail "no anonymous access" "missing"; fi

# Refusals write nothing.
refuses() {   # refuses <name> <VAR=value ...>
  local name="$1" dir="$SANDBOX/refused-$RANDOM" rc
  shift
  render "$dir" "$@" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 2 ] && [ ! -e "$dir/internal_users.yml" ]; then pass "$name"; else fail "$name" "rc=$rc"; fi
}
refuses "a missing password is refused" OPENSEARCH_APP_PASSWORD=
refuses "a short password is refused" OPENSEARCH_LEGACY_PASSWORD=abc123
refuses "a password with URL-breaking characters is refused" OPENSEARCH_ADMIN_PASSWORD="$(openssl rand -hex 16)@$(openssl rand -hex 16)"
stub badhash 'echo oops'
refuses "a hash command that prints no bcrypt hash is refused" HASH_CMD=badhash

# Re-rendering replaces the file (new passwords -> new hashes).
old="$(hash_of_user admin)"
admin_pw="$(openssl rand -hex 32)"
render "$out" >/dev/null 2>&1
if [ "$(hash_of_user admin)" != "$old" ]; then pass "re-rendering replaces the users file"; else fail "re-rendering replaces the users file" "unchanged"; fi
finish
