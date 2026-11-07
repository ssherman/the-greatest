#!/usr/bin/env bash
# Checks that the database server is locked down. Run both modes after every build or rebuild.
#
#   --outside   from a machine that is NOT an app server (a laptop): nothing may even connect.
#                 PG_IPV4=... PG_IPV6=... deployment/scripts/verify-postgres-lockdown.sh --outside
#   --inside ROLE DATABASE   from an app server that is on the allowlist, as one of its logins:
#               plaintext is refused, TLS connects, the login is refused on the other database,
#               it is not a superuser, and the postgres superuser cannot log in over the network.
#                 PG_IPV4=... PGPASSWORD=... deployment/scripts/verify-postgres-lockdown.sh --inside the_greatest the_greatest
#               ROLE is the login name, DATABASE the one it owns (the_greatest or tgb). Uses psql if
#               the host has it, otherwise a one-off postgres:18 container. PG_CLIENT=psql|docker forces one.
#
# Outside, the server is expected to DROP 6543 (DOCKER-USER, ufw), so a pass is curl exit 28 with
# time_connect 0: no TCP connection was ever made. Exit 7 (refused), a connection, or a timeout after
# connecting all fail. A drop looks the same as an unreachable network, so each address first gets a
# positive control: a TCP connection to port 22 (ufw allows OpenSSH on IPv4 and IPv6). If the control
# cannot connect, the 6543 probe for that address proves nothing and is skipped, with a FAIL.
# The password reaches psql through the environment only, never a command line.
set -uo pipefail
mode="${1:-}"
failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1 -- $2"; failures=$((failures + 1)); }
PORT="${PG_PORT:-6543}"   # PG_PORT exists for a throwaway test server, never for the real one
if [ -n "${PG_PORT:-}" ] && [ "$PG_PORT" != 6543 ]; then echo "NOTE  PG_PORT is set: checking port $PORT, not the real server's 6543"; fi

usage() { echo "usage: verify-postgres-lockdown.sh --outside | --inside ROLE DATABASE (see the header)" >&2; exit 2; }
bad_input() { echo "$1" >&2; usage; }
valid_ipv4() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
valid_ipv6() { [[ "$1" =~ ^[0-9A-Fa-f:]+$ && "$1" == *:* ]]; }
connected() { [[ "${1##* }" =~ [1-9] ]]; }   # a non-zero time_connect: a TCP connection was made

control() {   # control NAME HOST   (HOST: 1.2.3.4 or [v6]) -> 0 if port 22 accepts a connection
  local tc
  tc="$(curl -s -o /dev/null --connect-timeout 5 --max-time 3 -w '%{time_connect}' "telnet://$2:22")"
  if connected "$tc"; then return 0; fi
  fail "$1 control: port 22 unreachable" "cannot reach the server on $1 from this machine -- the $PORT probe would prove nothing; run --outside from a host that can reach it"
  return 1
}

no_connection() {   # no_connection NAME HOST
  local out rc
  out="$(curl -s -o /dev/null -w '%{time_connect}' --connect-timeout 10 --max-time 15 "telnet://$2:$PORT")"; rc=$?
  if [ "$rc" = 28 ] && ! connected "$out"; then pass "$1 (dropped: curl exit 28, no TCP connection)"
  elif [ "$rc" = 7 ]; then fail "$1" "curl exit 7 (refused) -- a correct firewall drops, it does not refuse"
  elif connected "$out"; then fail "$1" "a TCP connection was made (curl exit $rc) -- the database server answered"
  else fail "$1" "curl exit $rc, expected a drop (exit 28)"; fi
}

# pgq SSLMODE USER DATABASE PASSWORD SQL -> psql output; return code is psql's. The password is
# exported for psql (or passed to the container by name), so it is never an argument.
pgq() {
  local sslmode="$1" user="$2" db="$3" pw="$4" sql="$5"
  case "$client" in
    psql)
      PGHOST="$PG_IPV4" PGPORT="$PORT" PGSSLMODE="$sslmode" PGUSER="$user" PGDATABASE="$db" PGPASSWORD="$pw" \
        PGCONNECT_TIMEOUT=10 psql -w -tA -c "$sql" 2>&1 ;;
    docker)
      PGPASSWORD="$pw" docker run --rm -e PGPASSWORD -e PGSSLMODE="$sslmode" -e PGCONNECT_TIMEOUT=10 \
        postgres:18 psql -w -tA -h "$PG_IPV4" -p "$PORT" -U "$user" -d "$db" -c "$sql" 2>&1 ;;
  esac
}

