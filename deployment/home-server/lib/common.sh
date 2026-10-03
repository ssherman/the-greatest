# deployment/home-server/lib/common.sh
# shellcheck shell=bash
# shellcheck disable=SC2034 # HOST_STATE is read by provision, which sources this file
# Logging, change tracking and the SSH plumbing every provision step uses.

HS_DIR="${HS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$HS_DIR/../.." && pwd)}"
CHANGES=()
# Where provision keeps its own state on the host (tunnels flag, tracked ref).
HOST_STATE=/etc/the-greatest-home-server
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'provision: %s\n' "$*" >&2; exit 1; }
note_change() { CHANGES+=("$1"); log "changed: $1"; }

# new_tmpdir <var>: a temp dir (it holds rendered secrets or addresses) that is
# removed on any exit, die included. One shared list and one EXIT trap, so
# callers cannot replace each other's cleanup. Not a $(...) call: the list
# must be updated in the calling shell.
CLEANUP_DIRS=()
cleanup_dirs() { if [ "${#CLEANUP_DIRS[@]}" -gt 0 ]; then rm -rf "${CLEANUP_DIRS[@]}"; fi; }
new_tmpdir() {
  local d; d="$(mktemp -d)" || die "mktemp failed"
  CLEANUP_DIRS+=("$d")
  trap cleanup_dirs EXIT
  printf -v "$1" '%s' "$d"
}

# shellcheck disable=SC2029 # the command is built on the client on purpose
# A fixed locale: sshd accepts the client's LC_*, and an unsupported one makes
# perl warn on stderr, which provision parses and treats as failure.
on_host() { ssh "${SSH_OPTS[@]}" "root@$PVE_HOST" "export LC_ALL=C LANG=C;" "$@"; }

# host_file_matches <local> <remote>: true when the remote file has the same bytes.
host_file_matches() {
  local want have
  want="$(sha256sum <"$1" | cut -d' ' -f1)"
  have="$(on_host "sha256sum 2>/dev/null < '$2' | cut -d' ' -f1" || true)"
  [ "$want" = "$have" ]
}

# put_host <local> <remote> [mode]: write only when different; records a change.
# /etc/pve is the cluster filesystem: no chmod there, and no temp file + rename.
put_host() {
  local src=$1 dest=$2 mode=${3:-0644}
  host_file_matches "$src" "$dest" && return 0
  case "$dest" in
    /etc/pve/*) on_host "cat > '$dest'" <"$src" ;;
    *) on_host "mkdir -p '$(dirname "$dest")' && cat > '$dest.new' && chmod $mode '$dest.new' && mv '$dest.new' '$dest'" <"$src" ;;
  esac
  note_change "$dest"
}

# load_secrets: secrets/home-server.env -> exported variables. Parsed, not
# eval'ed: a value is data, never shell.
load_secrets() {
  local file="$REPO_ROOT/secrets/home-server.env" key value
  [ -f "$file" ] || die "missing $file"
  local plain
  plain="$(sops -d "$file")" || die "could not decrypt $file (is SOPS_AGE_KEY_FILE set?)"
  while IFS='=' read -r key value; do
    if [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then export "$key=$value"; fi
  done <<<"$plain"
  [ -n "${PVE_HOST:-}" ] || die "PVE_HOST is not set in $file"
}

# load_host_state [ref]: the ref the VMs track and whether tunnels are on, both
# kept on the host so any machine running provision sees the same answer.
load_host_state() {
  on_host "mkdir -p $HOST_STATE"
  if [ -n "${1:-}" ]; then
    on_host "printf '%s\n' '$1' > $HOST_STATE/repo-ref"
  fi
  REPO_REF="$(on_host "cat $HOST_STATE/repo-ref 2>/dev/null || echo main")"
  TUNNELS_ENABLED=0
  if on_host "test -f $HOST_STATE/tunnels-enabled"; then TUNNELS_ENABLED=1; fi
  export REPO_REF TUNNELS_ENABLED
}

report_changes() {
  if [ "${#CHANGES[@]}" = 0 ]; then log "no changes"; else log "${#CHANGES[@]} change(s): ${CHANGES[*]}"; fi
}
