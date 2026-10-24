#!/usr/bin/env bash
# deployment/opensearch/bin/render-security.sh OUT_DIR
# Builds the complete security directory the container mounts at config/opensearch-security:
# every security/*.yml as-is, plus internal_users.yml rendered from internal_users.yml.tmpl with
# the bcrypt hash of each password from the environment (OPENSEARCH_ADMIN_PASSWORD,
# OPENSEARCH_APP_PASSWORD, OPENSEARCH_LEGACY_PASSWORD). Plain passwords never reach a file.
# HASH_CMD reads one password on stdin and prints its hash (default: bin/hash-password.sh).
# Passwords must be 32+ letters and digits: they travel inside OPENSEARCH_URL, where : @ / %
# would break parsing. All hashing happens before anything is written. Spec §5.2.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:?usage: render-security.sh OUT_DIR}"
sec="$here/../security"
hash_cmd="${HASH_CMD:-$here/hash-password.sh}"

hash_of() {   # hash_of VAR_NAME
  local name="$1" password hash
  password="${!name:-}"
  if [ -z "$password" ]; then echo "render-security: $name is not set" >&2; return 2; fi
  if ! [[ "$password" =~ ^[A-Za-z0-9]{32,}$ ]]; then
    echo "render-security: $name must be 32 or more letters and digits (openssl rand -hex 32)" >&2; return 2
  fi
  hash="$(printf '%s' "$password" | "$hash_cmd")" || { echo "render-security: hashing $name failed" >&2; return 2; }
  if ! [[ "$hash" =~ ^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$ ]]; then
    echo "render-security: the hash command printed no bcrypt hash for $name" >&2; return 2
  fi
  printf '%s' "$hash"
}
admin="$(hash_of OPENSEARCH_ADMIN_PASSWORD)" || exit 2
app="$(hash_of OPENSEARCH_APP_PASSWORD)" || exit 2
legacy="$(hash_of OPENSEARCH_LEGACY_PASSWORD)" || exit 2

mkdir -p "$out"
cp "$sec"/*.yml "$out/"
tmp="$(mktemp "$out/.internal_users.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
# bcrypt output is [./A-Za-z0-9$], so | is a safe sed delimiter.
sed -e "s|@ADMIN_HASH@|$admin|" -e "s|@APP_HASH@|$app|" -e "s|@LEGACY_HASH@|$legacy|" \
  "$sec/internal_users.yml.tmpl" >"$tmp"
if grep -q '@[A-Z_]*_HASH@' "$tmp"; then echo "render-security: a placeholder was left unreplaced" >&2; exit 2; fi
chmod 0640 "$tmp"
mv "$tmp" "$out/internal_users.yml"
trap - EXIT
