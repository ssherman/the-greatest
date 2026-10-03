# deployment/home-server/lib/host.sh
# shellcheck shell=bash
# shellcheck disable=SC2034 # UPGRADED is read by provision, which sources this file
# The Proxmox host (spec §4): packages, network, firewall.

# converge_host_zfs: cap ZFS's cache (the ARC) on a host that runs ZFS, so it
# cannot crowd out the VMs (spec §12). A host without ZFS is left alone.
converge_host_zfs() {
  on_host "test -d /sys/module/zfs" || return 0
  local arc="${ARC_MAX_BYTES:-8589934592}" tmp file_changed=0
  [[ "$arc" =~ ^[0-9]+$ ]] || die "ARC_MAX_BYTES must be a number of bytes, got '$arc'"
  new_tmpdir tmp
  printf 'options zfs zfs_arc_max=%s\n' "$arc" >"$tmp/zfs.conf"
  host_file_matches "$tmp/zfs.conf" /etc/modprobe.d/zfs.conf || file_changed=1
  put_host "$tmp/zfs.conf" /etc/modprobe.d/zfs.conf
  if [ "$(on_host "cat /sys/module/zfs/parameters/zfs_arc_max")" != "$arc" ]; then
    on_host "echo $arc > /sys/module/zfs/parameters/zfs_arc_max" || die "could not set zfs_arc_max at runtime"
    note_change "zfs_arc_max set to $arc"
  fi
  # A root-on-ZFS host loads the module from the initramfs, which carries modprobe.d.
  if [ "$file_changed" = 1 ] && [ "$(on_host "findmnt -no FSTYPE /")" = zfs ]; then
    on_host "update-initramfs -u -k all >/dev/null 2>&1" || die "update-initramfs failed after capping the ZFS ARC"
    note_change "initramfs rebuilt for the ARC cap"
  fi
}

converge_host_packages() {
  put_host "$HS_DIR/host/sbin/confirm-or-revert" /usr/local/sbin/confirm-or-revert 0755

  # The enterprise repos need a subscription; with none, apt update fails.
  local f
  for f in pve-enterprise ceph; do
    if on_host "test -f /etc/apt/sources.list.d/$f.sources && ! grep -q '^Enabled: no' /etc/apt/sources.list.d/$f.sources"; then
      on_host "echo 'Enabled: no' >> /etc/apt/sources.list.d/$f.sources"
      note_change "disabled $f.sources"
    fi
  done
  put_host "$HS_DIR/host/apt/proxmox.sources" /etc/apt/sources.list.d/proxmox.sources
  put_host "$HS_DIR/host/apt/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
  put_host "$HS_DIR/host/apt/52unattended-upgrades-home-server" /etc/apt/apt.conf.d/52unattended-upgrades-home-server

  on_host "apt-get update -q >/dev/null" || die "apt-get update failed on the host"
  if ! on_host "dpkg -s jq unattended-upgrades >/dev/null 2>&1"; then
    on_host "DEBIAN_FRONTEND=noninteractive apt-get install -y -q jq unattended-upgrades >/dev/null"
    note_change "installed jq unattended-upgrades"
  fi
  if [ "${VERIFY:-0}" = 1 ]; then
    log "skipping upgrade under --verify"
  else
    local pending
    # No pipefail on the far side: capture first so a failing apt is not a zero.
    # shellcheck disable=SC2016 # the remote shell expands these
    pending="$(on_host 'out="$(apt-get -s full-upgrade)" || exit 1; printf "%s\n" "$out" | grep -c "^Inst" || true')" ||
      die "apt-get -s full-upgrade failed on the host"
    if [ "$pending" != 0 ]; then
      log "upgrading $pending host package(s)"
      # A transient unit, so an SSH drop cannot SIGHUP dpkg mid-upgrade.
      on_host "systemd-run --wait --pipe --quiet --collect --unit=provision-upgrade env DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade >/dev/null" ||
        die "apt-get full-upgrade failed on the host"
      UPGRADED="$pending" # reported, but not a "change" for the idempotence check
    fi
  fi

  # Nothing here uses NFS.
  # shellcheck disable=SC2016 # the remote shell expands these
  if ! on_host 'for u in rpcbind.socket rpcbind.service; do [ "$(systemctl is-enabled $u 2>/dev/null)" = masked ] || exit 1; done'; then
    on_host "systemctl mask --now rpcbind.socket rpcbind.service >/dev/null 2>&1"
    note_change "masked rpcbind"
  fi

  # Custom cloud-init user-data lives in snippets on `local`.
  # (`pvesm config` does not exist on PVE 9, so read storage.cfg.)
  if ! on_host "awk '/^dir: local\$/{f=1;next} /^[a-z]+:/{f=0} f && /content/' /etc/pve/storage.cfg | grep -q snippets"; then
    on_host "pvesm set local --content iso,vztmpl,backup,import,snippets"
    note_change "snippets on local storage"
  fi
  on_host "mkdir -p $HOST_STATE"
  converge_host_zfs

  local running newest
  running="$(on_host "uname -r")"
  newest="$(on_host "ls /boot/vmlinuz-* | sed 's|/boot/vmlinuz-||' | sort -V | tail -1")"
  if [ "$running" != "$newest" ]; then
    log "NOTE: kernel $newest is installed but $running is running; the host never reboots itself"
  fi
}

