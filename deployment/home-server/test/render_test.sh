#!/usr/bin/env bash
# deployment/home-server/test/render_test.sh
# shellcheck disable=SC2016 # the Ruby programs are single-quoted on purpose
# What each VM is told at first boot.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"
# shellcheck source=../lib/common.sh
. "$HS_DIR/lib/common.sh"
# shellcheck source=../lib/host.sh
. "$HS_DIR/lib/host.sh"
# shellcheck source=../lib/vm.sh
. "$HS_DIR/lib/vm.sh"
# shellcheck source=../lib/verify.sh
. "$HS_DIR/lib/verify.sh"

new_sandbox
export REPO_REF=main TUNNELS_ENABLED=0 OL_TUNNEL_TOKEN=ol-token FETCHER_TUNNEL_TOKEN=fetcher-token
export HC_OL_HEARTBEAT=https://hc.test/ol-beat HC_OL_DEPLOY=https://hc.test/ol-deploy HC_OL_REFRESH=https://hc.test/ol-refresh
export HC_FETCHER_HEARTBEAT=https://hc.test/f-beat HC_FETCHER_DEPLOY=https://hc.test/f-deploy
echo "ssh-ed25519 AAAATEST test@example.com" >"$SANDBOX/key.pub"
export SSH_PUBKEY_FILE="$SANDBOX/key.pub"

for role in ol fetcher; do
  render_vm_env "$role" "$SANDBOX/$role.env"
  render_user_data "$role" "$SANDBOX/$role.env" "$SANDBOX/$role.yaml"
done
env_from_yaml() { # decode the env file a rendered user-data carries
  ruby -ryaml -rbase64 -e 'y = YAML.load_file(ARGV[0]); f = y["write_files"].find { |w| w["path"] == "/etc/the-greatest/home-server.env" }; print Base64.decode64(f["content"])' "$1"
}

