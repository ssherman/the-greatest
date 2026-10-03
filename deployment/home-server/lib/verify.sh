# deployment/home-server/lib/verify.sh
# shellcheck shell=bash
# provision --verify: everything about the box that can be checked from here.
VERIFY_FAILURES=0
ok() { echo "PASS  $1"; }
bad() { echo "FAIL  $1${2:+ -- $2}"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }
# expect <name> <cmd...>: the command runs in a subshell, so a `die` inside it
# fails the check instead of ending the run; its output is shown on failure.
expect() {
  local name=$1 out rc=0; shift
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" = 0 ]; then ok "$name"; else bad "$name" "rc=$rc"; [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/        /'; fi
}

# Probes return the connection's rc: 0 reached, 124 timed out (what a DROP
# looks like), anything else is something other than a block.
tcp_from_vm() { # tcp_from_vm <role> <host> <port>
  vm_ssh "$1" "timeout 5 bash -c '</dev/tcp/$2/$3'" >/dev/null 2>&1
}
PROBE_PY='import socket,sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), 5)
except (socket.timeout, TimeoutError):
    sys.exit(124)
except OSError:
    sys.exit(1)'
tcp_from_fetcher_container() {
  local b64; b64="$(printf '%s' "$PROBE_PY" | base64 -w0)"
  vm_ssh fetcher "docker exec the-greatest-fetcher-1 python -c \"import base64;exec(base64.b64decode('$b64'))\" $1 $2" >/dev/null 2>&1
}
# probe_rc <fn> <args...>: the rc, even from a `die` in the subshell.
probe_rc() { local rc=0; ("$@") || rc=$?; echo "$rc"; }

# expect_blocked <name> <rc> [extra rc accepted as "no route"]
expect_blocked() {
  local name=$1 rc=$2 alt=${3:-}
  if [ "$rc" = 124 ] || { [ -n "$alt" ] && [ "$rc" = "$alt" ]; }; then ok "$name"
  elif [ "$rc" = 0 ]; then bad "$name" "it connected"
  else bad "$name" "probe failed with rc=$rc, not a timeout, so this proves nothing"; fi
}

host_global_ipv6() { on_host "ip -6 -o addr show vmbr0 scope global | awk '{print \$4}' | cut -d/ -f1 | head -1"; }

