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
    ($r.environment | has("RECOMMENDATIONS_R2_ENDPOINT") and has("RECOMMENDATIONS_R2_ACCESS_KEY") and
      has("RECOMMENDATIONS_R2_SECRET_KEY") and has("RECOMMENDATIONS_R2_BUCKET")) and
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
t_worldcat_api() {
  # `config` renders 3g as bytes (a number or a string); accept either.
  cfg worldcat worldcat | jq -e '.services.worldcat as $w |
    $w.environment.WC_API_MEMORY_LIMIT == "2GB" and $w.environment.WC_API_THREADS == "2" and
    $w.volumes[0].read_only == true and $w.volumes[0].source == "/home/shane/wc-data" and
    ($w.mem_limit == 3221225472 or $w.mem_limit == "3221225472" or $w.mem_limit == "3g")' >/dev/null
}
t_worldcat_alias() {
  cfg worldcat worldcat | jq -e '.services.worldcat.networks.default.aliases == ["worldcat"]' >/dev/null
}
t_worldcat_off_by_default() { ! cfg worldcat | jq -e '.services | has("worldcat")' >/dev/null; }
t_wikidata_api() {
  cfg wikidata wikidata | jq -e '.services.wikidata as $w |
    $w.environment.WD_API_MEMORY_LIMIT == "512MB" and $w.environment.WD_API_THREADS == "2" and
    $w.volumes[0].read_only == true and $w.volumes[0].source == "/home/shane/wd-data" and
    $w.ports[0].target == 8083' >/dev/null
}
t_wikidata_build() {
  cfg wikidata wikidata | jq -e '.services["wikidata-build"] as $b |
    $b.command == ["python","-m","wikidata.pipeline.build","--root","/data","--memory-limit","8GB","--threads","6"] and
    ($b.volumes[0].read_only // false) == false and $b.restart == "no"' >/dev/null
}
t_wikidata_off_by_default() { ! cfg wikidata | jq -e '.services | has("wikidata") or has("wikidata-build")' >/dev/null; }

pgv() { # pgv: the merged model the pgverify VM runs; all three services are in the pgverify profile
  PGVERIFY_ROOT=/mnt/pgverify COMPOSE_PROFILES=pgverify cfg pgverify pgverify
}
t_pgverify_postgres() {
  pgv | jq -e '.services.postgres as $p |
    ($p.user == "999:999") and ($p.entrypoint == ["postgres"]) and ($p | has("ports") | not) and
    ($p.shm_size == 1073741824 or $p.shm_size == "1073741824" or $p.shm_size == "1g") and
    ($p.restart == "no") and
    ($p.command | index("archive_mode=off") != null) and
    ($p.command | index("max_logical_replication_workers=0") != null) and
    ($p.command | index("ssl=off") != null) and
    ($p.command | index("listen_addresses=") != null) and
    ($p.command | index("hba_file=/etc/pgverify-static/pg_hba.conf") != null) and
    ($p.command | index("restore_command=/etc/pgverify-static/archive-get.sh %f %p") != null) and
    ($p.build.context | endswith("/deployment/postgres")) and
    ($p.environment.PGBACKREST_CONFIG == "/etc/pgverify/pgbackrest.conf")' >/dev/null
}
t_pgverify_same_image_everywhere() {
  pgv | jq -e '.services.postgres.image == .services.tools.image and .services.tools.build == null' >/dev/null
}
t_pgverify_no_published_ports() {
  pgv | jq -e '[.services.postgres, .services.tools, .services.aws] | all(has("ports") | not)' >/dev/null
}
t_pgverify_volumes() {
  pgv | jq -e '(.services.postgres.volumes | map(.target)) as $t |
    ($t | index("/var/lib/postgresql/18/docker") != null) and ($t | index("/var/run/postgresql") != null) and
    (.services.postgres.volumes | map(select(.target == "/etc/pgverify-static")) | .[0].read_only == true) and
    (.services.postgres.volumes | map(select(.target == "/etc/pgverify")) | .[0].read_only == true) and
    (.services.tools.volumes | map(select(.target == "/dumps")) | .[0].source == "/mnt/pgverify/dumps") and
    (.services.aws.volumes | map(select(.target == "/dumps")) | .[0].read_only == true)' >/dev/null
}
t_pgverify_aws_pinned() {
  pgv | jq -e '.services.aws.image | test("^amazon/aws-cli:[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[0-9a-f]{64}$")' >/dev/null
}
t_pgverify_aws_takes_keys_by_name() {
  # The service names the variables and carries no value, so no key is in this file or on a command line.
  grep -q 'AWS_ACCESS_KEY_ID$' "$HS_DIR/compose.pgverify.yml" && ! grep -qE 'AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)[:=]' "$HS_DIR/compose.pgverify.yml"
}
t_pgverify_aws_passes_the_endpoint() {
  # The dump bucket is on R2: the endpoint must reach the CLI, or the upload goes to AWS.
  grep -qE '^ *- AWS_ENDPOINT_URL$' "$HS_DIR/compose.pgverify.yml" && grep -qE '^ *- AWS_DEFAULT_REGION$' "$HS_DIR/compose.pgverify.yml"
}
t_pgverify_off_by_default() {
  ! cfg pgverify | jq -e '.services | has("postgres") or has("tools") or has("aws")' >/dev/null
}
t_pgverify_not_on_other_roles() {
  ! cfg ol | jq -e '.services | has("postgres") or has("tools") or has("aws")' >/dev/null
}
t_pgverify_image_pinned_in_dockerfile() {
  # One pinned image for both servers: the VM builds the very Dockerfile production does.
  grep -qE '^FROM postgres:18\.[0-9]+-trixie@sha256:[0-9a-f]{64}$' "$REPO_ROOT/deployment/postgres/Dockerfile"
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
check "worldcat gets 2GB, 2 threads, 3g and a read-only data volume" t_worldcat_api
check "worldcat is on the default network with alias worldcat" t_worldcat_alias
check "worldcat is off until its profile or name selects it" t_worldcat_off_by_default
check "wikidata api: 512MB, 2 threads, port 8083, read-only data volume" t_wikidata_api
check "wikidata-build runs the pipeline with a writable data volume" t_wikidata_build
check "the wikidata services are off until their profile or name selects them" t_wikidata_off_by_default
check "pgverify postgres: no ports, user 999, 1g shm, forced archive/worker/ssl/listener flags, local hba, the shared Dockerfile" t_pgverify_postgres
check "pgverify tools run the same image the server does" t_pgverify_same_image_everywhere
check "no pgverify service publishes a port" t_pgverify_no_published_ports
check "pgverify mounts the data, socket, config read-only and dumps (read-only for the uploader)" t_pgverify_volumes
check "the uploader image is pinned by version and digest" t_pgverify_aws_pinned
check "the uploader gets its key by variable name, never a value" t_pgverify_aws_takes_keys_by_name
check "the uploader gets the dump bucket's endpoint and region by name" t_pgverify_aws_passes_the_endpoint
check "the pgverify services are off until named" t_pgverify_off_by_default
check "no other role gets the pgverify services" t_pgverify_not_on_other_roles
check "the Postgres Dockerfile the VM builds is pinned by digest" t_pgverify_image_pinned_in_dockerfile
finish
