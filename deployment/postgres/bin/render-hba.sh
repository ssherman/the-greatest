#!/usr/bin/env bash
# deployment/postgres/bin/render-hba.sh
# Prints pg_hba.conf from a clients file. Spec: docs/superpowers/specs/2026-11-06-postgres-server-design.md §5.2.
#
#   render-hba.sh CLIENTS_FILE    one `role database address` per line, # comments, blank lines ignored
#
# Every rule is hostssl + scram-sha-256 for one role on one database from one host address. No `host`
# (unencrypted) rule and no network rule naming `all` can come out of this script. The local socket
# is peer for postgres only. Only the role/database pairs below are accepted, so a typo in the SOPS
# value can never hand a login a database that is not its own. Exits 2, printing nothing, on any bad
# input: a bad value must fail the deploy, never render a partial or a wider file. An IPv6 client renders
# but warns on stderr: the port binds IPv4 only, so that client can never connect.
set -euo pipefail
[ $# -eq 1 ] || { echo "render-hba: usage: render-hba.sh CLIENTS_FILE" >&2; exit 2; }
clients="$1"
[ -r "$clients" ] || { echo "render-hba: cannot read $clients" >&2; exit 2; }

# Python's ipaddress does the validation, as in render-firewall.sh. Single host addresses only:
# accepting a CIDR is how 0.0.0.0/0 gets in.
rules="$(python3 -I - "$clients" <<'PY'
import ipaddress, sys
ALLOWED = {
    ("the_greatest", "the_greatest"),
    ("tgb_app", "tgb"),
    ("tgb_reader", "tgb"),
}
out = []
with open(sys.argv[1]) as f:
    for n, raw in enumerate(f, 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 3:
            sys.exit(f"render-hba: line {n} must be: role database address")
        role, database, address = parts
        if (role, database) not in ALLOWED:
            sys.exit(f"render-hba: line {n}: role {role} is not allowed on database {database}")
        try:
            ip = ipaddress.ip_address(address)
        except ValueError:
            sys.exit(f"render-hba: line {n} is not a single IP address")
        if ip.is_unspecified:
            sys.exit(f"render-hba: line {n} would allow everyone")
        if ip.version == 6 and ip.ipv4_mapped:
            sys.exit(f"render-hba: line {n} is an IPv4-mapped IPv6 address; write the plain IPv4 form")
        if getattr(ip, "scope_id", None):
            sys.exit(f"render-hba: line {n} is a scoped IPv6 address; a client address has no zone")
        if ip.version == 6:
            # A warning and not a failure: the rule is harmless. Line number only, this reaches a public log.
            print(f"render-hba: WARNING line {n} is an IPv6 client, which can never connect: port 6543 binds IPv4 only", file=sys.stderr)
        bits = 32 if ip.version == 4 else 128
        out.append(f"hostssl {database} {role} {ip}/{bits} scram-sha-256")
if not out:
    sys.exit("render-hba: the clients file is empty")
print("\n".join(out))
PY
)" || exit 2

echo "# Rendered by deployment/postgres/bin/render-hba.sh. Do not edit by hand."
echo "# TYPE   DATABASE  USER  ADDRESS  METHOD"
echo "local all postgres peer"
printf '%s\n' "$rules"
