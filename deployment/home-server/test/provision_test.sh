#!/usr/bin/env bash
# shellcheck disable=SC2016  # stub bodies and bash -c programs are single-quoted on purpose
# deployment/home-server/test/provision_test.sh
# provision's own plumbing: reading the secrets, the --ref check, put_host's
# file mode, the house's public IPv4, and --recovery's guest re-check. Nothing
# here reaches a host: on_host, sops and ssh are function overrides or stubs.
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

# secrets <plaintext>: load_secrets in a subshell, with sops replaced by a
# function printing <plaintext>; prints the resulting environment.
secrets() {
  (
    new_sandbox
    mkdir -p "$SANDBOX/secrets" && : >"$SANDBOX/secrets/home-server.env"
    REPO_ROOT="$SANDBOX"
    PLAIN="$1"
    sops() { printf '%s' "$PLAIN"; }
    unset PVE_HOST OL_TUNNEL_TOKEN FETCHER_TUNNEL_TOKEN HC_OL_DEPLOY lower
    load_secrets && env
  )
}
# secrets_has <plaintext> <exact line>: captured first, never piped. Under
# pipefail, `secrets | grep -q` fails when grep exits on its match while env
# is still writing (SIGPIPE), which a CI runner's large environment hits.
secrets_has() {
  local out
  out="$(secrets "$1")" || return 1
  grep -qxF -- "$2" <<<"$out"
}
t_single_trailing_equals() {
  secrets_has $'PVE_HOST=pve-test\nOL_TUNNEL_TOKEN=eyJhIjoiYiJ9=\n' 'OL_TUNNEL_TOKEN=eyJhIjoiYiJ9='
}
t_double_trailing_equals() {
  secrets_has $'PVE_HOST=pve-test\nFETCHER_TUNNEL_TOKEN=eyJh==\n' 'FETCHER_TUNNEL_TOKEN=eyJh=='
}
t_equals_in_middle() {
  secrets_has $'PVE_HOST=pve-test\nHC_OL_DEPLOY=https://hc.test/x?a=1&b=2\n' 'HC_OL_DEPLOY=https://hc.test/x?a=1&b=2'
}
t_last_line_without_newline() {
  secrets_has $'PVE_HOST=pve-test\nOL_TUNNEL_TOKEN=abc=' 'OL_TUNNEL_TOKEN=abc='
}
t_non_matching_lines_ignored() {
  local out
  out="$(secrets $'PVE_HOST=pve-test\n# COMMENT=1\nlower=x\nNO_EQUALS_SIGN\n')" || return 1
  grep -qx 'PVE_HOST=pve-test' <<<"$out" && ! grep -q '^lower=' <<<"$out" &&
    ! grep -q '^NO_EQUALS_SIGN' <<<"$out" && ! grep -q 'COMMENT' <<<"$out"
}
t_value_is_not_shell() {
  secrets_has $'PVE_HOST=pve-test\nOL_TUNNEL_TOKEN=$(touch /nonexistent/x) `id`\n' \
    'OL_TUNNEL_TOKEN=$(touch /nonexistent/x) `id`'
}
t_failing_sops_dies() {
  local out rc=0
  out="$( (
    new_sandbox
    mkdir -p "$SANDBOX/secrets" && : >"$SANDBOX/secrets/home-server.env"
    REPO_ROOT="$SANDBOX"
    sops() { return 1; }
    load_secrets
    echo "survived"
  ) 2>&1)" || rc=$?
  [ "$rc" = 1 ] && grep -q 'could not decrypt' <<<"$out" && ! grep -q survived <<<"$out"
}

