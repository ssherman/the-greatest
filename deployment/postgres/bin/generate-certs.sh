#!/usr/bin/env bash
# deployment/postgres/bin/generate-certs.sh DIR [UID] [GID]
# The database server's TLS certificate: one self-signed certificate, no CA (spec §5.3). Clients use
# sslmode=require and do not verify it. First run only: a complete pair is left alone, a partial one
# is regenerated whole. Ten-year validity.
# Postgres refuses a key that is not 0600 and owned by the user running it, so the key is owned by
# UID:GID, defaulting to 999:999, the postgres user in the official postgres image.
# Chowning to an owner other than the caller needs root.
set -euo pipefail
dir="${1:?usage: generate-certs.sh DIR [UID] [GID]}"
uid="${2:-999}"
gid="${3:-999}"
files=(server.pem server-key.pem)
days=3650

complete=1
for f in "${files[@]}"; do [ -s "$dir/$f" ] || complete=0; done
if [ "$complete" = 1 ]; then echo "present: certificates in $dir left alone"; exit 0; fi

umask 077
mkdir -p "$dir"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for f in "${files[@]}"; do rm -f "$dir/$f"; done

openssl genrsa -out "$work/key.rsa" 3072 2>/dev/null
openssl pkcs8 -topk8 -nocrypt -in "$work/key.rsa" -out "$work/server-key.pem"
openssl req -x509 -new -key "$work/server-key.pem" -sha256 -days "$days" \
  -subj "/O=the-greatest/OU=database/CN=postgres-server" \
  -addext "subjectAltName=DNS:localhost,DNS:postgres,IP:127.0.0.1" -out "$work/server.pem"

# The directory is bind-mounted, so it keeps these host permissions inside the container: it must be
# owned by the container user, and closed to everyone else.
chown "$uid:$gid" "$dir"
chmod 0700 "$dir"
install -m 0600 -o "$uid" -g "$gid" "$work/server-key.pem" "$dir/server-key.pem"
install -m 0644 -o "$uid" -g "$gid" "$work/server.pem" "$dir/server.pem"
echo "generated: certificates in $dir"
