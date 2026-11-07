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
export WORLDCAT_TUNNEL_TOKEN=wc-token HC_WORLDCAT_HEARTBEAT=https://hc.test/wc-beat HC_WORLDCAT_DEPLOY=https://hc.test/wc-deploy
export HC_RECOMMENDER=https://hc.test/ol-train RECOMMENDATIONS_R2_ENDPOINT=https://acct.r2.test
export RECOMMENDATIONS_R2_ACCESS_KEY=rec-access RECOMMENDATIONS_R2_SECRET_KEY=rec-secret RECOMMENDATIONS_R2_BUCKET=rec-bucket
export HC_PGVERIFY=https://hc.test/pgv-verified HC_PGVERIFY_DEPLOY=https://hc.test/pgv-deploy
export PGVERIFY_REPO_BUCKET=pgv-repo-bucket PGVERIFY_REPO_ENDPOINT=s3.pgv.test PGVERIFY_REPO_REGION=pgv-region-1
export PGVERIFY_REPO_PATH=/pgv-path PGVERIFY_REPO_KEY=pgv-repo-key PGVERIFY_REPO_KEY_SECRET=pgv-repo-secret
export PGVERIFY_CIPHER_PASS=pgv-cipher PGVERIFY_DUMP_BUCKET=pgv-dump-bucket PGVERIFY_DUMP_KEY=pgv-dump-key
export PGVERIFY_DUMP_KEY_SECRET=pgv-dump-secret PGVERIFY_DUMP_REGION=pgv-dump-region
echo "ssh-ed25519 AAAATEST test@example.com" >"$SANDBOX/key.pub"
export SSH_PUBKEY_FILE="$SANDBOX/key.pub"

for role in ol fetcher worldcat pgverify; do
  render_vm_env "$role" "$SANDBOX/$role.env"
  render_user_data "$role" "$SANDBOX/$role.env" "$SANDBOX/$role.yaml"
done
env_from_yaml() { # decode the env file a rendered user-data carries
  ruby -ryaml -rbase64 -e 'y = YAML.load_file(ARGV[0]); f = y["write_files"].find { |w| w["path"] == "/etc/the-greatest/home-server.env" }; print Base64.decode64(f["content"])' "$1"
}

t_yaml() { for r in ol fetcher worldcat; do ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$SANDBOX/$r.yaml" || return 1; done; }
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
  grep -qx 'TUNNEL_TOKEN=fetcher-token' <<<"$env" && ! grep -q 'ol-' <<<"$env" &&
    ! grep -q 'RECOMMENDER' <<<"$env" && ! grep -q 'rec-' <<<"$env"
}
t_ol_trainer_env() {
  env_from_yaml "$SANDBOX/ol.yaml" | grep -qx 'HC_RECOMMENDER=https://hc.test/ol-train' &&
    env_from_yaml "$SANDBOX/ol.yaml" | grep -qx 'RECOMMENDATIONS_R2_ENDPOINT=https://acct.r2.test' &&
    env_from_yaml "$SANDBOX/ol.yaml" | grep -qx 'RECOMMENDATIONS_R2_SECRET_KEY=rec-secret' &&
    env_from_yaml "$SANDBOX/ol.yaml" | grep -qx 'RECOMMENDATIONS_R2_BUCKET=rec-bucket'
}
t_env_keys() {
  local keys
  keys="$(env_from_yaml "$SANDBOX/ol.yaml" | cut -d= -f1 | tr '\n' ' ')"
  [ "$keys" = "ROLE REPO_REF TUNNELS_ENABLED TUNNEL_TOKEN HC_HEARTBEAT HC_DEPLOY HC_REFRESH HC_RECOMMENDER RECOMMENDATIONS_R2_ENDPOINT RECOMMENDATIONS_R2_ACCESS_KEY RECOMMENDATIONS_R2_SECRET_KEY RECOMMENDATIONS_R2_BUCKET " ] || return 1
  keys="$(env_from_yaml "$SANDBOX/fetcher.yaml" | cut -d= -f1 | tr '\n' ' ')"
  [ "$keys" = "ROLE REPO_REF TUNNELS_ENABLED TUNNEL_TOKEN HC_HEARTBEAT HC_DEPLOY HC_REFRESH " ] || return 1
  keys="$(env_from_yaml "$SANDBOX/worldcat.yaml" | cut -d= -f1 | tr '\n' ' ')"
  [ "$keys" = "ROLE REPO_REF TUNNELS_ENABLED TUNNEL_TOKEN HC_HEARTBEAT HC_DEPLOY HC_REFRESH " ]
}
t_codename_literal() {
  grep -qF '${distro_codename}-security' "$SANDBOX/ol.yaml" "$SANDBOX/fetcher.yaml"
}
t_key() { grep -q 'ssh-ed25519 AAAATEST' "$SANDBOX/ol.yaml"; }
t_ref() { grep -q 'clone --depth 1 --branch main ' "$SANDBOX/ol.yaml"; }
t_blank_secrets() {
  (unset OL_TUNNEL_TOKEN HC_OL_HEARTBEAT RECOMMENDATIONS_R2_BUCKET; render_vm_env ol "$SANDBOX/blank.env") &&
    grep -qx 'TUNNEL_TOKEN=' "$SANDBOX/blank.env" && grep -qx 'RECOMMENDATIONS_R2_BUCKET=' "$SANDBOX/blank.env"
}

