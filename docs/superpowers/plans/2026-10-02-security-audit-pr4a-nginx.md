# Security audit PR 4a: nginx — remove the bot blocker, pin the base image — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop running `nginx-ultimate-bad-bot-blocker` from upstream `master` in the TLS-terminating container, pin nginx to the stable line, and keep the per-visitor rate limits as our own two-line config.

**Architecture:** The nginx image no longer downloads or installs the blocker, and the site template no longer includes its `bots.d` files. `FROM nginx:latest` becomes `FROM nginx:1.30`, the current stable line. The deploy runs `build --pull --no-cache nginx` so patch releases inside 1.30 still arrive. The blocker's `ddos.conf` rate limits only started working on 2026-10-02, when origin-lockdown's `real_ip` made them per-visitor. They move into `nginx.conf` with the same values, as a separate task that can be dropped on its own.

**Tech Stack:** nginx 1.30 (official Debian image), Docker / Compose, GitHub Actions, bash test harness (`deployment/nginx/test/local-lockdown-test.sh`).

**Spec:** `docs/superpowers/specs/2026-10-01-security-audit-fixes-design.md`, section "PR 4a — nginx: remove the bot blocker, pin the base image". Origin-lockdown context: `docs/superpowers/specs/2026-09-14-origin-lockdown-design.md`.

**Branch / worktree:** `security-audit-pr4a-nginx` in `/home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes`. It was cut from `origin/main` at `f5e69a3e` (origin-lockdown merged, Checkpoint A passed, Checkpoint B applied 2026-10-02). It has no upstream branch until its first push.

## Global Constraints

- **Merging to `main` deploys to production.** The deploy rebuilds nginx. No task pushes, opens a PR, runs a workflow or touches the server. Task 3 lists the steps for Shane.
- Base image: `FROM nginx:1.30`. Resolved 2026-10-02: Docker Hub's `stable`, `1.30` and `1.30.5` share digest `sha256:b972f831f200…`, and `latest` is the 1.31 mainline. Use a tag, not a digest, because nothing would update a digest until Dependabot exists.
- Deploy build line: `docker compose -f docker-compose.prod.yml build --pull --no-cache nginx`. Keep `--no-cache`, because origin-lockdown's generator fetches Cloudflare's IP ranges at build and relies on it to refresh them.
- Do not change origin-lockdown's behaviour:
  - `real_ip` and `geo` snippets, `cloudflare-only.conf`, `ssl_reject_handshake`, the 444 default servers, `ssl_verify_client optional`, and the log format all stay as they are.
  - Task 7 of origin-lockdown (switching AOP to `on`) is a separate PR.
- **No Cloudflare changes.** Shane manages Cloudflare with his own tool.
- Rate-limit values carried over from upstream `bots.d/ddos.conf` and `conf.d/botblocker-nginx-settings.conf` (fetched 2026-10-02): `limit_req_zone $binary_remote_addr zone=flood:50m rate=90r/s;`, `limit_conn_zone $binary_remote_addr zone=addr:50m;`, `limit_conn addr 200;`, `limit_req zone=flood burst=200 nodelay;`.
- Docker: use only the image tags, container names and ports that the harness and these steps name. Never stop or recreate the running dev containers (`data-sources-api-1`, `the-greatest-db-1`, `redis-dev`, `opensearch-dev`).
- Git: always `git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes …`; a session guard refuses `cd <dir> && git …`. Every commit message ends with the line `<Co-Authored-By trailer>`. Replace it with the exact `Co-Authored-By:` line your harness gives you.
- The repo is public. Commit messages describe the change.

## Review Focus

These are failure modes the spec implies that no Rails test covers, most likely first. Each one is pinned by a step in the task named.

1. **The template still references `bots.d`** after the files are gone. nginx then fails to start at container start (the template renders at runtime, so `nginx -t` at build does not see it), and the site goes down on deploy. → Task 1, Step 4 runs the local harness, which renders the real template and starts nginx.
2. **Hash sizes.** The blocker's settings file raised `server_names_hash_bucket_size` and `variables_hash_*`. Without it, nginx's defaults must still hold our server names and the geo/real_ip variables. → Task 1, Step 4 (the harness starts the rendered config) and Step 3 (`nginx -t` at build).
3. **Origin-lockdown regressions from the image change** (1.31 mainline → 1.30 stable). Every lockdown probe must behave as before. → Task 1, Step 4: all of harness runs A and B pass.
4. **Rate limits keyed on the Cloudflare edge instead of the visitor.** One busy visitor must hit the limit while a second visitor behind the same peer is unaffected. → Task 2, Step 1 adds harness probe B8.
5. **The healthcheck must not be rate-limited or broken.** → Harness probe A7, which runs in both tasks.

---

