#!/usr/bin/env bash
# End-to-end test of the origin lockdown (spec §5) on this machine -- no Cloudflare, no
# production. Builds the nginx image and runs it twice against dummy certificates and a
# stub upstream:
#
#   run A  "not Cloudflare": the image's real generated snippets. Connections from this host
#          arrive from the test network's gateway (10.99.0.1), which is not a Cloudflare
#          range, so every direct probe must be refused -- and the loopback healthcheck must
#          still pass.
#   run B  "Cloudflare":     snippets generated from fixtures/cloudflare-ips-plus-docker.json,
#          which adds 10.99.0.0/24, so this host counts as Cloudflare. Requests must reach
#          the upstream, real_ip must apply, host validation must still hold, and AOP must
#          behave the way snippets/ssl-params.conf currently says (optional -> no-cert 200,
#          on -> no-cert 400).
#
# Needs docker, curl, openssl, jq. Usage (from anywhere): deployment/nginx/test/local-lockdown-test.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
nginx_dir="$root/deployment/nginx"
image="the-greatest-nginx:lockdown-test"
net="tg-lockdown-test"
upstream="tg-lockdown-upstream"
ctr="tg-lockdown-nginx"
http_port=18080
https_port=18443
work="$(mktemp -d)"

cleanup() {
  docker rm -f "$ctr" "$upstream" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1 -- $2"; failures=$((failures + 1)); }

# --- fixtures -------------------------------------------------------------------------
# One dummy server cert per server_name in the template, or nginx refuses to start.
for h in $(grep -oE 'CERT_PATH\}/[A-Za-z0-9.-]+/fullchain' "$nginx_dir/the-greatest.conf.template" | cut -d/ -f2 | sort -u); do
  mkdir -p "$work/live/$h"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$h" \
    -keyout "$work/live/$h/privkey.pem" -out "$work/live/$h/fullchain.pem" 2>/dev/null
done

# A throwaway CA standing in for Cloudflare's origin-pull CA, and a client cert it signed.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=test-origin-pull-ca" \
  -keyout "$work/ca.key" -out "$work/ca.pem" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=test-client" \
  -keyout "$work/client.key" -out "$work/client.csr" 2>/dev/null
openssl x509 -req -in "$work/client.csr" -CA "$work/ca.pem" -CAkey "$work/ca.key" \
  -CAcreateserial -days 1 -out "$work/client.pem" 2>/dev/null

mkdir -p "$work/snips"
"$nginx_dir/bin/generate-cloudflare-snippets.sh" "$work/snips" \
  "$nginx_dir/test/fixtures/cloudflare-ips-plus-docker.json" >/dev/null || { echo "generator failed"; exit 1; }

# --- image, network, stub upstream ------------------------------------------------------
docker build -q -t "$image" "$nginx_dir" >/dev/null || { echo "image build failed"; exit 1; }
docker network create --subnet 10.99.0.0/24 "$net" >/dev/null
docker run -d --name "$upstream" --network "$net" --network-alias web nginx:alpine >/dev/null

run_nginx() {   # run_nginx [extra docker run args...]
  docker rm -f "$ctr" >/dev/null 2>&1 || true
  docker run -d --name "$ctr" --network "$net" \
    -p "127.0.0.1:$http_port:80" -p "127.0.0.1:$https_port:443" \
    -e NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx/sites-enabled \
    -e WEB_HOST=web -e WEB_PORT=80 \
    -e CERT_PATH=/etc/letsencrypt/live -e KEY_PATH=/etc/letsencrypt/live \
    -v "$nginx_dir/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$nginx_dir/the-greatest.conf.template:/etc/nginx/templates/the-greatest.conf.template:ro" \
    -v "$nginx_dir/snippets/ssl-params.conf:/etc/nginx/snippets/ssl-params.conf:ro" \
    -v "$nginx_dir/snippets/proxy-params.conf:/etc/nginx/snippets/proxy-params.conf:ro" \
    -v "$nginx_dir/snippets/cloudflare-only.conf:/etc/nginx/snippets/cloudflare-only.conf:ro" \
    -v "$work/live:/etc/letsencrypt/live:ro" \
    -v "$work/ca.pem:/etc/nginx/certs/cloudflare-origin-pull-ca.pem:ro" \
    "$@" "$image" >/dev/null
  # Wait until nginx itself -- not docker-proxy on the published ports, which accepts the
  # TCP connection immediately regardless of whether nginx is ready -- answers on both
  # ports. The bot-blocker's config is huge (tens of thousands of lines) and takes real
  # time to load, so a host-side probe can hit docker-proxy while nginx is still starting
  # and get the connection reset mid-handshake. Probing from inside the container makes
  # "connection refused" (curl exit 7) unambiguous: once nginx is listening, port 80
  # answers 444 (exit 52) and port 443 rejects the SNI-less handshake (exit 35).
  for _ in $(seq 1 120); do
    docker exec "$ctr" curl -s -o /dev/null --max-time 2 http://127.0.0.1:80/ >/dev/null 2>&1; a=$?
    docker exec "$ctr" curl -sk -o /dev/null --max-time 2 https://127.0.0.1:443/ >/dev/null 2>&1; b=$?
    [ "$a" -ne 7 ] && [ "$b" -ne 7 ] && return 0
    sleep 0.25
  done
  echo "nginx did not come up:"; docker logs "$ctr" 2>&1 | tail -20; exit 1
}

# expect_exit <name> "<accepted>" <curl args...>
#   <accepted> lists curl exit codes, and optionally http:<status> tokens accepted on exit 0.
expect_exit() {
  local name="$1" accepted="$2"; shift 2
  local code rc
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"); rc=$?
  if [[ " $accepted " == *" $rc "* ]] || { [ "$rc" -eq 0 ] && [[ " $accepted " == *" http:$code "* ]]; }; then
    pass "$name (curl exit $rc, http $code)"
  else
    fail "$name" "curl exit $rc, http $code; expected one of [$accepted]"
  fi
}

# expect_http <name> <status> <curl args...>
expect_http() {
  local name="$1" want="$2"; shift 2
  local code rc
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"); rc=$?
  if [ "$rc" -eq 0 ] && [ "$code" = "$want" ]; then pass "$name (http $code)"
  else fail "$name" "curl exit $rc, http $code; expected http $want"; fi
}

music="thegreatestmusic.org"

echo "== run A: this host is NOT Cloudflare (image's real snippets)"
run_nginx
# 52/56 over HTTP/1.1, 92 over HTTP/2: nginx closed the connection (444); http 400 once ssl_verify_client is on
expect_exit "A1 HTTPS with correct SNI is refused"        "52 56 92 http:400" -k --resolve "$music:$https_port:127.0.0.1" "https://$music:$https_port/"
expect_exit "A2 HTTPS with no SNI is rejected at handshake" "35"   -k "https://127.0.0.1:$https_port/"
expect_exit "A3 HTTPS with unknown SNI is rejected at handshake" "35" -k --resolve "evil.test:$https_port:127.0.0.1" "https://evil.test:$https_port/"
expect_exit "A4 HTTP with forged X-Forwarded-Proto is refused" "52 56" -H "Host: $music" -H "X-Forwarded-Proto: https" "http://127.0.0.1:$http_port/"
expect_exit "A5 HTTP with unknown Host is refused"        "52 56" -H "Host: evil.test" "http://127.0.0.1:$http_port/"
expect_exit "A6 HTTP for our Host is refused"             "52 56" -H "Host: new.thegreatestbooks.org" "http://127.0.0.1:$http_port/"
if docker exec "$ctr" curl -sf -o /dev/null -H "Host: $music" http://localhost:80/up; then
  pass "A7 loopback healthcheck still passes"
else
  fail "A7 loopback healthcheck still passes" "curl -f from inside the container failed"
fi

echo "== run B: this host counts as Cloudflare (fixture snippets)"
run_nginx \
  -v "$work/snips/cloudflare-real-ip.conf:/etc/nginx/snippets/cloudflare-real-ip.conf:ro" \
  -v "$work/snips/cloudflare-geo.conf:/etc/nginx/snippets/cloudflare-geo.conf:ro"
expect_http "B1 HTTPS with the client cert reaches the upstream" 200 -k \
  --cert "$work/client.pem" --key "$work/client.key" \
  --resolve "$music:$https_port:127.0.0.1" -H "CF-Connecting-IP: 203.0.113.9" "https://$music:$https_port/"
if docker logs "$ctr" 2>/dev/null | grep -qE '^203\.0\.113\.9 .* cf=10\.99\.0\.1 verify=SUCCESS'; then
  pass "B2 access log shows the visitor IP, the peer as cf=, and verify=SUCCESS"
else
  fail "B2 access log shows the visitor IP, the peer as cf=, and verify=SUCCESS" "$(docker logs "$ctr" 2>&1 | grep -E '^[0-9.]+ ' | tail -3)"
fi
if grep -qE '^\s*ssl_verify_client\s+on\s*;' "$nginx_dir/snippets/ssl-params.conf"; then no_cert=400; else no_cert=200; fi
expect_http "B3 HTTPS without a client cert gets $no_cert (ssl_verify_client mode)" "$no_cert" -k \
  --resolve "$music:$https_port:127.0.0.1" "https://$music:$https_port/"
expect_http "B4 HTTP with forged X-Forwarded-Proto only redirects (proxy branch gone)" 301 \
  -H "Host: $music" -H "X-Forwarded-Proto: https" "http://127.0.0.1:$http_port/"
expect_exit "B5 HTTPS with unknown SNI is still rejected" "35" -k --resolve "evil.test:$https_port:127.0.0.1" "https://evil.test:$https_port/"
expect_exit "B6 HTTP with unknown Host is still refused"  "52 56" -H "Host: evil.test" "http://127.0.0.1:$http_port/"

echo
if [ "$failures" -eq 0 ]; then echo "all lockdown probes passed"; else echo "$failures lockdown probe(s) failed"; exit 1; fi
