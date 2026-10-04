# deployment/home-server/lib/vm.sh
# shellcheck shell=bash
# shellcheck disable=SC2034 # the spec variables and image constants are read by provision, which sources this file
# The two VMs: their shape (spec §5), what they are told at first boot, and
# their creation, rebuild and settings.

DEBIAN_IMAGE=debian-13-genericcloud-amd64.qcow2
DEBIAN_IMAGE_DIR=https://cloud.debian.org/images/cloud/trixie/latest
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-$HOME/.ssh/id_ed25519.pub}"

# Storage names come from secrets/home-server.env (spec §12). Functions, not
# assignments: the secrets are loaded after this file is sourced.
vm_storage() { printf '%s' "${VM_STORAGE:-local-lvm}"; }
data_storage() { printf '%s' "${DATA_STORAGE:-$(vm_storage)}"; }
image_storage() { printf '%s' "${IMAGE_STORAGE:-local}"; }

vm_spec() {
  case "$1" in
    ol)
      VMID=110 NAME=ol CORES=12 MEM=24576 OSDISK=32 DATADISK=300
      NET="virtio,bridge=vmbr0,firewall=1" IPCONFIG="ip=dhcp,ip6=auto" NAMESERVER="" STARTUP="order=1" ;;
    fetcher)
      VMID=120 NAME=fetcher CORES=4 MEM=4096 OSDISK=40 DATADISK=0
      NET="virtio,bridge=vmbr1,firewall=1" IPCONFIG="ip=10.20.0.10/24,gw=10.20.0.1"
      NAMESERVER="1.1.1.1 1.0.0.1" STARTUP="order=2" ;;
    *) die "unknown VM role '$1' (ol or fetcher)" ;;
  esac
}

# render_vm_env <role> <out>: the VM's /etc/the-greatest/home-server.env. Each
# VM gets only its own token and check URLs.
render_vm_env() {
  local role=$1 out=$2
  case "$role" in
    ol) printf '%s\n' "ROLE=ol" "REPO_REF=$REPO_REF" "TUNNELS_ENABLED=$TUNNELS_ENABLED" \
          "TUNNEL_TOKEN=${OL_TUNNEL_TOKEN:-}" "HC_HEARTBEAT=${HC_OL_HEARTBEAT:-}" \
          "HC_DEPLOY=${HC_OL_DEPLOY:-}" "HC_REFRESH=${HC_OL_REFRESH:-}" ;;
    fetcher) printf '%s\n' "ROLE=fetcher" "REPO_REF=$REPO_REF" "TUNNELS_ENABLED=$TUNNELS_ENABLED" \
          "TUNNEL_TOKEN=${FETCHER_TUNNEL_TOKEN:-}" "HC_HEARTBEAT=${HC_FETCHER_HEARTBEAT:-}" \
          "HC_DEPLOY=${HC_FETCHER_DEPLOY:-}" "HC_REFRESH=" ;;
    *) die "unknown VM role '$role'" ;;
  esac >"$out"
}

# render_user_data <role> <env-file> <out>
render_user_data() {
  vm_spec "$1"
  [ -f "$SSH_PUBKEY_FILE" ] || die "missing $SSH_PUBKEY_FILE"
  # The key goes into a single-quoted YAML scalar, so a comment containing " #" stays text.
  local key; key="$(cat "$SSH_PUBKEY_FILE")"
  # shellcheck disable=SC2016 # envsubst takes the variable list literally
  VM_NAME="$NAME" ROLE="$1" SSH_PUBKEY="${key//\'/\'\'}" ENV_B64="$(base64 -w0 <"$2")" \
    REPO_REF="$REPO_REF" envsubst '${VM_NAME} ${ROLE} ${SSH_PUBKEY} ${ENV_B64} ${REPO_REF}' \
    <"$HS_DIR/cloud-init/user-data.yaml.tmpl" >"$3"
}

VM_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# vm_ip <role>: fetcher's is fixed; ol's comes from the guest agent.
vm_ip() {
  vm_spec "$1"
  if [ "$1" = fetcher ]; then echo 10.20.0.10; return; fi
  on_host "qm guest cmd $VMID network-get-interfaces 2>/dev/null" |
    jq -r '[.[] | select(.name | test("^(eth|en)")) |."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"] | first // empty'
}

# vm_ssh <role> <cmd>: as `debian`, jumping through the host. Host keys are
# not pinned: the VMs are only reachable through the (pinned) host, and a
# rebuilt VM gets new keys by design.
vm_ssh() {
  local role=$1 ip; shift
  ip="$(vm_ip "$role")"
  [ -n "$ip" ] || die "no IPv4 address for $role yet"
  ssh "${VM_SSH_OPTS[@]}" -o ProxyCommand="ssh ${SSH_OPTS[*]} -W %h:%p root@$PVE_HOST" "debian@$ip" "$@"
}

