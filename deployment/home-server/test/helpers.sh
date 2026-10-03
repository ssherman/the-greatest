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
stub() {
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "$2" >"$SANDBOX/bin/$1"
  chmod +x "$SANDBOX/bin/$1"
}
called() { grep -qE "$1" "$CALLS"; }
