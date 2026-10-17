# OpenSearch Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hand-built production OpenSearch server with one built by `terraform apply` + cloud-init and
configured by a manual GitHub Actions workflow, reachable only from our app servers, with a login per site and
encrypted traffic.

**Architecture:** A separate Terraform root module creates one Ubuntu 26.04 Linode. Cloud-init hardens it and installs
a systemd unit that writes the port-9200 allowlist into Docker's `DOCKER-USER` chain *before* Docker starts. A
`workflow_dispatch` workflow decrypts `secrets/.env.opensearch` on the server and runs `deploy.sh`, which applies the
allowlist, generates the server's own certificates once, renders users and roles, starts OpenSearch from a pinned
compose file and loads the security config with `securityadmin.sh`. Both Rails apps keep reading `OPENSEARCH_URL`
and gain an `OPENSEARCH_SSL_VERIFY=false` switch.

**Tech Stack:** bash (shellcheck-clean, tested with plain pass/fail scripts), Terraform + `linode/linode` 3.0.0,
cloud-init, Docker Compose, OpenSearch 3.x security plugin, GitHub Actions, SOPS + age, Ruby / `opensearch-ruby` 3.4.

**Spec:** `docs/superpowers/specs/2026-10-13-opensearch-server-design.md` — read it before starting any task.

## Global Constraints

- Work on branch `worktree-opensearch-server`. Never commit to `main`. Do not push or open a PR without asking Shane.
- OS image: `linode/ubuntu26.04`. Plan default `g6-standard-4` (Linode 8 GB), region `us-central`.
- OpenSearch image pinned to an exact tag, `opensearchproject/opensearch:3.8.0` unless Task 5 Step 1 finds a newer 3.x.
  Never `:latest`.
- Port 9200 is published **IPv4-only**: `"0.0.0.0:${OPENSEARCH_PORT:-9200}:9200"`. Never a bare `"9200:9200"`.
- Users are exactly `admin`, `the_greatest_app`, `tgb_legacy`. Index patterns: `the_greatest_app` →
  `books_*_production`, `music_*_production`, `games_*_production`; `tgb_legacy` → `books`, `authors`.
- Passwords are `openssl rand -hex 32` (letters and digits only; they travel inside `OPENSEARCH_URL`).
- No server IPs, passwords or tokens in any committed plain-text file. They live in `secrets/.env.opensearch` (SOPS)
  or GitHub secrets. The repo is public.
- No Linode firewall, VLAN or volume resources. No Let's Encrypt for search. No snapshot repository, no S3 plugin.
- The deploy workflow is `workflow_dispatch` only. Merging to `main` must never restart search.
- Shell scripts: `#!/usr/bin/env bash`, `set -euo pipefail` (tests use `set -uo pipefail`), shellcheck-clean.
  Test stubs carry the depth guard from `deployment/home-server/test/helpers.sh` and wrap real tools with `command -p`.
- Minitest 6: use `assert_nil`, never `assert_equal nil`. Lint Ruby with `bundle exec standardrb`, never `bin/rubocop`.
- Subagents never run anything against production or create cloud resources. The "Operational" section at the end is
  run by Shane, with the controller session assisting.

## Review Focus

1. **Reboot race:** after a reboot, port 9200 must never answer an outsider, even for a second. Pinned by Task 2's
   unit-file assertions (`Before=docker.service`, `RequiredBy=docker.service`) and Operational step O3's reboot probe.
2. **A sloppy SOPS edit of the allowlist** (commas, spaces, CRLF, a typo): commas/spaces/CRLF must work, a typo must
   fail the deploy *without* touching the allowlist the server is already using. Pinned in Task 1 (CRLF) and Task 6
   (commas, bad entry leaves the old file).
3. **Docker's IPv6 listener:** a bare `9200:9200` makes docker-proxy listen on `[::]:9200`, a path `DOCKER-USER` never
   sees. Pinned by Task 5's compose assertion and the `--outside` IPv6 probe (Task 8).
4. **Redeploying an unchanged server** must not restart OpenSearch, regenerate certificates, or (via `Requires=`)
   restart Docker. Pinned in Task 2 (install never restarts the unit) and Task 6 (second run uses plain `up -d`,
   certificates unchanged).
5. **A login reaching the other site's indexes or the security API.** Pinned by Task 5's local end-to-end test and
   Task 8's `--inside` checks.

---

## File structure

```
deployment/opensearch/
  compose.yml                         Task 5   the OpenSearch service, pinned
  config/opensearch.yml               Task 4   node, TLS and security-plugin settings
  security/                           Task 4   users/roles/mappings; *.yml copied as-is, internal_users from .tmpl
  bin/render-firewall.sh              Task 1   allowlist -> iptables-restore input (v4 or v6)
  bin/apply-firewall.sh               Task 2   renders both families, applies with --noflush
  bin/install-firewall.sh             Task 2   installs the unit + scripts outside the checkout, applies now
  bin/generate-certs.sh               Task 3   CA, node and admin certificates, first run only
  bin/render-security.sh              Task 4   security/ + hashed passwords -> a complete security dir
  bin/hash-password.sh                Task 4   bcrypt via the pinned image's own hash tool
  bin/apply-security.sh               Task 5   wait for the node, run securityadmin.sh
  bin/deploy.sh                       Task 6   what the workflow runs on the server
  systemd/opensearch-firewall.service Task 2
  test/helpers.sh  test/run.sh        Task 1
  test/*_test.sh                      Tasks 1-4, 6, 8
  test/local-e2e-test.sh              Task 5   manual, needs Docker
deployment/terraform/opensearch/      Task 7   main.tf variables.tf cloud-init.yaml terraform.tfvars.example
deployment/scripts/verify-opensearch-lockdown.sh  Task 8
.github/workflows/deploy-opensearch.yml           Task 9
.github/workflows/ci.yml                          Task 1 (new job)
.sops.yaml, secrets/.env.opensearch               Task 9
web-app/app/lib/search/shared/client.rb           Task 10
docs/features/opensearch-server.md, deployment/ENV.md, deployment/README.md, .env.example   Task 11
the-greatest-books repo: admin/app/lib/search/{books,authors}_index.rb                        Task 12
```

Run every shell test with `deployment/opensearch/test/run.sh` from the worktree root. shellcheck is not installed on
Shane's machine; `run.sh` falls back to `uvx --from shellcheck-py shellcheck`, as the home-server runner does.

---

### Task 1: Allowlist renderer, test harness, CI job

**Files:**
- Create: `deployment/opensearch/bin/render-firewall.sh`
- Create: `deployment/opensearch/test/helpers.sh`, `deployment/opensearch/test/run.sh`,
  `deployment/opensearch/test/render-firewall_test.sh`
- Modify: `.github/workflows/ci.yml` (new job after `home-server`)

**Interfaces:**
- Produces: `render-firewall.sh --family v4|v6 (--allowlist FILE | --deny-all)` → iptables-restore input on stdout,
  exit 0; exit 2 with empty stdout on any bad input. `test/helpers.sh` gives `pass`, `fail`, `finish`, `new_sandbox`
  (sets `SANDBOX`, `CALLS`, `PATH`), `stub NAME BODY`, `called REGEX`, and `BIN` (absolute path to `bin/`).

- [ ] **Step 1: Write the test harness**

`deployment/opensearch/test/helpers.sh`:

```bash
# deployment/opensearch/test/helpers.sh
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2016
# SC2034: BIN is used by the files that source this. SC2016: stub bodies are single-quoted on
# purpose, so they expand when the stub runs. Same shape as deployment/home-server/test/helpers.sh.
OS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$OS_DIR/bin"
failures=0
ORIGINAL_PATH="$PATH"

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1 -- $2"; failures=$((failures + 1)); }
finish() {
  if [ "$failures" = 0 ]; then echo "all passed"; else echo "$failures failed"; exit 1; fi
}

new_sandbox() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX"/{bin,log}
  export SANDBOX CALLS="$SANDBOX/log/calls" PATH="$SANDBOX/bin:$ORIGINAL_PATH"
  : >"$CALLS"
}

# stub <name> <body>: a command on PATH that logs "<name> <args>" to $CALLS, then runs body.
# The depth guard is not optional: a stub that reached itself by name once forked until it took
# the whole machine down. Stubs that wrap a real tool must call it with `command -p`.
stub() {
  {
    printf '#!/usr/bin/env bash\n'
    printf '[ "${STUB_DEPTH:-0}" -lt 3 ] || { echo "stub %s re-entered itself" >&2; exit 99; }\n' "$1"
    printf 'export STUB_DEPTH=$(( ${STUB_DEPTH:-0} + 1 ))\n'
    printf 'echo "%s $*" >>"$CALLS"\n' "$1"
    printf '%s\n' "$2"
  } >"$SANDBOX/bin/$1"
  command -p chmod +x "$SANDBOX/bin/$1"
}
called() { grep -qE "$1" "$CALLS"; }
```

`deployment/opensearch/test/run.sh`:

```bash
#!/usr/bin/env bash
# deployment/opensearch/test/run.sh
# Every OpenSearch-server shell test, plus shellcheck. CI runs this (opensearch job).
# local-e2e-test.sh is not a *_test.sh on purpose: it needs Docker and runs by hand.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
os="$(cd "$here/.." && pwd)"
root="$(cd "$os/../.." && pwd)"
if command -v shellcheck >/dev/null; then sc=(shellcheck); else sc=(uvx --from shellcheck-py shellcheck); fi

status=0
files=()
for f in "$os"/bin/*.sh "$here"/*.sh "$root/deployment/scripts/verify-opensearch-lockdown.sh"; do
  if [ -f "$f" ]; then files+=("$f"); fi
done
"${sc[@]}" -x "${files[@]}" || status=1
for t in "$here"/*_test.sh; do
  echo "--- $(basename "$t")"
  "$t" || status=1
done
exit "$status"
```

```bash
chmod +x deployment/opensearch/test/run.sh
```

- [ ] **Step 2: Write the failing test**

`deployment/opensearch/test/render-firewall_test.sh`:

```bash
#!/usr/bin/env bash
# Unit test for deployment/opensearch/bin/render-firewall.sh. Needs python3.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
render="$BIN/render-firewall.sh"
list="$SANDBOX/allowlist"
drop='-A DOCKER-USER -p tcp -m conntrack --ctorigdstport 9200 --ctdir ORIGINAL -j DROP'
allow() { echo "-A DOCKER-USER -p tcp -m conntrack --ctorigdstport 9200 --ctdir ORIGINAL -s $1 -j RETURN"; }
has() { grep -qxF -- "$2" <<<"$1"; }
line_of() { grep -nxF -- "$2" <<<"$1" | head -1 | cut -d: -f1; }

# --- a valid list ------------------------------------------------------------------------
printf '# app servers\n203.0.113.10\n\n203.0.113.11  # worker\n2001:db8::10\n' >"$list"
v4="$("$render" --family v4 --allowlist "$list")"; rc=$?
if [ "$rc" = 0 ]; then pass "a valid allowlist renders"; else fail "a valid allowlist renders" "exit $rc"; fi
if has "$v4" "$(allow 203.0.113.10/32)" && has "$v4" "$(allow 203.0.113.11/32)"; then
  pass "v4: every IPv4 address is allowed"; else fail "v4: every IPv4 address is allowed" "$v4"; fi
if ! grep -q '2001:db8' <<<"$v4"; then pass "v4: no IPv6 address leaks in"; else fail "v4: no IPv6 address leaks in" "$v4"; fi
if has "$v4" "$drop" && [ "$(line_of "$v4" "$drop")" -gt "$(line_of "$v4" "$(allow 203.0.113.11/32)")" ]; then
  pass "v4: the drop rule comes after the allow rules"; else fail "v4: the drop rule comes after the allow rules" "$v4"; fi
if [ "$(head -1 <<<"$v4")" = '*filter' ] && has "$v4" ':DOCKER-USER - [0:0]' && [ "$(tail -1 <<<"$v4")" = COMMIT ]; then
  pass "v4: rewrites only the DOCKER-USER chain"; else fail "v4: rewrites only the DOCKER-USER chain" "$v4"; fi

v6="$("$render" --family v6 --allowlist "$list")"
if has "$v6" "$(allow 2001:db8::10/128)" && ! grep -q '203.0.113' <<<"$v6" && has "$v6" "$drop"; then
  pass "v6: only the IPv6 address is allowed"; else fail "v6: only the IPv6 address is allowed" "$v6"; fi

printf '203.0.113.10\r\n' >"$list"
crlf="$("$render" --family v4 --allowlist "$list")"
if has "$crlf" "$(allow 203.0.113.10/32)"; then pass "a CRLF line ending is tolerated"; else fail "a CRLF line ending is tolerated" "$crlf"; fi

deny="$("$render" --family v4 --deny-all)"
if has "$deny" "$drop" && ! grep -q -- ' -s ' <<<"$deny"; then pass "--deny-all allows nobody"; else fail "--deny-all allows nobody" "$deny"; fi

# --- refusals: exit 2 and print nothing, so nothing half-rendered is ever applied ----------
rejects() {   # rejects <name> <file contents for printf %b> <render args...>
  local name="$1" content="$2" out rc
  shift 2
  printf '%b' "$content" >"$list"
  out="$("$render" "$@" 2>/dev/null)"; rc=$?
  if [ "$rc" = 2 ] && [ -z "$out" ]; then pass "$name"; else fail "$name" "exit $rc, out: $out"; fi
}
rejects "an empty allowlist is refused" '' --family v4 --allowlist "$list"
rejects "a comments-only allowlist is refused" '# nobody\n' --family v4 --allowlist "$list"
rejects "0.0.0.0 is refused" '0.0.0.0\n' --family v4 --allowlist "$list"
rejects ":: is refused" '::\n' --family v6 --allowlist "$list"
rejects "a CIDR range is refused" '10.0.0.0/8\n' --family v4 --allowlist "$list"
rejects "a hostname is refused" 'search.example.com\n' --family v4 --allowlist "$list"
rejects "one bad line refuses the whole list" '203.0.113.10\nnope\n' --family v4 --allowlist "$list"
rejects "a missing --family is refused" '203.0.113.10\n' --allowlist "$list"
rejects "an unknown family is refused" '203.0.113.10\n' --family v5 --allowlist "$list"
rejects "a missing file is refused" '' --family v4 --allowlist "$SANDBOX/nope"
finish
```

