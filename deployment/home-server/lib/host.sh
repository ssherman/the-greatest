# deployment/home-server/lib/host.sh
# shellcheck shell=bash
# shellcheck disable=SC2034 # UPGRADED is read by provision, which sources this file
# The Proxmox host (spec §4): packages, network, firewall.

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
  local pending
  pending="$(on_host "apt-get -s full-upgrade | grep -c '^Inst' || true")"
  if [ "$pending" != 0 ]; then
    log "upgrading $pending host package(s)"
    on_host "DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade >/dev/null"
    UPGRADED="$pending" # reported, but not a "change" for the idempotence check
  fi

  # Nothing here uses NFS.
  if on_host "systemctl is-enabled --quiet rpcbind.socket || systemctl is-active --quiet rpcbind"; then
    on_host "systemctl disable --now rpcbind.socket rpcbind.service >/dev/null 2>&1"
    note_change "disabled rpcbind"
  fi

  # Custom cloud-init user-data lives in snippets on `local`.
  # (`pvesm config` does not exist on PVE 9, so read storage.cfg.)
  if ! on_host "awk '/^dir: local\$/{f=1;next} /^[a-z]+:/{f=0} f && /content/' /etc/pve/storage.cfg | grep -q snippets"; then
    on_host "pvesm set local --content iso,vztmpl,backup,import,snippets"
    note_change "snippets on local storage"
  fi
  on_host "mkdir -p $HOST_STATE"

  local running newest
  running="$(on_host "uname -r")"
  newest="$(on_host "ls /boot/vmlinuz-* | sed 's|/boot/vmlinuz-||' | sort -V | tail -1")"
  if [ "$running" != "$newest" ]; then
    log "NOTE: kernel $newest is installed but $running is running; the host never reboots itself"
  fi
}

# Stubs, replaced by Tasks 6-7.
converge_host_network() { :; }
converge_host_firewall() { :; }