t_pgverify_env_keys() {
  local keys
  keys="$(env_from_yaml "$SANDBOX/pgverify.yaml" | cut -d= -f1 | tr '\n' ' ')"
  [ "$keys" = "ROLE REPO_REF TUNNELS_ENABLED TUNNEL_TOKEN HC_HEARTBEAT HC_DEPLOY HC_REFRESH HC_PGVERIFY PGVERIFY_REPO_BUCKET PGVERIFY_REPO_ENDPOINT PGVERIFY_REPO_REGION PGVERIFY_REPO_PATH PGVERIFY_REPO_KEY PGVERIFY_REPO_KEY_SECRET PGVERIFY_CIPHER_PASS PGVERIFY_DUMP_BUCKET PGVERIFY_DUMP_REGION PGVERIFY_DUMP_KEY PGVERIFY_DUMP_KEY_SECRET PGVERIFY_UPLOAD_ENABLED " ]
}
t_pgverify_env() {
  local env; env="$(env_from_yaml "$SANDBOX/pgverify.yaml")"
  grep -qx 'ROLE=pgverify' <<<"$env" && grep -qx 'HC_PGVERIFY=https://hc.test/pgv-verified' <<<"$env" &&
    grep -qx 'HC_DEPLOY=https://hc.test/pgv-deploy' <<<"$env" && grep -qx 'PGVERIFY_REPO_KEY_SECRET=pgv-repo-secret' <<<"$env" &&
    grep -qx 'PGVERIFY_CIPHER_PASS=pgv-cipher' <<<"$env" && grep -qx 'PGVERIFY_DUMP_BUCKET=pgv-dump-bucket' <<<"$env" &&
    grep -qx 'PGVERIFY_DUMP_REGION=pgv-dump-region' <<<"$env" &&
    # No tunnel, no heartbeat: it runs no always-on service.
    grep -qx 'TUNNELS_ENABLED=0' <<<"$env" && grep -qx 'TUNNEL_TOKEN=' <<<"$env" && grep -qx 'HC_HEARTBEAT=' <<<"$env"
}
t_pgverify_upload_off_by_default() {
  env_from_yaml "$SANDBOX/pgverify.yaml" | grep -qx 'PGVERIFY_UPLOAD_ENABLED=0' &&
    [ "$(PGVERIFY_UPLOAD_ENABLED=1; render_vm_env pgverify "$SANDBOX/up.env"; grep -x 'PGVERIFY_UPLOAD_ENABLED=1' "$SANDBOX/up.env")" = PGVERIFY_UPLOAD_ENABLED=1 ] &&
    [ "$(unset PGVERIFY_UPLOAD_ENABLED; render_vm_env pgverify "$SANDBOX/up.env"; grep -x 'PGVERIFY_UPLOAD_ENABLED=0' "$SANDBOX/up.env")" = PGVERIFY_UPLOAD_ENABLED=0 ]
}
t_pgverify_values_reach_no_other_role() {
  local r
  for r in ol fetcher worldcat; do
    ! env_from_yaml "$SANDBOX/$r.yaml" | grep -q 'PGVERIFY\|pgv-' || return 1
  done
}
t_pgverify_holds_nothing_of_the_others() {
  local env; env="$(env_from_yaml "$SANDBOX/pgverify.yaml")"
  ! grep -q 'ol-token\|fetcher-token\|wc-token\|ol-beat\|f-beat\|wc-beat\|RECOMMEND\|rec-\|ol-train' <<<"$env"
}
t_pgverify_refuses_unsafe_values() {
  # The env file is sourced by the VM's scripts: a value with a space, quote, $ or & would run as shell.
  local v
  for v in 'a b' "a'b" 'a$b' 'a&b' 'a;b' 'a`b'; do
    (PGVERIFY_CIPHER_PASS="$v"; render_vm_env pgverify "$SANDBOX/bad.env") >/dev/null 2>&1 && return 1
  done
  (PGVERIFY_CIPHER_PASS='aZ09+/=._:@,-'; render_vm_env pgverify "$SANDBOX/ok.env") >/dev/null 2>&1
}
t_pgverify_refuses_a_blank_check_url() {
  # Without it a failed restore check is silent, which is the failure the VM exists to prevent.
  (HC_PGVERIFY=""; render_vm_env pgverify "$SANDBOX/nohc.env") >/dev/null 2>&1 && return 1
  (unset HC_PGVERIFY; render_vm_env pgverify "$SANDBOX/nohc.env") >/dev/null 2>&1 && return 1
  (HC_PGVERIFY=""; render_vm_env fetcher "$SANDBOX/other.env") >/dev/null 2>&1
}
t_pgverify_spec() {
  vm_spec pgverify || return 1
  [ "$VMID $NAME $CORES $MEM $OSDISK $DATADISK $STARTUP" = "140 pgverify 4 8192 32 400 order=4" ] &&
    [ "$NET $IPCONFIG $NAMESERVER" = "virtio,bridge=vmbr1,firewall=1 ip=10.20.0.20/24,gw=10.20.0.1 1.1.1.1 1.0.0.1" ] &&
    [ "$(vm_ip pgverify)" = 10.20.0.20 ]
}
t_pgverify_fw() {
  local out="$SANDBOX/140.fw"
  render_pgverify_fw "$out" 203.0.113.7 || return 1
  ! grep -q '\${' "$out" || return 1
  [ "$(sed -n '/^\[IPSET house_public\]/,/^$/p' "$out" | sed 1d)" = 203.0.113.7 ] &&
    [ "$(sed -n '/^\[IPSET ipfilter-net0\]/,/^$/p' "$out" | sed 1d)" = 10.20.0.20 ] &&
    grep -qx 'policy_in: DROP' "$out" && grep -qx 'policy_out: ACCEPT' "$out" && grep -qx 'ipfilter: 1' "$out" &&
    grep -qx 'OUT DROP -dest +private -log nolog' "$out" && grep -qx 'OUT DROP -dest +guest/house_public -log nolog' "$out" &&
    # Inbound: SSH from the host's vmbr1 address and nothing else.
    [ "$(grep -c '^IN ' "$out")" = 1 ] && grep -qx 'IN ACCEPT -source 10.20.0.1 -p tcp -dport 22 -log nolog' "$out" &&
    # No rule opens a port to the world or the LAN.
    ! grep -q '^OUT ACCEPT\|+lan' "$out"
}
t_pgverify_fw_refuses_bad_ip() {
  ! render_pgverify_fw "$SANDBOX/bad.fw" "" && ! render_pgverify_fw "$SANDBOX/bad.fw" 2001:db8::1
}
t_pgverify_in_firewall_pairs() {
  grep -qF '"140.fw:/etc/pve/firewall/140.fw"' "$HS_DIR/lib/host.sh"
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
  vm_spec fetcher && [ "$CORES $MEM" = "4 4096" ] || return 1
  vm_spec worldcat && [ "$VMID $CORES $MEM $OSDISK $DATADISK $STARTUP" = "130 2 4096 32 40 order=3" ]
}
t_worldcat_env() {
  local env; env="$(env_from_yaml "$SANDBOX/worldcat.yaml")"
  grep -qx 'ROLE=worldcat' <<<"$env" && grep -qx 'TUNNEL_TOKEN=wc-token' <<<"$env" &&
    grep -qx 'HC_HEARTBEAT=https://hc.test/wc-beat' <<<"$env" && grep -qx 'HC_DEPLOY=https://hc.test/wc-deploy' <<<"$env" &&
    grep -qx 'HC_REFRESH=' <<<"$env"
}
t_worldcat_isolation() {
  local env; env="$(env_from_yaml "$SANDBOX/worldcat.yaml")"
  ! grep -q 'ol-token\|fetcher-token\|ol-beat\|f-beat\|RECOMMEND\|rec-' <<<"$env"
}
t_worldcat_firewall() {
  local fw="$HS_DIR/host/firewall/130.fw"
  [ -f "$fw" ] && grep -qx 'policy_in: DROP' "$fw" && grep -qx 'IN ACCEPT -source +lan -p tcp -dport 22 -log nolog' "$fw"
}
t_worldcat_in_firewall_pairs() {
  grep -qF '"130.fw:/etc/pve/firewall/130.fw"' "$HS_DIR/lib/host.sh"
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

t_meta_data() {
  render_meta_data ol "$SANDBOX/ol.meta" && render_meta_data fetcher "$SANDBOX/fetcher.meta" &&
    printf 'instance-id: the-greatest-ol\nlocal-hostname: ol\n' | cmp -s - "$SANDBOX/ol.meta" &&
    printf 'instance-id: the-greatest-fetcher\nlocal-hostname: fetcher\n' | cmp -s - "$SANDBOX/fetcher.meta"
}
t_cicustom_names_both() {
  vm_spec fetcher &&
    [ "$(cicustom)" = "user=local:snippets/fetcher-user-data.yaml,meta=local:snippets/fetcher-meta-data.yaml" ]
}
# converge_vm_settings <cicustom line>: run against a VM whose config is
# otherwise in order; prints the qm set calls it made.
converge_with() {
  (
    vm_spec fetcher
    CFG="$(printf 'cores: %s\nmemory: %s\nballoon: 0\nonboot: 1\nstartup: %s\n%s\n' "$CORES" "$MEM" "$STARTUP" "$1")"
    # shellcheck disable=SC2317,SC2329 # called by converge_vm_settings
    on_host() { case "$*" in "qm config"*) echo "$CFG" ;; *) echo "on_host $*" ;; esac; }
    converge_vm_settings 2>/dev/null
  )
}
t_converge_pins_instance_id() {
  converge_with "cicustom: user=local:snippets/fetcher-user-data.yaml" |
    grep -q -- '--cicustom user=local:snippets/fetcher-user-data.yaml,meta=local:snippets/fetcher-meta-data.yaml' &&
    [ -z "$(converge_with "cicustom: user=local:snippets/fetcher-user-data.yaml,meta=local:snippets/fetcher-meta-data.yaml")" ]
}
t_clone_repeatable() {
  grep -qF '[ -d /opt/the-greatest/.git ] || git clone --depth 1' "$SANDBOX/ol.yaml"
}

