# deployment/home-server/test/helpers.sh
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2016
# SC2034: GUEST and REPO_ROOT are used by the files that source this. SC2016: stub bodies are
# single-quoted on purpose, so they expand when the stub runs, not when it is written.
# Shared by the *_test.sh files: a temp sandbox, stub commands on PATH, and
# pass/fail counting in the style of deployment/nginx/test.
HS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$HS_DIR/../.." && pwd)"
GUEST="$HS_DIR/guest"
failures=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1 -- $2"; failures=$((failures + 1)); }
# check <name> <function>: the function's exit status decides; on failure the
# call log and the script's output are printed.
check() {
  if "$2"; then pass "$1"; else fail "$1" "calls: $(cat "$CALLS" 2>/dev/null) | out: $(cat "$SANDBOX/log/out" 2>/dev/null)"; fi
}
finish() {
  if [ "$failures" = 0 ]; then echo "all passed"; else echo "$failures failed"; exit 1; fi
}

new_sandbox() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX"/{bin,state,data/versions,run,log}
  export SANDBOX STATE_DIR="$SANDBOX/state" OL_DATA="$SANDBOX/data"
  export BUILD_LOCK="$SANDBOX/run/ol-build.lock" ENV_FILE="$SANDBOX/home-server.env"
  export CALLS="$SANDBOX/log/calls" PATH="$SANDBOX/bin:$ORIGINAL_PATH"
  : >"$CALLS"
}
ORIGINAL_PATH="$PATH"

write_env() { printf '%s\n' "$@" >"$ENV_FILE"; }

# stub <name> <body>: a command on PATH that logs "<name> <args>" to $CALLS,
# then runs body.
#
# Every stub carries a depth guard. A stub whose body reaches a command by
# name finds itself first on PATH; one did (`command chmod`), and the
# recursion forked until it took the whole machine down. The guard stops any
# such chain at a few levels and fails loudly. Stubs that wrap a real tool
# must call it with `command -p`, which ignores PATH.
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
