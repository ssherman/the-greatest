#!/usr/bin/env bash
# deployment/opensearch/test/run.sh
# Every OpenSearch-server shell test, plus shellcheck. CI runs this (opensearch job).
# local-e2e-test.sh is not a *_test.sh on purpose: it needs Docker and runs by hand.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
os="$(cd "$here/.." && pwd)"
root="$(cd "$os/../.." && pwd)"
if command -v shellcheck >/dev/null; then sc=(shellcheck); else sc=(uvx --from shellcheck-py shellcheck); fi

status=0
files=()
for f in "$os"/bin/*.sh "$here"/*.sh "$root/deployment/scripts/verify-opensearch-lockdown.sh"; do
  if [ -f "$f" ]; then files+=("$f"); fi
done
"${sc[@]}" -x "${files[@]}" || status=1
for t in "$here"/*_test.sh; do
  echo "--- $(basename "$t")"
  "$t" || status=1
done
exit "$status"