# network_change <description> <function>: run a change that could cut this
# session off. A revert is armed first; only a successful reconnect confirms it.
network_change() {
  local what=$1 mutate=$2
  on_host "cp -a /etc/network/interfaces /root/interfaces.provision-bak &&
    rm -rf /root/interfaces.d.provision-bak && cp -a /etc/network/interfaces.d /root/interfaces.d.provision-bak"
  on_host "confirm-or-revert arm network 120 'cp -a /root/interfaces.provision-bak /etc/network/interfaces;
    rm -rf /etc/network/interfaces.d; cp -a /root/interfaces.d.provision-bak /etc/network/interfaces.d; ifreload -a'"
  "$mutate"
  # Detached: ifreload may drop this very connection.
  on_host "rm -f /run/provision-ifreload.rc; systemd-run --quiet --collect --unit=provision-ifreload /bin/sh -c 'ifreload -a; echo \$? > /run/provision-ifreload.rc'" || true
  sleep 15
  if on_host true; then
    if [ "$(on_host "cat /run/provision-ifreload.rc 2>/dev/null" || true)" = 0 ]; then
      on_host "confirm-or-revert confirm network"
      note_change "$what"
    else
      log "ifreload did not report success after: $what; leaving the revert armed"
      sleep 130
      die "'$what' was reverted: ifreload failed or did not finish"
    fi
  else
    log "lost the host after: $what; waiting for the automatic revert"
    sleep 130
    if on_host true; then die "'$what' cut off SSH and was reverted"; fi
    die "host unreachable even after the revert; use the console"
  fi
}

add_vmbr0_ipv4() {
  on_host "sed -i '/^iface vmbr0 inet6 /i iface vmbr0 inet static\n\taddress $PVE_LAN_IPV4\n\tgateway $PVE_LAN_GATEWAY4\n' /etc/network/interfaces &&
    grep -q '^iface vmbr0 inet static' /etc/network/interfaces"
}
write_vmbr1() { on_host "cat > /etc/network/interfaces.d/vmbr1" <"$HS_DIR/host/network/vmbr1"; }

# The vmbr1 post-up rules must exist exactly once; a duplicate means a reload
# re-added them.
assert_nat_rules_single() {
  local nat ct
  nat="$(on_host "iptables -t nat -S POSTROUTING | grep -c -- '-s 10.20.0.0/24 -o vmbr0 -j MASQUERADE' || true")"
  ct="$(on_host "iptables -t raw -S PREROUTING | grep -c -- '-i fwbr+ -j CT --zone 1' || true")"
  [ "$nat" = 1 ] || die "expected one MASQUERADE rule for 10.20.0.0/24, found $nat"
  [ "$ct" = 1 ] || die "expected one raw CT zone rule, found $ct"
}