t_yaml() { for r in ol fetcher; do ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$SANDBOX/$r.yaml" || return 1; done; }
t_first_line() { [ "$(head -1 "$SANDBOX/ol.yaml")" = "#cloud-config" ]; }
# ${distro_codename} is apt's own variable, meant to survive rendering.
t_no_leftovers() { ! cat "$SANDBOX/ol.yaml" "$SANDBOX/fetcher.yaml" | grep -v 'distro_codename' | grep -q '\${'; }
t_ol_env() {
  env_from_yaml "$SANDBOX/ol.yaml" | grep -qx 'ROLE=ol' &&
    env_from_yaml "$SANDBOX/ol.yaml" | grep -qx 'TUNNEL_TOKEN=ol-token' &&
    env_from_yaml "$SANDBOX/ol.yaml" | grep -qx 'HC_REFRESH=https://hc.test/ol-refresh'
}
t_fetcher_isolation() {
  local env; env="$(env_from_yaml "$SANDBOX/fetcher.yaml")"
  grep -qx 'TUNNEL_TOKEN=fetcher-token' <<<"$env" && ! grep -q 'ol-' <<<"$env"
}
t_env_keys() {
  local r keys
  for r in ol fetcher; do
    keys="$(env_from_yaml "$SANDBOX/$r.yaml" | cut -d= -f1 | tr '\n' ' ')"
    [ "$keys" = "ROLE REPO_REF TUNNELS_ENABLED TUNNEL_TOKEN HC_HEARTBEAT HC_DEPLOY HC_REFRESH " ] || return 1
  done
}
t_codename_literal() {
  grep -qF '${distro_codename}-security' "$SANDBOX/ol.yaml" "$SANDBOX/fetcher.yaml"
}
t_key() { grep -q 'ssh-ed25519 AAAATEST' "$SANDBOX/ol.yaml"; }
t_ref() { grep -q 'clone --depth 1 --branch main ' "$SANDBOX/ol.yaml"; }
t_blank_secrets() {
  (unset OL_TUNNEL_TOKEN HC_OL_HEARTBEAT; render_vm_env ol "$SANDBOX/blank.env") &&
    grep -qx 'TUNNEL_TOKEN=' "$SANDBOX/blank.env"
}

t_cluster_fw() {
  local out="$SANDBOX/cluster.fw" set
  LAN_IPV4_CIDR=192.0.2.0/24 LAN_IPV6_PREFIX=2001:db8:1::/64 render_cluster_fw "$out" || return 1
  ! grep -q '\${' "$out" || return 1
  for set in lan management; do
    sed -n "/^\[IPSET $set\]/,/^\$/p" "$out" | grep -qx '192.0.2.0/24' || return 1
    sed -n "/^\[IPSET $set\]/,/^\$/p" "$out" | grep -qx '2001:db8:1::/64' || return 1
  done
}

t_cluster_fw_v4_only() {
  local out="$SANDBOX/cluster4.fw" set
  LAN_IPV4_CIDR=192.0.2.0/24 LAN_IPV6_PREFIX='' render_cluster_fw "$out" || return 1
  ! grep -q '\${' "$out" || return 1
  for set in lan management; do
    # Byte-exact (a $(...) capture would hide trailing blank lines): the
    # header dropped, the section is the one IPv4 line and its blank terminator.
    sed -n "/^\[IPSET $set\]/,/^\$/p" "$out" | sed 1d >"$SANDBOX/block"
    printf '192.0.2.0/24\n\n' | cmp -s - "$SANDBOX/block" || return 1
  done
  # No line of only whitespace, and no two blank lines in a row, anywhere.
  ! grep -qE '^[[:space:]]+$' "$out" || return 1
  cat -s "$out" | cmp -s - "$out" || return 1
  [ "$(grep -c '^\[IPSET' "$out")" = 3 ]
}
t_fetcher_fw() {
  local out="$SANDBOX/120.fw"
  render_fetcher_fw "$out" 203.0.113.7 || return 1
  ! grep -q '\${' "$out" || return 1
  [ "$(sed -n '/^\[IPSET house_public\]/,/^$/p' "$out" | sed 1d)" = 203.0.113.7 ] || return 1
  grep -qx 'OUT DROP -dest +guest/house_public -log nolog' "$out" &&
    grep -qx 'OUT DROP -dest +private -log nolog' "$out" &&
    [ "$(sed -n '/^\[IPSET ipfilter-net0\]/,/^$/p' "$out" | sed 1d)" = 10.20.0.10 ]
}
t_fetcher_fw_refuses_bad_ip() {
  ! render_fetcher_fw "$SANDBOX/bad.fw" "" && ! render_fetcher_fw "$SANDBOX/bad.fw" 2001:db8::1 &&
    ! render_fetcher_fw "$SANDBOX/bad.fw" "203.0.113.7 x"
}
t_fetcher_fw_not_committed_rendered() {
  [ ! -e "$HS_DIR/host/firewall/120.fw" ] && grep -qx '${HOUSE_PUBLIC_IPV4}' "$HS_DIR/host/firewall/120.fw.tmpl"
}
t_reboot_reason() {
  local msg
  [ -z "$(reboot_needed_reason 2.3.4-pve1 zfs-2.3.4-pve1 6.8.1 6.8.1)" ] &&
    [ -z "$(reboot_needed_reason "" "" 6.8.1 6.8.1)" ] || return 1
  msg="$(reboot_needed_reason 2.3.4-pve1 zfs-2.4.4-pve1 6.8.1 6.8.1)"
  grep -q '2.3.4-pve1' <<<"$msg" && grep -q '2.4.4-pve1' <<<"$msg" && grep -q 'onboot' <<<"$msg" || return 1
  msg="$(reboot_needed_reason "" "" 6.8.1 6.14.0)"
  grep -q '6.8.1' <<<"$msg" && grep -q '6.14.0' <<<"$msg"
}
t_vm_spec_sizes() {
  vm_spec ol && [ "$CORES $MEM $DATADISK" = "12 24576 300" ] || return 1
  vm_spec fetcher && [ "$CORES $MEM" = "4 4096" ]
}
t_storage_defaults() {
  [ "$(unset VM_STORAGE DATA_STORAGE IMAGE_STORAGE; echo "$(vm_storage) $(data_storage) $(image_storage)")" = "local-lvm local-lvm local" ] &&
    [ "$(VM_STORAGE=local-zfs DATA_STORAGE=rpool2 IMAGE_STORAGE=local; echo "$(vm_storage) $(data_storage) $(image_storage)")" = "local-zfs rpool2 local" ] &&
    [ "$(VM_STORAGE=local-zfs; unset DATA_STORAGE; data_storage)" = "local-zfs" ]
}
t_trace_ip() {
  [ "$(printf 'fl=1\nh=1.1.1.1\nip=203.0.113.9\nts=1\n' | pick_trace_ip)" = "203.0.113.9" ] &&
    [ -z "$(printf 'ip=not-an-address\nh=1.1.1.1\n' | pick_trace_ip)" ] &&
    [ -z "$(printf 'warp=off\n' | pick_trace_ip)" ]
}

t_key_with_comment() {
  local f="$SANDBOX/hash.pub"
  echo "ssh-ed25519 AAAATEST it's # x" >"$f"
  SSH_PUBKEY_FILE="$f" render_user_data ol "$SANDBOX/ol.env" "$SANDBOX/hash.yaml" &&
    [ "$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["users"][0]["ssh_authorized_keys"][0]' "$SANDBOX/hash.yaml")" = "ssh-ed25519 AAAATEST it's # x" ]
}
t_runcmd_fail_fast() {
  ruby -ryaml -e 'c = YAML.load_file(ARGV[0])["runcmd"].find { |r| r.is_a?(Array) }; exit(c[0] == "bash" && c[1] =~ /e/ && c[2] == "pipefail" && c.last.include?("first-boot.sh") ? 0 : 1)' "$SANDBOX/ol.yaml"
}

t_tmpdirs_cleaned() {
  local out
  out="$(bash -c '. "$1/lib/common.sh"; new_tmpdir a; new_tmpdir b; echo "$a $b"; die gone' _ "$HS_DIR" 2>/dev/null)"
  # shellcheck disable=SC2086 # two paths, split on purpose
  set -- $out
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ ! -e "$1" ] && [ ! -e "$2" ]
}
check "temp dirs holding rendered secrets are removed even when provision dies" t_tmpdirs_cleaned
check "a key comment containing ' #' stays inside the YAML string" t_key_with_comment
check "docker, clone and first-boot run as one fail-fast script" t_runcmd_fail_fast
check "both user-data files are valid YAML" t_yaml
check "user-data starts with #cloud-config" t_first_line
check "no template variable is left unrendered" t_no_leftovers
check "ol gets its role, token and refresh check" t_ol_env
check "fetcher holds nothing of ol's" t_fetcher_isolation
check "each env has exactly the keys guest/lib.sh documents" t_env_keys
check "the security-only origin pattern survives rendering" t_codename_literal
check "the dev key is authorized" t_key
check "the VM clones the tracked ref" t_ref
check "unset secrets render as blanks, not errors" t_blank_secrets
check "cluster.fw renders both LAN ranges into lan and management" t_cluster_fw
check "cluster.fw renders IPv4-only sets with no blank or unrendered line" t_cluster_fw_v4_only
check "120.fw renders the house's public IPv4 into house_public and drops it" t_fetcher_fw
check "120.fw refuses an empty or non-IPv4 house address" t_fetcher_fw_refuses_bad_ip
check "120.fw is committed only as a template" t_fetcher_fw_not_committed_rendered
check "vm_spec sizes: ol 12 vCPU / 24 GB, fetcher unchanged" t_vm_spec_sizes
check "storage names default to local-lvm / local and come from the secrets when set" t_storage_defaults
check "pick_trace_ip returns only a dotted IPv4 ip= line" t_trace_ip
check "a ZFS module/userland or kernel mismatch yields a reboot message naming both versions" t_reboot_reason
finish