```bash
chmod +x deployment/opensearch/test/render-firewall_test.sh
```

- [ ] **Step 3: Run it to verify it fails**

Run: `deployment/opensearch/test/render-firewall_test.sh`
Expected: every check FAILs (the renderer does not exist yet), ending with `N failed`.

- [ ] **Step 4: Write the renderer**

`deployment/opensearch/bin/render-firewall.sh`:

```bash
#!/usr/bin/env bash
# deployment/opensearch/bin/render-firewall.sh
# Prints iptables-restore input that rewrites the DOCKER-USER chain so only the allowlisted app
# servers can open connections to OpenSearch on port 9200. Docker-published ports bypass ufw:
# they are DNAT-ed in PREROUTING and filtered in FORWARD, so DOCKER-USER is the one place a rule
# reliably applies. Rules match the ORIGINAL destination port because DOCKER-USER sees packets
# after Docker's DNAT. Spec: docs/superpowers/specs/2026-10-13-opensearch-server-design.md §5.1.
#
#   render-firewall.sh --family v4|v6 --allowlist FILE   one address per line, # comments
#   render-firewall.sh --family v4|v6 --deny-all         nobody may connect
#
# Feed the output to `iptables-restore --noflush` (v4) or `ip6tables-restore --noflush` (v6).
# Declaring :DOCKER-USER flushes that chain alone, so the rewrite is atomic and Docker's own
# chains are untouched. Exits 2, printing nothing, on any bad input: a typo in the SOPS file must
# fail the deploy, never open the port or lock the apps out.
set -euo pipefail
PORT=9200

family="" allowlist="" deny_all=0
while [ $# -gt 0 ]; do
  case "$1" in
    --family) family="${2:-}"; shift 2 || shift ;;
    --allowlist) allowlist="${2:-}"; shift 2 || shift ;;
    --deny-all) deny_all=1; shift ;;
    *) echo "render-firewall: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$family" in
  v4) host_bits=32 ;;
  v6) host_bits=128 ;;
  *) echo "render-firewall: --family must be v4 or v6" >&2; exit 2 ;;
esac

addresses=""
if [ "$deny_all" = 0 ]; then
  [ -n "$allowlist" ] || { echo "render-firewall: need --allowlist FILE or --deny-all" >&2; exit 2; }
  [ -r "$allowlist" ] || { echo "render-firewall: cannot read $allowlist" >&2; exit 2; }
  # Python's ipaddress does the validation: hand-written IPv6 patterns are how bad entries slip
  # through. Single host addresses only -- accepting a CIDR is how 0.0.0.0/0 gets in.
  addresses="$(python3 -I - "$allowlist" "$family" <<'PY'
import ipaddress, sys
path, family = sys.argv[1], sys.argv[2]
found, wanted = 0, []
with open(path) as f:
    for n, raw in enumerate(f, 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        try:
            ip = ipaddress.ip_address(line)
        except ValueError:
            sys.exit(f"render-firewall: line {n}: {line!r} is not a single IP address")
        if ip.is_unspecified:
            sys.exit(f"render-firewall: line {n}: {line} would allow everyone")
        found += 1
        if (ip.version == 4) == (family == "v4"):
            wanted.append(str(ip))
if found == 0:
    sys.exit("render-firewall: the allowlist is empty")
print("\n".join(wanted))
PY
)" || exit 2
fi

echo "*filter"
echo ":DOCKER-USER - [0:0]"
echo "-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN"
while IFS= read -r ip; do
  [ -n "$ip" ] || continue
  echo "-A DOCKER-USER -p tcp -m conntrack --ctorigdstport $PORT --ctdir ORIGINAL -s $ip/$host_bits -j RETURN"
done <<<"$addresses"
echo "-A DOCKER-USER -p tcp -m conntrack --ctorigdstport $PORT --ctdir ORIGINAL -j DROP"
echo "-A DOCKER-USER -j RETURN"
echo "COMMIT"
```

```bash
chmod +x deployment/opensearch/bin/render-firewall.sh
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `deployment/opensearch/test/render-firewall_test.sh`
Expected: every line `PASS`, ending `all passed`.

- [ ] **Step 6: Add the CI job**

In `.github/workflows/ci.yml`, after the `home-server` job, add:

```yaml
  opensearch:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    # The workflow default is web-app/; these paths are from the repo root.
    defaults:
      run:
        working-directory: .
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      # The search server deploys these scripts from main, and the firewall ones run at boot.
      - name: OpenSearch shell tests and shellcheck
        run: deployment/opensearch/test/run.sh
```

- [ ] **Step 7: Run the whole runner**

Run: `deployment/opensearch/test/run.sh`
Expected: shellcheck prints nothing, the test ends `all passed`, exit 0.

- [ ] **Step 8: Commit**

```bash
git add deployment/opensearch/bin/render-firewall.sh deployment/opensearch/test .github/workflows/ci.yml
git commit -m "OpenSearch server: allowlist renderer for the DOCKER-USER chain, test harness, CI job"
```

---

### Task 2: Boot-time firewall unit

**Files:**
- Create: `deployment/opensearch/bin/apply-firewall.sh`, `deployment/opensearch/bin/install-firewall.sh`,
  `deployment/opensearch/systemd/opensearch-firewall.service`
- Test: `deployment/opensearch/test/apply-firewall_test.sh`, `deployment/opensearch/test/install-firewall_test.sh`

**Interfaces:**
- Consumes: `render-firewall.sh` (Task 1).
- Produces: `apply-firewall.sh` (env `ALLOWLIST`, default `/etc/opensearch/allowlist`); `install-firewall.sh` (env
  `ROOT`, default empty, prefixes every installed path; run as root). Installed layout:
  `/usr/local/lib/opensearch-firewall/{render,apply}-firewall.sh`, `/etc/systemd/system/opensearch-firewall.service`.

- [ ] **Step 1: Write the failing tests**

`deployment/opensearch/test/apply-firewall_test.sh`:

```bash
#!/usr/bin/env bash
# Unit test for deployment/opensearch/bin/apply-firewall.sh. iptables is stubbed.
# shellcheck disable=SC2016  # stub bodies and bcrypt strings are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
setup() {
  new_sandbox
  stub iptables-restore 'command -p cat >"$SANDBOX/log/v4.rules"'
  stub ip6tables-restore 'command -p cat >"$SANDBOX/log/v6.rules"'
}

setup
ALLOWLIST="$SANDBOX/missing" "$BIN/apply-firewall.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -q -- '-j DROP' "$SANDBOX/log/v4.rules" && grep -q -- '-j DROP' "$SANDBOX/log/v6.rules" \
  && ! grep -q -- ' -s ' "$SANDBOX/log/v4.rules" "$SANDBOX/log/v6.rules"; then
  pass "no allowlist file: both families drop everyone"; else fail "no allowlist file: both families drop everyone" "rc=$rc"; fi
if called '^iptables-restore --noflush$' && called '^ip6tables-restore --noflush$'; then
  pass "rules go in with --noflush, leaving Docker's chains alone"; else fail "rules go in with --noflush" "$(cat "$CALLS")"; fi

setup
: >"$SANDBOX/allowlist"
ALLOWLIST="$SANDBOX/allowlist" "$BIN/apply-firewall.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && ! grep -q -- ' -s ' "$SANDBOX/log/v4.rules"; then
  pass "an empty allowlist file drops everyone"; else fail "an empty allowlist file drops everyone" "rc=$rc"; fi

setup
printf '203.0.113.10\n' >"$SANDBOX/allowlist"
ALLOWLIST="$SANDBOX/allowlist" "$BIN/apply-firewall.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -q -- '-s 203.0.113.10/32 -j RETURN' "$SANDBOX/log/v4.rules"; then
  pass "an allowlist is applied"; else fail "an allowlist is applied" "rc=$rc"; fi

setup
printf 'nope\n' >"$SANDBOX/allowlist"
ALLOWLIST="$SANDBOX/allowlist" "$BIN/apply-firewall.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" != 0 ] && ! called 'restore'; then
  pass "an invalid allowlist applies nothing and fails"; else fail "an invalid allowlist applies nothing and fails" "rc=$rc $(cat "$CALLS")"; fi
finish
```

`deployment/opensearch/test/install-firewall_test.sh`:

```bash
#!/usr/bin/env bash
# Unit test for deployment/opensearch/bin/install-firewall.sh and the unit file it installs.
# shellcheck disable=SC2016  # stub bodies and bcrypt strings are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
stub systemctl ''
stub iptables-restore 'command -p cat >/dev/null'
stub ip6tables-restore 'command -p cat >/dev/null'
lib="$SANDBOX/root/usr/local/lib/opensearch-firewall"
unit="$SANDBOX/root/etc/systemd/system/opensearch-firewall.service"

ROOT="$SANDBOX/root" ALLOWLIST="$SANDBOX/missing" "$BIN/install-firewall.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then pass "install exits 0"; else fail "install exits 0" "rc=$rc"; fi
if [ -x "$lib/render-firewall.sh" ] && [ -x "$lib/apply-firewall.sh" ] && [ -f "$unit" ]; then
  pass "scripts and unit are installed outside the checkout"; else fail "scripts and unit installed" "$(ls -R "$SANDBOX/root")"; fi
if called '^systemctl daemon-reload$' && called '^systemctl enable opensearch-firewall.service$'; then
  pass "the unit is enabled for the next boot"; else fail "the unit is enabled" "$(cat "$CALLS")"; fi
# docker.service Requires= this unit, and restarting a required unit restarts Docker -- every
# deploy would bounce OpenSearch. Rules are re-applied by running the script directly instead.
if ! called '^systemctl (restart|stop|reload-or-restart|try-restart)'; then
  pass "install never restarts the unit (that would restart Docker)"; else fail "install restarted the unit" "$(cat "$CALLS")"; fi
if called '^iptables-restore --noflush$' && called '^ip6tables-restore --noflush$'; then
  pass "the rules are applied immediately"; else fail "the rules are applied immediately" "$(cat "$CALLS")"; fi

for line in 'Before=docker.service' 'RequiredBy=docker.service' 'Type=oneshot' 'RemainAfterExit=yes' \
  'ExecStart=/usr/local/lib/opensearch-firewall/apply-firewall.sh'; do
  if grep -qxF "$line" "$unit"; then pass "unit: $line"; else fail "unit: $line" "missing"; fi
done
if ! grep -q '^After=docker.service' "$unit"; then pass "unit: not ordered after Docker"; else fail "unit: ordered after Docker" "boot race"; fi
finish
```

```bash
chmod +x deployment/opensearch/test/apply-firewall_test.sh deployment/opensearch/test/install-firewall_test.sh
```

- [ ] **Step 2: Run them to verify they fail**

Run: `deployment/opensearch/test/apply-firewall_test.sh; deployment/opensearch/test/install-firewall_test.sh`
Expected: FAILs (scripts missing).

- [ ] **Step 3: Write the scripts and the unit**

`deployment/opensearch/bin/apply-firewall.sh`:

```bash
#!/usr/bin/env bash
# deployment/opensearch/bin/apply-firewall.sh
# Applies the OpenSearch allowlist to DOCKER-USER for IPv4 and IPv6. Run at boot by
# opensearch-firewall.service, before docker.service, and by install-firewall.sh on every deploy.
# A missing or empty allowlist means nobody may connect: port 9200 is never open by default.
# An invalid one fails before anything is applied, and since docker.service requires the unit,
# Docker then stays down rather than coming up unprotected. Spec §5.1.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ALLOWLIST="${ALLOWLIST:-/etc/opensearch/allowlist}"

# Render both families before applying either, so a failure never leaves them half-updated.
declare -A rules
for family in v4 v6; do
  if [ -s "$ALLOWLIST" ]; then
    rules[$family]="$("$here/render-firewall.sh" --family "$family" --allowlist "$ALLOWLIST")"
  else
    rules[$family]="$("$here/render-firewall.sh" --family "$family" --deny-all)"
  fi
done
printf '%s\n' "${rules[v4]}" | iptables-restore --noflush
printf '%s\n' "${rules[v6]}" | ip6tables-restore --noflush
```

`deployment/opensearch/bin/install-firewall.sh`:

```bash
#!/usr/bin/env bash
# deployment/opensearch/bin/install-firewall.sh   (as root)
# Installs opensearch-firewall.service and its scripts OUTSIDE the git checkout -- a `git pull`
# must not change what runs at boot until a deploy installs it -- enables the unit for the next
# boot, and applies the rules now. Cloud-init runs this before Docker is installed; deploy.sh runs
# it on every deploy. It never restarts the unit: docker.service Requires= it, and restarting a
# required unit restarts Docker, which would bounce OpenSearch on every deploy. ROOT prefixes
# every path (tests install into a sandbox).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ROOT="${ROOT:-}"
lib="$ROOT/usr/local/lib/opensearch-firewall"