verify_host() {
  expect "host: apt update is clean" on_host "! apt-get update -q 2>&1 | grep -qE '^(E|Err):| 401 |401 +Unauthorized'"
  expect "host: enterprise repos disabled" on_host "grep -q '^Enabled: no' /etc/apt/sources.list.d/pve-enterprise.sources"
  expect "host: unattended-upgrades installed" on_host "dpkg -s unattended-upgrades"
  expect "host: nothing listens on 111 (tcp or udp)" on_host "! ss -lntuH 'sport = :111' | grep -q ."
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
# from the ol VM, and only then must the fetcher fail to reach it. "Blocked"
# means a timeout; any other failure is reported as a broken probe.
verify_egress() {
  local lan_ip router ol_ip target host port rc host6
  lan_ip="$(on_host "ip -4 -o addr show vmbr0 | awk '{print \$4}' | cut -d/ -f1 | head -1")"
  router="$(on_host "ip -4 route show default dev vmbr0 | awk '{print \$3}' | head -1")"
  ol_ip="$(vm_ip ol)"
  expect "egress control: fetcher VM probe works" tcp_from_vm fetcher 1.1.1.1 443
  expect "egress control: host reaches 10.20.0.1:8006" on_host "timeout 5 bash -c '</dev/tcp/10.20.0.1/8006'"
  expect "egress control: host reaches 10.20.0.1:22" on_host "timeout 5 bash -c '</dev/tcp/10.20.0.1/22'"
  for target in "10.20.0.1:8006" "10.20.0.1:22" "$lan_ip:8006" "$ol_ip:22" "$router:53"; do
    host="${target%:*}" port="${target##*:}"
    if [ "$host" != 10.20.0.1 ] && ! tcp_from_vm ol "$host" "$port"; then
      bad "egress control: ol cannot reach $target either, so this probe proves nothing"; continue
    fi
    rc="$(probe_rc tcp_from_vm fetcher "$host" "$port")"
    expect_blocked "egress: fetcher cannot reach $target" "$rc"
    rc="$(probe_rc tcp_from_fetcher_container "$host" "$port")"
    expect_blocked "egress: fetcher container cannot reach $target" "$rc"
  done

  # The host's own global IPv6 address, read here and never printed.
  host6="$(host_global_ipv6)"
  if [ -z "$host6" ]; then
    bad "egress: the host has no global IPv6 address to probe"
  else
    if tcp_from_vm ol "$host6" 22; then
      ok "egress control: ol reaches the host's public IPv6 on 22"
      rc="$(probe_rc tcp_from_vm fetcher "$host6" 22)"
      expect_blocked "egress: fetcher cannot reach the host's public IPv6" "$rc" 1
      rc="$(probe_rc tcp_from_fetcher_container "$host6" 22)"
      expect_blocked "egress: fetcher container cannot reach the host's public IPv6" "$rc" 1
    else
      bad "egress control: ol cannot reach the host's public IPv6 on 22, so this probe proves nothing"
    fi
  fi
  expect "egress: fetcher has no IPv6 address" vm_ssh fetcher "! ip -6 -o addr | grep -v ' lo ' | grep -q inet6"
  expect "egress: fetcher reaches the public internet" vm_ssh fetcher "curl -fsS -m 10 -o /dev/null https://www.wikipedia.org"
  expect "egress: fetcher container reaches the public internet (DNS included)" tcp_from_fetcher_container www.wikipedia.org 443
}

verify_idempotent() {
  CHANGES=()
  converge_host_packages; converge_host_network; converge_host_firewall
  local role; for role in fetcher ol; do ensure_vm "$role"; done
  if [ "${#CHANGES[@]}" = 0 ]; then ok "a second provision changes nothing"; else bad "a second provision changed: ${CHANGES[*]}"; fi
}

# --external-from user@host: a machine outside the house checks the host's
# public IPv6 address for open ports. The address is read from the host at
# run time and never printed. A port counts as closed only when nc reports a
# timeout or a refusal; anything else (resolution, usage, no nc, ssh) fails.
verify_external() {
  local host6 port out rc closed22=0
  host6="$(host_global_ipv6)"
  if [ -z "$host6" ]; then bad "exposure: the host has no global IPv6 address to check"; return; fi
  for port in 22 8006 111 3128; do
    rc=0
    # shellcheck disable=SC2029 # the command is built on the client on purpose
    out="$(ssh "${SSH_OPTS[@]}" "$EXTERNAL_FROM" "nc -6 -v -z -w 5 $host6 $port 2>&1" 2>&1)" || rc=$?
    if [ "$rc" = 0 ]; then
      bad "exposure: port $port on the host's public IPv6 is reachable from $EXTERNAL_FROM"
    elif printf '%s' "$out" | grep -qiE 'timed out|refused'; then
      ok "exposure: port $port on the host's public IPv6 is closed from outside"
      if [ "$port" = 22 ]; then closed22=1; fi
    else
      bad "exposure: port $port check was inconclusive (rc=$rc)" "$(printf '%s' "${out//$host6/<host>}" | head -c 200)"
    fi
  done
  if [ "$closed22" = 1 ]; then
    ok "exposure control: nc from $EXTERNAL_FROM reached the address and saw a timeout or refusal on 22"
  else
    bad "exposure control: nc's result for port 22 was not a timeout or refusal"
  fi
  expect "exposure control: $EXTERNAL_FROM has IPv6 (reaches 2606:4700:4700::1111:443)" \
    ssh "${SSH_OPTS[@]}" "$EXTERNAL_FROM" "nc -6 -z -w 5 2606:4700:4700::1111 443"
}

# crash_service <role> <container> <check cmd>: SIGKILL the container's main
# process (a crash; `docker kill` is a manual stop that restart policies respect),
# then expect Docker to bring it back.
crash_service() {
  local role=$1 container=$2 check=$3 before after
  before="$(vm_ssh "$role" "docker inspect -f '{{.RestartCount}}' $container" 2>/dev/null || echo 0)"
  vm_ssh "$role" "sudo kill -9 \"\$(docker inspect -f '{{.State.Pid}}' $container)\"" >/dev/null
  sleep 30
  expect "recovery: $container answers after its process was killed" vm_ssh "$role" "$check"
  after="$(vm_ssh "$role" "docker inspect -f '{{.RestartCount}}' $container" 2>/dev/null || echo 0)"
  if [ "$after" -gt "$before" ] 2>/dev/null; then ok "recovery: $container restart count rose ($before -> $after)"; else bad "recovery: $container restart count did not rise ($before -> $after)"; fi
}

# --recovery: kills each service, then reboots the host. Ask Shane before running.
verify_recovery() {
  crash_service fetcher the-greatest-fetcher-1 "curl -fsS 127.0.0.1:8081/health"
  if vm_ssh ol "test -f /srv/ol-data/current-version"; then
    crash_service ol the-greatest-api-1 "curl -fsS 127.0.0.1:8080/version"
  fi
  log "rebooting the host"
  on_host "systemctl reboot" || true
  sleep 60
  local _ back=0
  for _ in $(seq 1 60); do if on_host true 2>/dev/null; then back=1; break; fi; sleep 10; done
  if [ "$back" = 0 ]; then bad "recovery: the host did not come back within the wait"; return; fi
  sleep 120
  verify_host
  verify_vms
  verify_egress
}

verify_all() {
  export VERIFY=1 # converge, but do not upgrade packages: verify changes nothing
  verify_host
  verify_vms
  verify_egress
  verify_idempotent
  if [ -n "$EXTERNAL_FROM" ]; then verify_external; fi
  if [ "$RECOVERY" = 1 ]; then verify_recovery; fi
  if [ "$VERIFY_FAILURES" = 0 ]; then log "verify: all passed"; else die "verify: $VERIFY_FAILURES failed"; fi
}
