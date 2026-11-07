#!/usr/bin/env bash
# deployment/postgres/migration/set-readonly.sh DATABASE on|off     (on the OLD server: SOURCE_DSN or SOURCE_PSQL)
# Spec §13.2 step 10 and §14. `on` runs ALTER DATABASE ... SET default_transaction_read_only = on and then
# terminates the database's sessions. `off` removes the setting (RESET, not "= off") and terminates the
# sessions AGAIN. The setting applies only when a session starts, so a session opened during the window
# stays read-only after `off` until it is replaced: that is what the second termination is for, and why
# rolling back without it leaves the site failing writes.
# Only ordinary client sessions are terminated. The replication walsenders of the subscription keep running:
# killing them would stall the very catch-up the window is for.
# It does not trust pg_terminate_backend: it records the moment of the change, then terminates and re-counts
# until no client session that started before that moment is left, and fails (exit 1) naming the count if any stays.
# Refuses (exit 1, nothing changed) when a role has its own default_transaction_read_only, either for this
# database or for every database (ALTER ROLE x SET ...), because a role-level setting beats the database-level
# one and would stay writable.
# Refuses (exit 1, nothing changed) unless the connecting role is a superuser or holds BOTH pg_read_all_stats and
# pg_signal_backend: without them pg_stat_activity hides other roles' sessions (backend_type and backend_start read
# as NULL), so a count of "sessions left" would be zero while they were still writing.
# Environment: SET_READONLY_PASSES (default 30) is how many terminate-and-recount passes to make.
# `off` is the rollback and is never blocked: it is exempt from the privilege check. Run by a role that cannot see
# other roles' sessions it still removes the setting, warns that it could not see or end those sessions (restart the
# apps), and exits 0 once the setting is gone.
# Exit codes: 0 done. 1 refused before changing anything (override, privileges) or the setting could not be
# confirmed. 2 could not do it (bad input, a failed query). 3 only for `off`: the setting IS removed, but a
# session that started during the window would not end and may stay read-only until it is replaced. For `on`, a
# session that will not end is exit 1 and the window is NOT closed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

db="${1:-}"
mode="${2:-}"
check_db_name "$db"
case "$mode" in on | off) ;; *) die "usage: set-readonly.sh DATABASE on|off" ;; esac

priv="$(sq "$db" -At -c "SELECT current_setting('is_superuser') = 'on' OR (pg_has_role(current_user, 'pg_read_all_stats', 'member') AND pg_has_role(current_user, 'pg_signal_backend', 'member'))" </dev/null)" \
  || die "could not check the role's privileges"
unprivileged=0
if [ "$priv" != t ] && [ "$mode" = off ]; then
  unprivileged=1
elif [ "$priv" != t ]; then
  echo "set-readonly: the connecting role is not a superuser and lacks pg_read_all_stats plus pg_signal_backend, so it could not see or end other roles' sessions; nothing was changed" >&2
  exit 1
fi
passes="${SET_READONLY_PASSES:-30}"
[[ "$passes" =~ ^[0-9]+$ ]] && [ "$passes" -gt 0 ] || die "SET_READONLY_PASSES must be a positive number"