converge_host_network() {
  # GitHub and ghcr.io have no IPv6, so the host and guests need IPv4 (spec §1).
  # Static, not DHCP: ifupdown2 treats an interface with an `inet dhcp` stanza as
  # wholly dhcp (dhcp.py:191 starts `dhclient -6`; address.py:1565 skips static
  # addresses), which drops vmbr0's static IPv6.
  [ -n "${PVE_LAN_IPV4:-}" ] && [ -n "${PVE_LAN_GATEWAY4:-}" ] ||
    die "PVE_LAN_IPV4 and PVE_LAN_GATEWAY4 must be set in secrets/home-server.env"
  if ! on_host "grep -q '^iface vmbr0 inet ' /etc/network/interfaces"; then
    network_change "vmbr0 gains static IPv4 $PVE_LAN_IPV4" add_vmbr0_ipv4
  else
    local have
    have="$(on_host "awk '/^iface vmbr0 inet /{f=1;next} /^iface|^auto|^source/{f=0} f && \$1==\"address\" {print \$2}' /etc/network/interfaces")"
    [ "$have" = "$PVE_LAN_IPV4" ] || die "vmbr0 has IPv4 ${have:-<none>}, secrets say $PVE_LAN_IPV4; fix by hand"
  fi
  if ! host_file_matches "$HS_DIR/host/network/vmbr1" /etc/network/interfaces.d/vmbr1; then
    network_change "vmbr1 private NAT bridge" write_vmbr1
  fi

  assert_nat_rules_single

  LAN_IPV4_CIDR="$(on_host "ip -4 -o route show dev vmbr0 proto kernel scope link | awk '{print \$1}' | head -1")"
  LAN_IPV6_PREFIX="$(on_host "ip -6 -o route show dev vmbr0 proto kernel | awk '\$1 !~ /^fe80/ {print \$1}' | head -1")"
  [ -n "$LAN_IPV4_CIDR" ] || die "vmbr0 has no IPv4 route; is the static inet stanza for PVE_LAN_IPV4 present in /etc/network/interfaces?"
  [ -n "$LAN_IPV6_PREFIX" ] || log "vmbr0 has no global IPv6 prefix; the firewall sets will be IPv4 only"
  export LAN_IPV4_CIDR LAN_IPV6_PREFIX

  [ "$(on_host "sysctl -n net.ipv4.ip_forward")" = 1 ] || die "ip_forward is off; vmbr1's post-up did not run"
  [ "$(on_host "sysctl -n net.ipv6.conf.all.forwarding")" = 0 ] || die "IPv6 forwarding is on; the fetcher must have no IPv6 path"
}

# render_cluster_fw <out>: the datacenter file with this house's LAN ranges.
render_cluster_fw() {
  # shellcheck disable=SC2016 # envsubst takes the variable list literally
  # With no IPv6 prefix the placeholder line is dropped, not rendered blank.
  { if [ -n "${LAN_IPV6_PREFIX:-}" ]; then cat; else grep -vxF '${LAN_IPV6_PREFIX}'; fi; } \
    <"$HS_DIR/host/firewall/cluster.fw.tmpl" |
    LAN_IPV4_CIDR="$LAN_IPV4_CIDR" LAN_IPV6_PREFIX="${LAN_IPV6_PREFIX:-}" \
      envsubst '${LAN_IPV4_CIDR} ${LAN_IPV6_PREFIX}' >"$1"
}

converge_host_firewall() {
  # The rendered files hold the host's /64; remove them on any exit, die included.
  new_tmpdir FW_RENDERED
  render_cluster_fw "$FW_RENDERED/cluster.fw"
  cp "$HS_DIR/host/firewall/host.fw" "$HS_DIR/host/firewall/110.fw" "$HS_DIR/host/firewall/120.fw" "$FW_RENDERED/"

  # cluster.fw is last: it is the file that turns the firewall on.
  local pairs=("host.fw:/etc/pve/nodes/pve/host.fw" "110.fw:/etc/pve/firewall/110.fw"
    "120.fw:/etc/pve/firewall/120.fw" "cluster.fw:/etc/pve/firewall/cluster.fw")
  local pair stale=()
  for pair in "${pairs[@]}"; do
    host_file_matches "$FW_RENDERED/${pair%%:*}" "${pair#*:}" || stale+=("$pair")
  done
  # Matching files are not enough: a fired revert leaves them in place with the
  # firewall stopped. Then fall through and apply under a fresh revert.
  if [ "${#stale[@]}" = 0 ] && on_host "pve-firewall status | grep -q 'enabled/running'"; then
    return 0
  fi

  # The revert disables the datacenter firewall in cluster.fw before stopping
  # it, so a reboot afterwards comes up open rather than with the bad rules, and
  # the next run sees cluster.fw differ and rewrites it.
  on_host "confirm-or-revert arm firewall 120 \"sed -i 's/^enable: 1/enable: 0/' /etc/pve/firewall/cluster.fw; pve-firewall stop\""
  for pair in "${stale[@]}"; do put_host "$FW_RENDERED/${pair%%:*}" "${pair#*:}"; done
  # compile exits 0 on bad rules (it warns on stderr and skips them).
  local warnings
  warnings="$(on_host "pve-firewall compile 2>&1 >/dev/null")" || die "pve-firewall compile failed: $warnings"
  [ -z "$warnings" ] || die "pve-firewall rejected rules: $warnings"
  on_host "systemctl restart pve-firewall"
  sleep 15
  if on_host "pve-firewall status | grep -q 'enabled/running'"; then
    on_host "confirm-or-revert confirm firewall"
  else
    die "firewall did not come up; the armed revert stops it in under two minutes"
  fi
  # A pve-firewall restart must leave vmbr1's NAT and CT rules alone (spec §4).
  assert_nat_rules_single
}
