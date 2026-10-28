#!/usr/bin/env bash
# Static checks on deployment/opensearch/compose.yml (no Docker needed).
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
compose="$OS_DIR/compose.yml"
if grep -qE '^\s+image: opensearchproject/opensearch:[0-9]+\.[0-9]+\.[0-9]+$' "$compose"; then
  pass "the image is pinned to an exact version"; else fail "the image is pinned" "$(grep image: "$compose")"; fi
ports="$(sed -n '/^    ports:/,/^    [a-z]/p' "$compose" | grep -E '^\s+- ')"
if [ -n "$ports" ] && ! grep -vqE '^\s+- "0\.0\.0\.0:' <<<"$ports"; then
  pass "every published port is bound to IPv4 0.0.0.0 (no [::] docker-proxy path)"; else fail "IPv4-only ports" "$ports"; fi
if grep -q 'DISABLE_INSTALL_DEMO_CONFIG=true' "$compose"; then pass "demo config disabled"; else fail "demo config disabled" "missing"; fi
if ! grep -qi 'DISABLE_SECURITY_PLUGIN' "$compose"; then pass "security plugin left on"; else fail "security plugin left on" "found"; fi
finish
