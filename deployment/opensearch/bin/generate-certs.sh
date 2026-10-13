#!/usr/bin/env bash
# deployment/opensearch/bin/generate-certs.sh DIR
# The search server's own certificates: a private CA, the node certificate (transport and HTTP
# TLS) and the admin client certificate securityadmin.sh authenticates with. First run only: a
# complete set is left alone, a partial one is regenerated whole. Ten-year validity -- the server is
# replaced long before, and nobody renews anything. Clients do not verify the node certificate
# (spec §5.3); the CA exists because OpenSearch's transport layer requires one.
# Subjects must match plugins.security.nodes_dn / authcz.admin_dn in config/opensearch.yml.
set -euo pipefail
dir="${1:?usage: generate-certs.sh DIR}"
files=(root-ca.pem root-ca-key.pem node.pem node-key.pem admin.pem admin-key.pem)
days=3650
org="/O=the-greatest/OU=search"

complete=1
for f in "${files[@]}"; do [ -s "$dir/$f" ] || complete=0; done
if [ "$complete" = 1 ]; then echo "present: certificates in $dir left alone"; exit 0; fi

umask 077
mkdir -p "$dir"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for f in "${files[@]}"; do rm -f "$dir/$f"; done

openssl genrsa -out "$work/ca.key" 3072 2>/dev/null
openssl req -x509 -new -key "$work/ca.key" -sha256 -days "$days" -subj "$org/CN=search-root-ca" -out "$work/ca.pem"

leaf() {   # leaf NAME CN EXTFILE_LINE
  openssl genrsa -out "$work/$1.rsa" 3072 2>/dev/null
  # OpenSearch reads PKCS#8 keys only.
  openssl pkcs8 -topk8 -nocrypt -in "$work/$1.rsa" -out "$work/$1-key.pem"
  openssl req -new -key "$work/$1-key.pem" -subj "$org/CN=$2" -out "$work/$1.csr"
  printf '%s\n' "$3" >"$work/$1.ext"
  openssl x509 -req -in "$work/$1.csr" -CA "$work/ca.pem" -CAkey "$work/ca.key" -CAcreateserial \
    -sha256 -days "$days" -extfile "$work/$1.ext" -out "$work/$1.pem" 2>/dev/null
}
leaf node search-node "subjectAltName=DNS:localhost,DNS:opensearch,IP:127.0.0.1"
leaf admin admin "basicConstraints=CA:FALSE"

install -m 0600 "$work/ca.pem" "$dir/root-ca.pem"
install -m 0600 "$work/ca.key" "$dir/root-ca-key.pem"
for n in node admin; do
  install -m 0600 "$work/$n.pem" "$dir/$n.pem"
  install -m 0600 "$work/$n-key.pem" "$dir/$n-key.pem"
done
echo "generated: certificates in $dir"