### Task 1: Remove the bot blocker, pin nginx 1.30, pull on deploy

**Files:**
- Modify: `deployment/nginx/Dockerfile`: line 1; line 3 (drop `wget`); lines 10–15 (delete)
- Modify: `deployment/nginx/the-greatest.conf.template`: delete the 8 `include /etc/nginx/bots.d/…` lines (64–65, 107–108, 150–151, 179–180)
- Modify: `deployment/nginx/nginx.conf`: lines 53–54
- Modify: `.github/workflows/deploy-production.yml`: the `build --no-cache nginx` line
- Modify (docs/comments): `deployment/README.md:90` and `:280`; `deployment/nginx/bin/generate-cloudflare-snippets.sh:6`; `deployment/nginx/test/local-lockdown-test.sh:82-85`

**Interfaces:** Produces an image with no `/etc/nginx/bots.d`, no `install-ngxblocker`, and nothing in `/etc/nginx/conf.d/`. Task 2 builds on this `nginx.conf`.

Facts already checked:
- **Nothing else uses the blocker.** The template does not reference any blocker variable (`$bad_bot`, `$validate_client`, …), so removing the includes leaves no dangling variables.
- **`wget` was only for the blocker.** The generator and the harness use `curl` and `jq`.
- **`conf.d/` was only the blocker's.** The Dockerfile already deletes the stock `conf.d/default.conf`. The compose file renders the site template into `sites-enabled/` (`NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx/sites-enabled`). Nothing from origin-lockdown lives in `conf.d/`, which only ever held the blocker's files. So the `include /etc/nginx/conf.d/*.conf;` line goes too. This matches the Dockerfile's "our servers are the only servers".

- [ ] **Step 1: Baseline.** Run the harness on the unmodified branch and record the result:

```bash
/home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/deployment/nginx/test/local-lockdown-test.sh 2>&1 | tail -25
```

Expected: `all lockdown probes passed`. If it fails on unmodified `main`, STOP and report it, because that is a pre-existing break. Also run the generator's unit test, `deployment/nginx/test/generate-cloudflare-snippets_test.sh`, and record its result.

- [ ] **Step 2: Edit the files.**

`deployment/nginx/Dockerfile`:
- Line 1 becomes `FROM nginx:1.30`. Add this comment directly above it:
  ```dockerfile
  # The stable line, not :latest (mainline). The deploy builds with --pull, so 1.30.x patch
  # releases still arrive; move to the next stable line deliberately.
  ```
- Line 3 becomes `RUN apt-get update && apt-get install -y --no-install-recommends curl jq ca-certificates`. That drops `wget`.
- Delete lines 10–15: the two bot-blocker comment lines and the four `RUN` lines for `wget`, `chmod`, `install-ngxblocker` and `setup-ngxblocker`.

`deployment/nginx/the-greatest.conf.template`: delete all eight lines matching `include /etc/nginx/bots.d/blockbots.conf;` or `include /etc/nginx/bots.d/ddos.conf;`. Change nothing else.

`deployment/nginx/nginx.conf`: delete lines 53–54 (`# Include bot blocker configuration …` and `include /etc/nginx/conf.d/*.conf;`).

`.github/workflows/deploy-production.yml`: change `docker compose -f docker-compose.prod.yml build --no-cache nginx` to `docker compose -f docker-compose.prod.yml build --pull --no-cache nginx`.

Docs and comments:
- `deployment/README.md:90`: `- **Build**: Custom image with bad-bot-blocker` → `- **Build**: Custom image on nginx 1.30 (stable), rebuilt with --pull --no-cache on every deploy`.
- `deployment/README.md:280`: in "nginx's `$remote_addr`, the access log, the bot-blocker's per-IP limits, and Rails' `request.remote_ip`", replace "the bot-blocker's per-IP limits" with "the per-visitor rate limits". Task 2 adds those limits. If Task 2 is dropped, say "the access log and Rails' `request.remote_ip`" instead.
- `deployment/nginx/bin/generate-cloudflare-snippets.sh:6`: make the same replacement in the comment.
- `deployment/nginx/test/local-lockdown-test.sh:82-85`: the comment says the bot-blocker's config is huge and slow to load. Reword it to give the actual reason for probing from inside the container: docker-proxy accepts the TCP connection before nginx is ready, so a host-side probe can be reset mid-handshake. Keep the remaining sentences about exit codes 7/52/35. Change no code in the harness.

