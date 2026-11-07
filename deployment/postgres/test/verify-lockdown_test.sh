#!/usr/bin/env bash
# Unit test for deployment/scripts/verify-postgres-lockdown.sh; curl, psql and docker are stubbed.
# shellcheck disable=SC2016  # stub bodies are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
verify="${VERIFY_SCRIPT:-$OS_DIR/../scripts/verify-postgres-lockdown.sh}"
export PG_IPV4=203.0.113.50 PG_IPV6=2001:db8::50

# curl stub for --outside. Knobs: CTRL4/CTRL6 = time_connect the port 22 control reports;
# P_RC/P_TC = exit code and time_connect of every port 6543 probe.
OUTSIDE_STUB='last=""; for a in "$@"; do last="$a"; done
case "$last" in
  telnet://*:22) case "$last" in telnet://\[*) printf "%s" "$CTRL6" ;; *) printf "%s" "$CTRL4" ;; esac; exit 28 ;;
  *) printf "%s" "$P_TC"; exit "$P_RC" ;;
esac'
export CTRL4=0.012 CTRL6=0.015 P_RC=28 P_TC=0.000000
outside() { new_sandbox; stub curl "$OUTSIDE_STUB"; "$verify" --outside >"$SANDBOX/log/out" 2>&1; rc=$?; }

outside
if [ "$rc" = 0 ]; then pass "--outside: controls connect, 6543 dropped"; else fail "--outside: drops pass" "rc=$rc $(cat "$SANDBOX/log/out")"; fi
if called '\[2001:db8::50\]:6543' && called '203.0.113.50:6543'; then pass "--outside probes both families on 6543"; else fail "--outside probes" "$(cat "$CALLS")"; fi

CTRL4=0.000000 outside
if [ "$rc" = 1 ] && grep -q 'IPv4 control' "$SANDBOX/log/out" && ! called '203.0.113.50:6543'; then pass "--outside: failed IPv4 control fails and skips the IPv4 probe"; else fail "--outside: IPv4 control unreachable" "rc=$rc $(cat "$SANDBOX/log/out")"; fi

new_sandbox
stub curl "$OUTSIDE_STUB"
PG_PORT=7654 "$verify" --outside >"$SANDBOX/log/out" 2>&1; rc=$?
if grep -q '7654' "$SANDBOX/log/out" && grep -q 'PG_PORT' "$SANDBOX/log/out" && called '203.0.113.50:7654'; then pass "PG_PORT is announced and used"; else fail "PG_PORT announced" "rc=$rc $(cat "$SANDBOX/log/out")"; fi
outside
if ! grep -q 'PG_PORT' "$SANDBOX/log/out"; then pass "no port notice on the real port"; else fail "port notice" "$(cat "$SANDBOX/log/out")"; fi

CTRL6=0.000000 outside
if [ "$rc" = 1 ] && grep -q 'IPv6 control' "$SANDBOX/log/out" && ! called '\[2001:db8::50\]:6543'; then pass "--outside: failed control fails and skips that family's probe"; else fail "--outside: control unreachable" "rc=$rc $(cat "$SANDBOX/log/out")"; fi

P_RC=7 outside
if [ "$rc" = 1 ]; then pass "--outside: refused (exit 7) fails"; else fail "--outside: exit 7" "rc=$rc"; fi

P_TC=0.031 outside
if [ "$rc" = 1 ]; then pass "--outside: timeout after connecting fails"; else fail "--outside: slow after connect" "rc=$rc"; fi

P_RC=0 P_TC=0.020 outside
if [ "$rc" = 1 ]; then pass "--outside: a TCP connection fails"; else fail "--outside: connection" "rc=$rc"; fi

new_sandbox
stub curl "$OUTSIDE_STUB"
PG_IPV4=203.0.113.50/32 "$verify" --outside >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ] && [ ! -s "$CALLS" ]; then pass "--outside: IPv4 with /32 refused, curl never called"; else fail "--outside: /32" "rc=$rc"; fi
PG_IPV6=nope "$verify" --outside >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ] && [ ! -s "$CALLS" ]; then pass "--outside: malformed IPv6 refused"; else fail "--outside: ipv6 nope" "rc=$rc"; fi
PG_IPV6=2001:db8::50/128 outside
if [ "$rc" = 0 ] && ! called '/128'; then pass "--outside strips a /128 suffix"; else fail "--outside /128" "rc=$rc $(cat "$CALLS")"; fi
new_sandbox
stub curl 'printf 000; exit 28'
PG_IPV6="" "$verify" --outside >/dev/null 2>&1; rc=$?
if [ "$rc" != 0 ]; then pass "--outside without PG_IPV6 is refused"; else fail "--outside without PG_IPV6" "rc=0"; fi

# psql stub for --inside, answering from the environment the script sets (PGUSER, PGDATABASE,
# PGSSLMODE). The login is allowed on the_greatest only. Knobs:
#   OK_DISABLE=1 sslmode=disable connects (wrong)    OK_REQUIRE=0 sslmode=require refused
#   OK_OTHER=1   login works on the other database   SUPER=t      rolsuper answer
#   OK_SUPERUSER=1 postgres connects over the network
#   DIS_MSG, OTHER_MSG, SU_MSG   what the refused plaintext / other-database / superuser attempt
#                                says; the default is the real text of a pg_hba rejection
HBA="FATAL:  no pg_hba.conf entry for host 203.0.113.9, user x, database y, no encryption"
export HBA
PSQL_STUB='if [ "$PGUSER" = postgres ]; then if [ "${OK_SUPERUSER:-0}" = 1 ]; then echo t; exit 0; fi; echo "${SU_MSG:-$HBA}" >&2; exit 2; fi
if [ "$PGSSLMODE" = disable ]; then if [ "${OK_DISABLE:-0}" = 1 ]; then echo f; exit 0; fi; echo "${DIS_MSG:-$HBA}" >&2; exit 2; fi
if [ "$PGDATABASE" != the_greatest ]; then if [ "${OK_OTHER:-0}" = 1 ]; then echo f; exit 0; fi; echo "${OTHER_MSG:-$HBA}" >&2; exit 2; fi
if [ "${OK_REQUIRE:-1}" != 1 ]; then echo "FATAL:  password authentication failed" >&2; exit 2; fi
echo "${SUPER:-f}"'
export PGPASSWORD=sekrit-pw
inside() { new_sandbox; stub psql "$PSQL_STUB"; PG_CLIENT=psql "$verify" --inside the_greatest the_greatest >"$SANDBOX/log/out" 2>&1; rc=$?; }

