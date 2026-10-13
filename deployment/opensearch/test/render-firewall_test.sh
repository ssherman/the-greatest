#!/usr/bin/env bash
# Unit test for deployment/opensearch/bin/render-firewall.sh. Needs python3.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
render="$BIN/render-firewall.sh"
list="$SANDBOX/allowlist"
drop='-A DOCKER-USER -p tcp -m conntrack --ctorigdstport 9200 --ctdir ORIGINAL -j DROP'
allow() { echo "-A DOCKER-USER -p tcp -m conntrack --ctorigdstport 9200 --ctdir ORIGINAL -s $1 -j RETURN"; }
has() { grep -qxF -- "$2" <<<"$1"; }
line_of() { grep -nxF -- "$2" <<<"$1" | head -1 | cut -d: -f1; }

# --- a valid list ------------------------------------------------------------------------
printf '# app servers\n203.0.113.10\n\n203.0.113.11  # worker\n2001:db8::10\n' >"$list"
v4="$("$render" --family v4 --allowlist "$list")"; rc=$?
if [ "$rc" = 0 ]; then pass "a valid allowlist renders"; else fail "a valid allowlist renders" "exit $rc"; fi
if has "$v4" "$(allow 203.0.113.10/32)" && has "$v4" "$(allow 203.0.113.11/32)"; then
  pass "v4: every IPv4 address is allowed"; else fail "v4: every IPv4 address is allowed" "$v4"; fi
if ! grep -q '2001:db8' <<<"$v4"; then pass "v4: no IPv6 address leaks in"; else fail "v4: no IPv6 address leaks in" "$v4"; fi
if has "$v4" "$drop" && [ "$(line_of "$v4" "$drop")" -gt "$(line_of "$v4" "$(allow 203.0.113.11/32)")" ]; then
  pass "v4: the drop rule comes after the allow rules"; else fail "v4: the drop rule comes after the allow rules" "$v4"; fi
if [ "$(head -1 <<<"$v4")" = '*filter' ] && has "$v4" ':DOCKER-USER - [0:0]' && [ "$(tail -1 <<<"$v4")" = COMMIT ]; then
  pass "v4: rewrites only the DOCKER-USER chain"; else fail "v4: rewrites only the DOCKER-USER chain" "$v4"; fi

v6="$("$render" --family v6 --allowlist "$list")"
if has "$v6" "$(allow 2001:db8::10/128)" && ! grep -q '203.0.113' <<<"$v6" && has "$v6" "$drop"; then
  pass "v6: only the IPv6 address is allowed"; else fail "v6: only the IPv6 address is allowed" "$v6"; fi

printf '203.0.113.10\r\n' >"$list"
crlf="$("$render" --family v4 --allowlist "$list")"
if has "$crlf" "$(allow 203.0.113.10/32)"; then pass "a CRLF line ending is tolerated"; else fail "a CRLF line ending is tolerated" "$crlf"; fi

deny="$("$render" --family v4 --deny-all)"
if has "$deny" "$drop" && ! grep -q -- ' -s ' <<<"$deny"; then pass "--deny-all allows nobody"; else fail "--deny-all allows nobody" "$deny"; fi

# --- refusals: exit 2 and print nothing, so nothing half-rendered is ever applied ----------
rejects() {   # rejects <name> <file contents for printf %b> <render args...>
  local name="$1" content="$2" out rc
  shift 2
  printf '%b' "$content" >"$list"
  out="$("$render" "$@" 2>/dev/null)"; rc=$?
  if [ "$rc" = 2 ] && [ -z "$out" ]; then pass "$name"; else fail "$name" "exit $rc, out: $out"; fi
}
rejects "an empty allowlist is refused" '' --family v4 --allowlist "$list"
rejects "a comments-only allowlist is refused" '# nobody\n' --family v4 --allowlist "$list"
rejects "0.0.0.0 is refused" '0.0.0.0\n' --family v4 --allowlist "$list"
rejects ":: is refused" '::\n' --family v6 --allowlist "$list"
rejects "a CIDR range is refused" '10.0.0.0/8\n' --family v4 --allowlist "$list"
rejects "a hostname is refused" 'search.example.com\n' --family v4 --allowlist "$list"
rejects "one bad line refuses the whole list" '203.0.113.10\nnope\n' --family v4 --allowlist "$list"
rejects "a missing --family is refused" '203.0.113.10\n' --allowlist "$list"
rejects "an unknown family is refused" '203.0.113.10\n' --family v5 --allowlist "$list"
rejects "a missing file is refused" '' --family v4 --allowlist "$SANDBOX/nope"
finish
