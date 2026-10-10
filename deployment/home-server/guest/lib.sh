# deployment/home-server/guest/lib.sh
# shellcheck shell=bash
# Shared by the scripts the home-server VMs run (docs/features/home-server.md).
# Sourced, never executed. Every path can be overridden, which is how
# deployment/home-server/test/ runs these scripts against a temp directory.
# The sourcing script sets $here first.

REPO_DIR="${REPO_DIR:-/opt/the-greatest}"
ENV_FILE="${ENV_FILE:-/etc/the-greatest/home-server.env}"
STATE_DIR="${STATE_DIR:-/var/lib/the-greatest}"
OL_DATA="${OL_DATA:-/srv/ol-data}"
BUILD_LOCK="${BUILD_LOCK:-/run/ol-build.lock}"
COMPOSE="${COMPOSE:-$here/compose.sh}"

# ROLE, REPO_REF, TUNNELS_ENABLED, TUNNEL_TOKEN, HC_HEARTBEAT, HC_DEPLOY, HC_REFRESH;
# on ol also HC_RECOMMENDER and RECOMMENDATIONS_R2_ENDPOINT/ACCESS_KEY/SECRET_KEY/BUCKET
# (compose.sh exports them, which is how the recommender service gets them).
load_env() {
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
}

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

# hc_ping <url> [start|fail] [message]: report to healthchecks.io. A blank url
# (not configured yet) is a no-op, and an undeliverable ping is logged, never
# fatal: an outage of the monitor must not fail the thing it monitors. The URL
# is never logged: its path is the check's credential.
hc_ping() {
  local url="${1:-}" suffix="${2:-}" message="${3:-}"
  [ -n "$url" ] || return 0
  if [ -n "$suffix" ]; then url="$url/$suffix"; fi
  curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "$message" "$url" ||
    log "could not ping healthchecks.io (${suffix:-success})"
}
