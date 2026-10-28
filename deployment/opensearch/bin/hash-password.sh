#!/usr/bin/env bash
# deployment/opensearch/bin/hash-password.sh   (password on stdin, bcrypt hash on stdout)
# Hashes with the security plugin's own tool from the image compose.yml pins, so the hash format
# always matches the version that checks it. The password reaches the container through its
# environment, never a command line, so it does not show in `ps`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
image="$(docker compose -f "$here/../compose.yml" config --images | head -1)"
PW="$(cat)"
export PW
# shellcheck disable=SC2016  # a literal bcrypt prefix, not a parameter
docker run --rm -e PW --entrypoint /usr/share/opensearch/plugins/opensearch-security/tools/hash.sh "$image" -env PW \
  | grep -E '^\$2[aby]\$' | tail -1