t_valid_refs() {
  valid_ref main && valid_ref worktree-home-server && valid_ref release/2026.10_1 &&
    ! valid_ref "main'; rm -rf /" && ! valid_ref 'a b' && ! valid_ref '$(id)' &&
    ! valid_ref 'x:y' && ! valid_ref '--upload-pack=x' && ! valid_ref ''
}
# The real script: a bad --ref dies before it decrypts anything, a good one
# gets as far as sops (a stub that fails), so neither reaches a host.
t_provision_rejects_bad_ref() {
  new_sandbox
  stub sops 'exit 1'
  stub ssh 'exit 255'
  local out rc=0
  out="$("$HS_DIR/provision" --ref "main';touch x" 2>&1)" || rc=$?
  [ "$rc" = 1 ] && grep -q 'invalid --ref' <<<"$out" && ! called '^sops' && ! called '^ssh' || return 1
  : >"$CALLS"; rc=0
  out="$("$HS_DIR/provision" --ref main 2>&1)" || rc=$?
  [ "$rc" = 1 ] && grep -q 'could not decrypt' <<<"$out" && called '^sops' && ! called '^ssh'
}
t_host_state_rejects_bad_stored_ref() {
  local rc=0
  (
    on_host() { case "$*" in *repo-ref*) echo "main;id" ;; *) return 0 ;; esac; }
    load_host_state ""
  ) 2>/dev/null || rc=$?
  [ "$rc" = 1 ]
}

# put_host: the bytes are written under umask 077. on_host runs the command
# locally; `cat` records the mode of the file it is writing into (its fd 1) at
# the moment of writing, which is the window the umask closes.
t_put_host_mode() {
  if [ ! -d /proc/self/fd ]; then echo "SKIP  put_host mode: no /proc here"; return 0; fi
  new_sandbox
  local dest="$SANDBOX/etc/secret.env" src="$SANDBOX/src"
  printf 'TOKEN=x\n' >"$src"
  mkdir -p "$SANDBOX/etc"
  # A .new left behind world-readable by an earlier failed run.
  printf 'old\n' >"$dest.new" && command -p chmod 0644 "$dest.new"
  (
    on_host() {
      MODES="$SANDBOX/modes" bash -c '
        cat() { command -p stat -L -c %a "/proc/$BASHPID/fd/1" >>"$MODES"; command -p cat "$@"; }
        '"$*"
    }
    put_host "$src" "$dest" 0640
  ) >/dev/null 2>&1 || return 1
  [ "$(command -p cat "$SANDBOX/modes")" = 600 ] &&
    [ "$(command -p stat -c %a "$dest")" = 640 ] && [ "$(command -p cat "$dest")" = "TOKEN=x" ] &&
    [ ! -e "$dest.new" ]
}

t_house_ip_read() {
  [ "$(on_host() { printf 'fl=1\nip=203.0.113.7\nts=1\n'; }; house_public_ipv4)" = 203.0.113.7 ]
}
t_house_ip_unreadable_fails() {
  (on_host() { return 7; }; house_public_ipv4) && return 1
  (on_host() { printf 'ip=2001:db8::1\n'; }; house_public_ipv4) && return 1
  return 0
}
t_firewall_dies_without_house_ip() {
  local out rc=0
  out="$( (
    LAN_IPV4_CIDR=192.0.2.0/24 LAN_IPV6_PREFIX=''
    on_host() { case "$*" in *cdn-cgi/trace*) return 7 ;; *) echo "on_host $*" ;; esac; }
    converge_host_firewall
  ) 2>&1)" || rc=$?
  [ "$rc" = 1 ] && grep -q "public IPv4" <<<"$out" && ! grep -q 'cat >' <<<"$out" &&
    ! grep -q 'confirm-or-revert' <<<"$out"
}

# --recovery: after the host reboot, the pre-existing guests are checked again.
t_recovery_rechecks_guests() {
  local out
  out="$(
    crash_service() { :; }
    vm_ssh() { return 1; }
    sleep() { :; }
    verify_host() { :; }
    verify_vms() { :; }
    verify_egress() { :; }
    on_host() { case "$*" in *"qm status 101"*) return 0 ;; *"qm status 102"*) return 1 ;; *) return 0 ;; esac; }
    verify_recovery "101 102" 2>/dev/null
  )"
  grep -qx 'PASS  pre-existing guest 101 still running after the reboot' <<<"$out" &&
    grep -q '^FAIL  pre-existing guest 102 still running after the reboot' <<<"$out"
}

