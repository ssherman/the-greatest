#!/usr/bin/env bash
# Post-deploy check that the origin serves only Cloudflare. Run from a machine outside
# Cloudflare's network (a laptop is fine) after every nginx change:
#
#   deployment/scripts/verify-origin-lockdown.sh            # against 45.33.28.21
#   ORIGIN_IP=203.0.113.5 deployment/scripts/verify-origin-lockdown.sh   # a rebuilt server
#
# Direct probes must be refused: connection closed (curl 52/56), handshake rejected (35),
# refused (7), timed out (28), stream closed (92, HTTP/2), or nginx's 400 "No required SSL
# certificate was sent" once Authenticated Origin Pulls is enforced. Anything that looks
# like a page or a redirect is a failure. Through-Cloudflare probes use /api/ paths, which
# skip Super Bot Fight Mode, and must carry a cf-ray with an origin-generated status (401
# or 404) -- never 403, 5xx, or a Cloudflare 52x. Spec:
# docs/superpowers/specs/2026-09-14-origin-lockdown-design.md §6-7.
set -uo pipefail

ORIGIN_IP="${ORIGIN_IP:-45.33.28.21}"
ua="verify-origin-lockdown/1.0"
failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1 -- $2"; failures=$((failures + 1)); }

direct_refused() {   # direct_refused <name> <curl args...>
  local name="$1"; shift
  local code rc
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -k -A "$ua" "$@"); rc=$?
  case "$rc:$code" in
    7:*|28:*|35:*|52:*|56:*|92:*|0:400) pass "$name (curl exit $rc, http $code)" ;;
    *) fail "$name" "curl exit $rc, http $code -- the origin answered directly" ;;
  esac
}

through_cloudflare() {   # through_cloudflare <name> <url> <accepted status regex>
  local name="$1" url="$2" want="$3"
  local headers code ray
  headers=$(curl -s -D - -o /dev/null --max-time 20 -A "$ua" "$url")
  code=$(printf '%s\n' "$headers" | head -1 | awk '{print $2}')
  ray=$(printf '%s\n' "$headers" | grep -i '^cf-ray:' | tr -d '\r')
  if [[ "$code" =~ $want ]] && [ -n "$ray" ]; then pass "$name (http $code, $ray)"
  else fail "$name" "http '${code:-none}', cf-ray '${ray:-none}'; expected status matching $want with a cf-ray"; fi
}

echo "== direct to $ORIGIN_IP (must all be refused)"
direct_refused "HTTPS with correct SNI"            --resolve "thegreatestmusic.org:443:$ORIGIN_IP" "https://thegreatestmusic.org/"
direct_refused "HTTPS with no SNI"                 "https://$ORIGIN_IP/"
direct_refused "HTTPS with unknown SNI"            --resolve "evil.test:443:$ORIGIN_IP" "https://evil.test/"
direct_refused "HTTP with forged X-Forwarded-Proto" -H "Host: thegreatestmusic.org" -H "X-Forwarded-Proto: https" "http://$ORIGIN_IP/"
direct_refused "HTTP with unknown Host"            -H "Host: evil.test" "http://$ORIGIN_IP/"
direct_refused "HTTP for new.thegreatestbooks.org" -H "Host: new.thegreatestbooks.org" "http://$ORIGIN_IP/"

echo "== through Cloudflare (origin must answer)"
through_cloudflare "books API"      "https://new.thegreatestbooks.org/api/v1/books" '^401$'
through_cloudflare "music API path" "https://thegreatestmusic.org/api/v1/books"     '^(401|404)$'
through_cloudflare "games API path" "https://thegreatest.games/api/v1/books"        '^(401|404)$'

echo
if [ "$failures" -eq 0 ]; then echo "origin lockdown verified"; else echo "$failures probe(s) failed"; exit 1; fi
