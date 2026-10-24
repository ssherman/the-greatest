#!/usr/bin/env bash
# Unit test for deployment/opensearch/bin/generate-certs.sh. Needs openssl.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
dir="$SANDBOX/certs"
gen="$BIN/generate-certs.sh"

out="$("$gen" "$dir" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q '^generated' <<<"$out"; then pass "first run generates"; else fail "first run generates" "rc=$rc $out"; fi
if [ "$(cd "$dir" && printf '%s ' *)" = "admin-key.pem admin.pem node-key.pem node.pem root-ca-key.pem root-ca.pem " ]; then
  pass "exactly the six files, no leftovers"; else fail "exactly the six files" "$(ls "$dir")"; fi
subject() { openssl x509 -in "$1" -noout -subject -nameopt RFC2253 | sed 's/^subject=//'; }
if [ "$(subject "$dir/node.pem")" = "CN=search-node,OU=search,O=the-greatest" ]; then
  pass "node subject matches plugins.security.nodes_dn"; else fail "node subject" "$(subject "$dir/node.pem")"; fi
if [ "$(subject "$dir/admin.pem")" = "CN=admin,OU=search,O=the-greatest" ]; then
  pass "admin subject matches plugins.security.authcz.admin_dn"; else fail "admin subject" "$(subject "$dir/admin.pem")"; fi
if openssl verify -CAfile "$dir/root-ca.pem" "$dir/node.pem" "$dir/admin.pem" >/dev/null 2>&1; then
  pass "both certificates chain to the CA"; else fail "both certificates chain to the CA" "openssl verify failed"; fi
# OpenSearch reads PKCS#8 only; a "BEGIN RSA PRIVATE KEY" file stops the node from starting.
if [ "$(head -1 "$dir/node-key.pem")" = "-----BEGIN PRIVATE KEY-----" ] && [ "$(head -1 "$dir/admin-key.pem")" = "-----BEGIN PRIVATE KEY-----" ]; then
  pass "keys are PKCS#8"; else fail "keys are PKCS#8" "$(head -1 "$dir/node-key.pem")"; fi
if openssl x509 -in "$dir/node.pem" -noout -ext subjectAltName | grep -q 'DNS:localhost'; then
  pass "node certificate names localhost (securityadmin and the healthcheck use it)"; else fail "node SAN" "no DNS:localhost"; fi
if openssl x509 -in "$dir/node.pem" -noout -checkend $((9 * 365 * 86400)) >/dev/null; then
  pass "node certificate outlives the server (>9 years)"; else fail "node certificate lifetime" "expires within 9 years"; fi
if [ "$(stat -c %a "$dir/root-ca-key.pem")" = 600 ] && [ "$(stat -c %a "$dir/node-key.pem")" = 600 ]; then
  pass "keys are 0600"; else fail "keys are 0600" "$(stat -c '%a %n' "$dir"/*key.pem)"; fi

before="$(sha256sum "$dir/node.pem")"
out="$("$gen" "$dir" 2>&1)"
if [ "$(sha256sum "$dir/node.pem")" = "$before" ] && grep -q '^present' <<<"$out"; then
  pass "a second run leaves a complete set alone"; else fail "a second run leaves a complete set alone" "$out"; fi

rm "$dir/admin.pem"
"$gen" "$dir" >/dev/null 2>&1
if [ -f "$dir/admin.pem" ] && [ "$(sha256sum "$dir/node.pem")" != "$before" ] \
  && openssl verify -CAfile "$dir/root-ca.pem" "$dir/node.pem" "$dir/admin.pem" >/dev/null 2>&1; then
  pass "a partial set is regenerated whole"; else fail "a partial set is regenerated whole" "$(ls "$dir")"; fi

if ! "$gen" >/dev/null 2>&1; then pass "no DIR argument is refused"; else fail "no DIR argument is refused" "exit 0"; fi
finish