# refused_by_hba NAME ATTEMPT_OUTPUT RC: PASS only if the server itself said no. render-hba.sh emits
# named hostssl lines only, so a correct server answers every attempt it must refuse with
# "no pg_hba.conf entry". A timeout, a connection limit, a failed docker pull or "password
# authentication failed" (a rule matched, so the attempt was allowed to try) is a FAIL, never a pass.
refused_by_hba() {
  local name="$1" out="$2" rc="$3"
  if [ "$rc" != 0 ] && [[ "$out" == *"no pg_hba.conf entry"* ]]; then pass "$name"
  elif [ "$rc" = 0 ]; then fail "$name" "it connected"
  else fail "$name" "not refused by pg_hba, last line: ${out##*$'\n'}"; fi
}

case "$mode" in
  --outside)
    : "${PG_IPV4:?set PG_IPV4}" "${PG_IPV6:?set PG_IPV6 -- the server has one, and it must be probed}"
    PG_IPV6="${PG_IPV6%%/*}"   # Terraform reports it with a /128 suffix
    valid_ipv4 "$PG_IPV4" || bad_input "PG_IPV4 must be a bare IPv4 address, got: $PG_IPV4"
    valid_ipv6 "$PG_IPV6" || bad_input "PG_IPV6 must be a bare IPv6 address, got: $PG_IPV6"
    if control "IPv4" "$PG_IPV4"; then no_connection "IPv4 :$PORT" "$PG_IPV4"; fi
    if control "IPv6" "[$PG_IPV6]"; then no_connection "IPv6 :$PORT" "[$PG_IPV6]"; fi
    ;;
  --inside)
    role="${2:-}" db="${3:-}"
    [ -n "$role" ] && [ -n "$db" ] || bad_input "--inside needs ROLE and DATABASE"
    [ -n "${PG_IPV4:-}" ] || bad_input "set PG_IPV4"
    [ -n "${PGPASSWORD:-}" ] || bad_input "set PGPASSWORD (the password of ROLE)"
    valid_ipv4 "$PG_IPV4" || bad_input "PG_IPV4 must be a bare IPv4 address, got: $PG_IPV4"
    case "$db" in
      the_greatest) other=tgb ;;
      tgb) other=the_greatest ;;
      *) bad_input "DATABASE must be the_greatest or tgb, got: $db" ;;
    esac
    client="${PG_CLIENT:-}"
    if [ -z "$client" ]; then if command -v psql >/dev/null; then client=psql; else client=docker; fi; fi
    case "$client" in psql|docker) ;; *) bad_input "PG_CLIENT must be psql or docker" ;; esac

    out="$(pgq disable "$role" "$db" "$PGPASSWORD" 'select 1')"; rc=$?
    refused_by_hba "plaintext is refused (sslmode=disable)" "$out" "$rc"

    if out="$(pgq require "$role" "$db" "$PGPASSWORD" 'select 1')"; then pass "TLS login works (sslmode=require)"
    else fail "TLS login works" "sslmode=require did not connect: ${out##*$'\n'}"; fi

    out="$(pgq require "$role" "$other" "$PGPASSWORD" 'select 1')"; rc=$?
    refused_by_hba "login is refused on database $other" "$out" "$rc"

    out="$(pgq require "$role" "$db" "$PGPASSWORD" 'select rolsuper from pg_roles where rolname = current_user')" || out="(no answer)"
    if [ "$out" = f ]; then pass "$role is not a superuser"; else fail "$role is not a superuser" "rolsuper answered: $out"; fi

    # A wrong password on purpose. A correct server has no rule for postgres at all, so it answers
    # "no pg_hba.conf entry" before any password is asked; "password authentication failed" would
    # mean a rule matched, which is the failure this check exists to catch.
    out="$(pgq require postgres postgres "not-the-password-$$" 'select 1')"; rc=$?
    refused_by_hba "superuser login over the network is refused" "$out" "$rc"
    ;;
  *) usage ;;
esac
if [ "$failures" = 0 ]; then echo "all passed"; else echo "$failures failed"; exit 1; fi