install -d "$lib" "$ROOT/etc/systemd/system"
install -m 0755 "$here/render-firewall.sh" "$here/apply-firewall.sh" "$lib/"
install -m 0644 "$here/../systemd/opensearch-firewall.service" "$ROOT/etc/systemd/system/"
systemctl daemon-reload
systemctl enable opensearch-firewall.service
"$lib/apply-firewall.sh"
```

`deployment/opensearch/systemd/opensearch-firewall.service`:

```ini
# deployment/opensearch/systemd/opensearch-firewall.service
# Closes port 9200 to everyone but the allowlisted app servers BEFORE Docker starts. Ordering it
# after docker.service would be wrong: restart-unless-stopped containers come up with the daemon,
# so 9200 would be open for a few seconds on every boot. docker.service requires this unit, so if
# the rules cannot be applied Docker stays down instead of coming up unprotected. Docker keeps a
# DOCKER-USER chain that already exists. Spec §5.1; installed by bin/install-firewall.sh.
[Unit]
Description=OpenSearch port 9200 allowlist (DOCKER-USER), applied before Docker
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/opensearch-firewall/apply-firewall.sh

[Install]
WantedBy=multi-user.target
RequiredBy=docker.service
```

```bash
chmod +x deployment/opensearch/bin/apply-firewall.sh deployment/opensearch/bin/install-firewall.sh
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `deployment/opensearch/test/run.sh`
Expected: shellcheck clean; all three test files end `all passed`.

- [ ] **Step 5: Commit**

```bash
git add deployment/opensearch/bin/apply-firewall.sh deployment/opensearch/bin/install-firewall.sh \
  deployment/opensearch/systemd deployment/opensearch/test/apply-firewall_test.sh deployment/opensearch/test/install-firewall_test.sh
git commit -m "OpenSearch server: firewall unit applied before Docker starts"
```

---

### Task 3: Certificates

**Files:**
- Create: `deployment/opensearch/bin/generate-certs.sh`
- Test: `deployment/opensearch/test/generate-certs_test.sh`

**Interfaces:**
- Produces: `generate-certs.sh DIR` → DIR holds exactly `root-ca.pem root-ca-key.pem node.pem node-key.pem admin.pem
  admin-key.pem`. Subjects (RFC 2253): node `CN=search-node,OU=search,O=the-greatest`, admin
  `CN=admin,OU=search,O=the-greatest`. Keys are PKCS#8. Prints `generated ...` or `present ...`. A complete set is left
  alone; a partial set is regenerated whole.

- [ ] **Step 1: Write the failing test**

`deployment/opensearch/test/generate-certs_test.sh`:

```bash
#!/usr/bin/env bash
# Unit test for deployment/opensearch/bin/generate-certs.sh. Needs openssl.
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
dir="$SANDBOX/certs"
gen="$BIN/generate-certs.sh"

out="$("$gen" "$dir" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q '^generated' <<<"$out"; then pass "first run generates"; else fail "first run generates" "rc=$rc $out"; fi
if [ "$(cd "$dir" && ls | sort | tr '\n' ' ')" = "admin-key.pem admin.pem node-key.pem node.pem root-ca-key.pem root-ca.pem " ]; then
  pass "exactly the six files, no leftovers"; else fail "exactly the six files" "$(ls "$dir")"; fi
subject() { openssl x509 -in "$1" -noout -subject -nameopt RFC2253 | sed 's/^subject=//'; }
if [ "$(subject "$dir/node.pem")" = "CN=search-node,OU=search,O=the-greatest" ]; then
  pass "node subject matches plugins.security.nodes_dn"; else fail "node subject" "$(subject "$dir/node.pem")"; fi
if [ "$(subject "$dir/admin.pem")" = "CN=admin,OU=search,O=the-greatest" ]; then
  pass "admin subject matches plugins.security.authcz.admin_dn"; else fail "admin subject" "$(subject "$dir/admin.pem")"; fi
if openssl verify -CAfile "$dir/root-ca.pem" "$dir/node.pem" "$dir/admin.pem" >/dev/null 2>&1; then
  pass "both certificates chain to the CA"; else fail "both certificates chain to the CA" "openssl verify failed"; fi
# OpenSearch reads PKCS#8 only; a "BEGIN RSA PRIVATE KEY" file stops the node from starting.
if [ "$(head -1 "$dir/node-key.pem")" = "-----BEGIN PRIVATE KEY-----" ] && [ "$(head -1 "$dir/admin-key.pem")" = "-----BEGIN PRIVATE KEY-----" ]; then
  pass "keys are PKCS#8"; else fail "keys are PKCS#8" "$(head -1 "$dir/node-key.pem")"; fi
if openssl x509 -in "$dir/node.pem" -noout -ext subjectAltName | grep -q 'DNS:localhost'; then
  pass "node certificate names localhost (securityadmin and the healthcheck use it)"; else fail "node SAN" "no DNS:localhost"; fi
if openssl x509 -in "$dir/node.pem" -noout -checkend $((9 * 365 * 86400)) >/dev/null; then
  pass "node certificate outlives the server (>9 years)"; else fail "node certificate lifetime" "expires within 9 years"; fi
if [ "$(stat -c %a "$dir/root-ca-key.pem")" = 600 ] && [ "$(stat -c %a "$dir/node-key.pem")" = 600 ]; then
  pass "keys are 0600"; else fail "keys are 0600" "$(stat -c '%a %n' "$dir"/*key.pem)"; fi

before="$(sha256sum "$dir/node.pem")"
out="$("$gen" "$dir" 2>&1)"
if [ "$(sha256sum "$dir/node.pem")" = "$before" ] && grep -q '^present' <<<"$out"; then
  pass "a second run leaves a complete set alone"; else fail "a second run leaves a complete set alone" "$out"; fi

rm "$dir/admin.pem"
"$gen" "$dir" >/dev/null 2>&1
if [ -f "$dir/admin.pem" ] && [ "$(sha256sum "$dir/node.pem")" != "$before" ] \
  && openssl verify -CAfile "$dir/root-ca.pem" "$dir/node.pem" "$dir/admin.pem" >/dev/null 2>&1; then
  pass "a partial set is regenerated whole"; else fail "a partial set is regenerated whole" "$(ls "$dir")"; fi

if ! "$gen" >/dev/null 2>&1; then pass "no DIR argument is refused"; else fail "no DIR argument is refused" "exit 0"; fi
finish
```

```bash
chmod +x deployment/opensearch/test/generate-certs_test.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `deployment/opensearch/test/generate-certs_test.sh`
Expected: FAILs.

- [ ] **Step 3: Write the script**

`deployment/opensearch/bin/generate-certs.sh`:

```bash
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
```

```bash
chmod +x deployment/opensearch/bin/generate-certs.sh
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `deployment/opensearch/test/run.sh`
Expected: shellcheck clean, all test files `all passed`.

- [ ] **Step 5: Commit**

```bash
git add deployment/opensearch/bin/generate-certs.sh deployment/opensearch/test/generate-certs_test.sh
git commit -m "OpenSearch server: self-generated CA, node and admin certificates"
```

---

### Task 4: Node config, users and roles

**Files:**
- Create: `deployment/opensearch/config/opensearch.yml`
- Create: `deployment/opensearch/security/{config,roles,roles_mapping,action_groups,tenants,nodes_dn,allowlist,audit}.yml`,
  `deployment/opensearch/security/internal_users.yml.tmpl`