inside
if [ "$rc" = 0 ]; then pass "--inside: correct answers pass"; else fail "--inside: correct answers" "rc=$rc $(cat "$SANDBOX/log/out")"; fi
if ! called 'sekrit-pw'; then pass "--inside keeps the password off the psql command line"; else fail "password on argv" "$(cat "$CALLS")"; fi
if grep -q 'PASS  superuser login over the network is refused' "$SANDBOX/log/out"; then pass "--inside names the superuser check"; else fail "superuser check named" "$(cat "$SANDBOX/log/out")"; fi

OK_DISABLE=1 inside
if [ "$rc" = 1 ]; then pass "--inside: sslmode=disable connecting fails"; else fail "--inside: disable" "rc=$rc"; fi
OK_REQUIRE=0 inside
if [ "$rc" = 1 ]; then pass "--inside: sslmode=require refused fails"; else fail "--inside: require refused" "rc=$rc"; fi
OK_OTHER=1 inside
if [ "$rc" = 1 ]; then pass "--inside: login working on the other database fails"; else fail "--inside: other db" "rc=$rc"; fi
SUPER=t inside
if [ "$rc" = 1 ]; then pass "--inside: rolsuper true fails"; else fail "--inside: rolsuper" "rc=$rc"; fi
OK_SUPERUSER=1 inside
if [ "$rc" = 1 ]; then pass "--inside: a superuser network login fails"; else fail "--inside: superuser" "rc=$rc"; fi

# A refusal that is not pg_hba's must never count as one.
for msg in "psql: error: connection to server timed out" "docker: error pulling image configuration: toomanyrequests" "FATAL:  too many connections for role"; do
  DIS_MSG="$msg" inside
  if [ "$rc" = 1 ] && grep -q 'FAIL  plaintext' "$SANDBOX/log/out"; then pass "--inside: plaintext attempt failing as '${msg:0:28}...' fails"; else fail "--inside: plaintext, $msg" "rc=$rc $(cat "$SANDBOX/log/out")"; fi
  OTHER_MSG="$msg" inside
  if [ "$rc" = 1 ] && grep -q 'FAIL  login is refused on database' "$SANDBOX/log/out"; then pass "--inside: other-database attempt failing as '${msg:0:28}...' fails"; else fail "--inside: other db, $msg" "rc=$rc $(cat "$SANDBOX/log/out")"; fi
  SU_MSG="$msg" inside
  if [ "$rc" = 1 ] && grep -q 'FAIL  superuser login' "$SANDBOX/log/out"; then pass "--inside: superuser attempt failing as '${msg:0:28}...' fails"; else fail "--inside: superuser, $msg" "rc=$rc $(cat "$SANDBOX/log/out")"; fi
done
SU_MSG="FATAL:  password authentication failed for user \"postgres\"" inside
if [ "$rc" = 1 ] && grep -q 'FAIL  superuser login' "$SANDBOX/log/out"; then pass "--inside: superuser answered 'password authentication failed' fails (a rule matched)"; else fail "--inside: superuser auth failed" "rc=$rc $(cat "$SANDBOX/log/out")"; fi

# Without psql the check runs a postgres:18 client container, password through the environment.
new_sandbox
# The docker stub reads the user and database from the arguments, as the container's psql would.
stub docker 'while [ $# -gt 0 ]; do case "$1" in -U) PGUSER="$2" ;; -d) PGDATABASE="$2" ;; -e) case "$2" in PGSSLMODE=*) PGSSLMODE="${2#*=}" ;; esac ;; esac; shift; done
export PGUSER PGDATABASE PGSSLMODE
'"$PSQL_STUB"
PG_CLIENT=docker "$verify" --inside the_greatest the_greatest >"$SANDBOX/log/out" 2>&1; rc=$?
if [ "$rc" = 0 ] && called 'docker run .*postgres:18' && called ' -e PGPASSWORD( |$)' && ! called 'sekrit-pw'; then pass "--inside via docker: client container, password not on argv"; else fail "--inside via docker" "rc=$rc $(cat "$CALLS") $(cat "$SANDBOX/log/out")"; fi

new_sandbox
stub psql "$PSQL_STUB"
env -u PGPASSWORD PG_CLIENT=psql "$verify" --inside the_greatest the_greatest >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then pass "--inside without PGPASSWORD is refused"; else fail "--inside without PGPASSWORD" "rc=$rc"; fi
PG_CLIENT=psql "$verify" --inside the_greatest >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then pass "--inside without DATABASE is refused"; else fail "--inside missing database" "rc=$rc"; fi
PG_CLIENT=psql "$verify" --inside the_greatest nonesuch >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then pass "--inside with an unknown database is refused"; else fail "--inside unknown database" "rc=$rc"; fi
if ! "$verify" >/dev/null 2>&1; then pass "no mode is refused"; else fail "no mode is refused" "exit 0"; fi
finish
