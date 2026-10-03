#!/usr/bin/env bash
# deployment/home-server/test/run.sh
# Every home-server shell test, plus shellcheck. CI runs this (home-server job).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
hs="$(cd "$here/.." && pwd)"
if command -v shellcheck >/dev/null; then sc=(shellcheck); else sc=(uvx --from shellcheck-py shellcheck); fi

status=0
# Only files that exist yet: provision, lib/ and host/ arrive in Tasks 4-5.
files=()
for f in "$hs/provision" "$hs"/lib/*.sh "$hs"/guest/*.sh "$hs"/host/sbin/* "$here"/*.sh; do
  if [ -f "$f" ]; then files+=("$f"); fi
done
"${sc[@]}" -x "${files[@]}" || status=1
for t in "$here"/*_test.sh; do
  echo "--- $(basename "$t")"
  "$t" || status=1
done
exit "$status"