- Create: `deployment/opensearch/bin/render-security.sh`, `deployment/opensearch/bin/hash-password.sh`
- Test: `deployment/opensearch/test/render-security_test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `render-security.sh OUT_DIR` — env `OPENSEARCH_ADMIN_PASSWORD`, `OPENSEARCH_APP_PASSWORD`,
  `OPENSEARCH_LEGACY_PASSWORD`; optional `HASH_CMD` (reads one password on stdin, prints a bcrypt hash; default
  `bin/hash-password.sh`). Writes every `security/*.yml` plus `internal_users.yml` into OUT_DIR. Exit 2 on bad input,
  writing nothing. `hash-password.sh` needs Docker and `compose.yml` (Task 5) at run time, not in tests.

- [ ] **Step 1: Write the static config files**

`deployment/opensearch/config/opensearch.yml`:

```yaml
# deployment/opensearch/config/opensearch.yml -- the search server's node settings.
# Spec: docs/superpowers/specs/2026-10-13-opensearch-server-design.md. Certificates come from
# bin/generate-certs.sh; their subjects must match nodes_dn and admin_dn below.
cluster.name: the-greatest-search
node.name: search-1
network.host: 0.0.0.0
discovery.type: single-node
bootstrap.memory_lock: true

# Carried over from the old server, which never had performance problems.
indices.breaker.total.limit: 70%
indices.breaker.request.limit: 60%
indices.breaker.fielddata.limit: 40%
thread_pool.search.queue_size: 500

plugins.security.ssl.transport.pemcert_filepath: certs/node.pem
plugins.security.ssl.transport.pemkey_filepath: certs/node-key.pem
plugins.security.ssl.transport.pemtrustedcas_filepath: certs/root-ca.pem
plugins.security.ssl.transport.enforce_hostname_verification: false
plugins.security.ssl.http.enabled: true
plugins.security.ssl.http.pemcert_filepath: certs/node.pem
plugins.security.ssl.http.pemkey_filepath: certs/node-key.pem
plugins.security.ssl.http.pemtrustedcas_filepath: certs/root-ca.pem
plugins.security.allow_unsafe_democertificates: false
# The mounted security directory is ours (bin/render-security.sh), so first start loads our users,
# never the image's demo ones.
plugins.security.allow_default_init_securityindex: true
plugins.security.authcz.admin_dn:
  - "CN=admin,OU=search,O=the-greatest"
plugins.security.nodes_dn:
  - "CN=search-node,OU=search,O=the-greatest"
plugins.security.restapi.roles_enabled: ["all_access"]
plugins.security.system_indices.enabled: true
```

`deployment/opensearch/security/config.yml`:

```yaml
# Logins are HTTP basic auth against the users in internal_users.yml. No anonymous access.
_meta:
  type: "config"
  config_version: 2
config:
  dynamic:
    http:
      anonymous_auth_enabled: false
    authc:
      basic_internal_auth_domain:
        http_enabled: true
        transport_enabled: true
        order: 0
        http_authenticator:
          type: basic
          challenge: true
        authentication_backend:
          type: intern
```

`deployment/opensearch/security/roles.yml`:

```yaml
# One role per site, limited to that site's indexes. Neither can change cluster settings, roles or
# the security index. Index names: web-app/app/lib/search/base/index.rb (<domain>_<model>_<env>)
# and the old site's admin/app/lib/search/{books,authors}_index.rb.
_meta:
  type: "roles"
  config_version: 2
the_greatest_app:
  cluster_permissions: ["cluster_composite_ops", "cluster_monitor"]
  index_permissions:
    - index_patterns: ["books_*_production", "music_*_production", "games_*_production"]
      allowed_actions: ["indices_all"]
tgb_legacy:
  cluster_permissions: ["cluster_composite_ops", "cluster_monitor"]
  index_permissions:
    - index_patterns: ["books", "authors"]
      allowed_actions: ["indices_all"]
```

`deployment/opensearch/security/roles_mapping.yml`:

```yaml
_meta:
  type: "rolesmapping"
  config_version: 2
all_access:
  reserved: true
  users: ["admin"]
the_greatest_app:
  users: ["the_greatest_app"]
tgb_legacy:
  users: ["tgb_legacy"]
```

`deployment/opensearch/security/action_groups.yml` (built-in static groups such as `indices_all` need no entry):

```yaml
_meta:
  type: "actiongroups"
  config_version: 2
```

`deployment/opensearch/security/tenants.yml`:

```yaml
_meta:
  type: "tenants"
  config_version: 2
```

`deployment/opensearch/security/nodes_dn.yml`:

```yaml
_meta:
  type: "nodesdn"
  config_version: 2
```

`deployment/opensearch/security/allowlist.yml`:

```yaml
_meta:
  type: "allowlist"
  config_version: 2
config:
  enabled: false
```

`deployment/opensearch/security/audit.yml`:

```yaml
_meta:
  type: "audit"
  config_version: 2
config:
  enabled: false
```

`deployment/opensearch/security/internal_users.yml.tmpl`:

```yaml
# Rendered by bin/render-security.sh: each @..._HASH@ becomes the bcrypt hash of a password from
# secrets/.env.opensearch. The plain passwords never reach this file.
_meta:
  type: "internalusers"
  config_version: 2
admin:
  hash: "@ADMIN_HASH@"
  reserved: true
  description: "Break-glass and setup only. No app uses it."
the_greatest_app:
  hash: "@APP_HASH@"
  description: "The new app (web-app/)."
tgb_legacy:
  hash: "@LEGACY_HASH@"
  description: "The old books site, until it shuts down."
```

- [ ] **Step 2: Write the failing test**

`deployment/opensearch/test/render-security_test.sh`:

```bash
#!/usr/bin/env bash
# Unit test for deployment/opensearch/bin/render-security.sh and the security/ files it ships.
# Hashing is faked: a bcrypt-shaped string derived from the password, so no Java or Docker.
# shellcheck disable=SC2016  # stub bodies and bcrypt strings are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
cat >"$SANDBOX/bin/fakehash" <<'EOF'
#!/usr/bin/env bash
pw="$(command -p cat)"
printf '$2y$12$%s\n' "$(printf %s "$pw" | command -p sha256sum | command -p head -c 53)"
EOF
chmod +x "$SANDBOX/bin/fakehash"
expected_hash() { printf '$2y$12$%s' "$(printf %s "$1" | sha256sum | head -c 53)"; }
admin_pw="$(openssl rand -hex 32)" app_pw="$(openssl rand -hex 32)" legacy_pw="$(openssl rand -hex 32)"
render() {   # render OUT_DIR [VAR=value ...]
  local out="$1"; shift
  env HASH_CMD=fakehash OPENSEARCH_ADMIN_PASSWORD="$admin_pw" OPENSEARCH_APP_PASSWORD="$app_pw" \
    OPENSEARCH_LEGACY_PASSWORD="$legacy_pw" "$@" "$BIN/render-security.sh" "$out"
}
out="$SANDBOX/security"
users="$out/internal_users.yml"

render "$out" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && [ -f "$users" ]; then pass "renders internal_users.yml"; else fail "renders internal_users.yml" "rc=$rc"; fi
hash_of_user() { grep -A1 -x "$1:" "$users" | sed -n 's/^  hash: "\(.*\)"$/\1/p'; }
if [ "$(hash_of_user admin)" = "$(expected_hash "$admin_pw")" ] && [ "$(hash_of_user the_greatest_app)" = "$(expected_hash "$app_pw")" ] \
  && [ "$(hash_of_user tgb_legacy)" = "$(expected_hash "$legacy_pw")" ]; then
  pass "each user gets the hash of its own password"; else fail "each user gets its own hash" "$(cat "$users")"; fi
if ! grep -rqF -e "$admin_pw" -e "$app_pw" -e "$legacy_pw" "$out"; then
  pass "no plain password reaches the directory"; else fail "no plain password reaches the directory" "found one"; fi
if [ "$(grep -E '^[a-z_]+:$' "$users" | grep -v '^_meta:$' | tr '\n' ' ')" = "admin: the_greatest_app: tgb_legacy: " ]; then
  pass "exactly admin, the_greatest_app, tgb_legacy (no demo users)"; else fail "exactly three users" "$(grep -E '^[a-z_]+:$' "$users")"; fi
if ! grep -q '@[A-Z_]*_HASH@' "$users"; then pass "no placeholder left"; else fail "no placeholder left" "$(cat "$users")"; fi
for f in config roles roles_mapping action_groups tenants nodes_dn allowlist audit; do
  if [ -f "$out/$f.yml" ]; then pass "$f.yml is copied"; else fail "$f.yml is copied" "missing"; fi
done
if [ ! -e "$out/internal_users.yml.tmpl" ]; then pass "the template is not copied"; else fail "the template is not copied" "present"; fi

# The shipped roles and mappings: each site sees only its own indexes.
roles="$OS_DIR/security/roles.yml" mapping="$OS_DIR/security/roles_mapping.yml"
if grep -A3 -x 'the_greatest_app:' "$roles" | grep -qxF '    - index_patterns: ["books_*_production", "music_*_production", "games_*_production"]'; then
  pass "the_greatest_app: only the new app's index patterns"; else fail "the_greatest_app patterns" "$(cat "$roles")"; fi
if grep -A3 -x 'tgb_legacy:' "$roles" | grep -qxF '    - index_patterns: ["books", "authors"]'; then
  pass "tgb_legacy: only the old site's indexes"; else fail "tgb_legacy patterns" "$(cat "$roles")"; fi
if ! grep -qE 'index_patterns:.*"\*"' "$roles"; then pass "no role matches every index"; else fail "no role matches every index" "wildcard"; fi
if [ "$(grep -oE 'users: \[[^]]*\]' "$mapping" | tr '\n' ' ')" = 'users: ["admin"] users: ["the_greatest_app"] users: ["tgb_legacy"] ' ]; then
  pass "mappings name only our three users"; else fail "mappings" "$(cat "$mapping")"; fi
if grep -q 'anonymous_auth_enabled: false' "$OS_DIR/security/config.yml"; then pass "no anonymous access"; else fail "no anonymous access" "missing"; fi

# Refusals write nothing.
refuses() {   # refuses <name> <VAR=value ...>
  local name="$1" dir="$SANDBOX/refused-$RANDOM" rc
  shift
  render "$dir" "$@" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 2 ] && [ ! -e "$dir/internal_users.yml" ]; then pass "$name"; else fail "$name" "rc=$rc"; fi
}
refuses "a missing password is refused" OPENSEARCH_APP_PASSWORD=
refuses "a short password is refused" OPENSEARCH_LEGACY_PASSWORD=abc123
refuses "a password with URL-breaking characters is refused" OPENSEARCH_ADMIN_PASSWORD="$(openssl rand -hex 16)@$(openssl rand -hex 16)"
stub badhash 'echo oops'
refuses "a hash command that prints no bcrypt hash is refused" HASH_CMD=badhash

# Re-rendering replaces the file (new passwords -> new hashes).
old="$(hash_of_user admin)"
admin_pw="$(openssl rand -hex 32)"
render "$out" >/dev/null 2>&1
if [ "$(hash_of_user admin)" != "$old" ]; then pass "re-rendering replaces the users file"; else fail "re-rendering replaces the users file" "unchanged"; fi
finish
```

```bash
chmod +x deployment/opensearch/test/render-security_test.sh
```

- [ ] **Step 3: Run it to verify it fails**

Run: `deployment/opensearch/test/render-security_test.sh`
Expected: FAILs (no renderer).

- [ ] **Step 4: Write the renderer and the hash wrapper**

`deployment/opensearch/bin/render-security.sh`:

```bash
#!/usr/bin/env bash
# deployment/opensearch/bin/render-security.sh OUT_DIR
# Builds the complete security directory the container mounts at config/opensearch-security:
# every security/*.yml as-is, plus internal_users.yml rendered from internal_users.yml.tmpl with
# the bcrypt hash of each password from the environment (OPENSEARCH_ADMIN_PASSWORD,
# OPENSEARCH_APP_PASSWORD, OPENSEARCH_LEGACY_PASSWORD). Plain passwords never reach a file.
# HASH_CMD reads one password on stdin and prints its hash (default: bin/hash-password.sh).
# Passwords must be 32+ letters and digits: they travel inside OPENSEARCH_URL, where : @ / %
# would break parsing. All hashing happens before anything is written. Spec §5.2.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:?usage: render-security.sh OUT_DIR}"
sec="$here/../security"
hash_cmd="${HASH_CMD:-$here/hash-password.sh}"

hash_of() {   # hash_of VAR_NAME
  local name="$1" password hash
  password="${!name:-}"
  if [ -z "$password" ]; then echo "render-security: $name is not set" >&2; return 2; fi
  if ! [[ "$password" =~ ^[A-Za-z0-9]{32,}$ ]]; then
    echo "render-security: $name must be 32 or more letters and digits (openssl rand -hex 32)" >&2; return 2
  fi
  hash="$(printf '%s' "$password" | "$hash_cmd")" || { echo "render-security: hashing $name failed" >&2; return 2; }
  if ! [[ "$hash" =~ ^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$ ]]; then
    echo "render-security: the hash command printed no bcrypt hash for $name" >&2; return 2
  fi
  printf '%s' "$hash"
}
admin="$(hash_of OPENSEARCH_ADMIN_PASSWORD)" || exit 2
app="$(hash_of OPENSEARCH_APP_PASSWORD)" || exit 2
legacy="$(hash_of OPENSEARCH_LEGACY_PASSWORD)" || exit 2

mkdir -p "$out"
cp "$sec"/*.yml "$out/"
tmp="$(mktemp "$out/.internal_users.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
# bcrypt output is [./A-Za-z0-9$], so | is a safe sed delimiter.
sed -e "s|@ADMIN_HASH@|$admin|" -e "s|@APP_HASH@|$app|" -e "s|@LEGACY_HASH@|$legacy|" \
  "$sec/internal_users.yml.tmpl" >"$tmp"
if grep -q '@[A-Z_]*_HASH@' "$tmp"; then echo "render-security: a placeholder was left unreplaced" >&2; exit 2; fi
chmod 0640 "$tmp"
mv "$tmp" "$out/internal_users.yml"
trap - EXIT
```

`deployment/opensearch/bin/hash-password.sh`:

```bash
#!/usr/bin/env bash
# deployment/opensearch/bin/hash-password.sh   (password on stdin, bcrypt hash on stdout)
# Hashes with the security plugin's own tool from the image compose.yml pins, so the hash format
# always matches the version that checks it. The password reaches the container through its
# environment, never a command line, so it does not show in `ps`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
image="$(docker compose -f "$here/../compose.yml" config --images | head -1)"
PW="$(cat)"
export PW
# shellcheck disable=SC2016  # a literal bcrypt prefix, not a parameter
docker run --rm -e PW --entrypoint /usr/share/opensearch/plugins/opensearch-security/tools/hash.sh "$image" -env PW \
  | grep -E '^\$2[aby]\$' | tail -1
```

```bash
chmod +x deployment/opensearch/bin/render-security.sh deployment/opensearch/bin/hash-password.sh
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `deployment/opensearch/test/run.sh`
Expected: shellcheck clean, every test file `all passed`.

- [ ] **Step 6: Commit**

```bash
git add deployment/opensearch/config deployment/opensearch/security deployment/opensearch/bin/render-security.sh \
  deployment/opensearch/bin/hash-password.sh deployment/opensearch/test/render-security_test.sh
git commit -m "OpenSearch server: node config, per-site users and roles, password hashing"
```

---

### Task 5: Compose file, securityadmin, local end-to-end test

This task proves the OpenSearch-specific facts the earlier tasks assumed (PKCS#8 keys, DN strings, the `hash.sh -env`
flag, `securityadmin.sh` flags, a complete security directory). If the e2e test fails, fix the config or script it
points at, re-run Task 3/4's unit tests, and note the fix in the commit message.

**Files:**
- Create: `deployment/opensearch/compose.yml`, `deployment/opensearch/bin/apply-security.sh`,
  `deployment/opensearch/test/local-e2e-test.sh`, `deployment/opensearch/test/compose_test.sh`

**Interfaces:**
- Consumes: `generate-certs.sh DIR`, `render-security.sh OUT_DIR`, `hash-password.sh` (Tasks 3-4).
- Produces: `compose.yml` (project name `opensearch`, service `opensearch`; env `OPENSEARCH_PORT` default 9200,
  `OPENSEARCH_HEAP` default `4g`, `OPENSEARCH_MEM_LIMIT` default `7g`, `OPENSEARCH_CERTS_DIR` default
  `/srv/opensearch/certs`, `OPENSEARCH_SECURITY_DIR` default `/srv/opensearch/security`). `apply-security.sh`: waits up
  to 3 minutes for HTTPS, then runs `securityadmin.sh`; honours `COMPOSE_PROJECT_NAME`.

- [ ] **Step 1: Pick the version**

Open https://github.com/opensearch-project/OpenSearch/releases and take the newest `3.x.y` release (3.8.0 was newest on
2026-10-13). Use that exact tag below and in every later reference. Skim that version's security-plugin docs
(https://docs.opensearch.org/latest/security/configuration/) for changes to `securityadmin.sh` or `hash.sh`.

- [ ] **Step 2: Write the compose file and its static test**

`deployment/opensearch/compose.yml`:

```yaml
# deployment/opensearch/compose.yml -- the search server. Started by bin/deploy.sh.
# Spec: docs/superpowers/specs/2026-10-13-opensearch-server-design.md
name: opensearch
services:
  opensearch:
    # Pinned. Upgrading is a one-line change here plus a deploy (docs/features/opensearch-server.md).
    image: opensearchproject/opensearch:3.8.0
    restart: unless-stopped
    environment:
      - DISABLE_INSTALL_DEMO_CONFIG=true
      - "OPENSEARCH_JAVA_OPTS=-Xms${OPENSEARCH_HEAP:-4g} -Xmx${OPENSEARCH_HEAP:-4g}"
    ulimits:
      memlock: { soft: -1, hard: -1 }
      nofile: { soft: 65536, hard: 65536 }
    mem_limit: ${OPENSEARCH_MEM_LIMIT:-7g}
    memswap_limit: ${OPENSEARCH_MEM_LIMIT:-7g}
    ports:
      # IPv4 only. A bare "9200:9200" also listens on [::]:9200 through docker-proxy, a path the
      # DOCKER-USER allowlist never sees.
      - "0.0.0.0:${OPENSEARCH_PORT:-9200}:9200"
    volumes:
      - opensearch-data:/usr/share/opensearch/data
      - ./config/opensearch.yml:/usr/share/opensearch/config/opensearch.yml:ro
      - ${OPENSEARCH_CERTS_DIR:-/srv/opensearch/certs}:/usr/share/opensearch/config/certs:ro
      # A directory mount, not single files: deploy.sh replaces files in it, and a single-file
      # bind mount would keep showing the container the old inode.
      - ${OPENSEARCH_SECURITY_DIR:-/srv/opensearch/security}:/usr/share/opensearch/config/opensearch-security:ro
    healthcheck:
      test: ["CMD-SHELL", "curl -sk -o /dev/null -w '%{http_code}' https://localhost:9200/ | grep -qE '^(200|401)$'"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s
    logging:
      driver: json-file
      options: { max-size: "50m", max-file: "5" }
volumes:
  opensearch-data:
```

`deployment/opensearch/test/compose_test.sh`:

```bash
#!/usr/bin/env bash
# Static checks on deployment/opensearch/compose.yml (no Docker needed).
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
compose="$OS_DIR/compose.yml"
if grep -qE '^\s+image: opensearchproject/opensearch:[0-9]+\.[0-9]+\.[0-9]+$' "$compose"; then
  pass "the image is pinned to an exact version"; else fail "the image is pinned" "$(grep image: "$compose")"; fi
ports="$(sed -n '/^    ports:/,/^    [a-z]/p' "$compose" | grep -E '^\s+- ')"
if [ -n "$ports" ] && ! grep -vqE '^\s+- "0\.0\.0\.0:' <<<"$ports"; then
  pass "every published port is bound to IPv4 0.0.0.0 (no [::] docker-proxy path)"; else fail "IPv4-only ports" "$ports"; fi
if grep -q 'DISABLE_INSTALL_DEMO_CONFIG=true' "$compose"; then pass "demo config disabled"; else fail "demo config disabled" "missing"; fi
if ! grep -qi 'DISABLE_SECURITY_PLUGIN' "$compose"; then pass "security plugin left on"; else fail "security plugin left on" "found"; fi
finish
```

```bash
chmod +x deployment/opensearch/test/compose_test.sh
deployment/opensearch/test/compose_test.sh
```

Expected: `all passed`.

- [ ] **Step 3: Write apply-security.sh**

`deployment/opensearch/bin/apply-security.sh`:

```bash
#!/usr/bin/env bash
# deployment/opensearch/bin/apply-security.sh
# Waits for the node to answer HTTPS, then loads the mounted security directory (users, roles,
# mappings) into the security index with securityadmin.sh and the admin client certificate.
# Safe to repeat. COMPOSE_PROJECT_NAME selects another project (the local e2e test uses one).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
compose=(docker compose -f "$here/../compose.yml")
cfg=/usr/share/opensearch/config

code=000
for _ in $(seq 1 60); do
  # 503 means up, security index not initialised yet; securityadmin fixes that.
  code="$("${compose[@]}" exec -T opensearch curl -sk -o /dev/null -w '%{http_code}' https://localhost:9200/ 2>/dev/null || true)"
  case "$code" in 200|401|503) break ;; esac
  sleep 3
done
case "$code" in
  200|401|503) ;;
  *) echo "apply-security: OpenSearch did not answer HTTPS within 3 minutes (last: $code)" >&2; exit 1 ;;
esac

"${compose[@]}" exec -T opensearch /usr/share/opensearch/plugins/opensearch-security/tools/securityadmin.sh \
  -cd "$cfg/opensearch-security/" -icl -nhnv \
  -cacert "$cfg/certs/root-ca.pem" -cert "$cfg/certs/admin.pem" -key "$cfg/certs/admin-key.pem" \
  -h localhost
```

```bash
chmod +x deployment/opensearch/bin/apply-security.sh
```

- [ ] **Step 4: Write the local end-to-end test**

`deployment/opensearch/test/local-e2e-test.sh`:

```bash
#!/usr/bin/env bash
# End-to-end test of the search server's security on this machine (spec §8.2): the real compose
# file, real generated certificates, the rendered security directory, securityadmin.sh, then the
# logins. No firewall here -- that is proven on the real server (verify-opensearch-lockdown.sh).
# Needs docker, curl, openssl, python3; port 19200 free. About 2 minutes (longer on first pull).
# Usage (from anywhere): deployment/opensearch/test/local-e2e-test.sh
set -uo pipefail
os="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
export COMPOSE_PROJECT_NAME=tg-opensearch-e2e OPENSEARCH_PORT=19200 OPENSEARCH_HEAP=512m OPENSEARCH_MEM_LIMIT=2g
export OPENSEARCH_CERTS_DIR="$work/certs" OPENSEARCH_SECURITY_DIR="$work/security"
compose=(docker compose -f "$os/compose.yml")
cleanup() { "${compose[@]}" down -v >/dev/null 2>&1; rm -rf "$work"; }
trap cleanup EXIT

failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1 -- $2"; failures=$((failures + 1)); }

admin_pw="$(openssl rand -hex 32)" app_pw="$(openssl rand -hex 32)" legacy_pw="$(openssl rand -hex 32)"
"$os/bin/generate-certs.sh" "$work/certs" >/dev/null
OPENSEARCH_ADMIN_PASSWORD="$admin_pw" OPENSEARCH_APP_PASSWORD="$app_pw" OPENSEARCH_LEGACY_PASSWORD="$legacy_pw" \
  "$os/bin/render-security.sh" "$work/security" || { echo "render-security failed (hash-password.sh?)"; exit 1; }
# The container runs as uid 1000; this throwaway copy just needs to be readable by it.
chmod -R a+rX "$work/certs" "$work/security"

"${compose[@]}" up -d >/dev/null 2>&1 || { echo "compose up failed"; "${compose[@]}" logs; exit 1; }
if "$os/bin/apply-security.sh" >"$work/securityadmin.log" 2>&1; then pass "securityadmin.sh applied the config"
else fail "securityadmin.sh applied the config" "$(tail -20 "$work/securityadmin.log")"; fi

base="https://localhost:19200"
req() {   # req USER PASSWORD METHOD PATH [BODY] -> prints the HTTP status
  local auth=() body=()
  if [ -n "$1" ]; then auth=(--netrc-file <(printf 'machine localhost login %s password %s\n' "$1" "$2")); fi
  if [ -n "${5:-}" ]; then body=(-H 'Content-Type: application/json' -d "$5"); fi
  curl -sk -o /dev/null -w '%{http_code}' --max-time 20 "${auth[@]}" -X "$3" "${body[@]}" "$base$4"
}
expect() {   # expect NAME WANT USER PASSWORD METHOD PATH [BODY]
  local name="$1" want="$2" got
  shift 2
  got="$(req "$@")"
  if [ "$got" = "$want" ]; then pass "$name ($got)"; else fail "$name" "http $got, wanted $want"; fi
}
expect "no login is refused" 401 "" "" GET /
expect "admin works" 200 admin "$admin_pw" GET /_cluster/health
expect "app: cluster health" 200 the_greatest_app "$app_pw" GET /_cluster/health
expect "app: creates its own index" 200 the_greatest_app "$app_pw" PUT /books_books_production
expect "app: writes to it" 201 the_greatest_app "$app_pw" POST '/books_books_production/_doc?refresh=true' '{"title":"x"}'
expect "app: searches it" 200 the_greatest_app "$app_pw" GET /books_books_production/_search
expect "app: bulk to its own index" 200 the_greatest_app "$app_pw" POST /_bulk $'{"index":{"_index":"music_albums_production"}}\n{"t":1}\n'
expect "app: refused on the old site's index" 403 the_greatest_app "$app_pw" PUT /books
expect "app: refused on the security API" 403 the_greatest_app "$app_pw" GET /_plugins/_security/api/internalusers
expect "app: refused on cluster settings" 403 the_greatest_app "$app_pw" PUT /_cluster/settings '{"persistent":{"cluster.routing.allocation.enable":"all"}}'
expect "legacy: creates its own index" 200 tgb_legacy "$legacy_pw" PUT /books
expect "legacy: refused on the new app's index" 403 tgb_legacy "$legacy_pw" GET /books_books_production/_search
expect "legacy: refused on cluster settings" 403 tgb_legacy "$legacy_pw" PUT /_cluster/settings '{"persistent":{"cluster.routing.allocation.enable":"all"}}'
expect "wrong password is refused" 401 the_greatest_app "$legacy_pw" GET /_cluster/health

if [ "$failures" = 0 ]; then echo "all passed"; else echo "$failures failed"; exit 1; fi
```

Note: the `_bulk` check uses `$'...'` so the NDJSON body carries real newlines.

```bash
chmod +x deployment/opensearch/test/local-e2e-test.sh
```

- [ ] **Step 5: Run the end-to-end test**

Run: `deployment/opensearch/test/local-e2e-test.sh`
Expected: every line `PASS`, ending `all passed`.

If something fails, the usual causes and fixes:
- `render-security failed`: `hash.sh` in this version lacks `-env`. Check with
  `docker run --rm --entrypoint /usr/share/opensearch/plugins/opensearch-security/tools/hash.sh opensearchproject/opensearch:<tag> -h`.
  If there is no env option, change `hash-password.sh` to
  `docker run --rm -e PW --entrypoint bash "$image" -c '/usr/share/opensearch/plugins/opensearch-security/tools/hash.sh -p "$PW"'`
  (the password is then in the container's argv, not the host shell's) and add a comment saying why.
- The node does not start (`docker compose -p tg-opensearch-e2e -f deployment/opensearch/compose.yml logs`): a
  certificate or DN mismatch shows there. The subjects in `opensearch.yml` must equal Task 3's.
- `securityadmin.sh` rejects a file in `security/`: compare it with the image's own copy
  (`docker run --rm --entrypoint cat opensearchproject/opensearch:<tag> /usr/share/opensearch/config/opensearch-security/<file>`)
  and fix ours, keeping our intent (no demo users, audit and allowlist disabled).

- [ ] **Step 6: Run the unit suite again**

Run: `deployment/opensearch/test/run.sh`
Expected: `all passed` for every file (compose_test.sh included), shellcheck clean.

- [ ] **Step 7: Commit**

```bash
git add deployment/opensearch/compose.yml deployment/opensearch/bin/apply-security.sh \
  deployment/opensearch/test/local-e2e-test.sh deployment/opensearch/test/compose_test.sh
git commit -m "OpenSearch server: pinned compose file, securityadmin step, local end-to-end test"
```

---

### Task 6: deploy.sh

**Files:**
- Create: `deployment/opensearch/bin/deploy.sh`
- Test: `deployment/opensearch/test/deploy_test.sh`

**Interfaces:**
- Consumes: `render-firewall.sh`, `install-firewall.sh` (env `ROOT`, `ALLOWLIST`), `generate-certs.sh`,
  `render-security.sh` (env `HASH_CMD`), `apply-security.sh`, `compose.yml` (env `OPENSEARCH_CERTS_DIR`,
  `OPENSEARCH_SECURITY_DIR`).
- Produces: `deploy.sh ENV_FILE`. ENV_FILE defines `OPENSEARCH_ALLOWED_IPS` (addresses separated by spaces, commas or
  newlines), `OPENSEARCH_ADMIN_PASSWORD`, `OPENSEARCH_APP_PASSWORD`, `OPENSEARCH_LEGACY_PASSWORD`. Overridable for tests:
  `STATE_DIR` (default `/srv/opensearch`), `ETC_DIR` (default `/etc/opensearch`), `NO_SUDO=1`, `OS_UID`/`OS_GID`
  (default 1000, the container's opensearch user).

- [ ] **Step 1: Write the failing test**

`deployment/opensearch/test/deploy_test.sh`:

```bash
#!/usr/bin/env bash
# Unit test for deployment/opensearch/bin/deploy.sh. Docker, systemctl and iptables are stubbed;
# certificates are real (openssl), hashing is faked.
# shellcheck disable=SC2016  # stub bodies and bcrypt strings are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
new_sandbox
cat >"$SANDBOX/bin/fakehash" <<'EOF'
#!/usr/bin/env bash
printf '$2y$12$%s\n' "$(command -p cat | command -p sha256sum | command -p head -c 53)"
EOF
chmod +x "$SANDBOX/bin/fakehash"
stub systemctl ''
stub iptables-restore 'command -p cat >"$SANDBOX/log/v4.rules"'
stub ip6tables-restore 'command -p cat >/dev/null'
stub docker 'case "$*" in *curl*) printf 401 ;; esac'
export NO_SUDO=1 OS_UID="$(id -u)" OS_GID="$(id -g)" HASH_CMD=fakehash ROOT="$SANDBOX/root"
export STATE_DIR="$SANDBOX/srv" ETC_DIR="$SANDBOX/etc" ALLOWLIST="$SANDBOX/etc/allowlist"
env_file="$SANDBOX/env"
write_env() {   # write_env ALLOWED_IPS [APP_PASSWORD]
  printf 'OPENSEARCH_ALLOWED_IPS="%s"\nOPENSEARCH_ADMIN_PASSWORD=%s\nOPENSEARCH_APP_PASSWORD=%s\nOPENSEARCH_LEGACY_PASSWORD=%s\n' \
    "$1" "$(openssl rand -hex 32)" "${2-$(openssl rand -hex 32)}" "$(openssl rand -hex 32)" >"$env_file"
}
line_no() { grep -nE "$1" "$CALLS" | head -1 | cut -d: -f1; }

# --- first deploy -------------------------------------------------------------------------
write_env "203.0.113.10, 203.0.113.11"
"$BIN/deploy.sh" "$env_file" >"$SANDBOX/log/out" 2>&1; rc=$?
if [ "$rc" = 0 ]; then pass "first deploy exits 0"; else fail "first deploy exits 0" "rc=$rc $(tail -5 "$SANDBOX/log/out")"; fi
if [ "$(cat "$ETC_DIR/allowlist")" = $'203.0.113.10\n203.0.113.11' ]; then
  pass "a comma-and-space list becomes one address per line"; else fail "allowlist file" "$(cat "$ETC_DIR/allowlist" 2>&1)"; fi
if grep -q -- '-s 203.0.113.11/32 -j RETURN' "$SANDBOX/log/v4.rules"; then pass "the allowlist is applied"; else fail "the allowlist is applied" "no rule"; fi
if [ -f "$STATE_DIR/certs/node.pem" ] && [ -f "$STATE_DIR/security/internal_users.yml" ] && [ -f "$STATE_DIR/security/roles.yml" ]; then
  pass "certificates and the security directory are in place"; else fail "certs and security dir" "$(ls -R "$STATE_DIR" 2>&1)"; fi
if called 'compose .* up -d --force-recreate$'; then pass "first deploy force-recreates"; else fail "first deploy force-recreates" "$(cat "$CALLS")"; fi
if called 'securityadmin.sh'; then pass "the security config is loaded"; else fail "the security config is loaded" "$(cat "$CALLS")"; fi
fw="$(line_no '^iptables-restore')" up="$(line_no 'compose .* up -d')"
if [ -n "$fw" ] && [ -n "$up" ] && [ "$fw" -lt "$up" ]; then pass "the firewall goes up before OpenSearch"; else fail "firewall before OpenSearch" "fw=$fw up=$up"; fi

# --- second deploy, nothing changed ---------------------------------------------------------
before="$(sha256sum "$STATE_DIR/certs/node.pem")"
: >"$CALLS"
write_env "203.0.113.10 203.0.113.11"
"$BIN/deploy.sh" "$env_file" >"$SANDBOX/log/out" 2>&1; rc=$?
if [ "$rc" = 0 ] && called 'compose .* up -d$' && ! called 'force-recreate'; then
  pass "an unchanged redeploy does not restart OpenSearch"; else fail "unchanged redeploy" "rc=$rc $(cat "$CALLS")"; fi
if [ "$(sha256sum "$STATE_DIR/certs/node.pem")" = "$before" ]; then pass "certificates are kept"; else fail "certificates are kept" "regenerated"; fi

# --- a bad allowlist leaves the running one alone -------------------------------------------
: >"$CALLS"
write_env "203.0.113.10 nope"
"$BIN/deploy.sh" "$env_file" >"$SANDBOX/log/out" 2>&1; rc=$?
if [ "$rc" != 0 ] && [ "$(cat "$ETC_DIR/allowlist")" = $'203.0.113.10\n203.0.113.11' ] && ! called 'compose|restore'; then
  pass "a bad allowlist fails before touching anything"; else fail "a bad allowlist" "rc=$rc $(cat "$CALLS")"; fi

# --- a missing password stops everything -----------------------------------------------------
: >"$CALLS"
write_env "203.0.113.10" ""
"$BIN/deploy.sh" "$env_file" >"$SANDBOX/log/out" 2>&1; rc=$?
if [ "$rc" = 2 ] && ! called '.'; then pass "a missing password stops the deploy before anything runs"; else fail "missing password" "rc=$rc $(cat "$CALLS")"; fi

if ! "$BIN/deploy.sh" >/dev/null 2>&1; then pass "no ENV_FILE argument is refused"; else fail "no ENV_FILE argument is refused" "exit 0"; fi
finish
```

```bash
chmod +x deployment/opensearch/test/deploy_test.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `deployment/opensearch/test/deploy_test.sh`
Expected: FAILs.

- [ ] **Step 3: Write deploy.sh**

`deployment/opensearch/bin/deploy.sh`:

```bash
#!/usr/bin/env bash
# deployment/opensearch/bin/deploy.sh ENV_FILE
# Configures and starts the search server. Run on the server by .github/workflows/deploy-opensearch.yml
# as the deploy user (passwordless sudo); ENV_FILE is the decrypted secrets/.env.opensearch.
# Every step is safe to repeat; an unchanged redeploy restarts nothing. Spec §6.4.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
os_dir="$(cd "$here/.." && pwd)"
env_file="${1:?usage: deploy.sh ENV_FILE}"
STATE_DIR="${STATE_DIR:-/srv/opensearch}"
ETC_DIR="${ETC_DIR:-/etc/opensearch}"
OS_UID="${OS_UID:-1000}" OS_GID="${OS_GID:-1000}"   # the container's opensearch user
sudo=(sudo --preserve-env=ROOT,ALLOWLIST)
if [ "${NO_SUDO:-0}" = 1 ]; then sudo=(); fi

set -a
# shellcheck source=/dev/null
. "$env_file"
set +a
for v in OPENSEARCH_ALLOWED_IPS OPENSEARCH_ADMIN_PASSWORD OPENSEARCH_APP_PASSWORD OPENSEARCH_LEGACY_PASSWORD; do
  if [ -z "${!v:-}" ]; then echo "deploy: $v is missing from $env_file" >&2; exit 2; fi
done
export OPENSEARCH_CERTS_DIR="$STATE_DIR/certs" OPENSEARCH_SECURITY_DIR="$STATE_DIR/security"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 1. Firewall. Validate first: a bad allowlist must never reach the file the boot unit reads.
tr ', \r\t' '\n\n\n\n' <<<"$OPENSEARCH_ALLOWED_IPS" | sed '/^$/d' >"$work/allowlist"
"$here/render-firewall.sh" --family v4 --allowlist "$work/allowlist" >/dev/null
"${sudo[@]}" install -d -m 0755 "$ETC_DIR"
"${sudo[@]}" install -m 0644 "$work/allowlist" "$ETC_DIR/allowlist"
"${sudo[@]}" env ALLOWLIST="${ALLOWLIST:-$ETC_DIR/allowlist}" "$here/install-firewall.sh"

# 2. Certificates, first run only, readable by the container user.
"${sudo[@]}" "$here/generate-certs.sh" "$STATE_DIR/certs"
"${sudo[@]}" chown -R "$OS_UID:$OS_GID" "$STATE_DIR/certs"

# 3. Users and roles: hash as this user (needs Docker), then install for the container user.
"$here/render-security.sh" "$work/security"
"${sudo[@]}" install -d -m 0750 -o "$OS_UID" -g "$OS_GID" "$OPENSEARCH_SECURITY_DIR"
"${sudo[@]}" install -m 0640 -o "$OS_UID" -g "$OS_GID" "$work/security"/*.yml "$OPENSEARCH_SECURITY_DIR/"

# 4. Start. Single-file mounts (opensearch.yml) and certificates are read at start, so a change to
# either needs a recreate; anything else is a no-op `up -d`. A new image tag recreates by itself.
fingerprint="$("${sudo[@]}" cat "$os_dir/config/opensearch.yml" "$STATE_DIR/certs/node.pem" "$STATE_DIR/certs/root-ca.pem" \
  | sha256sum | cut -d' ' -f1)"
previous="$("${sudo[@]}" cat "$STATE_DIR/config.sha256" 2>/dev/null || true)"
up=(up -d)
if [ "$previous" != "$fingerprint" ]; then up=(up -d --force-recreate); fi
docker compose -f "$os_dir/compose.yml" "${up[@]}"
printf '%s\n' "$fingerprint" | "${sudo[@]}" tee "$STATE_DIR/config.sha256" >/dev/null

# 5. Load users and roles into the security index (picks up password rotations too).
"$here/apply-security.sh"
echo "deploy: done"
```

Note on the stubbed `docker`: in the test, `apply-security.sh` sees `printf 401` for the curl probe and the stub
accepts the `securityadmin.sh` exec, so both are logged to `$CALLS`.

```bash
chmod +x deployment/opensearch/bin/deploy.sh
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `deployment/opensearch/test/run.sh`
Expected: shellcheck clean, every test file `all passed`.

- [ ] **Step 5: Commit**

```bash
git add deployment/opensearch/bin/deploy.sh deployment/opensearch/test/deploy_test.sh
git commit -m "OpenSearch server: deploy script (firewall, certificates, users, start, securityadmin)"
```

---

### Task 7: Terraform module and cloud-init

**Files:**
- Create: `deployment/terraform/opensearch/main.tf`, `variables.tf`, `cloud-init.yaml`, `terraform.tfvars.example`,
  `.terraform.lock.hcl` (generated by `terraform init`)

**Interfaces:**
- Consumes: `deployment/opensearch/bin/install-firewall.sh` (Task 2), run by cloud-init as root.
- Produces: outputs `ipv4` and `ipv6`; a server with Docker, `deploy` user, repo at `/home/deploy/apps/the-greatest`,
  firewall unit enabled with deny-all, OpenSearch **not** started.

- [ ] **Step 1: Write the module**

`deployment/terraform/opensearch/main.tf`:

```hcl
# The search server. Its own root module and state, so an apply here can never touch the web server.
# Spec: docs/superpowers/specs/2026-10-13-opensearch-server-design.md. Runbook: docs/features/opensearch-server.md.
terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "3.0.0"
    }
  }
}

provider "linode" {
  token = var.linode_token
}

resource "linode_instance" "search" {
  image           = "linode/ubuntu26.04"
  label           = var.instance_label
  region          = var.instance_region
  type            = var.instance_type
  authorized_keys = var.authorized_keys
  root_pass       = var.root_password

  metadata {
    user_data = base64encode(
      templatefile("${path.module}/cloud-init.yaml", {
        primary_ssh_key = var.authorized_keys[0]
      })
    )
  }
}

output "ipv4" {
  value = linode_instance.search.ip_address
}

output "ipv6" {
  value = linode_instance.search.ipv6
}
```

`deployment/terraform/opensearch/variables.tf`:

```hcl
variable "linode_token" {
  description = "Linode API token"
  type        = string
  sensitive   = true
}

variable "instance_label" {
  description = "Label for the Linode instance"
  type        = string
  default     = "thegreatest-search"
}

variable "instance_region" {
  description = "Region; keep it the same as the app servers"
  type        = string
  default     = "us-central"
}

variable "instance_type" {
  description = "Linode plan. g6-standard-4 is Linode 8 GB (4 cores, 160 GB), the old server's size"
  type        = string
  default     = "g6-standard-4"
}

variable "authorized_keys" {
  description = "SSH public keys; the first also becomes the deploy user's key"
  type        = list(string)
}

variable "root_password" {
  description = "Root password (root SSH login is disabled by cloud-init)"
  type        = string
  sensitive   = true
}
```

`deployment/terraform/opensearch/terraform.tfvars.example`:

```hcl
linode_token    = "your-linode-api-token"
authorized_keys = ["ssh-ed25519 AAAA... your-public-key"]
root_password   = "your-secure-root-password"

# Optional: override defaults
# instance_label  = "thegreatest-search"
# instance_region = "us-central"
# instance_type   = "g6-standard-4"
```

`deployment/terraform/opensearch/cloud-init.yaml`:

```yaml
#cloud-config
# The search server's first boot. Modelled on ../web-cloud-init.yaml. It hardens the host, closes
# port 9200 BEFORE Docker is installed, and clones the repo. It does not start OpenSearch: the
# server has no secrets until the deploy-opensearch workflow runs. Spec §6.3.
users:
  - name: deploy
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys:
      - ${primary_ssh_key}

package_update: true
package_upgrade: true
ssh_pwauth: false
disable_root: true
packages:
  - fail2ban
  - ufw
  - git
  - ca-certificates
  - curl
  - age
  - iptables
  - python3
  - openssl
  - unattended-upgrades

write_files:
  # OpenSearch refuses to start below this.
  - path: /etc/sysctl.d/90-opensearch.conf
    owner: root:root
    permissions: '0644'
    content: |
      vm.max_map_count=262144

  - path: /etc/apt/apt.conf.d/20auto-upgrades
    owner: root:root
    permissions: '0644'
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";

  - path: /usr/local/bin/gb-clone-or-pull.sh
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      REPO_URL="https://github.com/ssherman/the-greatest.git"
      APP_DIR="$HOME/apps/the-greatest"  # $HOME == /home/deploy when run as -u deploy -H

      mkdir -p "$APP_DIR"
      if [ -d "$APP_DIR/.git" ]; then
        git -C "$APP_DIR" fetch --prune --tags
        git -C "$APP_DIR" reset --hard origin/HEAD
      else
        git clone --depth=1 "$REPO_URL" "$APP_DIR"
      fi

runcmd:
  - sysctl --system
  # SSH only. Docker-published ports bypass ufw; 9200 is handled by opensearch-firewall.service.
  - ufw default deny incoming && ufw allow OpenSSH && ufw --force enable
  - systemctl enable --now fail2ban

  # Clone as deploy (retry in case the network is not ready yet).
  - install -d -o deploy -g deploy /home/deploy/apps
  - bash -lc 'for i in 1 2 3; do sudo -u deploy -H /usr/local/bin/gb-clone-or-pull.sh && break || sleep 5; done'

  # Close 9200 before Docker exists: with no allowlist yet, the unit drops every connection.
  - /home/deploy/apps/the-greatest/deployment/opensearch/bin/install-firewall.sh

  # Docker from Docker's own repository.
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$${UBUNTU_CODENAME:-$$VERSION_CODENAME}\") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - usermod -aG docker deploy

  # SOPS, same version as the web server.
  - curl -LO https://github.com/getsops/sops/releases/download/v3.11.0/sops-v3.11.0.linux.amd64
  - mv sops-v3.11.0.linux.amd64 /usr/local/bin/sops
  - chmod +x /usr/local/bin/sops

  - install -d -m 0750 -o root -g root /srv/opensearch
  - chown -R deploy:deploy /home/deploy/apps
```

- [ ] **Step 2: Validate Terraform**

```bash
terraform -chdir=deployment/terraform/opensearch init -backend=false
terraform -chdir=deployment/terraform/opensearch fmt -check
terraform -chdir=deployment/terraform/opensearch validate
```

Expected: `Success! The configuration is valid.` and `fmt -check` prints nothing. `init` writes
`.terraform.lock.hcl` (committed, like the web module's) and `.terraform/` (gitignored).

- [ ] **Step 3: Validate cloud-init**

Render the template with a dummy key and run cloud-init's own schema check in a throwaway container:

```bash
scratch="$(mktemp -d)"
sed -e 's|\${primary_ssh_key}|ssh-ed25519 AAAAdummy test|' -e 's|\$\$|$|g' \
  deployment/terraform/opensearch/cloud-init.yaml >"$scratch/user-data.yaml"
docker run --rm -v "$scratch:/c:ro" ubuntu:26.04 bash -c \
  'apt-get update -qq >/dev/null && apt-get install -y -qq cloud-init >/dev/null && cloud-init schema -c /c/user-data.yaml'
rm -rf "$scratch"
```

Expected: `Valid schema user-data`. (If the `ubuntu:26.04` tag is unavailable, use `ubuntu:24.04`; the schema check is
the same.)

- [ ] **Step 4: Commit**

```bash
git add deployment/terraform/opensearch/main.tf deployment/terraform/opensearch/variables.tf \
  deployment/terraform/opensearch/cloud-init.yaml deployment/terraform/opensearch/terraform.tfvars.example \
  deployment/terraform/opensearch/.terraform.lock.hcl
git status --short deployment/terraform/opensearch   # must show nothing else (no tfstate, no tfvars)
git commit -m "OpenSearch server: Terraform module and cloud-init (Ubuntu 26.04, port closed before Docker)"
```

---

### Task 8: Lockdown verify script

**Files:**
- Create: `deployment/scripts/verify-opensearch-lockdown.sh`
- Test: `deployment/opensearch/test/verify-lockdown_test.sh`

**Interfaces:**
- Produces: `verify-opensearch-lockdown.sh --outside` (env `SEARCH_IPV4`, `SEARCH_IPV6`) and `--inside` (env
  `SEARCH_IPV4`, `OPENSEARCH_APP_PASSWORD`, `OPENSEARCH_LEGACY_PASSWORD`). Exit 0 only if every check passes.

- [ ] **Step 1: Write the failing test**

`deployment/opensearch/test/verify-lockdown_test.sh`:

```bash
#!/usr/bin/env bash
# Unit test for deployment/scripts/verify-opensearch-lockdown.sh; curl is stubbed.
# shellcheck disable=SC2016  # stub bodies and bcrypt strings are single-quoted on purpose
set -uo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
verify="$OS_DIR/../scripts/verify-opensearch-lockdown.sh"
export SEARCH_IPV4=203.0.113.50 SEARCH_IPV6=2001:db8::50

new_sandbox
stub curl 'printf 000; exit 28'
"$verify" --outside >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then pass "--outside: timeouts everywhere pass"; else fail "--outside: timeouts pass" "rc=$rc"; fi
if called '\[2001:db8::50\]:9200'; then pass "--outside probes IPv6"; else fail "--outside probes IPv6" "$(cat "$CALLS")"; fi

new_sandbox
stub curl 'printf 401; exit 0'
"$verify" --outside >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ]; then pass "--outside: an answer from the server fails"; else fail "--outside: an answer fails" "rc=$rc"; fi

new_sandbox
stub curl 'printf 000; exit 28'
SEARCH_IPV6="" "$verify" --outside >/dev/null 2>&1; rc=$?
if [ "$rc" != 0 ]; then pass "--outside without SEARCH_IPV6 is refused"; else fail "--outside without SEARCH_IPV6" "rc=0"; fi

new_sandbox
# Answers by path: the right code for each inside check.
stub curl 'for a in "$@"; do last="$a"; done
case "$last" in
  */_cluster/health) printf 200 ;;
  */books_books_production/_count) case "$*" in *legacy*) printf 403 ;; *) printf 404 ;; esac ;;
  */books/_count) case "$*" in *legacy*) printf 200 ;; *) printf 403 ;; esac ;;
  */_plugins/_security/api/internalusers) printf 403 ;;
  *) printf 401 ;;
