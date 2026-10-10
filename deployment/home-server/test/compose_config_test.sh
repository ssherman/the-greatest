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
    .services.api.environment.OL_API_THREADS == "8" and
    .services.api.environment.OL_API_RESOLVE_CONCURRENCY == "1" and
    .services.api.environment.OL_API_RESOLVE_DEADLINE_S == "55" and
    (.services.api.volumes[0].source == "/srv/ol-data") and (.services.api.volumes[0].read_only == true)' >/dev/null
}
t_pinned() {
  cfg ol tunnel | jq -e '.services.cloudflared.image | test("^cloudflare/cloudflared:[0-9]{4}\\.[0-9]+\\.[0-9]+$")' >/dev/null
}
t_off_by_default() { ! cfg ol | jq -e '.services | has("cloudflared")' >/dev/null; }
t_fetcher_untouched() {
  cfg fetcher | jq -e '.services.fetcher.mem_limit != null and (.services | has("cloudflared") | not)' >/dev/null
}
t_recommender() {
  # `config` normalises 14g to bytes (as a number or a string); accept any of the three.
  cfg ol recommender | jq -e '.services.recommender as $r |
    ($r.mem_limit == 15032385536 or $r.mem_limit == "15032385536" or $r.mem_limit == "14g") and $r.cpus == 10 and
    ($r.memswap_limit == 15032385536 or $r.memswap_limit == "15032385536" or $r.memswap_limit == "14g") and
    ($r.environment.TYPER_STANDARD_TRACEBACK == "1") and
    ($r.environment | has("RECOMMENDER_R2_ENDPOINT") and has("RECOMMENDER_R2_ACCESS_KEY") and
      has("RECOMMENDER_R2_SECRET_KEY") and has("RECOMMENDER_R2_BUCKET")) and
    ($r.volumes[0].target == "/work")' >/dev/null
}
t_recommender_off_by_default() { ! cfg ol | jq -e '.services | has("recommender")' >/dev/null; }
t_recommender_not_on_fetcher() { cfg fetcher recommender | jq -e '.services.recommender.mem_limit == null' >/dev/null; }
t_api_alias() {
  cfg ol | jq -e '.services.api.networks | has("default") and (.default.aliases | index("openlibrary") != null)' >/dev/null
}
t_fetcher_alias() {
  cfg fetcher | jq -e '.services.fetcher.networks | has("default") and (.default.aliases | index("page-fetcher") != null)' >/dev/null
}

if ! command -v docker >/dev/null; then echo "SKIP  docker not installed"; exit 0; fi
check "build is capped at 10 CPUs and 8GB" t_build
check "api gets 6GB, 8 threads, one resolve at a time and a read-only /srv/ol-data" t_api
check "cloudflared is a pinned version" t_pinned
check "cloudflared is off until the tunnel profile is on" t_off_by_default
check "the fetcher service is unchanged" t_fetcher_untouched
check "the trainer gets 14g and 10 CPUs on ol, with the R2 variables and its work volume" t_recommender
check "the trainer is off until named or its profile is on" t_recommender_off_by_default
check "the fetcher's compose does not cap the trainer" t_recommender_not_on_fetcher
check "api is on the default network with alias openlibrary" t_api_alias
check "fetcher is on the default network with alias page-fetcher" t_fetcher_alias
finish