# The VMs provision made (110, 120, 130) are never "foreign"; any other running guest is.
t_foreign_vmids_ignore_ours() {
  local out
  out="$(
    on_host() {
      printf '%s\n' '      VMID NAME   STATUS     MEM(MB)' '       110 ol     running    24576' \
        '       120 fetcher running    4096' '       130 worldcat running   4096' \
        '       101 other  running    2048' '       102 off    stopped    1024'
    }
    running_foreign_vmids
  )"
  [ "$out" = 101 ]
}

# ol's address comes from an ssh to the host; that ssh must not eat the stdin
# meant for the VM (it once left ol with an empty env file).
t_vm_ssh_stdin_reaches_vm() {
  (
    new_sandbox
    PVE_HOST=pve-test
    # shellcheck disable=SC2317,SC2329 # called by vm_ip, inside vm_ssh
    on_host() { cat >/dev/null; echo '[{"name":"eth0","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"192.0.2.5"}]}]'; }
    ssh() { cat >"$SANDBOX/got"; }
    printf 'ROLE=ol\n' | vm_ssh ol 'sudo install -m 0600 /dev/stdin /x' &&
      [ "$(cat "$SANDBOX/got")" = ROLE=ol ]
  )
}
t_push_env_refuses_a_mismatch() {
  local out rc=0
  out="$( (
    new_sandbox
    ENV_RENDERED="$SANDBOX/env" && printf 'ROLE=ol\n' >"$ENV_RENDERED"
    vm_ssh() { case "$2" in *install*) cat >/dev/null ;; *sha256sum*) echo e3b0c44298fc ;; *) echo "vm_ssh $*" ;; esac; }
    push_vm_env ol
  ) 2>&1)" || rc=$?
  [ "$rc" = 1 ] && grep -q 'does not match' <<<"$out" && ! grep -q 'systemctl start' <<<"$out"
}

# Every service's CPU cap must fit inside the ol VM (build and recommender).
t_build_cpus_fit_vm() {
  local cpus found=0
  vm_spec ol || return 1
  while read -r cpus; do
    found=1
    [ "$cpus" -le "$CORES" ] || return 1
  done < <(sed -n 's/^ *cpus: *\([0-9]*\)$/\1/p' "$HS_DIR/compose.ol.yml")
  [ "$found" = 1 ]
}

check "secrets: a value ending in a single = keeps it" t_single_trailing_equals
check "secrets: a value ending in == keeps both" t_double_trailing_equals
check "secrets: an = inside a value is kept" t_equals_in_middle
check "secrets: a last line without a newline is read" t_last_line_without_newline
check "secrets: comments, lowercase keys and lines with no = are ignored" t_non_matching_lines_ignored
check "secrets: a value is data, never run" t_value_is_not_shell
check "secrets: a failing sops dies" t_failing_sops_dies
check "valid_ref accepts branch names and refuses shell, spaces and leading dashes" t_valid_refs
check "provision --ref with a bad ref dies before decrypting or reaching the host" t_provision_rejects_bad_ref
check "a bad ref stored on the host is refused" t_host_state_rejects_bad_stored_ref
check "put_host writes under umask 077, then sets the mode" t_put_host_mode
check "the house's public IPv4 is read from the trace" t_house_ip_read
check "an unreadable or non-IPv4 trace fails instead of returning nothing" t_house_ip_unreadable_fails
check "the firewall step dies before writing anything when the public IPv4 can't be read" t_firewall_dies_without_house_ip
check "--recovery re-checks the pre-existing guests after the reboot" t_recovery_rechecks_guests
check "running_foreign_vmids ignores 110, 120 and 130 and stopped guests" t_foreign_vmids_ignore_ours
check "vm_ssh to ol passes its stdin to the VM, not to the host lookup" t_vm_ssh_stdin_reaches_vm
check "an env file that lands different from what was sent stops before the deploy" t_push_env_refuses_a_mismatch
check "the build's cpus cap fits in the ol VM's vCPUs" t_build_cpus_fit_vm