esac'
OPENSEARCH_APP_PASSWORD=apppw OPENSEARCH_LEGACY_PASSWORD=legacypw "$verify" --inside >"$SANDBOX/log/out" 2>&1; rc=$?
if [ "$rc" = 0 ]; then pass "--inside: correct answers pass"; else fail "--inside: correct answers pass" "$(cat "$SANDBOX/log/out")"; fi
if ! called 'apppw|legacypw'; then pass "--inside keeps passwords off the curl command line"; else fail "passwords on the command line" "$(cat "$CALLS")"; fi

if ! "$verify" >/dev/null 2>&1; then pass "no mode is refused"; else fail "no mode is refused" "exit 0"; fi
finish
```

The `--inside` stub tells the two logins apart by a marker the script puts in each netrc file name (see Step 3), never
by the password.

```bash
chmod +x deployment/opensearch/test/verify-lockdown_test.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `deployment/opensearch/test/verify-lockdown_test.sh`
Expected: FAILs.

- [ ] **Step 3: Write the script**

`deployment/scripts/verify-opensearch-lockdown.sh`:

```bash
#!/usr/bin/env bash
# Checks that the search server is locked down (spec §8.3). Run both modes after every build or rebuild.
#
#   --outside   from a machine that is NOT an app server (a laptop): nothing may even connect.
#                 SEARCH_IPV4=... SEARCH_IPV6=... deployment/scripts/verify-opensearch-lockdown.sh --outside
#   --inside    from the new app server: both logins work over HTTPS, each is refused on the other
#               site's indexes and on the security API, and a request without a login is refused.
#                 SEARCH_IPV4=... OPENSEARCH_APP_PASSWORD=... OPENSEARCH_LEGACY_PASSWORD=... \
#                   deployment/scripts/verify-opensearch-lockdown.sh --inside
#
# Outside, a pass is curl exit 7 (refused) or 28 (timed out: the DOCKER-USER drop). Any HTTP answer
# at all, even 401, is a failure: it means the firewall let the connection through. Passwords go to
# curl through a netrc file, never its command line.
set -uo pipefail
mode="${1:-}"
failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1 -- $2"; failures=$((failures + 1)); }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

no_connection() {   # no_connection NAME URL
  local code rc
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$2")"; rc=$?
  case "$rc" in
    7|28) pass "$1 (curl exit $rc: no connection)" ;;
    *) fail "$1" "curl exit $rc, http $code -- the search server answered" ;;
  esac
}

status() {   # status NAME WANT_REGEX LOGIN(app|legacy|none) PATH
  local name="$1" want="$2" login="$3" path="$4" auth=() code
  case "$login" in
    app) auth=(--netrc-file "$work/netrc-app") ;;
    legacy) auth=(--netrc-file "$work/netrc-legacy") ;;
  esac
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "${auth[@]}" "https://$SEARCH_IPV4:9200$path")"
  if [[ "$code" =~ ^($want)$ ]]; then pass "$name (http $code)"; else fail "$name" "http $code, wanted $want"; fi
}

case "$mode" in
  --outside)
    : "${SEARCH_IPV4:?set SEARCH_IPV4}" "${SEARCH_IPV6:?set SEARCH_IPV6 -- the server has one, and it must be probed}"
    no_connection "IPv4 :9200" "https://$SEARCH_IPV4:9200/"
    no_connection "IPv6 :9200" "https://[$SEARCH_IPV6]:9200/"
    no_connection "IPv4 :9300 (transport, never published)" "https://$SEARCH_IPV4:9300/"
    ;;
  --inside)
    : "${SEARCH_IPV4:?}" "${OPENSEARCH_APP_PASSWORD:?}" "${OPENSEARCH_LEGACY_PASSWORD:?}"
    (umask 077
      printf 'machine %s login the_greatest_app password %s\n' "$SEARCH_IPV4" "$OPENSEARCH_APP_PASSWORD" >"$work/netrc-app"
      printf 'machine %s login tgb_legacy password %s\n' "$SEARCH_IPV4" "$OPENSEARCH_LEGACY_PASSWORD" >"$work/netrc-legacy")
    status "no login is refused" 401 none /
    status "app: cluster health" 200 app /_cluster/health
    status "app: its own index (404 until the first reindex)" '200|404' app /books_books_production/_count
    status "app: refused on the old site's index" 403 app /books/_count
    status "app: refused on the security API" 403 app /_plugins/_security/api/internalusers
    status "legacy: its own index (404 until the first reindex)" '200|404' legacy /books/_count
    status "legacy: refused on the new app's index" 403 legacy /books_books_production/_count
    ;;
  *) echo "usage: verify-opensearch-lockdown.sh --outside|--inside (see the header)" >&2; exit 2 ;;
esac
if [ "$failures" = 0 ]; then echo "all passed"; else echo "$failures failed"; exit 1; fi
```

