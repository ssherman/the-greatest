#!/bin/sh
# deployment/postgres/test/firewall-netfilter-harness.sh RULES_DIR
# Runs inside a throwaway privileged Alpine container, started by firewall-netfilter_test.sh. Everything here
# happens in that container's own network namespaces: the host's netfilter tables and ports are never touched.
#
# It builds Docker's shape with real netfilter, then loads the real output of render-firewall.sh:
#   c   the Postgres container, listening on 5433 (stands in for the container's 5432), NATed out
#   s   an allowlisted app server
#   x   another machine, listening on 6543 as the old server does; it is on no allowlist
#   the container's host: a FORWARD chain that jumps to DOCKER-USER, and a published port 6543 DNATed to c.
# Prints one line per probe: FAMILY SCENARIO PROBE CONNECTED|BLOCKED, or "v6 SKIP REASON".
RULES_DIR="$1"
apk add --no-cache iptables ip6tables iproute2 netcat-openbsd >/dev/null 2>&1 || { echo "harness: apk failed"; exit 9; }
set -u

ip netns add c; ip netns add s; ip netns add x
ip link add vc type veth peer name vc1; ip link set vc1 netns c
ip link add br0 type bridge; ip link set br0 up
ip link add vs type veth peer name vs1; ip link set vs1 netns s; ip link set vs master br0; ip link set vs up
ip link add vx type veth peer name vx1; ip link set vx1 netns x; ip link set vx master br0; ip link set vx up
ip link set vc up
for ns in c s x; do ip netns exec "$ns" ip link set lo up; done
ip netns exec c ip link set vc1 up
ip netns exec s ip link set vs1 up
ip netns exec x ip link set vx1 up

probe() { if "$@" >/dev/null 2>&1; then echo CONNECTED; else echo BLOCKED; fi; }

# scenario FAMILY NAME NC_FLAG PUBLISHED_ADDRESS REMOTE_ADDRESS
scenario() {
  echo "$1 $2 container-outbound-to-remote-6543 $(probe ip netns exec c nc "$3" -z -w 3 "$5" 6543)"
  echo "$1 $2 allowlisted-client-to-published-6543 $(probe ip netns exec s nc "$3" -z -w 3 "$4" 6543)"
  echo "$1 $2 other-client-to-published-6543 $(probe ip netns exec x nc "$3" -z -w 3 "$4" 6543)"
}

# run_family FAMILY IPTABLES NC_FLAG PUBLISHED_ADDRESS REMOTE_ADDRESS
run_family() {
  "$2" -N DOCKER-USER
  "$2" -A FORWARD -j DOCKER-USER
  scenario "$1" no-rules "$3" "$4" "$5"
  "$2-restore" --noflush <"$RULES_DIR/$1.allow"
  scenario "$1" allowlist "$3" "$4" "$5"
  "$2-restore" --noflush <"$RULES_DIR/$1.deny"
  scenario "$1" deny-all "$3" "$4" "$5"
}

# --- IPv4 ----------------------------------------------------------------------------------------------
ip addr add 172.18.0.1/16 dev vc
ip addr add 203.0.113.1/24 dev br0
ip netns exec c ip addr add 172.18.0.2/16 dev vc1
ip netns exec c ip route add default via 172.18.0.1
ip netns exec s ip addr add 203.0.113.50/24 dev vs1
ip netns exec s ip route add default via 203.0.113.1
ip netns exec x ip addr add 203.0.113.60/24 dev vx1
ip netns exec x ip route add default via 203.0.113.1
sysctl -qw net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s 172.18.0.0/16 -o br0 -j MASQUERADE
iptables -t nat -A PREROUTING -i br0 -p tcp --dport 6543 -j DNAT --to-destination 172.18.0.2:5433
ip netns exec c sh -c 'nc -4 -lk -p 5433 >/dev/null 2>&1 &'
ip netns exec x sh -c 'nc -4 -lk -p 6543 >/dev/null 2>&1 &'
sleep 1
run_family v4 iptables -4 203.0.113.1 203.0.113.60

# --- IPv6 ----------------------------------------------------------------------------------------------
# The real port is IPv4 only, so this DNAT never happens on the server. The rule is still rendered and loaded
# there, so it is held to the same behaviour.
if ! ip6tables -t nat -L >/dev/null 2>&1; then
  echo "v6 SKIP this kernel has no ip6tables nat table"
  exit 0
fi
ip addr add fd18::1/64 dev vc nodad
ip addr add 2001:db8:1::1/64 dev br0 nodad
ip netns exec c ip addr add fd18::2/64 dev vc1 nodad
ip netns exec c ip -6 route add default via fd18::1
ip netns exec s ip addr add 2001:db8:1::50/64 dev vs1 nodad
ip netns exec s ip -6 route add default via 2001:db8:1::1
ip netns exec x ip addr add 2001:db8:1::60/64 dev vx1 nodad
ip netns exec x ip -6 route add default via 2001:db8:1::1
sysctl -qw net.ipv6.conf.all.forwarding=1
ip6tables -t nat -A POSTROUTING -s fd18::/64 -o br0 -j MASQUERADE
ip6tables -t nat -A PREROUTING -i br0 -p tcp --dport 6543 -j DNAT --to-destination '[fd18::2]:5433'
ip netns exec c sh -c 'nc -6 -lk -p 5433 >/dev/null 2>&1 &'
ip netns exec x sh -c 'nc -6 -lk -p 6543 >/dev/null 2>&1 &'
sleep 1
run_family v6 ip6tables -6 2001:db8:1::1 2001:db8:1::60
