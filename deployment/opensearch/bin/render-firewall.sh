#!/usr/bin/env bash
# deployment/opensearch/bin/render-firewall.sh
# Prints iptables-restore input that rewrites the DOCKER-USER chain so only the allowlisted app
# servers can open connections to OpenSearch on port 9200. Docker-published ports bypass ufw:
# they are DNAT-ed in PREROUTING and filtered in FORWARD, so DOCKER-USER is the one place a rule
# reliably applies. Rules match the ORIGINAL destination port because DOCKER-USER sees packets
# after Docker's DNAT. Spec: docs/superpowers/specs/2026-10-13-opensearch-server-design.md §5.1.
#
#   render-firewall.sh --family v4|v6 --allowlist FILE   one address per line, # comments
#   render-firewall.sh --family v4|v6 --deny-all         nobody may connect
#
# Feed the output to `iptables-restore --noflush` (v4) or `ip6tables-restore --noflush` (v6).
# Declaring :DOCKER-USER flushes that chain alone, so the rewrite is atomic and Docker's own
# chains are untouched. Exits 2, printing nothing, on any bad input: a typo in the SOPS file must
# fail the deploy, never open the port or lock the apps out.
set -euo pipefail
PORT=9200

family="" allowlist="" deny_all=0
while [ $# -gt 0 ]; do
  case "$1" in
    --family) family="${2:-}"; shift 2 || shift ;;
    --allowlist) allowlist="${2:-}"; shift 2 || shift ;;
    --deny-all) deny_all=1; shift ;;
    *) echo "render-firewall: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$family" in
  v4) host_bits=32 ;;
  v6) host_bits=128 ;;
  *) echo "render-firewall: --family must be v4 or v6" >&2; exit 2 ;;
esac

addresses=""
if [ "$deny_all" = 0 ]; then
  [ -n "$allowlist" ] || { echo "render-firewall: need --allowlist FILE or --deny-all" >&2; exit 2; }
  [ -r "$allowlist" ] || { echo "render-firewall: cannot read $allowlist" >&2; exit 2; }
  # Python's ipaddress does the validation: hand-written IPv6 patterns are how bad entries slip
  # through. Single host addresses only -- accepting a CIDR is how 0.0.0.0/0 gets in.
  addresses="$(python3 -I - "$allowlist" "$family" <<'PY'
import ipaddress, sys
path, family = sys.argv[1], sys.argv[2]
found, wanted = 0, []
with open(path) as f:
    for n, raw in enumerate(f, 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        try:
            ip = ipaddress.ip_address(line)
        except ValueError:
            sys.exit(f"render-firewall: line {n}: {line!r} is not a single IP address")
        if ip.is_unspecified:
            sys.exit(f"render-firewall: line {n}: {line} would allow everyone")
        if ip.version == 6 and ip.ipv4_mapped:
            sys.exit(f"render-firewall: line {n}: {line} is an IPv4-mapped IPv6 address; write the plain IPv4 form {ip.ipv4_mapped}")
        found += 1
        if (ip.version == 4) == (family == "v4"):
            wanted.append(str(ip))
if found == 0:
    sys.exit("render-firewall: the allowlist is empty")
if family == "v4" and not wanted:
    sys.exit("render-firewall: the allowlist has no IPv4 address; port 9200 is IPv4-only, so every app would be locked out")
print("\n".join(wanted))
PY
)" || exit 2
fi

echo "*filter"
echo ":DOCKER-USER - [0:0]"
echo "-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN"
while IFS= read -r ip; do
  [ -n "$ip" ] || continue
  echo "-A DOCKER-USER -p tcp -m conntrack --ctorigdstport $PORT --ctdir ORIGINAL -s $ip/$host_bits -j RETURN"
done <<<"$addresses"
echo "-A DOCKER-USER -p tcp -m conntrack --ctorigdstport $PORT --ctdir ORIGINAL -j DROP"
echo "-A DOCKER-USER -j RETURN"
echo "COMMIT"