```bash
chmod +x deployment/scripts/verify-opensearch-lockdown.sh
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `deployment/opensearch/test/run.sh`
Expected: shellcheck clean (the verify script is in `run.sh`'s file list), every test file `all passed`.

- [ ] **Step 5: Commit**

```bash
git add deployment/scripts/verify-opensearch-lockdown.sh deployment/opensearch/test/verify-lockdown_test.sh
git commit -m "OpenSearch server: lockdown verify script (outside: no connection on v4/v6; inside: logins)"
```

---

### Task 9: Deploy workflow and secrets

**Files:**
- Create: `.github/workflows/deploy-opensearch.yml`
- Modify: `.sops.yaml`
- Create: `secrets/.env.opensearch` (SOPS-encrypted)

**Interfaces:**
- Consumes: `deploy.sh ENV_FILE` (Task 6).
- Produces: GitHub secrets the operator must add after the server exists: `OPENSEARCH_SSH_HOST`,
  `OPENSEARCH_SSH_HOST_FINGERPRINT`. Reuses `DEPLOY_SSH_KEY` and `AGE_PRIVATE_KEY`.

- [ ] **Step 1: Write the workflow**

`.github/workflows/deploy-opensearch.yml`:

```yaml
name: Deploy OpenSearch

# Manual only. Merging to main deploys the web app; it must never restart search.
# Runbook: docs/features/opensearch-server.md.
on:
  workflow_dispatch:

