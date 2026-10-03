# deployment/home-server/lib/verify.sh
# shellcheck shell=bash
# provision --verify: everything about the box that can be checked from here.
VERIFY_FAILURES=0
ok() { echo "PASS  $1"; }
bad() { echo "FAIL  $1${2:+ -- $2}"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }
expect() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }

tcp_from_vm() { # tcp_from_vm <role> <host> <port>: can the VM open a TCP connection?
  vm_ssh "$1" "timeout 5 bash -c '</dev/tcp/$2/$3'" >/dev/null 2>&1
}
tcp_from_fetcher_container() {
  vm_ssh fetcher "docker exec the-greatest-fetcher-1 python -c 'import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), 5)' $1 $2" >/dev/null 2>&1
}

verify_host() {
  expect "host: apt update is clean" on_host "! apt-get update -q 2>&1 | grep -qiE '^(E|Err):|401'"
  expect "host: enterprise repos disabled" on_host "grep -q '^Enabled: no' /etc/apt/sources.list.d/pve-enterprise.sources"
  expect "host: unattended-upgrades installed" on_host "dpkg -s unattended-upgrades"
  expect "host: nothing listens on 111" on_host "! ss -ltnH 'sport = :111' | grep -q ."
  expect "host: firewall running" on_host "pve-firewall status | grep -q 'enabled/running'"
  expect "host: IPv4 forwarding on" on_host "[ \$(sysctl -n net.ipv4.ip_forward) = 1 ]"
  expect "host: IPv6 forwarding off" on_host "[ \$(sysctl -n net.ipv6.conf.all.forwarding) = 0 ]"
  expect "host: vmbr0 has IPv4" on_host "ip -4 -o addr show vmbr0 | grep -q inet"
}

verify_vms() {
  local role
  for role in ol fetcher; do
    vm_spec "$role"
    expect "$role: running" on_host "qm status $VMID | grep -q running"
    expect "$role: starts on boot" on_host "qm config $VMID | grep -qx 'onboot: 1'"
    expect "$role: cloud-init done" vm_ssh "$role" "cloud-init status | grep -q done"
  done
  expect "fetcher: /health answers" vm_ssh fetcher "curl -fsS 127.0.0.1:8081/health"
  if vm_ssh ol "test -f /srv/ol-data/current-version"; then
    expect "ol: /version answers" vm_ssh ol "curl -fsS 127.0.0.1:8080/version"
  else
    echo "SKIP  ol: no Open Library version yet (first build running or failed: journalctl -u ol-refresh)"
  fi
}

# A probe that fails for everyone proves nothing: each target is first reached
# from the ol VM, and only then must the fetcher fail to reach it.
verify_egress() {
  local lan_ip router ol_ip target host port
  lan_ip="$(on_host "ip -4 -o addr show vmbr0 | awk '{print \$4}' | cut -d/ -f1 | head -1")"
  router="$(on_host "ip -4 route show default dev vmbr0 | awk '{print \$3}' | head -1")"
  ol_ip="$(vm_ip ol)"
  for target in "10.20.0.1:8006" "10.20.0.1:22" "$lan_ip:8006" "$ol_ip:22" "$router:53"; do
    host="${target%:*}" port="${target##*:}"
    if [ "$host" = 10.20.0.1 ]; then
      : # the ol VM is not on vmbr1; the host itself listens there, checked below
    elif ! tcp_from_vm ol "$host" "$port"; then
      bad "egress control: ol cannot reach $target either, so this probe proves nothing"; continue
    fi
    if tcp_from_vm fetcher "$host" "$port"; then bad "egress: fetcher reached $target"; else ok "egress: fetcher cannot reach $target"; fi
    if tcp_from_fetcher_container "$host" "$port"; then bad "egress: fetcher container reached $target"; else ok "egress: fetcher container cannot reach $target"; fi
  done
  expect "egress control: host listens on 10.20.0.1:8006" on_host "ss -ltnH 'sport = :8006' | grep -q ."
  expect "egress: fetcher has no IPv6 address" vm_ssh fetcher "! ip -6 -o addr | grep -v ' lo ' | grep -q inet6"
  expect "egress: fetcher reaches the public internet" vm_ssh fetcher "curl -fsS -m 10 -o /dev/null https://www.wikipedia.org"
  expect "egress: fetcher container reaches the public internet" tcp_from_fetcher_container 1.1.1.1 443
}

verify_idempotent() {
  CHANGES=()
  converge_host_packages; converge_host_network; converge_host_firewall
  local role; for role in fetcher ol; do ensure_vm "$role"; done
  if [ "${#CHANGES[@]}" = 0 ]; then ok "a second provision changes nothing"; else bad "a second provision changed: ${CHANGES[*]}"; fi
}

# --external-from user@host: a machine outside the house checks the host's
# public IPv6 address for open ports.
verify_external() {
  local port
  for port in 22 8006 111 3128; do
    # shellcheck disable=SC2029 # the command is built on the client on purpose
    if ssh "${SSH_OPTS[@]}" "$EXTERNAL_FROM" "nc -6 -z -w 5 $PVE_HOST $port" >/dev/null 2>&1; then
      bad "exposure: port $port is reachable from $EXTERNAL_FROM"
    else
      ok "exposure: port $port closed from outside"
    fi
  done
  expect "exposure control: $EXTERNAL_FROM has IPv6 (reaches 2606:4700:4700::1111:443)" \
    ssh "${SSH_OPTS[@]}" "$EXTERNAL_FROM" "nc -6 -z -w 5 2606:4700:4700::1111 443"
}

# --recovery: kills each service, then reboots the host. Ask Shane before running.
verify_recovery() {
  vm_ssh fetcher "docker kill the-greatest-fetcher-1" >/dev/null
  sleep 30
  expect "recovery: fetcher back after docker kill" vm_ssh fetcher "curl -fsS 127.0.0.1:8081/health"
  if vm_ssh ol "test -f /srv/ol-data/current-version"; then
    vm_ssh ol "docker kill the-greatest-api-1" >/dev/null
    sleep 30
    expect "recovery: api back after docker kill" vm_ssh ol "curl -fsS 127.0.0.1:8080/version"
  fi
  log "rebooting the host"
  on_host "systemctl reboot" || true
  sleep 60
  local _; for _ in $(seq 1 60); do on_host true 2>/dev/null && break; sleep 10; done
  sleep 120
  verify_vms
}

verify_all() {
  verify_host
  verify_vms
  verify_egress
  verify_idempotent
  if [ -n "$EXTERNAL_FROM" ]; then verify_external; fi
  if [ "$RECOVERY" = 1 ]; then verify_recovery; fi
  if [ "$VERIFY_FAILURES" = 0 ]; then log "verify: all passed"; else die "verify: $VERIFY_FAILURES failed"; fi
}