Then confirm nothing still refers to the blocker:

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes && git grep -n -i -E 'ngxblocker|bots\.d|blockbots|ddos\.conf|bad-bot|bot-blocker|bot blocker' -- deployment .github docker-compose.prod.yml
```

Expected: no output. `docs/superpowers/` is historical and is deliberately left out of the grep.

- [ ] **Step 3: Build the image and inspect it.**

```bash
docker build --pull -t the-greatest-nginx:pr4a-check /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/deployment/nginx
docker run --rm --entrypoint nginx the-greatest-nginx:pr4a-check -v          # expect: nginx/1.30.x
docker run --rm --entrypoint sh the-greatest-nginx:pr4a-check -c 'ls /etc/nginx/bots.d /usr/local/sbin/install-ngxblocker 2>&1; ls -A /etc/nginx/conf.d'
# expect: both "No such file", and conf.d empty
docker image rm the-greatest-nginx:pr4a-check
```

The build itself runs `nginx -t` (Dockerfile line `RUN nginx -t`), so a broken `nginx.conf` fails the build.

- [ ] **Step 4: Run the harness and the generator test.**

```bash
/home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/deployment/nginx/test/local-lockdown-test.sh 2>&1 | tail -25
/home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/deployment/nginx/test/generate-cloudflare-snippets_test.sh 2>&1 | tail -5
```

Expected: `all lockdown probes passed`, with A1–A8 and B1–B7 all PASS, and the generator test passing. The harness builds the image from the working tree and renders the real template. That covers Review Focus 1–3 and 5.

If nginx fails to start with `could not build server_names_hash` or `could not build variables_hash`, add the smallest directive that fixes it to the `http` block of `nginx.conf`. For example, `server_names_hash_bucket_size 64;`. Add a one-line comment saying the bot blocker used to set it, then re-run. Report it.

- [ ] **Step 5: Lint the workflow.**

```bash
docker run --rm -v /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes:/repo --workdir /repo rhysd/actionlint:latest -color .github/workflows/deploy-production.yml; echo "exit=$?"
```

Expected: exit 0.

- [ ] **Step 6: Commit.**

```bash
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes add deployment/nginx/Dockerfile deployment/nginx/the-greatest.conf.template deployment/nginx/nginx.conf .github/workflows/deploy-production.yml deployment/README.md deployment/nginx/bin/generate-cloudflare-snippets.sh deployment/nginx/test/local-lockdown-test.sh
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes commit -m "nginx: remove the bad-bot blocker; pin nginx 1.30 and pull on deploy

The image no longer downloads and runs nginx-ultimate-bad-bot-blocker
from upstream master at every build, and the site template no longer
includes its bots.d files. nginx is pinned to the 1.30 stable line;
the deploy builds with --pull so 1.30.x patches still arrive, and
keeps --no-cache for origin-lockdown's Cloudflare range refresh.

<Co-Authored-By trailer>"
```

---

### Task 2: Keep the per-visitor rate limits as our own config

**Files:**
- Modify: `deployment/nginx/nginx.conf` (the `http` block, after the two origin-lockdown snippet includes)
- Modify: `deployment/nginx/test/local-lockdown-test.sh` (a new probe B8 in run B)
- Modify: `deployment/README.md` (one sentence near line 280, where Task 1 now says "the per-visitor rate limits")

**Interfaces:** Consumes Task 1's `nginx.conf`, which has no `conf.d` include and no blocker.

**Why this task exists, and why it can be dropped separately:**
- The blocker's `ddos.conf` limited each client to 90 req/s (burst 200) and 200 connections. Behind Cloudflare that keyed on the edge's address, so it did almost nothing until real_ip went live on 2026-10-02.
- Removing the blocker without this task removes origin-side rate limiting the same day it started working.
- This task keeps the same values in `nginx.conf`, two directives each way, with no upstream download.
- It returns 429 instead of nginx's default 503, so Cloudflare and clients read it as "slow down", not as an origin failure.
- If Shane prefers to rely only on Cloudflare, drop this task. Task 1 stands alone, apart from the README wording noted in Task 1.

- [ ] **Step 1: Write the failing harness probe.** In `local-lockdown-test.sh`, inside run B and after `B7`, add:

**As built:** the B8 probe below could not tell per-visitor from per-edge keying (the burst ends before the bucket matters). The shipped probe is in `deployment/nginx/test/local-lockdown-test.sh` (commit d45c6747): a foreground 1000-request burst from one visitor, then 150 requests from a second visitor that must all get 200, with the client cert on every request.

```bash
# B8: per-visitor rate limiting (nginx.conf). One visitor (CF-Connecting-IP 203.0.113.50)
# far over 90 r/s + burst 200 gets 429s; a different visitor arriving through the same peer
# (10.99.0.1) is unaffected, which proves the key is the visitor, not the Cloudflare edge.
burst_codes=$(curl -sk -Z --parallel-max 100 --resolve "$music:$https_port:127.0.0.1" \
  -H "CF-Connecting-IP: 203.0.113.50" -o /dev/null -w '%{http_code}\n' \
  "https://$music:$https_port/?n=[1-1000]")