# The job reaches the server over SSH only and never uses GITHUB_TOKEN.
permissions: {}

concurrency:
  group: deploy-opensearch
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      # An unset secret renders as "" and the SSH action would skip the host-key check silently.
      - name: Require the host and its host-key fingerprint
        env:
          HOST: ${{ secrets.OPENSEARCH_SSH_HOST }}
          FINGERPRINT: ${{ secrets.OPENSEARCH_SSH_HOST_FINGERPRINT }}
        run: |
          test -n "$HOST" || { echo "::error::OPENSEARCH_SSH_HOST is not set"; exit 1; }
          test -n "$FINGERPRINT" || { echo "::error::OPENSEARCH_SSH_HOST_FINGERPRINT is not set"; exit 1; }

      - name: Deploy OpenSearch
        # Same pinned commit as deploy-production.yml.
        uses: appleboy/ssh-action@c4f70287fc37c43b14b30b407224bbbc8e8c6327
        env:
          AGE_PRIVATE_KEY: ${{ secrets.AGE_PRIVATE_KEY }}
        with:
          host: ${{ secrets.OPENSEARCH_SSH_HOST }}
          username: deploy
          key: ${{ secrets.DEPLOY_SSH_KEY }}
          # SHA256 fingerprint of the server's ECDSA host key. A rebuild changes it: update the
          # secret (docs/features/opensearch-server.md, "Rebuild").
          fingerprint: ${{ secrets.OPENSEARCH_SSH_HOST_FINGERPRINT }}
          envs: AGE_PRIVATE_KEY
          script: |
            set -e
            cd /home/deploy/apps/the-greatest
            git pull --ff-only
            env_file="$(mktemp)"
            trap 'rm -f "$env_file"' EXIT
            # sops reads the age key from the environment, so the key is never written to disk.
            (umask 077; SOPS_AGE_KEY="$AGE_PRIVATE_KEY" sops -d secrets/.env.opensearch > "$env_file")
            unset AGE_PRIVATE_KEY
            deployment/opensearch/bin/deploy.sh "$env_file"
```

- [ ] **Step 2: Add the SOPS creation rule**

In `.sops.yaml`, after the `secrets/home-server\.env$` rule, add (same age recipient as the others):

```yaml
  - path_regex: secrets/\.env\.opensearch$
    age: age1dnc82r63zyqtqlet84l2naxhjrdcdrc3gaxp592y69u0pg0m2u3q9j02zf
```

- [ ] **Step 3: Ask Shane for the allowlist and the old server's index list**

Stop and ask Shane (controller session, not a subagent) for:
1. The IPv4 addresses of every server that must reach search: the new app server, and the old site's web/worker server
   (the app host listed in the old Postgres `pg_hba.conf` is a likely candidate; confirm it). Do not guess.
2. The old server's full index list (spec §11), from its own shell: `curl -s 'localhost:9200/_cat/indices?h=index'`.
   If it shows site indexes other than `books` and `authors`, add them to `tgb_legacy`'s `index_patterns` in
   `deployment/opensearch/security/roles.yml` and to the matching assertion in `render-security_test.sh`, re-run
   `deployment/opensearch/test/run.sh`, and commit that change separately.

- [ ] **Step 4: Create the encrypted secrets file**

Encrypt from a scratch file so the plain text never sits in the repo directory:

```bash
scratch="$(mktemp -d)"
cat >"$scratch/plain.env" <<EOF
# Spec: docs/superpowers/specs/2026-10-13-opensearch-server-design.md §5. Runbook: docs/features/opensearch-server.md.
# Comma-separated, no spaces: deploy.sh sources this file, and an unquoted space would run the rest as a command.
OPENSEARCH_ALLOWED_IPS=<new app server IPv4>,<old site server IPv4>
OPENSEARCH_ADMIN_PASSWORD=$(openssl rand -hex 32)
OPENSEARCH_APP_PASSWORD=$(openssl rand -hex 32)
OPENSEARCH_LEGACY_PASSWORD=$(openssl rand -hex 32)
EOF
# Replace the two <...> with the addresses from Step 3 (edit $scratch/plain.env), then:
sops --encrypt --input-type dotenv --output-type dotenv --filename-override secrets/.env.opensearch \
  "$scratch/plain.env" > secrets/.env.opensearch
rm -rf "$scratch"
sops -d secrets/.env.opensearch | sed 's/=.*/=…/'    # shows the four keys, values hidden
```

Expected: the last command lists exactly the four keys. `git diff --stat` shows `secrets/.env.opensearch` with
`ENC[...]` values only (`grep -c 'ENC\[' secrets/.env.opensearch` → 4).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/deploy-opensearch.yml .sops.yaml secrets/.env.opensearch
git commit -m "OpenSearch server: manual deploy workflow and SOPS secrets"
```

---

### Task 10: New app client switch

**Files:**
- Modify: `web-app/app/lib/search/shared/client.rb`
- Test: `web-app/test/lib/search/shared/client_test.rb`

