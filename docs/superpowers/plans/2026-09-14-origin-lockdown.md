# Origin Lockdown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the production origin (`45.33.28.21`) serve a page only to Cloudflare, only for our hostnames, and only when Cloudflare presents its origin-pull certificate — with `real_ip` so nginx and Rails see the visitor's IP.

**Architecture:** Everything is inside the nginx image and `docker-compose.prod.yml`: a `geo` map on `$realip_remote_addr` (generated at image build from Cloudflare's published ranges) returns 444 to non-Cloudflare connections; `default_server` blocks refuse unknown `Host`/SNI; the port-80 proxy branch is deleted; Authenticated Origin Pulls verifies Cloudflare's client certificate. The Cloudflare side is one zone setting (`tls_client_auth`) managed by `cfrules` in the private `the-greatest-cloudflare` repo. Nothing hosting-provider-specific, no new runtime component.

**Tech Stack:** nginx 1.29 (`nginx:latest`, Debian), Docker, bash + `curl` + `jq` (image build and tests), OpenSSL (tests), Ruby (`cfrules`, standard library only).

**Spec:** `docs/superpowers/specs/2026-09-14-origin-lockdown-design.md` — read it first; every task below cites its sections.

## Global Constraints

- **Nothing hosting-provider-specific** (spec §1): no terraform resources, no cloud-init changes, no host firewall work. Everything moves with `docker compose up`.
- **No Rails changes** (spec §1). No `web-app/` files are touched. Nothing to run under `bin/rails test` or `standardrb`.
- **Cloudflare-only enforcement uses `geo $realip_remote_addr`, never `allow`/`deny`** (spec decision 1).
- **Non-Cloudflare and unknown-host requests get `return 444`; unknown SNI gets `ssl_reject_handshake on`** (decisions 2–3).
- **Authenticated Origin Pulls uses Cloudflare's global CA**, committed at `deployment/nginx/certs/cloudflare-origin-pull-ca.pem`, SHA-256 fingerprint `9A:1A:C2:B4:BE:15:F9:F2:7E:EE:20:A7:34:CB:A4:E9:89:8F:61:00:1B:3B:D7:C8:4B:69:B5:6A:3E:25:A2:B9`, expiry `2029-11-01` (decision 5). Increments 1–2 ship `ssl_verify_client optional`; only increment 3 flips it to `on` (decision 6).
- **The generator fails the build on any doubt** — `success != true`, fewer than 10 IPv4 or 3 IPv6 entries, any non-CIDR entry — and writes nothing on failure (decision 7).
- **Loopback (`127.0.0.1/32`, `::1/128`) stays in the geo map** so the container healthcheck keeps working (decision 2).
- **Work on branch `origin-lockdown`** in `/home/shane/dev/the-greatest` (the spec is already committed there). Never commit to `main`. Do not push or open a PR without Shane asking. End every commit message with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- **Merging to `main` deploys to production.** Increment 1 is one PR; increment 3 is a separate one-line PR after Shane has confirmed `verify=SUCCESS` in production logs for a day.
- **Do not mention `thegreatestmovies.org` anywhere new** except where the existing template forces it (the local harness must issue a dummy cert for every `server_name` in the template or nginx will not start).
- Host tooling verified 2026-09-14: `docker` 29.7.2, `jq` 1.7, `openssl`, `curl`. `shellcheck` is **not** installed; use `bash -n` for syntax checks.

---

### Task 1: Cloudflare snippet generator

**Files:**
- Create: `deployment/nginx/bin/generate-cloudflare-snippets.sh`
- Create: `deployment/nginx/test/generate-cloudflare-snippets_test.sh`
- Create: `deployment/nginx/test/fixtures/cloudflare-ips.json`

**Interfaces:**
- Produces: `generate-cloudflare-snippets.sh <output-dir> [<local-ips-json>]` — writes `<output-dir>/cloudflare-real-ip.conf` and `<output-dir>/cloudflare-geo.conf`; exit 0 on success, non-zero with a `generate-cloudflare-snippets: <reason>` line on stderr and **no files written** on any failure. The geo snippet defines `$from_cloudflare` (`1` for Cloudflare ranges and loopback, `0` otherwise) keyed on `$realip_remote_addr`. Task 2's Dockerfile and Task 3's harness call it.

- [ ] **Step 1: Save the real Cloudflare response as a fixture**

```bash
mkdir -p deployment/nginx/test/fixtures
curl -fsS https://api.cloudflare.com/client/v4/ips | jq . > deployment/nginx/test/fixtures/cloudflare-ips.json
jq '.result.ipv4_cidrs | length, (.result.ipv6_cidrs | length), .result.etag' deployment/nginx/test/fixtures/cloudflare-ips.json
```

Expected: `15`, `7`, `"38f79d050aa027e3be3865e495dcc9bc"`. If the etag differs, Cloudflare changed the list since the spec was written — that is fine; adjust the etag and count assertions in Step 2 to what you saw.

- [ ] **Step 2: Write the failing test**

Create `deployment/nginx/test/generate-cloudflare-snippets_test.sh`:

```bash
#!/usr/bin/env bash
# Unit test for deployment/nginx/bin/generate-cloudflare-snippets.sh. Needs jq.
# Run from anywhere: deployment/nginx/test/generate-cloudflare-snippets_test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
gen="$here/../bin/generate-cloudflare-snippets.sh"
fixture="$here/fixtures/cloudflare-ips.json"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1 -- $2"; failures=$((failures + 1)); }

# --- a valid response produces both snippets -----------------------------------------
out="$work/ok"
if "$gen" "$out" "$fixture" >/dev/null; then
  pass "valid response exits 0"
else
  fail "valid response exits 0" "non-zero exit"
fi

realip="$out/cloudflare-real-ip.conf"
geo="$out/cloudflare-geo.conf"

if grep -q '^set_real_ip_from 173\.245\.48\.0/20;$' "$realip" \
   && grep -q '^set_real_ip_from 2400:cb00::/32;$' "$realip" \
   && grep -q '^real_ip_header CF-Connecting-IP;$' "$realip"; then
  pass "real-ip snippet has IPv4, IPv6 and the header directive"
else
  fail "real-ip snippet has IPv4, IPv6 and the header directive" "$(cat "$realip" 2>&1)"
fi

if [ "$(grep -c '^set_real_ip_from ' "$realip" 2>/dev/null)" = "22" ]; then
  pass "real-ip snippet lists all 22 ranges"
else
  fail "real-ip snippet lists all 22 ranges" "got $(grep -c '^set_real_ip_from ' "$realip" 2>/dev/null)"
fi

if grep -q '^geo \$realip_remote_addr \$from_cloudflare {$' "$geo" \
   && grep -qE '^\s+default\s+0;' "$geo" \
   && grep -qE '^\s+127\.0\.0\.1/32\s+1;' "$geo" \
   && grep -qE '^\s+::1/128\s+1;' "$geo" \
   && grep -qE '^\s+104\.16\.0\.0/13\s+1;$' "$geo" \
   && grep -qE '^\s+2606:4700::/32\s+1;$' "$geo" \
   && grep -q '^}$' "$geo"; then
  pass "geo snippet keys on \$realip_remote_addr and includes loopback"
else
  fail "geo snippet keys on \$realip_remote_addr and includes loopback" "$(cat "$geo" 2>&1)"
fi

if grep -q 'etag 38f79d050aa027e3be3865e495dcc9bc' "$geo" && grep -q 'etag 38f79d050aa027e3be3865e495dcc9bc' "$realip"; then
  pass "both snippets carry the etag in their header comment"
else
  fail "both snippets carry the etag in their header comment" "$(head -1 "$geo" 2>&1)"
fi

# --- failures exit non-zero and write nothing ----------------------------------------
bad() {   # bad <name> <json>
  local name="$1" json="$2" dir="$work/bad-$RANDOM"
  printf '%s' "$json" > "$work/bad.json"
  if "$gen" "$dir" "$work/bad.json" >/dev/null 2>&1; then
    fail "$name" "exited 0"
  elif [ -e "$dir/cloudflare-geo.conf" ] || [ -e "$dir/cloudflare-real-ip.conf" ]; then
    fail "$name" "wrote files despite failing"
  else
    pass "$name"
  fi
}

bad "success:false is rejected" \
  '{"success":false,"result":{"ipv4_cidrs":[],"ipv6_cidrs":[],"etag":"x"}}'
bad "too few IPv4 ranges is rejected" \
  '{"success":true,"result":{"ipv4_cidrs":["1.1.1.0/24"],"ipv6_cidrs":["2400:cb00::/32","2606:4700::/32","2803:f800::/32"],"etag":"x"}}'
bad "missing IPv6 list is rejected" "$(jq 'del(.result.ipv6_cidrs)' "$fixture")"
bad "non-CIDR IPv4 entry is rejected" "$(jq '.result.ipv4_cidrs[0] = "not a cidr"' "$fixture")"
bad "non-CIDR IPv6 entry is rejected" "$(jq '.result.ipv6_cidrs[0] = "2606:4700::/32; evil"' "$fixture")"
bad "empty body is rejected" ''

echo
if [ "$failures" -eq 0 ]; then echo "all generator tests passed"; else echo "$failures generator test(s) failed"; exit 1; fi
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `chmod +x deployment/nginx/test/generate-cloudflare-snippets_test.sh && deployment/nginx/test/generate-cloudflare-snippets_test.sh`
Expected: `FAIL  valid response exits 0 -- non-zero exit` (the script does not exist), several more FAILs, final line `... generator test(s) failed`, exit 1.

- [ ] **Step 4: Write the generator**

Create `deployment/nginx/bin/generate-cloudflare-snippets.sh`:

```bash
#!/usr/bin/env bash
# Generates the two nginx snippets that make the origin Cloudflare-aware:
#
#   cloudflare-real-ip.conf  set_real_ip_from for every Cloudflare range, plus
#                            real_ip_header CF-Connecting-IP -- so $remote_addr, the access
#                            log, the bot-blocker's per-IP limits and Rails' request.remote_ip
#                            all see the visitor, not the Cloudflare edge.
#   cloudflare-geo.conf      geo $realip_remote_addr $from_cloudflare -- 1 for a Cloudflare
#                            range or loopback, 0 otherwise. Keyed on $realip_remote_addr
#                            (the connection's real peer) because real_ip has already
#                            rewritten $remote_addr by the time an access check runs.
#
# Runs at nginx image build (deployment/nginx/Dockerfile). Every deploy rebuilds the image
# --no-cache, so the list refreshes itself. Any failure exits non-zero and writes nothing,
# which fails the build and the deploy loudly while the running image keeps serving.
#
# Usage: generate-cloudflare-snippets.sh <output-dir> [<local-ips-json>]
#   <local-ips-json> replaces the network fetch (tests).
set -euo pipefail

out_dir="${1:?usage: $0 <output-dir> [<local-ips-json>]}"
source_json="${2:-}"
url="https://api.cloudflare.com/client/v4/ips"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

fail() { echo "generate-cloudflare-snippets: $*" >&2; exit 1; }

if [ -n "$source_json" ]; then
  cp "$source_json" "$tmp"
else
  curl -fsS --retry 3 --retry-all-errors --max-time 20 "$url" -o "$tmp" \
    || fail "could not fetch $url"
fi

[ -s "$tmp" ] || fail "empty response"
jq -e . "$tmp" >/dev/null 2>&1 || fail "response is not JSON"
[ "$(jq -r '.success' "$tmp")" = "true" ] || fail "response .success is not true"

v4_count=$(jq '.result.ipv4_cidrs | length' "$tmp")
v6_count=$(jq '.result.ipv6_cidrs | length' "$tmp")
[ "$v4_count" -ge 10 ] || fail "only $v4_count IPv4 ranges (expected at least 10)"
[ "$v6_count" -ge 3 ] || fail "only $v6_count IPv6 ranges (expected at least 3)"

v4_re='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
v6_re='^[0-9A-Fa-f:]+/[0-9]{1,3}$'
while IFS= read -r cidr; do
  [[ "$cidr" =~ $v4_re ]] || fail "unexpected IPv4 entry: $cidr"
done < <(jq -r '.result.ipv4_cidrs[]' "$tmp")
while IFS= read -r cidr; do
  [[ "$cidr" =~ $v6_re ]] || fail "unexpected IPv6 entry: $cidr"
done < <(jq -r '.result.ipv6_cidrs[]' "$tmp")

etag=$(jq -r '.result.etag // "unknown"' "$tmp")
stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
header="# Generated $stamp by deployment/nginx/bin/generate-cloudflare-snippets.sh from $url (etag $etag). Do not edit."

mkdir -p "$out_dir"

{
  echo "$header"
  jq -r '.result.ipv4_cidrs[], .result.ipv6_cidrs[] | "set_real_ip_from \(.);"' "$tmp"
  echo "real_ip_header CF-Connecting-IP;"
} > "$out_dir/cloudflare-real-ip.conf"

{
  echo "$header"
  echo 'geo $realip_remote_addr $from_cloudflare {'
  echo "    default      0;"
  echo "    127.0.0.1/32 1;   # container healthcheck"
  echo "    ::1/128      1;"
  jq -r '.result.ipv4_cidrs[], .result.ipv6_cidrs[] | "    \(.) 1;"' "$tmp"
  echo "}"
} > "$out_dir/cloudflare-geo.conf"

echo "generate-cloudflare-snippets: $v4_count IPv4 + $v6_count IPv6 ranges (etag $etag) -> $out_dir"
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `chmod +x deployment/nginx/bin/generate-cloudflare-snippets.sh && bash -n deployment/nginx/bin/generate-cloudflare-snippets.sh && deployment/nginx/test/generate-cloudflare-snippets_test.sh`
Expected: every line `PASS`, final line `all generator tests passed`, exit 0.

- [ ] **Step 6: Try the real network path once**

Run: `deployment/nginx/bin/generate-cloudflare-snippets.sh /tmp/claude-1001/-home-shane-dev-the-greatest/ff3b516d-2975-4bd8-aff7-b064bcfc3806/scratchpad/snips && cat /tmp/claude-1001/-home-shane-dev-the-greatest/ff3b516d-2975-4bd8-aff7-b064bcfc3806/scratchpad/snips/cloudflare-geo.conf`
Expected: the summary line reports `15 IPv4 + 7 IPv6 ranges`, and the geo file shows the header, `default 0`, loopback, 22 ranges, `}`.

- [ ] **Step 7: Commit**

```bash
git add deployment/nginx/bin/generate-cloudflare-snippets.sh deployment/nginx/test/generate-cloudflare-snippets_test.sh deployment/nginx/test/fixtures/cloudflare-ips.json
git commit -m "feat(nginx): generate Cloudflare real_ip and geo snippets at image build

Fetches Cloudflare's published ranges with hard assertions so a bad
response fails the build instead of shipping a permissive list.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Image build — CA, snippet, generator, `nginx -t`

**Files:**
- Create: `deployment/nginx/certs/cloudflare-origin-pull-ca.pem`
- Create: `deployment/nginx/snippets/cloudflare-only.conf`
- Modify: `deployment/nginx/Dockerfile`

**Interfaces:**
- Consumes: `generate-cloudflare-snippets.sh` from Task 1.
- Produces: an image in which `/etc/nginx/snippets/cloudflare-real-ip.conf`, `/etc/nginx/snippets/cloudflare-geo.conf`, `/etc/nginx/snippets/cloudflare-only.conf` and `/etc/nginx/certs/cloudflare-origin-pull-ca.pem` exist. Task 3's `nginx.conf` includes the first two; its template includes the third; its `ssl-params.conf` references the certificate path.

- [ ] **Step 1: Commit Cloudflare's origin-pull CA with its provenance**

```bash
mkdir -p deployment/nginx/certs
scratch=/tmp/claude-1001/-home-shane-dev-the-greatest/ff3b516d-2975-4bd8-aff7-b064bcfc3806/scratchpad
curl -fsSL https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem -o "$scratch/aop_ca.pem"
openssl x509 -in "$scratch/aop_ca.pem" -noout -fingerprint -sha256 -dates
```

Expected: `sha256 Fingerprint=9A:1A:C2:B4:BE:15:F9:F2:7E:EE:20:A7:34:CB:A4:E9:89:8F:61:00:1B:3B:D7:C8:4B:69:B5:6A:3E:25:A2:B9`, `notAfter=Nov  1 17:00:00 2029 GMT`. **If the fingerprint differs, stop** — Cloudflare rotated the CA; update the spec's decision 5 and this plan's Global Constraints before continuing.

Then write the file with a header comment (PEM readers skip everything before `-----BEGIN`):

```bash
{
  cat <<'EOF'
# Cloudflare's origin-pull CA for (global) Authenticated Origin Pulls.
# Source:      https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem
# Subject:     CN=origin-pull.cloudflare.net, O=CloudFlare, Inc., OU=Origin Pull
# SHA-256:     9A:1A:C2:B4:BE:15:F9:F2:7E:EE:20:A7:34:CB:A4:E9:89:8F:61:00:1B:3B:D7:C8:4B:69:B5:6A:3E:25:A2:B9
# Expires:     2029-11-01 -- replace it before then (Cloudflare will publish a successor).
# Fetched:     2026-09-14
#
# nginx verifies Cloudflare's client certificate against this file (ssl_client_certificate in
# snippets/ssl-params.conf). This certificate is shared by every Cloudflare customer, so it
# proves "from Cloudflare's network", not "from our zones" -- see
# docs/superpowers/specs/2026-09-14-origin-lockdown-design.md §4 and §9.
EOF
  cat "$scratch/aop_ca.pem"
} > deployment/nginx/certs/cloudflare-origin-pull-ca.pem
openssl x509 -in deployment/nginx/certs/cloudflare-origin-pull-ca.pem -noout -fingerprint -sha256
```

Expected: the same fingerprint printed from the committed file — proving OpenSSL parses it with the header present.

- [ ] **Step 2: Create the enforcement snippet**

Create `deployment/nginx/snippets/cloudflare-only.conf`:

```nginx
# Refuse any connection that did not come from a Cloudflare range (or loopback, for the
# container healthcheck). $from_cloudflare is defined by snippets/cloudflare-geo.conf,
# generated at image build, and is keyed on $realip_remote_addr -- the real peer -- because
# real_ip has already rewritten $remote_addr to the visitor's address. 444 closes the
# connection with no response. Included by every named server block on ports 80 and 443.
if ($from_cloudflare = 0) { return 444; }
```

- [ ] **Step 3: Update the Dockerfile**

Replace `deployment/nginx/Dockerfile` with:

```dockerfile
FROM nginx:latest

RUN apt-get update && apt-get install -y --no-install-recommends wget curl jq ca-certificates

# Create directories with proper permissions for nginx user
RUN mkdir -p /etc/nginx/snippets /etc/nginx/templates /etc/nginx/sites-enabled /etc/nginx/certs && \
    chmod 755 /etc/nginx/sites-enabled && \
    chown -R nginx:nginx /etc/nginx/sites-enabled

# Install nginx-ultimate-bad-bot-blocker using automated installer
# Reference: https://github.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker
RUN wget https://raw.githubusercontent.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker/master/install-ngxblocker -O /usr/local/sbin/install-ngxblocker
RUN chmod +x /usr/local/sbin/install-ngxblocker
RUN /usr/local/sbin/install-ngxblocker -x
RUN /usr/local/sbin/setup-ngxblocker -x -e conf

# Origin lockdown (docs/superpowers/specs/2026-09-14-origin-lockdown-design.md):
# Cloudflare's ranges become real_ip + geo snippets at build time, so every deploy
# (which rebuilds this image --no-cache) refreshes them. A bad fetch fails the build.
COPY bin/generate-cloudflare-snippets.sh /usr/local/sbin/generate-cloudflare-snippets.sh
COPY certs/cloudflare-origin-pull-ca.pem /etc/nginx/certs/cloudflare-origin-pull-ca.pem
COPY snippets/cloudflare-only.conf /etc/nginx/snippets/cloudflare-only.conf
RUN chmod +x /usr/local/sbin/generate-cloudflare-snippets.sh && \
    /usr/local/sbin/generate-cloudflare-snippets.sh /etc/nginx/snippets

COPY nginx.conf /etc/nginx/nginx.conf
COPY snippets/ssl-params.conf /etc/nginx/snippets/ssl-params.conf
COPY snippets/proxy-params.conf /etc/nginx/snippets/proxy-params.conf

# Validate nginx.conf and the generated snippets at build time. The site template is
# rendered at container start and is covered by deployment/nginx/test/local-lockdown-test.sh.
RUN nginx -t

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]
```

- [ ] **Step 4: Build and inspect**

Run:

```bash
docker build -t the-greatest-nginx:task2 deployment/nginx
docker run --rm the-greatest-nginx:task2 sh -c 'head -3 /etc/nginx/snippets/cloudflare-geo.conf; grep -c "^set_real_ip_from " /etc/nginx/snippets/cloudflare-real-ip.conf; cat /etc/nginx/snippets/cloudflare-only.conf | tail -1; openssl x509 -in /etc/nginx/certs/cloudflare-origin-pull-ca.pem -noout -fingerprint -sha256'
```

Expected: build ends with the `nginx -t` step printing `syntax is ok` / `test is successful`; the run prints the geo header + `geo $realip_remote_addr $from_cloudflare {` + `default 0;`, the number `22`, the `if (...) { return 444; }` line, and the fingerprint `9A:1A:C2:...:A2:B9`.

If `nginx -t` fails at build, read its message: a failure inside `/etc/nginx/conf.d/*.conf` or `bots.d` is the bot-blocker's install state and must be understood, not worked around by removing `RUN nginx -t`. (It is expected to pass: the installer has already run by that layer.)

- [ ] **Step 5: Commit**

```bash
git add deployment/nginx/certs/cloudflare-origin-pull-ca.pem deployment/nginx/snippets/cloudflare-only.conf deployment/nginx/Dockerfile
git commit -m "feat(nginx): build Cloudflare snippets, ship the origin-pull CA, validate at build

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: nginx enforcement — local harness first, then the config

**Files:**
- Create: `deployment/nginx/test/local-lockdown-test.sh`
- Create: `deployment/nginx/test/fixtures/cloudflare-ips-plus-docker.json`
- Modify: `deployment/nginx/nginx.conf`
- Modify: `deployment/nginx/snippets/ssl-params.conf`
- Modify: `deployment/nginx/the-greatest.conf.template`
- Modify: `docker-compose.prod.yml` (nginx `volumes:`)

**Interfaces:**
- Consumes: the image from Task 2 (built by the harness), `generate-cloudflare-snippets.sh` from Task 1.
- Produces: the enforcement described in spec §5.1. `$from_cloudflare` (geo), `$realip_remote_addr` and `$ssl_client_verify` appear in the access log as `cf=… verify=…`. The harness is the regression test for every later nginx change; increment 3 (Task 7) re-runs it and it adapts to `ssl_verify_client on` automatically.

- [ ] **Step 1: Create the "this host is Cloudflare" fixture**

The harness runs nginx twice. In run B it mounts snippets generated from a fixture that adds the harness's own Docker network (`10.99.0.0/24`, created with an explicit subnet so the gateway is always `10.99.0.1`), so connections from this machine count as Cloudflare:

```bash
jq '.result.ipv4_cidrs += ["10.99.0.0/24"]' deployment/nginx/test/fixtures/cloudflare-ips.json \
  > deployment/nginx/test/fixtures/cloudflare-ips-plus-docker.json
jq '.result.ipv4_cidrs | length' deployment/nginx/test/fixtures/cloudflare-ips-plus-docker.json
```

Expected: `16`.

- [ ] **Step 2: Write the harness (the failing test)**

Create `deployment/nginx/test/local-lockdown-test.sh`:

```bash
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
for h in $(grep -oE 'live/[A-Za-z0-9.-]+/fullchain' "$nginx_dir/the-greatest.conf.template" | cut -d/ -f2 | sort -u); do
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
  # Wait until the port answers with anything but "connection refused" (curl exit 7).
  for _ in $(seq 1 40); do
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$http_port/" >/dev/null 2>&1
    [ $? -ne 7 ] && return 0
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
# 52/56 while ssl_verify_client is optional (geo 444); http 400 once it is on (no client cert).
expect_exit "A1 HTTPS with correct SNI is refused"        "52 56 http:400" -k --resolve "$music:$https_port:127.0.0.1" "https://$music:$https_port/"
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
```

- [ ] **Step 3: Run the harness to verify it fails against the current config**

Run: `chmod +x deployment/nginx/test/local-lockdown-test.sh && deployment/nginx/test/local-lockdown-test.sh`
Expected: run A — A1, A2, A3 fail with `http 301` (the first `:443` block answers anything), A4 fails with a 502 or 200 (the port-80 proxy branch), A5/A6 fail with `http 301`; A7 passes. Run B — B1 fails (no `ssl_verify_client`, cert ignored, but the geo variable is undefined so nginx may not even start — either way not `200`), B2/B3/B4 fail. Final line `N lockdown probe(s) failed`, exit 1. (If nginx refuses to start because `$from_cloudflare` is unknown, the harness prints its log and exits 1 — that is also the expected red.)

- [ ] **Step 4: `nginx.conf` — includes and log format**

In `deployment/nginx/nginx.conf`, replace the `log_format main` block and add the two includes directly above `# Include bot blocker configuration`:

```nginx
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for" '
                    'cf=$realip_remote_addr verify=$ssl_client_verify';
```

```nginx
    # Origin lockdown (docs/superpowers/specs/2026-09-14-origin-lockdown-design.md).
    # Both snippets are generated at image build from Cloudflare's published ranges.
    # real_ip makes $remote_addr the visitor; geo defines $from_cloudflare from the real peer.
    include /etc/nginx/snippets/cloudflare-real-ip.conf;
    include /etc/nginx/snippets/cloudflare-geo.conf;

    # Include bot blocker configuration (installed during Docker build)
    include /etc/nginx/conf.d/*.conf;
```

- [ ] **Step 5: `ssl-params.conf` — Authenticated Origin Pulls**

Append to `deployment/nginx/snippets/ssl-params.conf`:

```nginx

# Authenticated Origin Pulls: verify Cloudflare's client certificate against its origin-pull
# CA (certs/cloudflare-origin-pull-ca.pem, expires 2029-11-01). `optional` accepts requests
# without a certificate and verifies one when presented, so the Cloudflare zone setting
# (tls_client_auth, managed by cfrules) can be turned on after this ships; it becomes `on`
# once production logs show verify=SUCCESS on every :443 request.
ssl_client_certificate /etc/nginx/certs/cloudflare-origin-pull-ca.pem;
ssl_verify_client optional;
```

- [ ] **Step 6: The template — default servers, port 80, includes**

Replace the block from `server {` / `listen 80;` through the end of that first server (the one with the `/.well-known/acme-challenge/` and `location /` proxy branch) with:

```nginx
# Origin lockdown (docs/superpowers/specs/2026-09-14-origin-lockdown-design.md §5.1).
# Unknown Host on 80 and unknown/missing SNI on 443 get nothing -- not even a certificate.
server {
    listen 80 default_server;
    return 444;
}

server {
    listen 443 ssl default_server;
    ssl_reject_handshake on;
}

server {
    listen 80;
    server_name thegreatestmusic.org www.thegreatestmusic.org
                thegreatest.games www.thegreatest.games
                thegreatestmovies.org www.thegreatestmovies.org
                new.thegreatestbooks.org;

    include /etc/nginx/snippets/cloudflare-only.conf;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Redirect only. Under Full/Strict SSL Cloudflare never sends an HTTPS visitor to
    # port 80, so the old "proxy to Rails when X-Forwarded-Proto is https" branch had no
    # legitimate caller -- it was the path a forged header used to reach Rails directly.
    location / {
        return 301 https://$host$request_uri;
    }
}
```

Then add the enforcement include after **every** `ssl-params.conf` include (one per `:443` server block):

```bash
sed -i 's|^\(\s*\)include /etc/nginx/snippets/ssl-params.conf;|&\n\1include /etc/nginx/snippets/cloudflare-only.conf;|' deployment/nginx/the-greatest.conf.template
grep -c 'cloudflare-only.conf' deployment/nginx/the-greatest.conf.template
grep -c 'proxy_pass http://rails_app' deployment/nginx/the-greatest.conf.template
```

Expected: `8` (one `:80` server + seven `:443` servers) and `4` (the port-80 proxy is gone; the four canonical `:443` blocks remain).

- [ ] **Step 7: compose mount**

In `docker-compose.prod.yml`, under the `nginx` service's `volumes:`, after the `proxy-params.conf` line add:

```yaml
      - ./deployment/nginx/snippets/cloudflare-only.conf:/etc/nginx/snippets/cloudflare-only.conf:ro
```

- [ ] **Step 8: Run the harness to verify it passes**

Run: `deployment/nginx/test/local-lockdown-test.sh`
Expected: every probe `PASS` (A1–A7, B1–B6, with B3 reading `gets 200`), final line `all lockdown probes passed`, exit 0.

If B2 fails but B1 passed, check `docker logs` output in the failure line: the log format change in Step 4 must be the one the container is using (it is bind-mounted from the repo, so a stale path would show the old format).

- [ ] **Step 9: Re-run the generator unit test and the compose file check**

Run: `deployment/nginx/test/generate-cloudflare-snippets_test.sh && docker compose -f docker-compose.prod.yml config --quiet && echo compose-ok`
Expected: `all generator tests passed`, then `compose-ok` (warnings about a missing `.env` are fine; an error is not).

- [ ] **Step 10: Commit**

```bash
git add deployment/nginx/nginx.conf deployment/nginx/snippets/ssl-params.conf deployment/nginx/the-greatest.conf.template docker-compose.prod.yml deployment/nginx/test/local-lockdown-test.sh deployment/nginx/test/fixtures/cloudflare-ips-plus-docker.json
git commit -m "feat(nginx): serve only Cloudflare, only our hostnames; AOP optional; real_ip

Non-Cloudflare peers get 444, unknown SNI a rejected handshake, unknown
Host 444; the port-80 proxy branch that a forged X-Forwarded-Proto could
reach Rails through is gone. Verified by the local lockdown harness.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Production verification script

**Files:**
- Create: `deployment/scripts/verify-origin-lockdown.sh`

**Interfaces:**
- Produces: `ORIGIN_IP=<ip> deployment/scripts/verify-origin-lockdown.sh` — exits 0 only when every direct-to-origin probe is refused and every through-Cloudflare probe shows a `cf-ray` with an origin-generated status. Run from a machine outside Cloudflare after each increment and after any future nginx change (spec §7).

- [ ] **Step 1: Write the script**

Create `deployment/scripts/verify-origin-lockdown.sh`:

```bash
#!/usr/bin/env bash
# Post-deploy check that the origin serves only Cloudflare. Run from a machine outside
# Cloudflare's network (a laptop is fine) after every nginx change:
#
#   deployment/scripts/verify-origin-lockdown.sh            # against 45.33.28.21
#   ORIGIN_IP=203.0.113.5 deployment/scripts/verify-origin-lockdown.sh   # a rebuilt server
#
# Direct probes must be refused: connection closed (curl 52/56), handshake rejected (35),
# refused (7), timed out (28), or nginx's 400 "No required SSL certificate was sent" once
# Authenticated Origin Pulls is enforced. Anything that looks like a page or a redirect is
# a failure. Through-Cloudflare probes use /api/ paths, which skip Super Bot Fight Mode,
# and must carry a cf-ray with an origin-generated status (401 or 404) -- never 403, 5xx,
# or a Cloudflare 52x. Spec: docs/superpowers/specs/2026-09-14-origin-lockdown-design.md §6-7.
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
    7:*|28:*|35:*|52:*|56:*|0:400) pass "$name (curl exit $rc, http $code)" ;;
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
```

- [ ] **Step 2: Run it against production now — it must be red**

Run: `chmod +x deployment/scripts/verify-origin-lockdown.sh && bash -n deployment/scripts/verify-origin-lockdown.sh && deployment/scripts/verify-origin-lockdown.sh`
Expected today (before increment 1 deploys): all six direct probes `FAIL ... the origin answered directly` (301s and a 200/502), all three through-Cloudflare probes `PASS`, final line `6 probe(s) failed`, exit 1. This is the documented open finding; the script goes green only after Shane deploys increment 1. Paste the output into the task report.

- [ ] **Step 3: Commit**

```bash
git add deployment/scripts/verify-origin-lockdown.sh
git commit -m "feat(deploy): verify-origin-lockdown.sh — post-deploy probes for the origin lockdown

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Documentation

**Files:**
- Modify: `deployment/README.md` (the `## Security` section)
- Modify: `deployment/TROUBLESHOOTING.md` (table of contents; `### Cloudflare Errors`; new `### Origin Lockdown` under Nginx Issues)
- Modify: `deployment/SERVER-UPGRADE-GUIDE.md` (`### 7. Verify`)
- Modify: `deployment/scripts/README.md` (new section)
- Modify: `docs/guides/stripe-account-setup.md` (the `real_ip` follow-up bullet, around line 601)

- [ ] **Step 1: `deployment/README.md` — replace the Security section**

Replace the existing `## Security` bullet list with:

```markdown
## Security

### Origin lockdown

The origin serves a page only when all three of these hold (design:
`docs/superpowers/specs/2026-09-14-origin-lockdown-design.md`):

1. **The connection comes from a Cloudflare IP range.** `deployment/nginx/bin/generate-cloudflare-snippets.sh`
   runs at image build and turns Cloudflare's published list into a `geo` map on
   `$realip_remote_addr`; every named server block returns 444 (connection closed, no
   response) when it says no. Every deploy rebuilds the image, so the list refreshes itself;
   a bad fetch fails the build instead of shipping a permissive list.
2. **The request names one of our hostnames.** A `default_server` on port 80 returns 444 for
   any other `Host`; a `default_server` on 443 uses `ssl_reject_handshake`, so an unknown or
   missing SNI never even sees a certificate. Port 80 only redirects — it no longer proxies
   to Rails on `X-Forwarded-Proto: https`.
3. **Cloudflare presented its origin-pull client certificate** (Authenticated Origin Pulls,
   `ssl_client_certificate` + `ssl_verify_client` in `snippets/ssl-params.conf`, CA in
   `deployment/nginx/certs/`, expires 2029-11-01). The matching Cloudflare setting is
   `tls_client_auth: on`, managed by `cfrules` in the private `the-greatest-cloudflare` repo.

The same Cloudflare list feeds `real_ip_header CF-Connecting-IP`, so nginx's `$remote_addr`,
the access log, the bot-blocker's per-IP limits, and Rails' `request.remote_ip` are the
visitor's address, not the Cloudflare edge's. The access log carries `cf=<peer> verify=<AOP result>`.

**Accepted residual:** Cloudflare's shared origin-pull certificate proves "from Cloudflare's
network", not "from our zones". An attacker with a Cloudflare *Enterprise* account could use
Host-header override through their own zone. Spec §9 lists the two ways to close that later.

**Verify after any nginx change:** `deployment/scripts/verify-origin-lockdown.sh` from a
machine outside Cloudflare. Locally, `deployment/nginx/test/local-lockdown-test.sh` exercises
the whole matrix against a throwaway container.

### Everything else

- All secrets managed via environment variables (SOPS/age)
- SSL certificates with strong ciphers (TLS 1.2+), HSTS enabled
- Bad bot blocking active
- UFW firewall (22, 80, 443) and fail2ban for SSH — note that Docker-published ports do not
  obey UFW, which is why the origin lockdown lives in nginx rather than the host firewall
- Non-root user for Rails processes
```

- [ ] **Step 2: `deployment/TROUBLESHOOTING.md` — entries**

Add `- [Origin Lockdown](#origin-lockdown)` to the Nginx Issues line of the table of contents (match the existing style of that list). Then, after the `### Nginx Configuration Errors` section and before `## Performance Issues`, add:

```markdown
### Origin Lockdown

The origin answers only Cloudflare (see README → Security → Origin lockdown). Three ways it
shows up when something is off:

**Every request returns 495 or 400 mentioning a client certificate.**
Cloudflare's `tls_client_auth` zone setting and nginx's `ssl_verify_client` disagree.
- 400 "No required SSL certificate was sent": nginx is `on` but Cloudflare is not presenting
  a certificate. Fastest fix is on the Cloudflare side: `bin/cfrules apply <zone>` in
  `the-greatest-cloudflare` with `tls_client_auth: on`, or set nginx back to `optional`.
- 495 "SSL certificate error": Cloudflare presents a certificate nginx cannot verify. Check
  `deployment/nginx/certs/cloudflare-origin-pull-ca.pem` against Cloudflare's published CA
  (fingerprint in the file header). Rolling Cloudflare back to `tls_client_auth: off` is one
  settings PATCH and stops the errors immediately.

**Site down or 52x from Cloudflare right after Cloudflare announced new IP ranges.**
The geo/real_ip lists are generated at image build. Rebuild nginx:
```bash
docker compose -f docker-compose.prod.yml build --no-cache nginx
docker compose -f docker-compose.prod.yml up -d nginx
```

**nginx container is `unhealthy` after a config change.**
The healthcheck curls `localhost` from inside the container, which is allowed only because
`127.0.0.1/32` and `::1/128` are in the generated geo map. Check
`docker compose -f docker-compose.prod.yml exec nginx cat /etc/nginx/snippets/cloudflare-geo.conf`.

**Confirming the lockdown works:** `deployment/scripts/verify-origin-lockdown.sh` from a
machine outside Cloudflare. A direct `curl` to the IP is *supposed* to fail.
```

In `### Cloudflare Errors`, replace item 3 (`Cloudflare IP not whitelisted …`) with:

```markdown
3. **Cloudflare range missing from the origin's allow list**
   Rebuild nginx (see Origin Lockdown above); the list is generated at image build.
```

- [ ] **Step 3: `deployment/SERVER-UPGRADE-GUIDE.md`**

In `### 7. Verify`, after the `curl -I https://thegreatestmusic.org` line's code block, add:

```markdown
The origin lockdown (README → Security) ships inside the nginx image — there is nothing to
configure per server. Confirm it from your machine:

```bash
ORIGIN_IP=<NEW_IP> deployment/scripts/verify-origin-lockdown.sh
```
```

- [ ] **Step 4: `deployment/scripts/README.md`**

Retitle the file `# Deployment Scripts` and add, before `## Automatic Renewal`:

```markdown
### verify-origin-lockdown.sh

Confirms the origin serves only Cloudflare (README → Security → Origin lockdown). Run from a
machine **outside** Cloudflare's network, after every nginx change or server rebuild.

**Usage:**
```bash
deployment/scripts/verify-origin-lockdown.sh                  # production IP
ORIGIN_IP=<ip> deployment/scripts/verify-origin-lockdown.sh   # a rebuilt server
```

**What it checks:** six direct-to-IP probes that must be refused (correct SNI, no SNI,
unknown SNI, forged `X-Forwarded-Proto` on port 80, unknown `Host`, our `Host` on port 80)
and three through-Cloudflare `/api/` probes that must answer with a `cf-ray`. Exit 0 only when
all nine pass. A direct probe that gets a page or a redirect is the failure it exists to catch.
```

- [ ] **Step 5: `docs/guides/stripe-account-setup.md`**

Replace the bullet that begins `- **Configure nginx's `real_ip` module with Cloudflare's published IP ranges.**` (the whole bullet, through `…which is why it's listed here rather than fixed in this branch.`) with:

```markdown
- **Configure nginx's `real_ip` module with Cloudflare's published IP ranges.** Done —
  `deployment/nginx/bin/generate-cloudflare-snippets.sh` generates `set_real_ip_from` for every
  Cloudflare range plus `real_ip_header CF-Connecting-IP` at image build, and the origin now
  refuses connections that are not from Cloudflare at all, so a forged `CF-Connecting-IP` cannot
  reach Rails. Design: `docs/superpowers/specs/2026-09-14-origin-lockdown-design.md`.
```

- [ ] **Step 6: Check the rendered docs**

Run: `grep -n 'Origin Lockdown\|Origin lockdown\|verify-origin-lockdown' deployment/README.md deployment/TROUBLESHOOTING.md deployment/SERVER-UPGRADE-GUIDE.md deployment/scripts/README.md docs/guides/stripe-account-setup.md | wc -l`
Expected: at least 8 matching lines across the five files.

- [ ] **Step 7: Commit**

```bash
git add deployment/README.md deployment/TROUBLESHOOTING.md deployment/SERVER-UPGRADE-GUIDE.md deployment/scripts/README.md docs/guides/stripe-account-setup.md
git commit -m "docs(deploy): describe the origin lockdown, its troubleshooting and verification

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Checkpoint A — increment 1 goes to production (Shane)

Not an agent task. Increment 1 is complete when Tasks 1–5 are committed on `origin-lockdown`. Shane opens the PR, merges (merging deploys), waits for the deploy workflow, then from his machine:

```bash
deployment/scripts/verify-origin-lockdown.sh
ssh deploy@45.33.28.21 'cd /home/deploy/apps/the-greatest && docker compose -f docker-compose.prod.yml ps nginx && docker compose -f docker-compose.prod.yml logs --since 5m nginx | grep -E "^[0-9.]+ " | tail -5'
```

Expected: `origin lockdown verified`; nginx `healthy`; log lines start with visitor IPs and end `cf=<Cloudflare edge> verify=NONE` (or `verify=-` for port 80). If the verify script is red, revert the PR (the deploy workflow rebuilds nginx) — spec §6 has the on-box emergency rollback.

---

### Task 6: Cloudflare — `tls_client_auth` in `cfrules` (increment 2, private repo)

Work in `/home/shane/dev/the-greatest-cloudflare` on a new branch `origin-lockdown-aop` off `main`. That repo's rules: Ruby standard library only, tests must pass on both rubies (`rake test` and `/home/shane/.local/share/mise/installs/ruby/4.0.6/bin/ruby -Ilib -e 'Dir["test/*_test.rb"].each { |f| require File.expand_path(f) }'`), never `apply` from an agent — Shane runs `bin/cfrules apply`.

**Files:**
- Modify: `lib/cf/zone.rb` (`live_settings` ~line 120, `apply_settings` ~line 365)
- Modify: `lib/cf/zone_file.rb` (`settings_errors` ~line 332)
- Modify: `test/zone_test.rb`, `test/zone_file_test.rb`
- Modify: `zones/thegreatestmusic.org.yml`, `zones/thegreatest.games.yml`, `zones/thegreatestbooks.org.yml`
- Modify: `AGENTS.md` (the Gotchas bullet mentioning `45.33.28.21`)

**Interfaces:**
- Consumes: Cloudflare's `GET`/`PATCH /zones/:id/settings/tls_client_auth` (`{"value": "on"|"off"}`, same shape as `/settings/ssl`).
- Produces: `settings.tls_client_auth` as a managed key — pulled into `state/<zone>.live.yml`, diffed like `ssl`, PATCHed on apply, validated to be `"on"` or `"off"` by `ZoneFile#validate!`.

- [ ] **Step 1: Failing tests in `test/zone_test.rb`**

Add after `test_diff_settings_ignores_undeclared_live_keys`:

```ruby
  # Authenticated Origin Pulls. The nginx side (the-greatest,
  # docs/superpowers/specs/2026-09-14-origin-lockdown-design.md) verifies the client
  # certificate this setting makes Cloudflare present; the file has to see the live value
  # and be able to write it, exactly like ssl.
  def test_live_settings_include_tls_client_auth
    client = FakeClient.new(settings_responses(live_ssl: "strict", live_bot_management: {}).merge(
      "/zones/#{ZID}/settings/tls_client_auth" => {"result" => {"id" => "tls_client_auth", "value" => "off"}}
    ))
    z = CF::Zone.new("thegreatest.games", client: client, file: CF::ZoneFile.new("zone" => "thegreatest.games"))
    assert_equal "off", z.live_settings["tls_client_auth"]
  end

  def test_diff_reports_tls_client_auth_local_edit
    file = CF::ZoneFile.new("zone" => "thegreatest.games", "settings" => {"tls_client_auth" => "on"})
    client = FakeClient.new(settings_responses(live_ssl: "strict", live_bot_management: {}).merge(
      "/zones/#{ZID}/settings/tls_client_auth" => {"result" => {"id" => "tls_client_auth", "value" => "off"}}
    ))
    z = CF::Zone.new("thegreatest.games", client: client, file: file)
    state = CF::State.new(zone: "thegreatest.games", settings_digest: CF::State.digest("tls_client_auth" => "off"))
    CF::Ruleset::PHASES.each_value { |phase| state.record(phase, id: nil, version: nil) }
    z.instance_variable_set(:@state, state)

    report = z.diff_report["settings"]
    assert_equal :local_edit, report[:status]
    assert_equal({"tls_client_auth" => "off"}, report[:live])
  end

  def test_apply_patches_tls_client_auth_when_declared
    Dir.mktmpdir do |dir|
      CF::Config.reset!
      CF::Config.root = dir
      file = CF::ZoneFile.new("zone" => "thegreatest.games", "settings" => {"tls_client_auth" => "on"})
      client = FakeClient.new(responses(rules: []).merge(
        "/zones/#{ZID}/settings/tls_client_auth" => {"result" => {"id" => "tls_client_auth", "value" => "off"}}
      ))
      z = CF::Zone.new("thegreatest.games", client: client, file: file)
      z.apply!(force: true)

      patch = client.calls.find { |c| c.first == :patch && c[1] == "/zones/#{ZID}/settings/tls_client_auth" }
      refute_nil patch, "expected a PATCH to /settings/tls_client_auth"
      assert_equal({"value" => "on"}, patch[2])
    ensure
      CF::Config.reset!
    end
  end
```

`responses(rules: [])` and `settings_responses` are existing helpers in that file; `FakeClient#get` returns `nil` for unstubbed paths when called with `allow_missing: true`, which is how `live_settings` reads every endpoint.

- [ ] **Step 2: Failing validation test in `test/zone_file_test.rb`**

Find the existing test that exercises `settings_errors` for `sbfm_verified_bots` (grep `sbfm_verified_bots must be` in `test/zone_file_test.rb`) and add beside it:

```ruby
  def test_validate_rejects_a_tls_client_auth_value_that_is_not_on_or_off
    file = CF::ZoneFile.new("zone" => "thegreatest.games", "settings" => {"tls_client_auth" => "yes"})
    err = assert_raises(CF::ValidationError) { file.validate! }
    assert_match(/tls_client_auth must be "on" or "off"/, err.message)
  end

  def test_validate_accepts_tls_client_auth_on
    file = CF::ZoneFile.new("zone" => "thegreatest.games", "settings" => {"tls_client_auth" => "on"})
    assert file.validate!
  end
```

`validate!` raises `CF::ValidationError` with every problem joined by `\n  - ` and returns `true` when clean.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd /home/shane/dev/the-greatest-cloudflare && rake test 2>&1 | tail -15`
Expected: 5 failures/errors — `live_settings` lacks the key, the diff report shows `:in_sync`/empty live, no PATCH found, no validation message, and the on-value test passing or failing depending on whether `validate!` already tolerates unknown keys (it should pass; only 4 red is also fine).

- [ ] **Step 4: Implement in `lib/cf/zone.rb`**

In `live_settings`, after the `ssl` read:

```ruby
      # Authenticated Origin Pulls. Read like ssl; the origin (the-greatest's nginx) is
      # what consumes it -- see the-greatest docs/superpowers/specs/2026-09-14-origin-lockdown-design.md.
      aop_body = client.get("/zones/#{zone_id}/settings/tls_client_auth", allow_missing: true)
      aop = aop_body && aop_body.dig("result", "value")
```

and in the `settings = {}` block add `settings["tls_client_auth"] = aop if aop` after the `ssl` line.

In `apply_settings`, after the `ssl` PATCH block:

```ruby
      if (aop = file.settings["tls_client_auth"])
        # Same endpoint family and verb as /settings/ssl (PATCH). Turning this on makes
        # Cloudflare present its origin-pull client certificate; nginx must already be
        # running ssl_verify_client optional or on, or the certificate is simply ignored.
        client.patch("/zones/#{zone_id}/settings/tls_client_auth", {"value" => aop})
        completed << "settings: tls_client_auth=#{aop}"
      end
```

- [ ] **Step 5: Implement validation in `lib/cf/zone_file.rb`**

Change `settings_errors` to collect both checks:

```ruby
    def settings_errors
      errors = []
      bot = settings["bot_management"]
      if bot.is_a?(Hash) && bot.key?("sbfm_verified_bots") && bot["sbfm_verified_bots"] != "allow"
        errors << "settings.bot_management.sbfm_verified_bots must be \"allow\" " \
                  "(got #{bot["sbfm_verified_bots"].inspect}) -- anything else challenges or blocks verified " \
                  "search crawlers, the incident that cost months of organic traffic"
      end
      # Authenticated Origin Pulls takes exactly "on" or "off"; Cloudflare rejects anything
      # else at PATCH time, and a typo here would surface only mid-apply.
      if settings.key?("tls_client_auth") && !%w[on off].include?(settings["tls_client_auth"])
        errors << "settings.tls_client_auth must be \"on\" or \"off\" (got #{settings["tls_client_auth"].inspect})"
      end
      errors
    end
```

- [ ] **Step 6: Run the tests on both rubies**

Run:

```bash
cd /home/shane/dev/the-greatest-cloudflare && rake test 2>&1 | tail -3
/home/shane/.local/share/mise/installs/ruby/4.0.6/bin/ruby -Ilib -e 'Dir["test/*_test.rb"].each { |f| require File.expand_path(f) }' 2>&1 | tail -3
```

Expected: `220 runs, ... 0 failures, 0 errors` (215 existing + 5 new) on both.

- [ ] **Step 7: Declare the setting in the three zone files**

In each of `zones/thegreatestmusic.org.yml`, `zones/thegreatest.games.yml`, `zones/thegreatestbooks.org.yml`, add directly under the `ssl:` line inside `settings:`:

```yaml
  # Authenticated Origin Pulls: Cloudflare presents its origin-pull client certificate to the
  # origin, and nginx at 45.33.28.21 verifies it (the-greatest, deployment/nginx/snippets/
  # ssl-params.conf; design in docs/superpowers/specs/2026-09-14-origin-lockdown-design.md).
  # Turn on only after that nginx change is deployed with ssl_verify_client optional; if
  # every request starts returning 495, set this back to off and re-apply -- one PATCH.
  tls_client_auth: on
```

On `thegreatestbooks.org.yml` append one more comment line before `tls_client_auth: on`:

```yaml
  # Zone-wide, so the legacy origin (apex, www) receives the certificate too; its nginx
  # does not verify client certificates, so nothing changes there.
```

- [ ] **Step 8: Validate the files and diff against live (read-only)**

Run: `cd /home/shane/dev/the-greatest-cloudflare && for z in thegreatestmusic.org thegreatest.games thegreatestbooks.org; do bin/cfrules diff $z; done 2>&1 | grep -iE 'settings|tls_client_auth|error' | head -20`
Expected: each zone's settings section reports the file as a local edit with `tls_client_auth` `off` live vs `on` in the file; no validation errors; ruleset phases in sync. Do **not** run `apply`.

- [ ] **Step 9: Update `AGENTS.md`**

Replace the sentence `The origin at \`45.33.28.21\` answers directly for now (\`curl --resolve\`), but that is an open finding, not a feature.` with:

```markdown
The origin at `45.33.28.21` refuses anything that is not Cloudflare (the-greatest,
  `docs/superpowers/specs/2026-09-14-origin-lockdown-design.md`), so `curl --resolve` against it
  no longer works either; `settings.tls_client_auth` here is the Cloudflare half of that.
```

- [ ] **Step 10: Commit**

```bash
cd /home/shane/dev/the-greatest-cloudflare
git add lib/cf/zone.rb lib/cf/zone_file.rb test/zone_test.rb test/zone_file_test.rb zones/ AGENTS.md
git commit -m "settings: manage tls_client_auth (Authenticated Origin Pulls) on all three zones

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Checkpoint B — increment 2 goes live (Shane)

Not an agent task. After Checkpoint A is green: merge the `the-greatest-cloudflare` PR, then per zone `bin/cfrules diff <zone>` and `bin/cfrules apply <zone>`. Within a minute:

```bash
ssh deploy@45.33.28.21 'cd /home/deploy/apps/the-greatest && docker compose -f docker-compose.prod.yml logs --since 2m nginx | grep -E "^[0-9.]+ " | grep -oE "verify=[A-Za-z:-]+" | sort | uniq -c'
```

Expected: only `verify=SUCCESS` and `verify=-` (port 80). Any `verify=NONE` on a 443 line means a zone is still off; any `verify=FAILED…` or 495s in the log means the CA does not match — set `tls_client_auth: off`, re-apply, and investigate. Leave it a day, re-run the same command, then proceed to Task 7.

---

### Task 7: Enforce — `ssl_verify_client on` (increment 3)

**Files:**
- Modify: `deployment/nginx/snippets/ssl-params.conf`

**Interfaces:**
- Consumes: Checkpoint B's evidence (a day of `verify=SUCCESS`). Do not start this task without it.

- [ ] **Step 1: Flip the directive**

In `deployment/nginx/snippets/ssl-params.conf`, change `ssl_verify_client optional;` to `ssl_verify_client on;` and replace the comment paragraph above the two AOP directives with:

```nginx
# Authenticated Origin Pulls: verify Cloudflare's client certificate against its origin-pull
# CA (certs/cloudflare-origin-pull-ca.pem, expires 2029-11-01). `on` rejects any :443 request
# that does not carry a certificate this CA signed with nginx's 400. The Cloudflare zone
# setting tls_client_auth (managed by cfrules) has been on since <YYYY-MM-DD>; if it is ever
# turned off, every request 400s -- set this back to `optional` or turn the zone setting on.
```

with the real date from Checkpoint B.

Also in `deployment/README.md`, under "Security → Origin Lockdown", delete the sentence that
begins `Rolling out in stages: nginx runs `ssl_verify_client optional`` (added during Task 5's
review) — once `on` ships, condition 3 is mandatory and the caveat would be wrong.

- [ ] **Step 2: Run the local harness — it must adapt**

Run: `deployment/nginx/test/local-lockdown-test.sh`
Expected: all probes pass, with A1 now reporting `curl exit 0, http 400` and B3 reading `B3 HTTPS without a client cert gets 400 (ssl_verify_client mode) (http 400)`.

- [ ] **Step 3: Commit**

```bash
git add deployment/nginx/snippets/ssl-params.conf deployment/README.md
git commit -m "feat(nginx): enforce Authenticated Origin Pulls (ssl_verify_client on)

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Checkpoint C — increment 3 goes to production (Shane)

Not an agent task. Merge, wait for the deploy, then `deployment/scripts/verify-origin-lockdown.sh` (the correct-SNI probe now reports `http 400` instead of exit 52 — both pass), the three sites in a browser, and the log command from Checkpoint B (still only `verify=SUCCESS` / `verify=-`). Then update the memory note `production-request-headers-untrusted` (spec §8).