# --- NIC watchdog provisioning -------------------------------------------------
LIVE_IFACES=$'auto lo\niface lo inet loopback\n\niface eno1 inet manual\n\tpost-up /usr/sbin/ethtool -K eno1 tso off gso off\n\nauto vmbr0\niface vmbr0 inet static\n\taddress 192.0.2.10/24\n\tgateway 192.0.2.1\n\tbridge-ports eno1\n\tbridge-stp off\n\nauto vmbr1\niface vmbr1 inet static\n\taddress 10.20.0.1/24\n\tbridge-ports none\n'
BARE_IFACES=${LIVE_IFACES/$'\tpost-up /usr/sbin/ethtool -K eno1 tso off gso off\n'/}

t_bridge_nic_reads_port() {
  [ "$(bridge_nic <<<"$LIVE_IFACES")" = eno1 ]
}
t_bridge_nic_refuses_several() {
  ! bridge_nic <<<$'iface vmbr0 inet static\n\tbridge-ports eno1 eno2\n' >/dev/null &&
    ! bridge_nic <<<$'iface vmbr0 inet static\n\taddress 192.0.2.10/24\n' >/dev/null &&
    ! bridge_nic <<<$'iface vmbr0 inet static\n\tbridge-ports eno1\niface vmbr0 inet6 static\n\tbridge-ports eno2\n' >/dev/null
}
t_offload_line_exact() {
  [ "$(offload_line eno1)" = "post-up /usr/sbin/ethtool -K eno1 tso off gso off" ]
}

# nic_run <interfaces text> <ethtool -k text>: converge_host_nic in a subshell over a
# sandbox interfaces file. on_host runs file commands locally against the sandbox copy;
# ethtool and network_change are recorded in $CALLS. Read the result from $IFACES.
nic_run() {
  new_sandbox
  IFACES="$SANDBOX/interfaces"
  printf '%s' "$1" >"$IFACES"
  ETHTOOL_K="$2"
  (
    CHANGES=()
    on_host() {
      case "$*" in
        "ethtool -k "*) printf '%s\n' "$ETHTOOL_K" ;;
        "/usr/sbin/ethtool -K "*) echo "ethtool-set $*" >>"$CALLS" ;;
        *) local cmd="$*"; bash -c "${cmd//\/etc\/network\/interfaces/$IFACES}" ;;
      esac
    }
    network_change() { echo "network_change $1" >>"$CALLS"; "$2"; }
    converge_host_nic
  ) >"$SANDBOX/log/out" 2>&1
}
ETHTOOL_OFF=$'tcp-segmentation-offload: off\ngeneric-segmentation-offload: off'
ETHTOOL_TSO_ON=$'tcp-segmentation-offload: on\ngeneric-segmentation-offload: off'

