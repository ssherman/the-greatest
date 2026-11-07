#!/usr/bin/env bash
# Unit test for deployment/postgres/bin/generate-certs.sh. Needs openssl.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
dir="$SANDBOX/certs"
gen="$BIN/generate-certs.sh"
me_uid="$(id -u)"; me_gid="$(id -g)"
mkdir -m 755 "$dir"   # pre-existing and too open: the script must tighten it

out="$("$gen" "$dir" "$me_uid" "$me_gid" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q '^generated' <<<"$out"; then pass "first run generates"; else fail "first run generates" "rc=$rc $out"; fi
if [ "$(cd "$dir" && printf '%s ' *)" = "server-key.pem server.pem " ]; then pass "exactly key and certificate"; else fail "exactly key and certificate" "$(ls "$dir")"; fi
if [ "$(stat -c %a "$dir/server-key.pem")" = 600 ]; then pass "key is 0600"; else fail "key is 0600" "$(stat -c %a "$dir/server-key.pem")"; fi
if [ "$(stat -c '%u:%g' "$dir/server-key.pem")" = "$me_uid:$me_gid" ]; then pass "key owned by the given uid:gid"; else fail "key owner" "$(stat -c '%u:%g' "$dir/server-key.pem")"; fi
# A bind-mounted directory keeps its host permissions: if it is not owned by the container user,
# Postgres cannot even open the key.
if [ "$(stat -c '%a %u:%g' "$dir")" = "700 $me_uid:$me_gid" ]; then pass "directory is 0700 and owned by uid:gid"; else fail "directory mode/owner" "$(stat -c '%a %u:%g' "$dir")"; fi
if openssl x509 -in "$dir/server.pem" -noout -checkend $((9 * 365 * 86400)) >/dev/null; then pass "valid more than 9 years"; else fail "validity" "under 9 years"; fi
if ! openssl x509 -in "$dir/server.pem" -noout -checkend $((11 * 365 * 86400)) >/dev/null; then pass "valid under 11 years"; else fail "validity" "over 11 years"; fi
if [ "$(openssl x509 -in "$dir/server.pem" -noout -pubkey)" = "$(openssl pkey -in "$dir/server-key.pem" -pubout)" ]; then
  pass "key matches certificate"; else fail "key matches certificate" "mismatch"; fi
if openssl x509 -in "$dir/server.pem" -noout -ext subjectAltName | grep -q 'DNS:localhost'; then pass "names localhost"; else fail "SAN" "no localhost"; fi

before="$(sha256sum "$dir"/server.pem "$dir"/server-key.pem)"
out="$("$gen" "$dir" "$me_uid" "$me_gid" 2>&1)"
if [ "$(sha256sum "$dir"/server.pem "$dir"/server-key.pem)" = "$before" ] && grep -q '^present' <<<"$out"; then
  pass "a second run leaves both byte-identical"; else fail "second run" "$out"; fi

rm "$dir/server.pem"
"$gen" "$dir" "$me_uid" "$me_gid" >/dev/null 2>&1
if [ -s "$dir/server.pem" ] && [ "$(openssl x509 -in "$dir/server.pem" -noout -pubkey)" = "$(openssl pkey -in "$dir/server-key.pem" -pubout)" ]; then
  pass "a partial set is regenerated whole"; else fail "partial set" "$(ls "$dir")"; fi
if ! "$gen" >/dev/null 2>&1; then pass "no DIR is refused"; else fail "no DIR is refused" "exit 0"; fi
finish
