#!/usr/bin/env bash
# Unit test for deployment/postgres/bin/render-hba.sh. Needs python3.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
render="$BIN/render-hba.sh"
clients="$SANDBOX/clients"
# Rule lines only: the output starts with comment lines that must not count.
rules() { grep -vE '^[[:space:]]*(#|$)' <<<"$1"; }

printf '# who connects from where\nthe_greatest the_greatest 192.0.2.10\n\ntgb_app tgb 192.0.2.20  # old site\ntgb_reader tgb 192.0.2.10\n' >"$clients"
out="$("$render" "$clients")"; rc=$?
hostssl="$(rules "$out" | grep -c '^hostssl ')"
if [ "$rc" = 0 ] && [ "$hostssl" = 3 ] \
  && rules "$out" | grep -qxF 'hostssl the_greatest the_greatest 192.0.2.10/32 scram-sha-256' \
  && rules "$out" | grep -qxF 'hostssl tgb tgb_app 192.0.2.20/32 scram-sha-256' \
  && rules "$out" | grep -qxF 'hostssl tgb tgb_reader 192.0.2.10/32 scram-sha-256'; then
  pass "t_one_line_per_client"; else fail "t_one_line_per_client" "rc=$rc count=$hostssl: $out"; fi

printf 'tgb_reader tgb 2001:db8::10\n' >"$clients"
out="$("$render" "$clients" 2>"$SANDBOX/err")"; rc=$?
if [ "$rc" = 0 ] && rules "$out" | grep -qxF 'hostssl tgb tgb_reader 2001:db8::10/128 scram-sha-256'; then
  pass "t_ipv6_client_renders_128"; else fail "t_ipv6_client_renders_128" "$out"; fi
# The port binds IPv4 only, so this client can never connect: said out loud, not a failure. The workflow log is
# public, so the warning gives the line number and not the address.
if grep -q 'line 1' "$SANDBOX/err" && grep -qi 'ipv6' "$SANDBOX/err" && ! grep -q '2001:db8' "$SANDBOX/err" && ! grep -q 'WARNING' <<<"$out"; then
  pass "an IPv6 client warns on stderr, names no address, and stays out of the file"; else fail "IPv6 client warning" "$(cat "$SANDBOX/err")"; fi
printf 'tgb_reader tgb 192.0.2.10\n' >"$clients"
"$render" "$clients" >/dev/null 2>"$SANDBOX/err"
if [ ! -s "$SANDBOX/err" ]; then pass "an IPv4 client prints no warning"; else fail "IPv4 client warning" "$(cat "$SANDBOX/err")"; fi

printf 'the_greatest the_greatest 192.0.2.10\ntgb_app tgb 192.0.2.20\n' >"$clients"
out="$("$render" "$clients")"
if [ -n "$out" ] && ! rules "$out" | grep -qE '^(host|hostnossl)[[:space:]]'; then
  pass "t_no_plain_host_rule"; else fail "t_no_plain_host_rule" "$out"; fi
if rules "$out" | grep -q '^hostssl ' && ! rules "$out" | grep '^hostssl ' | awk '$2 == "all" || $3 == "all" {f=1} END {exit !f}'; then
  pass "t_no_all_on_network_rule"; else fail "t_no_all_on_network_rule" "$out"; fi
locals="$(rules "$out" | grep -c '^local ')"
if [ "$locals" = 1 ] && rules "$out" | grep -qxE 'local[[:space:]]+all[[:space:]]+postgres[[:space:]]+peer'; then
  pass "t_local_is_peer"; else fail "t_local_is_peer" "$out"; fi

# Exit 2 and print nothing, so a bad SOPS value fails the deploy instead of rendering half a file.
rejects() {   # rejects <name> <file contents for printf %b>
  local name="$1" out rc
  printf '%b' "$2" >"$clients"
  out="$("$render" "$clients" 2>/dev/null)"; rc=$?
  if [ "$rc" = 2 ] && [ -z "$out" ]; then pass "t_rejects: $name"; else fail "t_rejects: $name" "exit $rc, out: $out"; fi
}
rejects "an empty file" ''
rejects "a comments-only file" '# nobody\n'
rejects "CIDR input" 'tgb_app tgb 192.0.2.0/24\n'
rejects "0.0.0.0" 'tgb_app tgb 0.0.0.0\n'
rejects "::" 'tgb_app tgb ::\n'
rejects "role postgres" 'postgres tgb 192.0.2.10\n'
rejects "an unknown role" 'intruder tgb 192.0.2.10\n'
rejects "the_greatest on tgb" 'the_greatest tgb 192.0.2.10\n'
rejects "tgb_app on the_greatest" 'tgb_app the_greatest 192.0.2.10\n'
rejects "tgb_reader on the_greatest" 'tgb_reader the_greatest 192.0.2.10\n'
rejects "database all" 'tgb_app all 192.0.2.10\n'
rejects "a hostname" 'tgb_app tgb db.example.com\n'
rejects "a missing address" 'tgb_app tgb\n'
rejects "an extra column" 'tgb_app tgb 192.0.2.10 extra\n'
rejects "an IPv4-mapped address" 'tgb_app tgb ::ffff:192.0.2.10\n'
rejects "a scoped IPv6 address" 'tgb_app tgb fe80::1%eth0\n'
rejects "one bad line among good ones" 'tgb_app tgb 192.0.2.10\nnope\n'
out="$("$render" "$SANDBOX/nope" 2>/dev/null)"; rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ]; then pass "t_rejects: a missing file"; else fail "t_rejects: a missing file" "exit $rc"; fi
finish
