#!/usr/bin/env bash
# deployment/home-server/guest/first-boot.sh
# cloud-init's last step (cloud-init/user-data.yaml.tmpl), after Docker is
# installed and the repo is cloned. Also runs on a rebuilt VM's first boot.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
load_env
mkdir -p "$STATE_DIR"

case "$ROLE" in
  ol)
    disk=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
    # Format only a blank disk: a rebuilt VM keeps the data it had (spec §5).
    # An absent disk is skipped (blkid -p on a missing device also exits 2, and
    # mkfs would fail and abort first-boot before the units install). blkid -p
    # exits 2 only for "nothing found"; any other failure (I/O error) leaves
    # the disk untouched.
    if [ ! -b "$disk" ]; then
      log "data disk $disk is absent; not formatting or mounting it"
    else
      rc=0
      blkid -p "$disk" >/dev/null || rc=$?
      if [ "$rc" = 2 ]; then
        mkfs.ext4 -q -L ol-data "$disk"
      elif [ "$rc" != 0 ]; then
        log "blkid exited $rc on $disk; not formatting it"
      fi
    fi
    mkdir -p "$OL_DATA"
    # nofail: a missing disk must not hang boot; ol-refresh.sh refuses to build instead.
    grep -q '^LABEL=ol-data ' /etc/fstab ||
      echo "LABEL=ol-data $OL_DATA ext4 defaults,discard,nofail 0 2" >>/etc/fstab
    # A failed mount must not stop the units installing: ol-refresh.sh refuses to build unmounted.
    mountpoint -q "$OL_DATA" || mount "$OL_DATA" || log "could not mount $OL_DATA"
    ;;
  fetcher)
    # No IPv6 at all: every device in the house has a public IPv6 address (spec §4).
    # The sysctl alone held only until the first reboot: networkd brings eth0 up
    # with link-local addressing and turns IPv6 back on for it. With link-local
    # off it leaves the sysctl alone.
    printf 'network:\n  version: 2\n  ethernets:\n    eth0:\n      link-local: []\n      accept-ra: false\n' |
      install -m 0600 /dev/stdin /etc/netplan/90-no-ipv6.yaml
    netplan generate
    networkctl reload
    networkctl reconfigure eth0
    printf 'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.eth0.disable_ipv6 = 1\n' \
      >/etc/sysctl.d/90-no-ipv6.conf
    sysctl -q --system || log "sysctl --system failed"
    ;;
  *) echo "first-boot: unknown ROLE '$ROLE'" >&2; exit 1 ;;
esac

"$here/install-units.sh"
touch "$STATE_DIR/force-deploy"
systemctl start the-greatest-deploy.service
