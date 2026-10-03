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
    blkid "$disk" >/dev/null || mkfs.ext4 -q -L ol-data "$disk"
    mkdir -p "$OL_DATA"
    # nofail: a missing disk must not hang boot; ol-refresh.sh refuses to build instead.
    grep -q '^LABEL=ol-data ' /etc/fstab ||
      echo "LABEL=ol-data $OL_DATA ext4 defaults,discard,nofail 0 2" >>/etc/fstab
    mountpoint -q "$OL_DATA" || mount "$OL_DATA"
    ;;
  fetcher)
    # No IPv6 at all: every device in the house has a public IPv6 address (spec §4).
    printf 'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\n' \
      >/etc/sysctl.d/90-no-ipv6.conf
    sysctl -q --system
    ;;
  *) echo "first-boot: unknown ROLE '$ROLE'" >&2; exit 1 ;;
esac

"$here/install-units.sh"
touch "$STATE_DIR/force-deploy"
systemctl start the-greatest-deploy.service
