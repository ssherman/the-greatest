#!/usr/bin/env bash
# Unit test for deployment/nginx/bin/generate-cloudflare-snippets.sh. Needs jq.
# Run from anywhere: deployment/nginx/test/generate-cloudflare-snippets_test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
gen="$here/../bin/generate-cloudflare-snippets.sh"
fixture="$here/fixtures/cloudflare-ips.json"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1 -- $2"; failures=$((failures + 1)); }

# --- a valid response produces both snippets -----------------------------------------
out="$work/ok"
if "$gen" "$out" "$fixture" >/dev/null; then
  pass "valid response exits 0"
else
  fail "valid response exits 0" "non-zero exit"
fi

realip="$out/cloudflare-real-ip.conf"
geo="$out/cloudflare-geo.conf"

if grep -q '^set_real_ip_from 173\.245\.48\.0/20;$' "$realip" \
   && grep -q '^set_real_ip_from 2400:cb00::/32;$' "$realip" \
   && grep -q '^real_ip_header CF-Connecting-IP;$' "$realip"; then
  pass "real-ip snippet has IPv4, IPv6 and the header directive"
else
  fail "real-ip snippet has IPv4, IPv6 and the header directive" "$(cat "$realip" 2>&1)"
fi

if [ "$(grep -c '^set_real_ip_from ' "$realip" 2>/dev/null)" = "22" ]; then
  pass "real-ip snippet lists all 22 ranges"
else
  fail "real-ip snippet lists all 22 ranges" "got $(grep -c '^set_real_ip_from ' "$realip" 2>/dev/null)"
fi

if grep -q '^geo \$realip_remote_addr \$from_cloudflare {$' "$geo" \
   && grep -qE '^\s+default\s+0;' "$geo" \
   && grep -qE '^\s+127\.0\.0\.1/32\s+1;' "$geo" \
   && grep -qE '^\s+::1/128\s+1;' "$geo" \
   && grep -qE '^\s+104\.16\.0\.0/13\s+1;$' "$geo" \
   && grep -qE '^\s+2606:4700::/32\s+1;$' "$geo" \
   && grep -q '^}$' "$geo"; then
  pass "geo snippet keys on \$realip_remote_addr and includes loopback"
else
  fail "geo snippet keys on \$realip_remote_addr and includes loopback" "$(cat "$geo" 2>&1)"
fi

if grep -q 'etag 38f79d050aa027e3be3865e495dcc9bc' "$geo" && grep -q 'etag 38f79d050aa027e3be3865e495dcc9bc' "$realip"; then
  pass "both snippets carry the etag in their header comment"
else
  fail "both snippets carry the etag in their header comment" "$(head -1 "$geo" 2>&1)"
fi

# --- failures exit non-zero and write nothing ----------------------------------------
bad() {   # bad <name> <json>
  local name="$1" json="$2" dir="$work/bad-$RANDOM"
  printf '%s' "$json" > "$work/bad.json"
  if "$gen" "$dir" "$work/bad.json" >/dev/null 2>&1; then
    fail "$name" "exited 0"
  elif [ -e "$dir/cloudflare-geo.conf" ] || [ -e "$dir/cloudflare-real-ip.conf" ]; then
    fail "$name" "wrote files despite failing"
  else
    pass "$name"
  fi
}

bad "success:false is rejected" \
  '{"success":false,"result":{"ipv4_cidrs":[],"ipv6_cidrs":[],"etag":"x"}}'
bad "too few IPv4 ranges is rejected" \
  '{"success":true,"result":{"ipv4_cidrs":["1.1.1.0/24"],"ipv6_cidrs":["2400:cb00::/32","2606:4700::/32","2803:f800::/32"],"etag":"x"}}'
bad "missing IPv6 list is rejected" "$(jq 'del(.result.ipv6_cidrs)' "$fixture")"
bad "non-CIDR IPv4 entry is rejected" "$(jq '.result.ipv4_cidrs[0] = "not a cidr"' "$fixture")"
bad "non-CIDR IPv6 entry is rejected" "$(jq '.result.ipv6_cidrs[0] = "2606:4700::/32; evil"' "$fixture")"
bad "empty body is rejected" ''

echo
if [ "$failures" -eq 0 ]; then echo "all generator tests passed"; else echo "$failures generator test(s) failed"; exit 1; fi
