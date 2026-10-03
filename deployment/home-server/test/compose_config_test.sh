#!/usr/bin/env bash
# deployment/home-server/test/compose_config_test.sh
# The merged compose model the `ol` and `fetcher` VMs actually run.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"

cfg() { # cfg <role> [profile]
  local files=(-f "$REPO_ROOT/data-sources/docker-compose.yml" -f "$HS_DIR/compose.tunnel.yml")
  if [ -f "$HS_DIR/compose.$1.yml" ]; then files+=(-f "$HS_DIR/compose.$1.yml"); fi
  OL_DATA_HOST=/srv/ol-data TUNNEL_TOKEN=x COMPOSE_PROFILES="${2:-}" \
    docker compose --project-directory "$REPO_ROOT/data-sources" "${files[@]}" config --format json
}

t_build() {
  cfg ol build | jq -e '.services.build.cpus == 10 and
    .services.build.command == ["python","-m","openlibrary.pipeline.build","--root","/data","--memory-limit","8GB","--threads","4"]' >/dev/null
}
t_api() {
  cfg ol | jq -e '.services.api.environment.OL_API_MEMORY_LIMIT == "6GB" and
    (.services.api.volumes[0].source == "/srv/ol-data") and (.services.api.volumes[0].read_only == true)' >/dev/null
}
t_pinned() {
  cfg ol tunnel | jq -e '.services.cloudflared.image | test("^cloudflare/cloudflared:[0-9]{4}\\.[0-9]+\\.[0-9]+$")' >/dev/null
}
t_off_by_default() { ! cfg ol | jq -e '.services | has("cloudflared")' >/dev/null; }
t_fetcher_untouched() {
  cfg fetcher | jq -e '.services.fetcher.mem_limit != null and (.services | has("cloudflared") | not)' >/dev/null
}

if ! command -v docker >/dev/null; then echo "SKIP  docker not installed"; exit 0; fi
check "build is capped at 10 CPUs and 8GB" t_build
check "api gets 6GB and a read-only /srv/ol-data" t_api
check "cloudflared is a pinned version" t_pinned
check "cloudflared is off until the tunnel profile is on" t_off_by_default
check "the fetcher service is unchanged" t_fetcher_untouched
finish