# The clock is read as seconds since the epoch, which no DateStyle can change. Checked here, before anything is
# changed: a server whose answer cannot be read must not be left read-only with its sessions alive.
epoch_now() {
  local e
  e="$(sq "$db" -At -c "SELECT extract(epoch FROM clock_timestamp())" </dev/null | tail -n 1)" || die "could not read the server's clock"
  [[ "$e" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "unexpected clock value from the server: '$e'"
  printf '%s' "$e"
}
epoch_now >/dev/null

# setdatabase = 0 is a role-wide setting; both kinds beat the database-level one.
overrides="$(sq "$db" -At -c "
SELECT coalesce(r.rolname, 'role ' || s.setrole::text) || CASE WHEN s.setdatabase = 0 THEN ' (all databases)' ELSE '' END
FROM pg_db_role_setting s CROSS JOIN pg_database d LEFT JOIN pg_roles r ON r.oid = s.setrole
WHERE d.datname = current_database() AND s.setrole <> 0 AND s.setdatabase IN (0, d.oid)
  AND EXISTS (SELECT 1 FROM unnest(s.setconfig) c WHERE c LIKE 'default_transaction_read_only=%')" </dev/null)" \
  || die "could not look for per-role overrides"
if [ "$mode" = on ] && [ -n "$overrides" ]; then
  echo "set-readonly: these roles set default_transaction_read_only themselves and would stay writable on $db: $(tr '\n' ',' <<<"$overrides")" >&2
  echo "set-readonly: nothing was changed; reset their setting first" >&2
  exit 1
fi

if [ "$mode" = on ]; then
  change="ALTER DATABASE $db SET default_transaction_read_only = on;"
else
  change="ALTER DATABASE $db RESET default_transaction_read_only;"
fi

# This session may itself be read-only (an `off` after an `on`), and ALTER DATABASE cannot run in a
# read-only transaction, so it opts out first. The last line is the moment after the change.
printf 'SET default_transaction_read_only = off;\n%s\n' "$change" | sq "$db" -At >/dev/null || die "could not change the database"
stamp="$(epoch_now)"

# Terminate every client session that started before the change, and look again, until none is left.
remaining=-1 total=0
for _ in $(seq 1 "$passes"); do
  out="$(printf "SET default_transaction_read_only = off;
SELECT count(*) FILTER (WHERE pg_terminate_backend(pid)) FROM pg_stat_activity
  WHERE datname = current_database() AND pid <> pg_backend_pid() AND backend_type = 'client backend' AND backend_start < to_timestamp(%s);
SELECT pg_sleep(0.5);
SELECT count(*) FROM pg_stat_activity
  WHERE datname = current_database() AND pid <> pg_backend_pid() AND backend_type = 'client backend' AND backend_start < to_timestamp(%s);
" "$stamp" "$stamp" | sq "$db" -At)" || die "could not terminate the database's sessions"
  mapfile -t nums < <(grep -E '^[0-9]+$' <<<"$out")
  [ "${#nums[@]}" = 2 ] || die "unexpected answer while terminating sessions: '$out'"
  total=$((total + nums[0]))
  remaining="${nums[1]}"
  if [ "$remaining" = 0 ]; then break; fi
done
# Read the setting back rather than trusting the statement.
left="$(sq "$db" -At -c "
SELECT count(*) FROM pg_db_role_setting s JOIN pg_database d ON d.oid = s.setdatabase
WHERE d.datname = current_database() AND s.setrole = 0 AND 'default_transaction_read_only=on' = ANY (s.setconfig)" </dev/null)" \
  || die "could not read the setting back"
if [ "$mode" = on ] && [ "$left" != 1 ]; then die "read-only is not set on $db after the change" 1; fi
if [ "$mode" = off ] && [ "$left" != 0 ]; then die "read-only is still set on $db after the change" 1; fi

if [ "$remaining" != 0 ]; then
  if [ "$mode" = off ]; then
    echo "set-readonly: read-only is REMOVED from $db, but $remaining client session(s) that started during the window would not end after $passes attempts; they may stay read-only until they are replaced. Restart the apps that use them." >&2
    exit 3
  fi
  echo "set-readonly: $remaining client session(s) that started before the change are still connected to $db after $passes attempts; the window is NOT closed" >&2
  exit 1
fi
if [ "$unprivileged" = 1 ]; then
  echo "set-readonly: WARNING the connecting role is not a superuser and lacks pg_read_all_stats plus pg_signal_backend, so it could not see or end other roles' sessions. The setting is removed, but a session another role opened during the window may stay read-only: restart the apps." >&2
fi

echo "set-readonly: $db read-only $mode; terminated $total session(s), none left that started before the change"
