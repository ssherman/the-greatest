# deployment/home-server/lib/vm.sh
# shellcheck shell=bash
# shellcheck disable=SC2034 # the spec variables and image constants are read by provision, which sources this file
# The two VMs: their shape (spec §5), what they are told at first boot, and
# their creation, rebuild and settings.

DEBIAN_IMAGE=debian-13-genericcloud-amd64.qcow2
DEBIAN_IMAGE_DIR=https://cloud.debian.org/images/cloud/trixie/latest
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-$HOME/.ssh/id_ed25519.pub}"

vm_spec() {
  case "$1" in
    ol)
      VMID=110 NAME=ol CORES=8 MEM=16384 OSDISK=32 DATADISK=300
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
  # shellcheck disable=SC2016 # envsubst takes the variable list literally
  VM_NAME="$NAME" ROLE="$1" SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE")" ENV_B64="$(base64 -w0 <"$2")" \
    REPO_REF="$REPO_REF" envsubst '${VM_NAME} ${ROLE} ${SSH_PUBKEY} ${ENV_B64} ${REPO_REF}' \
    <"$HS_DIR/cloud-init/user-data.yaml.tmpl" >"$3"
}

# Stub, replaced by Task 6.
ensure_vm() { :; }