t_existing_offload_line_left_alone() {
  nic_run "$LIVE_IFACES" "$ETHTOOL_OFF" || return 1
  [ "$(command -p cat "$IFACES")" = "${LIVE_IFACES%$'\n'}" ] && [ ! -s "$CALLS" ]
}
t_offload_line_added_once() {
  nic_run "$BARE_IFACES" "$ETHTOOL_OFF" || return 1
  [ "$(command -p grep -c 'ethtool -K eno1 tso off gso off' "$IFACES")" = 1 ] &&
    command -p grep -A1 '^iface eno1 inet manual$' "$IFACES" | command -p grep -qxF $'\tpost-up /usr/sbin/ethtool -K eno1 tso off gso off' &&
    [ "$(command -p grep -c '^network_change' "$CALLS")" = 1 ] || return 1
  # a second run over the result adds nothing
  local after
  after="$(command -p cat "$IFACES")"
  nic_run "$after" "$ETHTOOL_OFF" || return 1
  [ "$(command -p grep -c 'ethtool -K eno1 tso off gso off' "$IFACES")" = 1 ] && [ ! -s "$CALLS" ]
}
t_offload_missing_stanza_dies() {
  local text=${BARE_IFACES/iface eno1 inet manual/iface eno9 inet manual}
  if nic_run "$text" "$ETHTOOL_OFF"; then return 1; fi
  [ "$(command -p cat "$IFACES")" = "${text%$'\n'}" ] && command -p grep -q 'iface eno1 inet manual' "$SANDBOX/log/out" && [ ! -s "$CALLS" ]
}
t_offload_runtime_reapplied() {
  nic_run "$LIVE_IFACES" "$ETHTOOL_TSO_ON" || return 1
  command -p grep -q '^ethtool-set .*ethtool -K eno1 tso off gso off' "$CALLS" && ! command -p grep -q '^network_change' "$CALLS"
}
# verify_offload <interfaces text>: the verify check's predicate over a stubbed read.
verify_offload() {
  local text=$1
  ( on_host() { printf '%s' "$text"; }; host_nic_has_offload eno1 ) 2>/dev/null
}
t_verify_offload_accepts_spaces_in_stanza() {
  verify_offload "${LIVE_IFACES//$'\t'post-up/    post-up}"
}
t_verify_offload_rejects_line_under_vmbr0() {
  local text=${BARE_IFACES/$'\tgateway 192.0.2.1\n'/$'\tgateway 192.0.2.1\n\tpost-up /usr/sbin/ethtool -K eno1 tso off gso off\n'}
  ! verify_offload "$text" && verify_offload "$LIVE_IFACES"
}
t_verify_offload_failed_read_fails() {
  ! ( on_host() { return 255; }; host_nic_has_offload eno1 ) 2>/dev/null
}
t_watchdog_units_valid() {
  local t="$HS_DIR/host/systemd/nic-watchdog.timer" s="$HS_DIR/host/systemd/nic-watchdog.service"
  command -p grep -qx 'OnUnitActiveSec=1min' "$t" && command -p grep -qx 'OnBootSec=3min' "$t" &&
    command -p grep -qx 'WantedBy=timers.target' "$t" &&
    command -p grep -qx 'ExecStart=/usr/local/sbin/nic-watchdog' "$s" && command -p grep -qx 'Type=oneshot' "$s"
}
t_watchdog_env_mode() {
  new_sandbox
  local out
  out="$(
    CHANGES=()
    NIC=eno1 HC_NIC_WATCHDOG=https://hc.test/ping/abc
    on_host() { return 0; }
    put_host() { echo "put $2 ${3:-}"; case "$2" in */nic-watchdog.env) command -p cp "$1" "$SANDBOX/env.copy" ;; esac; }
    converge_host_watchdog
  )" || return 1
  grep -qx "put $HOST_STATE/nic-watchdog.env 0600" <<<"$out" &&
    grep -qx 'put /usr/local/sbin/nic-watchdog 0755' <<<"$out" &&
    [ "$(command -p cat "$SANDBOX/env.copy")" = $'NIC=eno1\nHC_NIC_WATCHDOG=https://hc.test/ping/abc' ]
}

check "bridge_nic reads vmbr0's port, not vmbr1's none" t_bridge_nic_reads_port
check "bridge_nic fails on several ports, none, or two vmbr0 stanzas" t_bridge_nic_refuses_several
check "offload_line is the exact interfaces line" t_offload_line_exact
check "an existing offload line means no network change and no edit" t_existing_offload_line_left_alone
check "the offload line is added once, under the NIC's stanza, through network_change" t_offload_line_added_once
check "a missing NIC stanza dies and leaves the file alone" t_offload_missing_stanza_dies
check "TSO on at runtime is turned off without a network change" t_offload_runtime_reapplied
check "verify accepts a space-indented offload line under the NIC's stanza" t_verify_offload_accepts_spaces_in_stanza
check "verify rejects an offload line that sits under vmbr0" t_verify_offload_rejects_line_under_vmbr0
check "verify fails when the interfaces file cannot be read" t_verify_offload_failed_read_fails
check "the watchdog units carry the specified schedule and command" t_watchdog_units_valid
check "the watchdog env file is sent mode 0600 with NIC and the ping URL" t_watchdog_env_mode
finish
