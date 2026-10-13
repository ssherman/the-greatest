#!/usr/bin/env bash
# deployment/opensearch/bin/deploy.sh ENV_FILE
# Configures and starts the search server. Run on the server by .github/workflows/deploy-opensearch.yml
# as the deploy user (passwordless sudo); ENV_FILE is the decrypted secrets/.env.opensearch.
# Every step is safe to repeat; an unchanged redeploy restarts nothing. Spec §6.4.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
os_dir="$(cd "$here/.." && pwd)"
env_file="${1:?usage: deploy.sh ENV_FILE}"
STATE_DIR="${STATE_DIR:-/srv/opensearch}"
ETC_DIR="${ETC_DIR:-/etc/opensearch}"
OS_UID="${OS_UID:-1000}" OS_GID="${OS_GID:-1000}"   # the container's opensearch user
sudo=(sudo "--preserve-env=ROOT,ALLOWLIST")
if [ "${NO_SUDO:-0}" = 1 ]; then sudo=(); fi

set -a
# shellcheck source=/dev/null
. "$env_file"
set +a
for v in OPENSEARCH_ALLOWED_IPS OPENSEARCH_ADMIN_PASSWORD OPENSEARCH_APP_PASSWORD OPENSEARCH_LEGACY_PASSWORD; do
  if [ -z "${!v:-}" ]; then echo "deploy: $v is missing from $env_file" >&2; exit 2; fi
done
export OPENSEARCH_CERTS_DIR="$STATE_DIR/certs" OPENSEARCH_SECURITY_DIR="$STATE_DIR/security"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 1. Firewall. Validate first: a bad allowlist must never reach the file the boot unit reads.
tr ', \r\t' '\n' <<<"$OPENSEARCH_ALLOWED_IPS" | sed '/^$/d' >"$work/allowlist"
"$here/render-firewall.sh" --family v4 --allowlist "$work/allowlist" >/dev/null
"${sudo[@]}" install -d -m 0755 "$ETC_DIR"
"${sudo[@]}" install -m 0644 "$work/allowlist" "$ETC_DIR/allowlist"
"${sudo[@]}" env ALLOWLIST="${ALLOWLIST:-$ETC_DIR/allowlist}" "$here/install-firewall.sh"

# 2. Certificates, first run only, readable by the container user.
"${sudo[@]}" "$here/generate-certs.sh" "$STATE_DIR/certs"
"${sudo[@]}" chown -R "$OS_UID:$OS_GID" "$STATE_DIR/certs"

# 3. Users and roles: hash as this user (needs Docker), then install for the container user.
"$here/render-security.sh" "$work/security"
"${sudo[@]}" install -d -m 0750 -o "$OS_UID" -g "$OS_GID" "$OPENSEARCH_SECURITY_DIR"
"${sudo[@]}" install -m 0640 -o "$OS_UID" -g "$OS_GID" "$work/security"/*.yml "$OPENSEARCH_SECURITY_DIR/"

# 4. Start. Single-file mounts (opensearch.yml) and certificates are read at start, so a change to
# either needs a recreate; anything else is a no-op `up -d`. A new image tag recreates by itself.
fingerprint="$("${sudo[@]}" cat "$os_dir/config/opensearch.yml" "$STATE_DIR/certs/node.pem" "$STATE_DIR/certs/root-ca.pem" \
  | sha256sum | cut -d' ' -f1)"
previous="$("${sudo[@]}" cat "$STATE_DIR/config.sha256" 2>/dev/null || true)"
up=(up -d)
if [ "$previous" != "$fingerprint" ]; then up=(up -d --force-recreate); fi
docker compose -f "$os_dir/compose.yml" "${up[@]}"
printf '%s\n' "$fingerprint" | "${sudo[@]}" tee "$STATE_DIR/config.sha256" >/dev/null

# 5. Load users and roles into the security index (picks up password rotations too).
"$here/apply-security.sh"
echo "deploy: done"
