#!/usr/bin/env bash
# deployment/opensearch/bin/apply-security.sh
# Waits for the node to answer HTTPS, then loads the mounted security directory (users, roles,
# mappings) into the security index with securityadmin.sh and the admin client certificate.
# Safe to repeat. COMPOSE_PROJECT_NAME selects another project (the local e2e test uses one).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
compose=(docker compose -f "$here/../compose.yml")
cfg=/usr/share/opensearch/config

code=000
for _ in $(seq 1 60); do
  # 503 means up, security index not initialised yet; securityadmin fixes that.
  code="$("${compose[@]}" exec -T opensearch curl -sk -o /dev/null -w '%{http_code}' https://localhost:9200/ 2>/dev/null || true)"
  case "$code" in 200|401|503) break ;; esac
  sleep 3
done
case "$code" in
  200|401|503) ;;
  *) echo "apply-security: OpenSearch did not answer HTTPS within 3 minutes (last: $code)" >&2; exit 1 ;;
esac

"${compose[@]}" exec -T opensearch /usr/share/opensearch/plugins/opensearch-security/tools/securityadmin.sh \
  -cd "$cfg/opensearch-security/" -icl -nhnv \
  -cacert "$cfg/certs/root-ca.pem" -cert "$cfg/certs/admin.pem" -key "$cfg/certs/admin-key.pem" \
  -h localhost
