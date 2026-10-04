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
t_single_trailing_equals() {
  secrets $'PVE_HOST=pve-test\nOL_TUNNEL_TOKEN=eyJhIjoiYiJ9=\n' | grep -qx 'OL_TUNNEL_TOKEN=eyJhIjoiYiJ9='
}
t_double_trailing_equals() {
  secrets $'PVE_HOST=pve-test\nFETCHER_TUNNEL_TOKEN=eyJh==\n' | grep -qx 'FETCHER_TUNNEL_TOKEN=eyJh=='
}
t_equals_in_middle() {
  secrets $'PVE_HOST=pve-test\nHC_OL_DEPLOY=https://hc.test/x?a=1&b=2\n' | grep -qx 'HC_OL_DEPLOY=https://hc.test/x?a=1&b=2'
}
t_last_line_without_newline() {
  secrets $'PVE_HOST=pve-test\nOL_TUNNEL_TOKEN=abc=' | grep -qx 'OL_TUNNEL_TOKEN=abc='
}
t_non_matching_lines_ignored() {
  local out
  out="$(secrets $'PVE_HOST=pve-test\n# COMMENT=1\nlower=x\nNO_EQUALS_SIGN\n')" || return 1
  grep -qx 'PVE_HOST=pve-test' <<<"$out" && ! grep -q '^lower=' <<<"$out" &&
    ! grep -q '^NO_EQUALS_SIGN' <<<"$out" && ! grep -q 'COMMENT' <<<"$out"
}
t_value_is_not_shell() {
  secrets $'PVE_HOST=pve-test\nOL_TUNNEL_TOKEN=$(touch /nonexistent/x) `id`\n' |
    grep -qxF 'OL_TUNNEL_TOKEN=$(touch /nonexistent/x) `id`'
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

# The build's CPU cap must fit inside the ol VM.
t_build_cpus_fit_vm() {
  local cpus
  cpus="$(sed -n 's/^ *cpus: *\([0-9]*\)$/\1/p' "$HS_DIR/compose.ol.yml")"
  vm_spec ol && [ -n "$cpus" ] && [ "$cpus" -le "$CORES" ]
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
check "vm_ssh to ol passes its stdin to the VM, not to the host lookup" t_vm_ssh_stdin_reaches_vm
check "an env file that lands different from what was sent stops before the deploy" t_push_env_refuses_a_mismatch
check "the build's cpus cap fits in the ol VM's vCPUs" t_build_cpus_fit_vm
finish