t_tmpdirs_cleaned() {
  local out
  out="$(bash -c '. "$1/lib/common.sh"; new_tmpdir a; new_tmpdir b; echo "$a $b"; die gone' _ "$HS_DIR" 2>/dev/null)"
  # shellcheck disable=SC2086 # two paths, split on purpose
  set -- $out
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ ! -e "$1" ] && [ ! -e "$2" ]
}
check "each VM's meta-data pins a fixed instance-id" t_meta_data
check "cicustom names both the user-data and the meta-data snippet" t_cicustom_names_both
check "converge adds the meta-data snippet to an older VM, and leaves a current one alone" t_converge_pins_instance_id
check "the runcmd can run again over an existing checkout" t_clone_repeatable
check "temp dirs holding rendered secrets are removed even when provision dies" t_tmpdirs_cleaned
check "a key comment containing ' #' stays inside the YAML string" t_key_with_comment
check "docker, clone and first-boot run as one fail-fast script" t_runcmd_fail_fast
check "both user-data files are valid YAML" t_yaml
check "user-data starts with #cloud-config" t_first_line
check "no template variable is left unrendered" t_no_leftovers
check "ol gets its role, token and refresh check" t_ol_env
check "ol gets the trainer's check and R2 values" t_ol_trainer_env
check "fetcher holds nothing of ol's" t_fetcher_isolation
check "each env has exactly the keys guest/lib.sh documents, ol with the trainer's" t_env_keys
check "the security-only origin pattern survives rendering" t_codename_literal
check "the dev key is authorized" t_key
check "the VM clones the tracked ref" t_ref
check "unset secrets render as blanks, not errors" t_blank_secrets
check "cluster.fw renders both LAN ranges into lan and management" t_cluster_fw
check "cluster.fw renders IPv4-only sets with no blank or unrendered line" t_cluster_fw_v4_only
check "120.fw renders the house's public IPv4 into house_public and drops it" t_fetcher_fw
check "120.fw refuses an empty or non-IPv4 house address" t_fetcher_fw_refuses_bad_ip
check "120.fw is committed only as a template" t_fetcher_fw_not_committed_rendered
check "vm_spec sizes: ol 12 vCPU / 24 GB, fetcher unchanged, worldcat 2 vCPU / 4 GB / 40 GB data" t_vm_spec_sizes
check "worldcat gets its role, token and check URLs, and no refresh check" t_worldcat_env
check "worldcat holds nothing of ol's or the fetcher's" t_worldcat_isolation
check "130.fw drops inbound except SSH from the LAN" t_worldcat_firewall
check "converge_host_firewall installs 130.fw" t_worldcat_in_firewall_pairs
check "pgverify gets its role, check URLs and settings, no tunnel and no heartbeat" t_pgverify_env
check "pgverify's env has exactly its own keys" t_pgverify_env_keys
check "the pgverify upload is off unless it is set to 1" t_pgverify_upload_off_by_default
check "pgverify refuses a blank HC_PGVERIFY, and only pgverify does" t_pgverify_refuses_a_blank_check_url
check "pgverify's values reach no other role" t_pgverify_values_reach_no_other_role
check "pgverify holds nothing of the other roles'" t_pgverify_holds_nothing_of_the_others
check "pgverify's env refuses a value that would run as shell" t_pgverify_refuses_unsafe_values
check "vm_spec pgverify: VM 140, 4 vCPU / 8 GB / 400 GB data, vmbr1 at 10.20.0.20" t_pgverify_spec
check "140.fw drops everything inbound but SSH from the host, and private destinations outbound" t_pgverify_fw
check "140.fw refuses an empty or non-IPv4 house address" t_pgverify_fw_refuses_bad_ip
check "converge_host_firewall installs 140.fw" t_pgverify_in_firewall_pairs
check "storage names default to local-lvm / local and come from the secrets when set" t_storage_defaults
check "pick_trace_ip returns only a dotted IPv4 ip= line" t_trace_ip
check "a ZFS module/userland or kernel mismatch yields a reboot message naming both versions" t_reboot_reason
finish
