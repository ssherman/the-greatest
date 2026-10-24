#!/usr/bin/env bash
# deployment/opensearch/bin/apply-firewall.sh
# Applies the OpenSearch allowlist to DOCKER-USER for IPv4 and IPv6. Run at boot by
# opensearch-firewall.service, before docker.service, and by install-firewall.sh on every deploy.
# A missing or empty allowlist means nobody may connect: port 9200 is never open by default.
# An invalid one fails before anything is applied, and since docker.service requires the unit,
# Docker then stays down rather than coming up unprotected. Spec §5.1.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ALLOWLIST="${ALLOWLIST:-/etc/opensearch/allowlist}"

# Render both families before applying either, so a failure never leaves them half-updated.
declare -A rules
for family in v4 v6; do
  if [ -s "$ALLOWLIST" ]; then
    rules[$family]="$("$here/render-firewall.sh" --family "$family" --allowlist "$ALLOWLIST")"
  else
    rules[$family]="$("$here/render-firewall.sh" --family "$family" --deny-all)"
  fi
done
printf '%s\n' "${rules[v4]}" | iptables-restore --noflush
printf '%s\n' "${rules[v6]}" | ip6tables-restore --noflush
