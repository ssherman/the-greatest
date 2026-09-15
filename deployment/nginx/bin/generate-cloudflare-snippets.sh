#!/usr/bin/env bash
# Generates the two nginx snippets that make the origin Cloudflare-aware:
#
#   cloudflare-real-ip.conf  set_real_ip_from for every Cloudflare range, plus
#                            real_ip_header CF-Connecting-IP -- so $remote_addr, the access
#                            log, the bot-blocker's per-IP limits and Rails' request.remote_ip
#                            all see the visitor, not the Cloudflare edge.
#   cloudflare-geo.conf      geo $realip_remote_addr $from_cloudflare -- 1 for a Cloudflare
#                            range or loopback, 0 otherwise. Keyed on $realip_remote_addr
#                            (the connection's real peer) because real_ip has already
#                            rewritten $remote_addr by the time an access check runs.
#
# Runs at nginx image build (deployment/nginx/Dockerfile). Every deploy rebuilds the image
# --no-cache, so the list refreshes itself. Any failure exits non-zero and writes nothing,
# which fails the build and the deploy loudly while the running image keeps serving.
#
# Usage: generate-cloudflare-snippets.sh <output-dir> [<local-ips-json>]
#   <local-ips-json> replaces the network fetch (tests).
set -euo pipefail

fail() { echo "generate-cloudflare-snippets: $*" >&2; exit 1; }

[ $# -ge 1 ] || fail "usage: $0 <output-dir> [<local-ips-json>]"
out_dir="$1"
source_json="${2:-}"
url="https://api.cloudflare.com/client/v4/ips"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if [ -n "$source_json" ]; then
  cp "$source_json" "$tmp"
else
  curl -fsS --retry 3 --retry-all-errors --max-time 20 "$url" -o "$tmp" \
    || fail "could not fetch $url"
fi

[ -s "$tmp" ] || fail "empty response"
jq -e . "$tmp" >/dev/null 2>&1 || fail "response is not JSON"
[ "$(jq -r '.success' "$tmp")" = "true" ] || fail "response .success is not true"

v4_count=$(jq '.result.ipv4_cidrs | length' "$tmp")
v6_count=$(jq '.result.ipv6_cidrs | length' "$tmp")
[ "$v4_count" -ge 10 ] || fail "only $v4_count IPv4 ranges (expected at least 10)"
[ "$v6_count" -ge 3 ] || fail "only $v6_count IPv6 ranges (expected at least 3)"

v4_re='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
v6_re='^[0-9A-Fa-f:]+/[0-9]{1,3}$'
while IFS= read -r cidr; do
  [[ "$cidr" =~ $v4_re ]] || fail "unexpected IPv4 entry: $cidr"
done < <(jq -r '.result.ipv4_cidrs[]' "$tmp")
while IFS= read -r cidr; do
  [[ "$cidr" =~ $v6_re ]] || fail "unexpected IPv6 entry: $cidr"
done < <(jq -r '.result.ipv6_cidrs[]' "$tmp")

etag=$(jq -r '.result.etag // "unknown"' "$tmp")
stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
header="# Generated $stamp by deployment/nginx/bin/generate-cloudflare-snippets.sh from $url (etag $etag). Do not edit."

mkdir -p "$out_dir"

{
  echo "$header"
  jq -r '.result.ipv4_cidrs[], .result.ipv6_cidrs[] | "set_real_ip_from \(.);"' "$tmp"
  echo "real_ip_header CF-Connecting-IP;"
} > "$out_dir/cloudflare-real-ip.conf"

{
  echo "$header"
  echo 'geo $realip_remote_addr $from_cloudflare {'
  echo "    default      0;"
  echo "    127.0.0.1/32 1;   # container healthcheck"
  echo "    ::1/128      1;"
  jq -r '.result.ipv4_cidrs[], .result.ipv6_cidrs[] | "    \(.) 1;"' "$tmp"
  echo "}"
} > "$out_dir/cloudflare-geo.conf"

echo "generate-cloudflare-snippets: $v4_count IPv4 + $v6_count IPv6 ranges (etag $etag) -> $out_dir"