limited=$(printf '%s\n' "$burst_codes" | grep -c '^429$')
if [ "$limited" -gt 0 ]; then pass "B8a one visitor over the limit gets 429 ($limited of 1000)"
else fail "B8a one visitor over the limit gets 429" "no 429 in 1000 requests: $(printf '%s\n' "$burst_codes" | sort | uniq -c | tr '\n' ' ')"; fi
expect_http "B8b another visitor through the same edge is unaffected" 200 -k \
  --resolve "$music:$https_port:127.0.0.1" -H "CF-Connecting-IP: 203.0.113.51" "https://$music:$https_port/"
```

- [ ] **Step 2: Run it and confirm it fails.** Run `local-lockdown-test.sh`. Expected: B8a FAILs with no 429s, because no limit exists after Task 1. B8b passes. Record the status-code histogram the failure prints.

- [ ] **Step 3: Implement.** In `nginx.conf`, directly after `include /etc/nginx/snippets/cloudflare-geo.conf;`, add:

```nginx
    # Per-visitor limits. real_ip (above) makes $binary_remote_addr the visitor, not the
    # Cloudflare edge. Values carried over from the removed bad-bot blocker's ddos.conf;
    # 429 rather than nginx's default 503 so it reads as "slow down", not an origin failure.
    limit_req_zone $binary_remote_addr zone=flood:50m rate=90r/s;
    limit_conn_zone $binary_remote_addr zone=addr:50m;
    limit_req zone=flood burst=200 nodelay;
    limit_conn addr 200;
    limit_req_status 429;
    limit_conn_status 429;
```

These sit at `http` level, so they apply to every server.
- The 444 default servers and the port-80 redirect `return` in nginx's rewrite phase. That runs before the limit phase, so those servers are unaffected.
- The loopback healthcheck is unaffected too. It is one request every 30 s, and probe A7 covers it.

Then update the README sentence near line 280 to name the limits: "…the per-visitor rate limits (90 req/s, burst 200, 200 connections; `nginx.conf`)…".

- [ ] **Step 4: Run the full harness and confirm it passes.** Expected: `all lockdown probes passed`, with A1–A8, B1–B7, B8a and B8b all PASS.
  - Run it twice. B8a depends on timing, so record both `limited` counts to show it is not flaky.
  - If B8a passes only intermittently, raise the request count from 1000 to 2000 rather than lowering the limit, and report what you did.

- [ ] **Step 5: Mutation check.** Temporarily change the `limit_req_zone` key from `$binary_remote_addr` to `$realip_remote_addr`, which is the Cloudflare edge. Run the harness:
  - B8b must now FAIL, because both visitors share the edge's bucket. If it does not, report it.
  - Restore the key and re-run until green. Record both runs.

- [ ] **Step 6: Commit.**

```bash
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes add deployment/nginx/nginx.conf deployment/nginx/test/local-lockdown-test.sh deployment/README.md
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes commit -m "nginx: keep per-visitor rate limits without the bot blocker

The blocker's 90 r/s (burst 200) and 200-connection limits only became
per-visitor when real_ip went live. They now live in nginx.conf with
the same values, answer 429, and the lockdown harness proves the key is
the visitor rather than the Cloudflare edge.

<Co-Authored-By trailer>"
```

---

### Task 3: Hand-off (controller, plus Shane)

The controller runs Steps 1–2; Steps 3–5 need Shane.

- [ ] **Step 1:** On the branch head, run the harness once more: `local-lockdown-test.sh` must report all probes passed. Then run `bin/rails test` from `web-app/` as the CI gate. Nothing Ruby changed, but CI runs the suite and gates the image build.
- [ ] **Step 2:** `git -C … diff --stat origin/main...HEAD` must list only the files named in Tasks 1–2, plus this plan.
- [ ] **Step 3 (needs Shane's OK):** push and open the PR.
- [ ] **Step 4 (Shane, after the merge deploys):**
  - Run `deployment/scripts/verify-origin-lockdown.sh`. It must print `origin lockdown verified`.
  - On the server, run `docker compose -f docker-compose.prod.yml exec nginx nginx -v`. It must print `nginx/1.30.x`.
  - Then run `docker compose -f docker-compose.prod.yml logs --no-log-prefix --since 10m nginx | tail`. Requests must still end with `verify=SUCCESS`, and the earlier 444s for OAI-SearchBot and DotBot must be gone.
  - Load the three sites in a browser.
- [ ] **Step 5 (Shane's decision, outside this repo):** SEO crawlers that the blocker refused (AhrefsBot, SemrushBot, MJ12bot, DotBot, rogerbot) and OpenAI's OAI-SearchBot will now reach music and games. AI training crawlers stay blocked by Cloudflare's `ai_bots_protection` on all three zones. If any of these should be blocked, do it with the cfrules tool.
