#!/usr/bin/env bash
# deployment/home-server/guest/heartbeat.sh
# the-greatest-heartbeat.timer, every 5 minutes: ping healthchecks.io only if
# this VM's service answers locally. Silence is the alert.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
load_env

case "$ROLE" in
  ol) url=http://127.0.0.1:8080/version ;;
  fetcher) url=http://127.0.0.1:8081/health ;;
  *) echo "heartbeat: unknown ROLE '$ROLE'" >&2; exit 1 ;;
esac
if curl -fsS -m 10 -o /dev/null "$url"; then hc_ping "${HC_HEARTBEAT:-}"; fi