# ensure_image [refresh]: the Debian cloud image, checksum-verified. A rebuild
# refreshes it; otherwise an existing copy is reused.
ensure_image() {
  local refresh=0 script
  if [ "${1:-}" = refresh ]; then refresh=1; fi
  # Downloads land in a staging dir under their real names, are verified there,
  # and only then replace the installed pair. A failure leaves the installed
  # image untouched. The reuse path re-verifies it against the stored SHA512SUMS.
  read -r -d '' script <<EOF || true
set -u
img=$DEBIAN_IMAGE
url=$DEBIAN_IMAGE_DIR
dir=/var/lib/vz/import
if [ '$(image_storage)' != local ]; then dir=\$(dirname "\$(pvesm path '$(image_storage):import/$DEBIAN_IMAGE')") || exit 1; fi
stage=\$(dirname \$dir)/.image-staging
mkdir -p \$dir
if [ $refresh = 0 ] && cd \$dir && [ -f \$img ] && [ -f SHA512SUMS ] && sha512sum --ignore-missing -c SHA512SUMS; then
  echo "reusing the verified local \$img" >&2
  exit 0
fi
rm -rf \$stage && mkdir -p \$stage && cd \$stage &&
  curl -fsSL -o \$img \$url/\$img && curl -fsSL -o SHA512SUMS \$url/SHA512SUMS &&
  sha512sum --ignore-missing -c SHA512SUMS &&
  mv \$img \$dir/\$img.new && mv SHA512SUMS \$dir/SHA512SUMS.new &&
  mv \$dir/\$img.new \$dir/\$img && mv \$dir/SHA512SUMS.new \$dir/SHA512SUMS
rc=\$?
cd / && rm -rf \$stage
exit \$rc
EOF
  on_host "$script" || die "could not fetch and verify $DEBIAN_IMAGE (any previous good copy is untouched)"
}

write_snippet() { # write_snippet <role>; leaves the rendered env in $ENV_RENDERED
  local tmp; new_tmpdir tmp
  render_vm_env "$1" "$tmp/env"
  render_user_data "$1" "$tmp/env" "$tmp/user-data"
  put_host "$tmp/user-data" "/var/lib/vz/snippets/$NAME-user-data.yaml" 0600
  ENV_RENDERED="$tmp/env"
}

attach_os_disk() {
  on_host "qm set $VMID --scsi0 $(vm_storage):0,import-from=$(image_storage):import/$DEBIAN_IMAGE,discard=on,ssd=1,iothread=1 --boot order=scsi0 >/dev/null &&
    qm disk resize $VMID scsi0 ${OSDISK}G"
}

create_vm() {
  log "creating VM $VMID ($NAME)"
  on_host "qm create $VMID --name $NAME --machine q35 --cpu host --cores $CORES --memory $MEM --balloon 0 \
    --scsihw virtio-scsi-single --net0 $NET --agent enabled=1 --onboot 1 --startup $STARTUP \
    --ostype l26 --serial0 socket --vga serial0 --ide2 $(vm_storage):cloudinit \
    --ipconfig0 $IPCONFIG --cicustom user=local:snippets/$NAME-user-data.yaml" || die "qm create $VMID failed"
  local half="VM $VMID ($NAME) was created but not finished and is left as it is; destroying it (qm destroy $VMID --purge) and re-running provision is Shane's call"
  if [ -n "$NAMESERVER" ]; then on_host "qm set $VMID --nameserver '$NAMESERVER' >/dev/null" || die "$half"; fi
  attach_os_disk || die "$half"
  if [ "$DATADISK" != 0 ]; then
    on_host "qm set $VMID --scsi1 $(data_storage):$DATADISK,discard=on,ssd=1,iothread=1 >/dev/null" || die "$half"
  fi
  on_host "qm start $VMID" || die "$half"
  note_change "created VM $VMID ($NAME)"
}

wait_for_first_boot() { # wait_for_first_boot <role>
  local i
  for i in $(seq 1 60); do (vm_ssh "$1" true) 2>/dev/null && break; sleep 10; done
  vm_ssh "$1" true || die "$1 never answered SSH"
  log "waiting for $1's cloud-init (the first image build takes several minutes)"
  local out
  out="$(vm_ssh "$1" "cloud-init status --wait >/dev/null; cloud-init status --long")" || true
  printf '%s\n' "$out" >&2
  grep -q 'status: done' <<<"$out" ||
    die "$1's cloud-init did not finish cleanly; read: vm_ssh $1 'sudo cat /var/log/cloud-init-output.log'"
}

