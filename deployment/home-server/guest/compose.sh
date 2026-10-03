#!/usr/bin/env bash
# deployment/home-server/guest/compose.sh
# docker compose with this VM's files and settings. Every guest script goes
# through here, so the invocation lives in one place.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
load_env

export COMPOSE_PROJECT_NAME=the-greatest OL_DATA_HOST="$OL_DATA"
if [ "${TUNNELS_ENABLED:-0}" = 1 ]; then export COMPOSE_PROFILES=tunnel; fi
# The refresh script passes OL_DATA_VERSION explicitly while promoting.
if [ -z "${OL_DATA_VERSION:-}" ] && [ -f "$OL_DATA/current-version" ]; then
  OL_DATA_VERSION="$(cat "$OL_DATA/current-version")"
  export OL_DATA_VERSION
fi

hs="$REPO_DIR/deployment/home-server"
files=(-f "$REPO_DIR/data-sources/docker-compose.yml" -f "$hs/compose.tunnel.yml")
if [ -f "$hs/compose.$ROLE.yml" ]; then files+=(-f "$hs/compose.$ROLE.yml"); fi
exec docker compose "${files[@]}" "$@"
