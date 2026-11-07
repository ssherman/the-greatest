#!/usr/bin/env bash
# deployment/postgres/migration/wait-catchup.sh DATABASE [--initial]
# Spec §13.2 steps 6 and 11. Waits, with a timeout, for the subscription:
#   --initial   every table of the subscription has finished its first copy (state 'r', ready).
#   (default)   the subscription has applied everything the old server has written up to now: it reads the
#               old server's WAL position once, then waits for the slot's confirmed_flush_lsn to reach it.
#               Run it after set-readonly.sh on, when nothing more can be written.
# Default mode refuses (exit 2) unless a NEW session on the old server reports default_transaction_read_only=on:
# against a writable source "caught up" means nothing. --initial is exempt (writes continue during the copy).
# The subscription's error counters are cumulative for the subscription's whole life, so a connection blip
# last night would otherwise fail the cutover for good. The count is recorded at the start and the script
# fails at once only when it RISES while waiting; the LSN wait and the timeout decide everything else.
# WAIT_TIMEOUT seconds (default 300; 7200 for --initial),
# WAIT_INTERVAL seconds between looks (default 2). Prints the seconds waited.
# Exit 0 reached, 1 timeout or subscription error, 2 could not look.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

db="${1:-}"
check_db_name "$db"
initial=0
case "${2:-}" in "") ;; --initial) initial=1 ;; *) die "usage: wait-catchup.sh DATABASE [--initial]" ;; esac
sub="$(sub_name "$db")"
if [ "$initial" = 1 ]; then timeout="${WAIT_TIMEOUT:-7200}"; else timeout="${WAIT_TIMEOUT:-300}"; fi
interval="${WAIT_INTERVAL:-2}"

# One look at the target: errors, tables not yet ready, and whether an apply worker is running.
state_sql="SELECT
  (SELECT coalesce(sum(apply_error_count + sync_error_count), 0) FROM pg_stat_subscription_stats WHERE subname = '$sub'),
  (SELECT count(*) FROM pg_subscription_rel r JOIN pg_subscription s ON s.oid = r.srsubid WHERE s.subname = '$sub' AND r.srsubstate <> 'r'),
  (SELECT count(*) FROM pg_subscription_rel r JOIN pg_subscription s ON s.oid = r.srsubid WHERE s.subname = '$sub'),
  (SELECT count(*) FROM pg_subscription WHERE subname = '$sub' AND subenabled)"

look() {
  local row
  row="$(tq "$db" -At -F ' ' -c "$state_sql" </dev/null)" || die "could not read the subscription state on the new server"
  read -r errors notready total enabled <<<"$row"
  [ -n "${total:-}" ] || die "unexpected subscription state: '$row'"
}

if [ "$initial" = 0 ]; then require_source_readonly "$db"; fi
start="$(date +%s)"
elapsed() { echo $(($(date +%s) - start)); }
look
base_errors="$errors"
[ "$enabled" = 1 ] || die "subscription $sub does not exist or is disabled on the new server" 1
[ "$total" -gt 0 ] || die "subscription $sub has no tables yet; is the schema loaded and the publication non-empty?" 1

target_lsn=""
if [ "$initial" = 0 ]; then
  target_lsn="$(sq "$db" -At -c "SELECT pg_current_wal_lsn()" </dev/null)" || die "could not read the old server's WAL position"
  [[ "$target_lsn" =~ ^[0-9A-F]+/[0-9A-F]+$ ]] || die "unexpected WAL position: '$target_lsn'"
fi

while :; do
  look
  if [ "$errors" -gt "$base_errors" ]; then
    echo "wait-catchup: subscription $sub raised $((errors - base_errors)) new apply/sync error(s) while waiting; read the new server's log" >&2
    exit 1
  fi
  if [ "$notready" = 0 ]; then
    if [ "$initial" = 1 ]; then
      echo "wait-catchup: $db initial copy finished ($total tables) after $(elapsed)s"
      exit 0
    fi
    reached="$(sq "$db" -At -c "SELECT coalesce((SELECT confirmed_flush_lsn >= '$target_lsn'::pg_lsn FROM pg_replication_slots WHERE slot_name = '$sub'), false)" </dev/null)" \
      || die "could not read the replication slot"
    if [ "$reached" = t ]; then
      echo "wait-catchup: $db subscription has applied everything up to $target_lsn after $(elapsed)s"
      exit 0
    fi
  fi
  if [ "$(elapsed)" -ge "$timeout" ]; then
    echo "wait-catchup: timed out after ${timeout}s ($notready of $total tables not ready${target_lsn:+, target position $target_lsn})" >&2
    exit 1
  fi
  sleep "$interval"
done
