# deployment/opensearch/test/helpers.sh
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2016
# SC2034: BIN is used by the files that source this. SC2016: stub bodies are single-quoted on
# purpose, so they expand when the stub runs. Same shape as deployment/home-server/test/helpers.sh.
OS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$OS_DIR/bin"
failures=0
ORIGINAL_PATH="$PATH"

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1 -- $2"; failures=$((failures + 1)); }
finish() {
  if [ "$failures" = 0 ]; then echo "all passed"; else echo "$failures failed"; exit 1; fi
}

new_sandbox() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX"/{bin,log}
  export SANDBOX CALLS="$SANDBOX/log/calls" PATH="$SANDBOX/bin:$ORIGINAL_PATH"
  : >"$CALLS"
}

# stub <name> <body>: a command on PATH that logs "<name> <args>" to $CALLS, then runs body.
# The depth guard is not optional: a stub that reached itself by name once forked until it took
# the whole machine down. Stubs that wrap a real tool must call it with `command -p`.
stub() {
  {
    printf '#!/usr/bin/env bash\n'
    printf '[ "${STUB_DEPTH:-0}" -lt 3 ] || { echo "stub %s re-entered itself" >&2; exit 99; }\n' "$1"
    printf 'export STUB_DEPTH=$(( ${STUB_DEPTH:-0} + 1 ))\n'
    printf 'echo "%s $*" >>"$CALLS"\n' "$1"
    printf '%s\n' "$2"
  } >"$SANDBOX/bin/$1"
  command -p chmod +x "$SANDBOX/bin/$1"
}
called() { grep -qE "$1" "$CALLS"; }
