#!/usr/bin/env bash
# deployment/home-server/test/dns_test.sh
# host_dns_search: the pure decision behind converge_host_dns.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"
# shellcheck source=../lib/host.sh
. "$HS_DIR/lib/host.sh"

t_changes_when_different() {
  [ "$(host_dns_search '{"dns1":"192.168.139.1","search":"mothership.local"}' 192.168.1.1)" = "mothership.local" ]
}
t_silent_when_same() {
  [ -z "$(host_dns_search '{"dns1":"192.168.1.1","search":"x.local"}' 192.168.1.1)" ]
}
t_default_search() {
  [ "$(host_dns_search '{"dns1":"192.168.139.1"}' 192.168.1.1)" = "home.arpa" ]
}
t_missing_dns1_changes() {
  [ "$(host_dns_search '{"search":"x.local"}' 192.168.1.1)" = "x.local" ]
}

check "a stale dns1 is replaced, keeping the search domain" t_changes_when_different
check "a matching dns1 changes nothing" t_silent_when_same
check "an empty search falls back to home.arpa" t_default_search
check "a missing dns1 is set" t_missing_dns1_changes
finish