converge_vm_settings() {
  local cfg drift=0
  cfg="$(on_host "qm config $VMID")"
  grep -qx "cores: $CORES" <<<"$cfg" || drift=1
  grep -qx "memory: $MEM" <<<"$cfg" || drift=1
  grep -qx "balloon: 0" <<<"$cfg" || drift=1
  grep -qx "onboot: 1" <<<"$cfg" || drift=1
  grep -qx "startup: $STARTUP" <<<"$cfg" || drift=1
  if [ "$DATADISK" != 0 ]; then
    grep -q '^scsi1:' <<<"$cfg" || die "VM $VMID ($NAME) has no data disk (scsi1); not touching it, look at: qm config $VMID"
  fi
  if [ "$drift" = 1 ]; then
    on_host "qm set $VMID --cores $CORES --memory $MEM --balloon 0 --onboot 1 --startup $STARTUP >/dev/null"
    note_change "VM $VMID settings (takes effect at its next restart)"
  fi
}

push_vm_env() { # push_vm_env <role>: the env file, then a forced deploy if it changed
  local want have
  want="$(sha256sum <"$ENV_RENDERED" | cut -d' ' -f1)"
  have="$(vm_ssh "$1" "sudo sha256sum /etc/the-greatest/home-server.env | cut -d' ' -f1")"
  [ "$want" = "$have" ] && return 0
  vm_ssh "$1" "sudo install -m 0600 /dev/stdin /etc/the-greatest/home-server.env" <"$ENV_RENDERED"
  vm_ssh "$1" "sudo touch /var/lib/the-greatest/force-deploy && sudo systemctl start the-greatest-deploy.service" ||
    log "deploy on $1 failed or was deferred; it retries every 15 minutes"
  note_change "$1 env"
}

ensure_vm() {
  vm_spec "$1"
  ensure_image
  write_snippet "$1"
  if ! on_host "qm status $VMID >/dev/null 2>&1"; then
    create_vm
    wait_for_first_boot "$1"
    return
  fi
  converge_vm_settings
  if ! on_host "qm status $VMID | grep -q running"; then on_host "qm start $VMID"; note_change "started VM $VMID"; fi
  # push_vm_env needs the env file and state dir cloud-init creates, so a VM
  # still in its first boot is waited for. A finished VM answers at once.
  local ci
  ci="$( (vm_ssh "$1" 'cloud-init status') 2>/dev/null)" || true
  if ! grep -q 'status: done' <<<"$ci"; then wait_for_first_boot "$1"; fi
  push_vm_env "$1"
}

rebuild_vm() { # replace only the OS disk; the data disk is never touched (spec §5)
  vm_spec "$1"
  on_host "qm status $VMID >/dev/null 2>&1" || die "VM $VMID does not exist; run provision without --rebuild"
  ensure_image refresh
  write_snippet "$1"
  on_host "qm shutdown $VMID --timeout 120 || qm stop $VMID"
  on_host "qm disk unlink $VMID --idlist scsi0 --force" || die "could not unlink VM $VMID's OS disk; nothing was changed after the shutdown"
  local gone="VM $VMID now has no OS disk; re-run: provision --rebuild $1"
  attach_os_disk || die "$gone"
  on_host "qm cloudinit update $VMID" || die "$gone"
  on_host "qm start $VMID" || die "$gone"
  note_change "rebuilt VM $VMID ($NAME)"
  wait_for_first_boot "$1"
}

enable_tunnels() {
  if [ -z "${OL_TUNNEL_TOKEN:-}" ] || [ -z "${FETCHER_TUNNEL_TOKEN:-}" ]; then
    die "both tunnel tokens must be set in secrets/home-server.env first (sops secrets/home-server.env)"
  fi
  on_host "touch $HOST_STATE/tunnels-enabled"
  TUNNELS_ENABLED=1
  local role
  for role in fetcher ol; do vm_spec "$role"; write_snippet "$role"; push_vm_env "$role"; done
}

# disable_tunnels: clear the flag and push TUNNELS_ENABLED=0; the forced deploy
# that follows stops and removes cloudflared (guest/deploy.sh).
disable_tunnels() {
  on_host "rm -f $HOST_STATE/tunnels-enabled"
  TUNNELS_ENABLED=0
  local role
  for role in fetcher ol; do vm_spec "$role"; write_snippet "$role"; push_vm_env "$role"; done
}
