#!/usr/bin/env bash
# deployment/postgres/test/run.sh [--fast|--docker|--all]
#   --fast    shellcheck plus every test that starts no container: apply-firewall, apply-roles, backup,
#             check-backup-health, compose (`docker compose config` only, no daemon), config, deploy,
#             generate-certs, install-backup, install-firewall, render-firewall, render-hba, verify-lockdown
#             (all with docker stubbed). This is what ci.yml's postgres job runs, and it gates web deploys.
#   --docker  the tests that start Docker containers and pull images: firewall-netfilter_test.sh and
#             migration_test.sh. This is what
#             .github/workflows/postgres-migration-tests.yml runs, on changes to deployment/postgres only.
#             It does not gate web deploys.
#   --all     both (the default, for a developer).
# local-e2e-test.sh is not a *_test.sh on purpose: it needs Docker and runs by hand.
# To add a test that starts a container, add its file name to DOCKER_TESTS below.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
os="$(cd "$here/.." && pwd)"
root="$(cd "$os/../.." && pwd)"
DOCKER_TESTS=(firewall-netfilter_test.sh migration_test.sh)

mode="${1:---all}"
case "$mode" in --fast | --docker | --all) ;; *) echo "usage: run.sh [--fast|--docker|--all]" >&2; exit 2 ;; esac
is_docker_test() {
  local t
  for t in "${DOCKER_TESTS[@]}"; do if [ "$t" = "$1" ]; then return 0; fi; done
  return 1
}

status=0
if [ "$mode" != --docker ]; then
  if command -v shellcheck >/dev/null; then sc=(shellcheck); else sc=(uvx --from shellcheck-py shellcheck); fi
  files=()
  for f in "$os"/bin/*.sh "$os"/migration/*.sh "$here"/*.sh "$root/deployment/scripts/verify-postgres-lockdown.sh"; do
    if [ -f "$f" ]; then files+=("$f"); fi
  done
  "${sc[@]}" -x "${files[@]}" || status=1
fi
for t in "$here"/*_test.sh; do
  name="$(basename "$t")"
  if is_docker_test "$name"; then
    if [ "$mode" = --fast ]; then continue; fi
  elif [ "$mode" = --docker ]; then
    continue
  fi
  echo "--- $name"
  "$t" || status=1
done
exit "$status"