**Interfaces:**
- Produces: env `OPENSEARCH_SSL_VERIFY`. Exactly `"false"` turns certificate verification off; anything else, or
  unset, keeps Faraday's default (on).

- [ ] **Step 1: Write the failing tests**

Add to `web-app/test/lib/search/shared/client_test.rb`, inside `ClientTest`, after the existing test:

```ruby
      test "instance skips certificate verification when OPENSEARCH_SSL_VERIFY is false" do
        with_env("OPENSEARCH_SSL_VERIFY" => "false") do
          Search::Shared::Client.reset!

          refute ssl_options.verify?
        end
      end

      test "instance verifies certificates when OPENSEARCH_SSL_VERIFY is unset" do
        with_env("OPENSEARCH_SSL_VERIFY" => nil) do
          Search::Shared::Client.reset!

          assert ssl_options.verify?
        end
      end

      test "instance verifies certificates for any value other than false" do
        with_env("OPENSEARCH_SSL_VERIFY" => "no") do
          Search::Shared::Client.reset!

          assert ssl_options.verify?
        end
      end

      private

      # opensearch-ruby 3.4: Client -> Transport::Client -> HTTP::Faraday -> Connection -> Faraday::Connection.
      def ssl_options
        Search::Shared::Client.instance.transport.transport.connections.first.connection.ssl
      end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd web-app && bin/rails test test/lib/search/shared/client_test.rb`
Expected: the "skips certificate verification" test FAILs (`Expected true to not be truthy`); the other two pass.

- [ ] **Step 3: Implement**

In `web-app/app/lib/search/shared/client.rb`, change the client construction and add a private method:

```ruby
            OpenSearch::Client.new(
              host: ENV.fetch("OPENSEARCH_URL"),
              serializer_class: Search::Shared::Serializer,
              transport_options: transport_options
            )
```

```ruby
        # The production search server presents a certificate it generated for itself
        # (docs/features/opensearch-server.md), so there is no CA to check it against. The
        # firewall and the per-app login keep others out; TLS here only stops eavesdropping.
        def transport_options
          return {} unless ENV["OPENSEARCH_SSL_VERIFY"] == "false"

          {ssl: {verify: false}}
        end
```

Place `transport_options` under the existing `private`, above `configure_bulk_serializer!`.

- [ ] **Step 4: Run the tests and lint**

```bash
cd web-app && bin/rails test test/lib/search/shared/client_test.rb && bundle exec standardrb app/lib/search/shared/client.rb test/lib/search/shared/client_test.rb
```

Expected: 4 runs, 0 failures; standardrb prints nothing.

- [ ] **Step 5: Run the whole suite**

Run: `cd web-app && bin/rails test`
Expected: 0 failures, 0 errors, and no new warning lines.

- [ ] **Step 6: Commit**

```bash
git add web-app/app/lib/search/shared/client.rb web-app/test/lib/search/shared/client_test.rb
git commit -m "Search client: OPENSEARCH_SSL_VERIFY=false for the search server's self-made certificate"
```

---

### Task 11: Documentation

**Files:**
- Create: `docs/features/opensearch-server.md`
- Modify: `deployment/ENV.md` (OpenSearch section), `deployment/README.md` (External Services), `.env.example`

- [ ] **Step 1: Write the runbook**

`docs/features/opensearch-server.md` — write these sections, each with the exact commands from this plan:

1. **What it is** — one Linode (Ubuntu 26.04, Linode 8 GB, `us-central`) running OpenSearch `<tag>` from
   `deployment/opensearch/compose.yml`; who uses it (`the_greatest_app`, `tgb_legacy`); no backups, the reindex is the
   recovery; the three security layers in three sentences, linking the spec.
2. **Files** — the file tree from this plan's "File structure", one line each.
3. **Build** — copy `terraform.tfvars.example` to `terraform.tfvars`, `terraform -chdir=deployment/terraform/opensearch
   init` / `apply`; read `ipv4`/`ipv6` from `terraform output`; wait for cloud-init
   (`ssh deploy@<ipv4> cloud-init status --wait`); get the host-key fingerprint with
   `ssh-keyscan -t ecdsa <ipv4> 2>/dev/null | ssh-keygen -lf - | awk '{print $2}'`; set GitHub secrets
   `OPENSEARCH_SSH_HOST` and `OPENSEARCH_SSH_HOST_FINGERPRINT` (`gh secret set ...`).
4. **Deploy** — Actions → "Deploy OpenSearch" → Run workflow (or `gh workflow run deploy-opensearch.yml`). What
   `deploy.sh` does, in its five steps; that an unchanged redeploy restarts nothing.
5. **Verify** — both modes of `verify-opensearch-lockdown.sh`, from where, with which env; the reboot probe
   (`while :; do curl -sk -m 2 -o /dev/null -w '%{http_code} ' https://<ipv4>:9200/; sleep 1; done` from a laptop
   while `ssh deploy@<ipv4> sudo reboot` — every value must be `000`).
6. **Add or remove an app server** — `sops secrets/.env.opensearch`, edit `OPENSEARCH_ALLOWED_IPS` (comma-separated, no spaces), commit, merge, run
   the workflow. Bad entries fail the deploy and leave the running allowlist alone.
7. **Rotate a password** — edit it in SOPS (`openssl rand -hex 32`), run the workflow, then update `OPENSEARCH_URL` for
   that app and deploy it.
8. **Upgrade OpenSearch** — change the tag in `compose.yml`, run `deployment/opensearch/test/local-e2e-test.sh`, merge,
   run the workflow (the new tag recreates the container; search is down about a minute).
9. **Rebuild** — `terraform -chdir=deployment/terraform/opensearch apply -replace=linode_instance.search`, update both
   GitHub secrets (new IP if it changed, always a new fingerprint), update `OPENSEARCH_URL` in both apps if the IP
   changed, run the workflow, verify, reindex both sites.
10. **Switchover from the old server (once)** — the Operational section's steps O4–O7, verbatim.
11. **Gotchas** — Docker bypasses ufw (why `DOCKER-USER`); never publish a bare `9200:9200` (IPv6 docker-proxy);
    never `systemctl restart opensearch-firewall` (restarts Docker); `opensearch.yml` and certificate changes need the
    fingerprint-triggered recreate, which `deploy.sh` does.

- [ ] **Step 2: Update ENV.md, README and .env.example**

In `deployment/ENV.md`, replace the `OPENSEARCH_URL` entry and add one after it:

```markdown
#### OPENSEARCH_URL
- **Description**: The search server, with this app's login in the URL. Production:
  `https://the_greatest_app:<OPENSEARCH_APP_PASSWORD>@<search server IPv4>:9200` (the password is in
  `secrets/.env.opensearch`). Development: `http://localhost:9200`.
- **Required**: Yes
- **Used By**: web, worker
- **Runbook**: `docs/features/opensearch-server.md`

#### OPENSEARCH_SSL_VERIFY
- **Description**: Set to `false` in production: the search server presents a certificate it generated
  itself, so there is no CA to verify it against. Any other value, or unset, verifies normally.
- **Required**: Production only
- **Example**: `false`
- **Used By**: web, worker
```

In `deployment/ENV.md`'s example block, change `OPENSEARCH_URL=https://opensearch.example.com:9200` to
`OPENSEARCH_URL=https://the_greatest_app:your_app_password@203.0.113.50:9200` and add `OPENSEARCH_SSL_VERIFY=false`
below it.

In `deployment/README.md`, change the "External Services" line to:
`- **External Services**: PostgreSQL (hosted separately) and OpenSearch (its own server: docs/features/opensearch-server.md)`.

In `.env.example`, next to `OPENSEARCH_URL`, add:

```
# Production only: the search server's certificate is self-made (docs/features/opensearch-server.md)
# OPENSEARCH_SSL_VERIFY=false
```

- [ ] **Step 3: Check no secret or real IP slipped in**

```bash
{ cat docs/features/opensearch-server.md; git diff -- deployment/ENV.md deployment/README.md .env.example; } \
  | grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -vE '203\.0\.113\.|127\.0\.0\.1' || echo "no real IPs"
```

Expected: `no real IPs` (only the 203.0.113.x documentation range appears).

- [ ] **Step 4: Commit**

```bash
git add docs/features/opensearch-server.md deployment/ENV.md deployment/README.md .env.example
git commit -m "Docs: OpenSearch server runbook, OPENSEARCH_URL/OPENSEARCH_SSL_VERIFY"
```

---

### Task 12: Old site client switch (the-greatest-books repo)

The old site is shutting down at launch, so this is the smallest change that lets it talk to the new server. Its own
branch in its own repo; do not push.

**Files:**
- Modify: `/home/shane/dev/the-greatest-books/admin/app/lib/search/books_index.rb:5-7`,
  `/home/shane/dev/the-greatest-books/admin/app/lib/search/authors_index.rb:5-7`

- [ ] **Step 1: Branch**

```bash
git -C /home/shane/dev/the-greatest-books status --short   # must be clean; if not, stop and ask Shane
git -C /home/shane/dev/the-greatest-books switch -c opensearch-server-client
```

- [ ] **Step 2: Change both clients**

In each of the two files, replace the `client` method with:

```ruby
    def self.client
      # The new search server's certificate is self-made, so production sets OPENSEARCH_SSL_VERIFY=false
      # (the-greatest repo, docs/features/opensearch-server.md). The login travels in OPENSEARCH_URL.
      @client ||= OpenSearch::Client.new(
        host: ENV.fetch("OPENSEARCH_URL"),
        transport_options: (ENV["OPENSEARCH_SSL_VERIFY"] == "false") ? {ssl: {verify: false}} : {}
      )
    end
```

- [ ] **Step 3: Check it loads and both settings behave**

```bash
cd /home/shane/dev/the-greatest-books/admin && OPENSEARCH_URL=https://tgb_legacy:x@203.0.113.50:9200 OPENSEARCH_SSL_VERIFY=false \
  bundle exec ruby -e 'require "opensearch"; load "app/lib/search/books_index.rb"; load "app/lib/search/authors_index.rb";
  [Search::BooksIndex, Search::AuthorsIndex].each { |k| c = k.client.transport.transport.connections.first; p [k, c.connection.ssl.verify?, c.host[:user]] }'
```

Expected: `[Search::BooksIndex, false, "tgb_legacy"]` and `[Search::AuthorsIndex, false, "tgb_legacy"]`. Re-run without
`OPENSEARCH_SSL_VERIFY=false`: both print `true`.

- [ ] **Step 4: Run the old site's tests for these files, if any exist**

```bash
cd /home/shane/dev/the-greatest-books/admin && ls test/lib/search 2>/dev/null && bin/rails test test/lib/search || echo "no search tests"
```

Expected: pass, or `no search tests`.

- [ ] **Step 5: Commit (old repo, not pushed)**

```bash
git -C /home/shane/dev/the-greatest-books add admin/app/lib/search/books_index.rb admin/app/lib/search/authors_index.rb
git -C /home/shane/dev/the-greatest-books commit -m "Search: OPENSEARCH_SSL_VERIFY=false for the new search server's self-made certificate"
```

---

## Operational (Shane runs these; the controller session assists — never a subagent)

Prerequisite: Tasks 1-12 MERGED to `main` before O1, because cloud-init clones `main` and runs the firewall installer from it (an unmerged branch silently skips the boot firewall unit). **The server's checkout tracks
`main`** (`git pull --ff-only` in the workflow), so merge the branch before O2 — merging changes nothing for the web app
except the client switch, which is inert until `OPENSEARCH_SSL_VERIFY=false` is set.

- [ ] **O1. Build.** Follow the runbook's "Build": `terraform apply`, wait for cloud-init, set the two GitHub secrets.
- [ ] **O2. Deploy and verify.** Run the workflow. Then from a laptop: `verify-opensearch-lockdown.sh --outside`; from
  the new app server: `--inside` (passwords from `sops -d secrets/.env.opensearch`). Both `all passed`.
- [ ] **O3. Prove the rebuild and the reboot (spec §2).** Reboot probe from the runbook (every value `000`). Then
  `terraform apply -replace=linode_instance.search`, update the fingerprint secret (and host if the IP changed), run the
  workflow, run both verify modes again. No SSH fixes in between; anything that needed one is a bug to fix in the code
  first.
- [ ] **O4. Old site first.** Deploy the old repo's `opensearch-server-client` branch. On the old site's server, run its
  reindex once with `OPENSEARCH_URL=https://tgb_legacy:<pw>@<ipv4>:9200 OPENSEARCH_SSL_VERIFY=false` set for that one
  command only, while the live site still uses the old server. When it finishes, set both variables in the old site's
  environment and redeploy it. Check a search on the old site.
- [ ] **O5. New app.** In `secrets/.env.production` (`sops secrets/.env.production`), set
  `OPENSEARCH_URL=https://the_greatest_app:<pw>@<ipv4>:9200` and `OPENSEARCH_SSL_VERIFY=false`; merge (merging deploys).
  Then on the web server: `docker compose -f docker-compose.prod.yml exec web bin/rails search:books:recreate_and_reindex_all`,
  then `search:music:recreate_and_reindex_all`, then `search:games:recreate_and_reindex_all`. Check a search on each site.
- [ ] **O6. Soak** a day or two. Rollback until O7 is setting `OPENSEARCH_URL` back to the old server.
- [ ] **O7. Retire the old server.** Delete the old Linode (the 2023 "opensearch" one) in the Linode dashboard; delete
  `the-greatest-books/opensearch/`. **Do not deactivate the AWS access key hardcoded in its Dockerfile**: the
  Postgres nightly backup still uses it (Shane, 2026-10-13); it is retired with the Postgres server rebuild.
