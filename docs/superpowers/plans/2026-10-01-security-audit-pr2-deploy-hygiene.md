# Security audit PR 2: deploy workflow and image hygiene — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the audit's deploy-path and image findings (H2, M6, L9, L11, L17, L14, L16, M5/I14 docs) in one PR that merges to `main` and deploys on its own.

**Architecture:** Config and docs only, with no app code. The deploy workflow pins its SSH action, checks the server's host key and decrypts secrets without writing the age key to disk. The web image installs from a checked node-build tarball and an enforced `yarn.lock`, and no longer carries test code or test gems. The Open Library image drops root, and the dev compose ports bind to loopback. The deploy and secrets docs match what the workflow actually does.

**Tech Stack:** GitHub Actions (appleboy/ssh-action → drone-ssh), SOPS 3.11.0 + age, Docker / Compose, Yarn Classic 1.22.22, node-build, Rails 8.1 (Bundler groups), Python 3.12 / uv image.

**Spec:** `docs/superpowers/specs/2026-10-01-security-audit-fixes-design.md`, section "PR 2 — deploy workflow and image hygiene". Read that section before starting any task.

**Branch / worktree:** `security-audit-pr2-deploy-hygiene` in
`/home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes`, cut from `origin/main` at
`50c37ee1` (PR 1, #334, merged and deployed). It has no upstream; it gets one only on its first push.

## Global Constraints

- **Merging to `main` deploys to production.** Nothing in this plan pushes, opens a PR, runs a workflow, or touches the production server. Those steps belong to Shane or need his explicit OK (Task 5).
- **No Cloudflare changes and no nginx changes.** nginx belongs to PR 4a.
- **Exact pins, verbatim:**
  - `appleboy/ssh-action@c4f70287fc37c43b14b30b407224bbbc8e8c6327` (master as of 2026-09-30; not the `v1.2.5` tag)
  - `actions/delete-package-versions@e5bc658cc4c965c472efe991f8beea3981499c55` (v5.0.0; the `v5` tag is annotated and dereferences to this commit)
  - `peter-evans/repository-dispatch@28959ce8df70de7be546dd1250a005dd32156697` (v4.0.1; `v4` points at the same commit)
  - node-build `v5.4.56`, tarball `https://github.com/nodenv/node-build/archive/refs/tags/v5.4.56.tar.gz`, sha256 `23ee5f1fb900437ac14d3f7012de861dc5ba86ccddb45526315a70dea5933f72`. It extracts to `node-build-5.4.56/` and contains the `22.20.0` definition (checked 2026-10-01).
- `NODE_VERSION` stays `22.20.0` and `YARN_VERSION` stays `1.22.22`. Every other GitHub action stays on its major tag; SHA-pinning the rest waits for Dependabot, which is deferred.
- Fingerprint secret name: `SERVER_SSH_HOST_FINGERPRINT`. It is a GitHub Actions secret, not SOPS. Use the ECDSA value `SHA256:N21xW1UBEL1ah+TNfjk/YdtN105gUidJwjMHxxwJUYk`. Shane sets it; no task does.
- **Never decrypt `secrets/.env.production`, and never handle the real age key.** Every SOPS test uses a throwaway key and a dummy file in the scratch directory.
- **`web-app/node_modules` is a symlink into the main checkout.** Never run `yarn install` (or `npm install`) inside `web-app/` in this worktree, because it would mutate the main checkout's modules. Lockfile checks run on copies in a scratch directory.
- **Do not recreate, stop or restart the running dev containers:** `data-sources-api-1`, `the-greatest-db-1`, `redis-dev`, `opensearch-dev`. Never tag an image `:latest`. Use the throwaway tags named in each task and remove them afterwards.
- Git: target the worktree with `git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes …`. A session guard refuses `cd <dir> && git …` and computed `-C` paths. Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- The repo is public. Commit messages describe the fix, never an attack path.
- Linter is `bundle exec standardrb` (not rubocop). Do not run brakeman. Run Rails commands from `web-app/`.

## Review Focus

Spec-implied failure modes that no Rails test exercises, most likely first. Each one is pinned by an explicit verification step in the task named.

1. **`AGE_PRIVATE_KEY` holds the whole age key file, comment lines included** (SECRETS.md: "Entire contents of age private key file"). `SOPS_AGE_KEY` must accept that form, or the first deploy after merge fails to decrypt. → Task 1, Step 3 decrypts with a full `age-keygen` file, comments and all, on sops 3.11.0, the server's version.
2. **A failed decrypt must leave the live `.env` untouched and leave no key on disk.** → Task 1, Step 3 runs the exact script lines under `set -e` with a wrong key and checks that `.env` is unchanged and that no `keys.txt` exists.
3. **Production code that silently needs a test-group gem.** With `BUNDLE_WITHOUT="development:test"` that becomes a boot or rake failure, and it only surfaces after deploy. → Task 2, Step 6 runs `zeitwerk:check` (full eager load) and `rails -T` (loads every `.rake` file) inside the built image.
4. **`yarn.lock` drift must fail rather than be repaired.** → Task 2, Step 2 proves `--frozen-lockfile` rejects a drifted copy, and Step 5 proves the committed pair passes.
5. **The non-root Open Library user must still read the host artifact and spill to its temp dir. The one-shot `build` service must still write its artifact.** → Task 3, Step 3 boots the real artifact read-only as uid 10001 and hits `/version`. Step 2 keeps `build` on root and Step 4 checks it in `docker compose config`.

---

### Task 1: Deploy workflow (H2)

**Files:**
- Modify: `.github/workflows/deploy-production.yml` (whole file, 48 lines)
- Modify: `.github/workflows/build-web-image.yml:63,73,84` (three `uses:` lines plus one comment)

**Interfaces:**
- Consumes: GitHub secrets `AGE_PRIVATE_KEY`, `DEPLOY_SSH_KEY`, `SERVER_WEB_HOST` (existing) and `SERVER_SSH_HOST_FINGERPRINT` (new; Shane adds it).
- Produces: the deploy flow that Task 4's docs describe. Decryption on the server runs `SOPS_AGE_KEY="$AGE_PRIVATE_KEY" sops -d secrets/.env.production > .env.new`, then `mv .env.new .env` and `chmod 600 .env`, and nothing is written to `~/.config/sops/age/`.

- [ ] **Step 1: Baseline actionlint on the unmodified workflows**

```bash
docker run --rm -v /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes:/repo --workdir /repo rhysd/actionlint:latest -color .github/workflows/deploy-production.yml .github/workflows/build-web-image.yml .github/workflows/ci.yml; echo "exit=$?"
```

Record the output in your report. Any findings here are pre-existing, and Step 5 must not add new ones.

- [ ] **Step 2: Rewrite `.github/workflows/deploy-production.yml`**

Replace the whole file with:

```yaml
name: Deploy to Production

on:
  workflow_dispatch:
  repository_dispatch:
    types: [image-built-event]

# The job reaches the server over SSH only and never uses GITHUB_TOKEN.
permissions: {}

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Deploy application
        # master as of 2026-09-30, pinned to a commit. Not the v1.2.5 tag: it
        # predates the action's checksum check on the drone-ssh binary.
        uses: appleboy/ssh-action@c4f70287fc37c43b14b30b407224bbbc8e8c6327
        env:
          AGE_PRIVATE_KEY: ${{ secrets.AGE_PRIVATE_KEY }}
        with:
          host: ${{ secrets.SERVER_WEB_HOST }}
          username: deploy
          key: ${{ secrets.DEPLOY_SSH_KEY }}
          # SHA256 fingerprint of the server's ECDSA host key. A mismatch fails
          # the connect and deploys nothing. After a server rebuild, update it:
          # deployment/SERVER-UPGRADE-GUIDE.md.
          fingerprint: ${{ secrets.SERVER_SSH_HOST_FINGERPRINT }}
          envs: AGE_PRIVATE_KEY
          script: |
            set -e
            cd /home/deploy/apps/the-greatest

            # Clean up Docker resources
            docker system prune -f

            # Pull latest code (includes encrypted secrets)
            git pull

            # Remove any age key an earlier version of this script left on
            # disk when its decrypt step failed before its cleanup ran.
            rm -f ~/.config/sops/age/keys.txt

            # Decrypt secrets to .env. sops reads the age key from the
            # environment, so the key is never written to disk.
            SOPS_AGE_KEY="$AGE_PRIVATE_KEY" sops -d secrets/.env.production > .env.new
            mv .env.new .env
            chmod 600 .env

            # Pull web/worker images and rebuild nginx
            docker compose -f docker-compose.prod.yml pull
            docker compose -f docker-compose.prod.yml build --no-cache nginx
            docker compose -f docker-compose.prod.yml up -d
```

The three `docker compose` lines stay byte-for-byte as they were. PR 4a changes the nginx line, not this PR.

- [ ] **Step 3: Prove the decrypt lines locally with a throwaway key (Review Focus 1 and 2)**

Write this script to the scratch directory and run it with `bash`. Local sops is 3.11.0, the same version as the server.

```bash
#!/bin/bash
# Throwaway proof of the deploy script's decrypt lines. Never touches real secrets.
set -u
W=$(mktemp -d)
cd "$W"
age-keygen -o key.txt 2>/dev/null           # full file: "# created", "# public key", AGE-SECRET-KEY line
PUB=$(age-keygen -y key.txt)
printf 'FOO=bar\nBAZ=qux\n' > plain.env
sops --encrypt --age "$PUB" --input-type dotenv --output-type dotenv plain.env > enc.env
export HOME="$W/home"; mkdir -p "$HOME"     # so a stray keys.txt would be visible

# 1. Success path, with the WHOLE key file as the env value.
AGE_PRIVATE_KEY=$(cat key.txt)
( set -e
  SOPS_AGE_KEY="$AGE_PRIVATE_KEY" sops -d enc.env > .env.new
  mv .env.new .env
  chmod 600 .env )
echo "success exit=$?"; cat .env; stat -c '%a' .env

# 2. Failure path: wrong key, under set -e. .env must stay as it was.
cp .env before.env
age-keygen -o wrong.txt 2>/dev/null
AGE_PRIVATE_KEY=$(cat wrong.txt)
( set -e
  SOPS_AGE_KEY="$AGE_PRIVATE_KEY" sops -d enc.env > .env.new
  mv .env.new .env
  chmod 600 .env ) 2>/dev/null
echo "failure exit=$? (expect non-zero)"
cmp -s .env before.env && echo ".env unchanged: OK" || echo ".env CHANGED: FAIL"
test -e "$HOME/.config/sops/age/keys.txt" && echo "keys.txt on disk: FAIL" || echo "no keys.txt: OK"
rm -rf "$W"
```

Expected output:
- `success exit=0`, followed by `FOO=bar`, `BAZ=qux` and `600`.
- `failure exit=` a non-zero value.
- `.env unchanged: OK`.
- `no keys.txt: OK`.

If the success path fails with the full key file, STOP and report it. Do not work around it. The workflow's design depends on this form.

- [ ] **Step 4: Pin the PAT-holding actions in `.github/workflows/build-web-image.yml`**

Change both `uses: actions/delete-package-versions@v5` lines (lines 63 and 73) to:

```yaml
        uses: actions/delete-package-versions@e5bc658cc4c965c472efe991f8beea3981499c55 # v5.0.0
```

Change `uses: peter-evans/repository-dispatch@v4` (line 84) to:

```yaml
        uses: peter-evans/repository-dispatch@28959ce8df70de7be546dd1250a005dd32156697 # v4.0.1
```

Add this comment line directly above the first `- name: Delete old untagged images` step, at the same indentation as `- name:`:

```yaml
      # The steps holding REPO_DISPATCH_PAT are pinned to commits. The other
      # actions stay on major tags until Dependabot can keep pins current.
```

Change nothing else in this file. It has trailing whitespace on some blank lines; leave it, because rewriting it bloats the diff.

- [ ] **Step 5: Lint and assert**

Run the Step 1 actionlint command again. It must show no findings beyond the baseline. Then run:

```bash
R=/home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/.github/workflows
grep -n '@master\|@v[0-9]' $R/deploy-production.yml            # expect: no output
grep -n 'keys.txt' $R/deploy-production.yml                     # expect: only the rm -f line
grep -n 'fingerprint: \${{ secrets.SERVER_SSH_HOST_FINGERPRINT }}' $R/deploy-production.yml   # expect: 1 line
grep -n '^permissions: {}' $R/deploy-production.yml             # expect: 1 line
grep -n 'delete-package-versions@\|repository-dispatch@' $R/build-web-image.yml   # expect: 3 lines, all 40-hex SHAs
python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]; print('yaml ok')" $R/deploy-production.yml $R/build-web-image.yml
```

- [ ] **Step 6: Commit**

```bash
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes add .github/workflows/deploy-production.yml .github/workflows/build-web-image.yml
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes commit -m "Deploy: pin the SSH action, check the host key, keep the age key off disk

The deploy job pins appleboy/ssh-action to a commit, verifies the server's
host key against SERVER_SSH_HOST_FINGERPRINT, and drops GITHUB_TOKEN
permissions. sops now reads the age key from SOPS_AGE_KEY instead of a
keys.txt the script had to remember to delete. The image workflow pins
the two actions that hold REPO_DISPATCH_PAT.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Web image and JS lockfile (M6, L9, L11, L17)

**Files:**
- Modify: `web-app/Dockerfile:26` (BUNDLE_WITHOUT), `:40-43` (node-build), `:53` (yarn flag)
- Modify: `web-app/.dockerignore` (append)
- Modify: `web-app/.gitignore` (append)
- Modify: `.github/workflows/ci.yml` (one step in the `test` job)
- Delete: `web-app/current_spec_output.txt`, `web-app/results.json`, `web-app/package-lock.json`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: an image without `test/`, `e2e/`, `docs/` or test-group gems. A CI step named `Install JavaScript dependencies (fails on yarn.lock drift)`.

Facts already checked (do not re-derive; re-check only if something fails):
- `bcrypt` is `require`d lazily inside the `firebase:canary` and `firebase:canary_for_user` task bodies (`lib/tasks/firebase_migration.rake:34,82`). Every other test-group gem name appears nowhere in `app/`, `config/` (outside `environments/development.rb` and `environments/test.rb`), `lib/`, `bin/` or `db/`. `lib/tasks/annotate_rb.rake` requires `annotate_rb` only inside `if Rails.env.development?`.
- Every Tailwind entrypoint uses `@import "tailwindcss" source(none);` with explicit `@source` globs under `app/` and `public/`. Excluding `test/`, `e2e/` and `docs/` from the build context therefore cannot change the compiled CSS.
- Nothing outside archived docs references `package-lock.json`, `current_spec_output.txt` or `results.json`.

- [ ] **Step 1: Copy the lockfile pair to scratch (never install in `web-app/`)**

```bash
S=/tmp/claude-1001/-home-shane-dev-the-greatest/1d060d07-cb75-4dbe-9710-bbd8540ba0d7/scratchpad/yarn-check
rm -rf $S && mkdir -p $S/good $S/drift
cp /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/web-app/package.json /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/web-app/yarn.lock $S/good/
cp $S/good/package.json $S/good/yarn.lock $S/drift/
```

(If the scratchpad path above does not exist in your session, use `mktemp -d` and say so in your report.)

- [ ] **Step 2: Prove `--frozen-lockfile` fails on drift, and that `--immutable` does not (the M6 defect)**

Each Bash call is a fresh shell, so set `S` again (the same path as Step 1):

```bash
S=/tmp/claude-1001/-home-shane-dev-the-greatest/1d060d07-cb75-4dbe-9710-bbd8540ba0d7/scratchpad/yarn-check
cd $S/drift
python3 - <<'PY'
import json; p=json.load(open("package.json")); p.setdefault("dependencies",{})["left-pad"]="1.3.0"; json.dump(p,open("package.json","w"),indent=2)
PY
yarn install --immutable --ignore-scripts --non-interactive > immutable.log 2>&1; echo "immutable exit=$? (expect 0: Yarn Classic ignores the flag)"
cp $S/good/yarn.lock yarn.lock    # undo the rewrite --immutable just did
yarn install --frozen-lockfile --ignore-scripts --non-interactive > frozen.log 2>&1; echo "frozen exit=$? (expect non-zero)"
tail -2 frozen.log                # expect: "Your lockfile needs to be updated"
```

Record both exits in your report.

- [ ] **Step 3: Change the Dockerfile**

In `web-app/Dockerfile`, line 26:

```dockerfile
    BUNDLE_WITHOUT="development:test"
```

Replace lines 36–43 (from `# Install JavaScript dependencies` through `rm -rf /tmp/node-build-master`) with:

```dockerfile
# Install JavaScript dependencies. node-build comes from a release tag whose
# tarball checksum is pinned here; if GitHub ever regenerates the archive the
# build fails loudly, and the fix is to re-verify and update the checksum.
ARG NODE_VERSION=22.20.0
ARG YARN_VERSION=1.22.22
ARG NODE_BUILD_VERSION=5.4.56
ARG NODE_BUILD_SHA256=23ee5f1fb900437ac14d3f7012de861dc5ba86ccddb45526315a70dea5933f72
ENV PATH=/usr/local/node/bin:$PATH
RUN curl -fsSL -o /tmp/node-build.tar.gz "https://github.com/nodenv/node-build/archive/refs/tags/v${NODE_BUILD_VERSION}.tar.gz" && \
    echo "${NODE_BUILD_SHA256}  /tmp/node-build.tar.gz" | sha256sum -c - && \
    tar xzf /tmp/node-build.tar.gz -C /tmp/ && \
    /tmp/node-build-${NODE_BUILD_VERSION}/bin/node-build "${NODE_VERSION}" /usr/local/node && \
    npm install -g yarn@$YARN_VERSION && \
    rm -rf /tmp/node-build.tar.gz /tmp/node-build-${NODE_BUILD_VERSION}
```

Line 53 (now shifted):

```dockerfile
# --frozen-lockfile, not --immutable: Yarn Classic ignores --immutable and
# would rewrite a drifted yarn.lock instead of failing.
RUN yarn install --frozen-lockfile
```

- [ ] **Step 4: `.dockerignore`, `.gitignore`, deletions, CI step**

Append to `web-app/.dockerignore`:

```
# Not needed at runtime: tests, E2E specs, docs, and stray local artifacts.
/test
/e2e
/docs
/current_spec_output.txt
/results.json
```

Append to `web-app/.gitignore`:

```

# Yarn is the package manager (yarn.lock). An npm lockfile here is never
# installed from and only attracts advisories.
/package-lock.json
```

Delete the three files:

```bash
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes rm -q web-app/current_spec_output.txt web-app/results.json web-app/package-lock.json
```

In `.github/workflows/ci.yml`, in the `test` job, insert this step between `Set up Ruby` and `Wait for OpenSearch`, at the same indentation as its neighbours:

```yaml
      # Before the tests: test:prepare runs a plain `yarn install`, which would
      # rewrite a drifted yarn.lock instead of failing on it.
      - name: Install JavaScript dependencies (fails on yarn.lock drift)
        run: yarn install --frozen-lockfile
```

(The job's `defaults.run.working-directory` is already `web-app`. The runner image ships Yarn 1.22.)

- [ ] **Step 5: Prove the committed pair passes `--frozen-lockfile`**

```bash
S=/tmp/claude-1001/-home-shane-dev-the-greatest/1d060d07-cb75-4dbe-9710-bbd8540ba0d7/scratchpad/yarn-check
cd $S/good && yarn install --frozen-lockfile --ignore-scripts --non-interactive >/dev/null; echo "frozen on committed pair exit=$? (expect 0)"
```

If this fails, `package.json` and `yarn.lock` have drifted on `main`. STOP and report: the fix is a deliberate `yarn.lock` update that Shane reviews, not something to fold in here.

- [ ] **Step 6: Build the image and inspect it (Review Focus 3)**

The build takes several minutes. Run it in the background if your harness supports that, and do not use a short timeout.

```bash
docker build -t the-greatest-web:pr2-check /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/web-app
```

Expected: the build succeeds. The log shows `/tmp/node-build.tar.gz: OK` from `sha256sum -c`.

Then:

```bash
docker run --rm --entrypoint sh the-greatest-web:pr2-check -c 'ls -A /rails'
# expect: no test, e2e, docs, package-lock.json, current_spec_output.txt, results.json

docker run --rm --entrypoint bundle the-greatest-web:pr2-check list 2>/dev/null | grep -E ' (capybara|mocha|webmock|minitest|selenium-webdriver|openapi_first|bcrypt|debug|brakeman|dotenv-rails|web-console|standard) '
# expect: no output

docker run --rm --entrypoint bundle the-greatest-web:pr2-check list 2>/dev/null | grep -cE ' (rails|sidekiq|pg|puma) '
# expect: 4

docker run --rm -e SECRET_KEY_BASE_DUMMY=1 --entrypoint ./bin/rails the-greatest-web:pr2-check zeitwerk:check
# expect: "All is good!" (production eager load with no test-group gems)

docker run --rm -e SECRET_KEY_BASE_DUMMY=1 --entrypoint ./bin/rails the-greatest-web:pr2-check -T > /dev/null; echo "rails -T exit=$?"
# expect: exit=0 (every .rake file loads)
```

If `zeitwerk:check` or `-T` fails because a production initializer wants an ENV var or a database, that is not a test-gem problem. Report the exact error, and rerun with the minimum env the error names (for example `-e DATABASE_URL=postgres://x@127.0.0.1/x`) to show the gem side is clean. Any `LoadError` or `NameError` naming a test-group gem is a real finding: STOP and report it.

Clean up: `docker image rm the-greatest-web:pr2-check`.

- [ ] **Step 7: Run the Rails suite and lint (Gemfile groups are unchanged, but the suite is the gate)**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/web-app && bin/rails test 2>&1 | tail -5 && bundle exec standardrb
```

Expected: 0 failures, 0 errors; standardrb is clean.

- [ ] **Step 8: Commit**

```bash
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes add web-app/Dockerfile web-app/.dockerignore web-app/.gitignore .github/workflows/ci.yml
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes commit -m "Web image: enforce yarn.lock, checksum node-build, ship no test code or gems

Yarn Classic ignores --immutable, so the image and CI now install with
--frozen-lockfile and fail on drift. node-build comes from the v5.4.56
tag with a pinned sha256 instead of master. The runtime image leaves out
the test group, test/, e2e/ and docs/. The unused npm lockfile and two
stray local artifacts are removed.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Open Library image drops root (L16); dev compose binds loopback (L14)

**Files:**
- Modify: `data-sources/Dockerfile` (after line 19, `ENV PATH=…`)
- Modify: `data-sources/docker-compose.yml` (the `build` service)
- Modify: `docker-compose.yml:9,34,35,40` (root, development)

**Interfaces:**
- Consumes: nothing from Tasks 1–2.
- Produces: the `the-greatest/data-sources` image runs as uid 10001 (user `openlibrary`). The compose `build` service keeps running as root.

Facts already checked:
- The API opens DuckDB in memory (`openlibrary/pipeline/duck.py:39`). It reads the artifact from a `:ro` mount and spills to `OL_API_TEMP_DIR`. Compose sets that to `/tmp`, and it defaults to `tempfile.gettempdir()`. It installs and loads no DuckDB extensions.
- The compose `build` service uses the same image and **writes** the artifact into `${OL_DATA_HOST:-/home/shane/ol-data}`, which is owned by the host user (uid 1001, mode 755). As uid 10001 it would get permission denied. It therefore stays on root: the spec's L16 concern is the long-running API, and this is a one-shot local job that has always run as root.
- `fetcher.Dockerfile` already uses `useradd --create-home --uid 10001 fetcher` / `USER fetcher`. This mirrors it.

- [ ] **Step 1: `data-sources/Dockerfile`**

After `ENV PATH="/app/.venv/bin:$PATH"` and before `EXPOSE 8080`, insert:

```dockerfile

# The API only reads its artifact (a read-only mount) and spills to /tmp, so it
# runs unprivileged, with the same uid as the page fetcher image.
RUN useradd --create-home --uid 10001 openlibrary
USER openlibrary
```

- [ ] **Step 2: `data-sources/docker-compose.yml`, `build` service**

Under `build:` (the service at the `services:` level, not the `build: .` key inside it), directly after its `profiles: ["build"]` line, add:

```yaml
    # The image runs as an unprivileged user, but this one-shot job writes the
    # artifact into the host's data directory, which that user cannot. It runs
    # as root, as it always has; the long-running `api` does not.
    user: root
```

- [ ] **Step 3: Build under a throwaway tag and boot it on the real artifact (Review Focus 5)**

Never tag `:latest`: the running `data-sources-api-1` uses that tag. Port 8080 is taken, so use 18080.

```bash
docker build -t the-greatest/data-sources:pr2-check /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/data-sources
docker run -d --name ol-pr2-check -p 127.0.0.1:18080:8080 \
  -v /home/shane/ol-data:/data:ro \
  -e OL_DATA_ROOT=/data -e OL_DATA_VERSION=2026-07-31 \
  -e OL_API_MEMORY_LIMIT=1GB -e OL_API_TEMP_DIR=/tmp \
  the-greatest/data-sources:pr2-check
for i in $(seq 1 60); do curl -sf http://127.0.0.1:18080/version > /dev/null && break; sleep 2; done
curl -s http://127.0.0.1:18080/version | head -c 400; echo
docker exec ol-pr2-check id -u           # expect: 10001
docker logs ol-pr2-check 2>&1 | grep -iE 'permission|denied|error' || echo "no permission errors"
docker rm -f ol-pr2-check
docker image rm the-greatest/data-sources:pr2-check
```

Expected: `/version` returns JSON with `dump_date` `2026-07-31`, `id -u` prints `10001`, and the logs show no permission errors. If `/version` never answers, include `docker logs ol-pr2-check` in your report before removing the container.

If `/home/shane/ol-data/versions/2026-07-31` is missing or unreadable on this machine, say so in your report and run only the `id -u` check. Do not fabricate a pass.

- [ ] **Step 4: Root `docker-compose.yml` ports, loopback only**

Change the four mappings to:

```yaml
      - "127.0.0.1:6543:5432"
```
```yaml
      - "127.0.0.1:9200:9200"
      - "127.0.0.1:9600:9600"
```
```yaml
      - "127.0.0.1:6379:6379"
```

Then check both compose files render and show the intended values. Do NOT run `up`, `down` or `restart`. The running dev containers keep their old bindings until Shane recreates them.

```bash
docker compose -f /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/docker-compose.yml config | grep -E 'host_ip|published'
# expect: every published port paired with host_ip: 127.0.0.1
docker compose -f /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/data-sources/docker-compose.yml --profile build config | grep -nE '^  [a-z]+:$|user:'
# expect: `user: root` under the build service only
```

- [ ] **Step 5: Commit**

```bash
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes add data-sources/Dockerfile data-sources/docker-compose.yml docker-compose.yml
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes commit -m "Open Library API runs unprivileged; dev services bind to loopback

The data-sources image runs as uid 10001, as the page fetcher image
does. The one-shot artifact build keeps root, because it writes into the
host's data directory. The development Postgres, OpenSearch and Redis
ports bind to 127.0.0.1, matching data-sources/docker-compose.yml.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Secrets docs and ignores (M5 docs, I14)

**Files:**
- Modify: `.gitignore` (root, the `# SOPS decrypted files` block)
- Modify: `deployment/SECRETS.md:230-245` (the "GitHub Actions Secrets Required" and "How Deployment Works" subsections)
- Modify: `deployment/SERVER-UPGRADE-GUIDE.md` (new step 6, renumber 6→7 and 7→8, rewrite "Decrypting Secrets", add a troubleshooting entry and a quick-reference row)

**Interfaces:**
- Consumes: Task 1's deploy flow (the script lines in Task 1, Step 2) and the secret name `SERVER_SSH_HOST_FINGERPRINT`.
- Produces: docs only.

- [ ] **Step 1: Root `.gitignore`**

Replace the block:

```
# SOPS decrypted files
secrets/*.decrypted
secrets/*.plain
secrets/*.tmp
```

with:

```
# SOPS decrypted files (deployment/SECRETS.md uses these names anywhere in the tree)
secrets/*.decrypted
secrets/*.plain
secrets/*.tmp
temp.env
*.decrypted
.env.*.plain
```

Verify that each name is ignored and that the encrypted file and the example are not:

```bash
R=/home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes
git -C $R check-ignore -v temp.env .env.decrypted web-app/.env.decrypted .env.production.plain
# expect: 4 lines, each naming a .gitignore rule
git -C $R check-ignore secrets/.env.production; echo "exit=$? (expect 1: NOT ignored)"
git -C $R ls-files | grep -E '(^|/)\.env\.example$'   # expect: still listed
```

- [ ] **Step 2: `deployment/SECRETS.md`, replace lines 230–245**

Replace from `### GitHub Actions Secrets Required` down to (not including) `### Manual Deployment with Secrets` with:

```markdown
### GitHub Actions Secrets Required

- `AGE_PRIVATE_KEY` - Entire contents of the age private key file
- `DEPLOY_SSH_KEY` - SSH private key for the deploy user
- `SERVER_WEB_HOST` - Production server hostname or IP
- `SERVER_SSH_HOST_FINGERPRINT` - SHA256 fingerprint of the server's ECDSA SSH host key
  (`SHA256:...`). Not sensitive: it is a hash of a public key. Update it whenever the server is
  rebuilt (see `SERVER-UPGRADE-GUIDE.md`).
- `REPO_DISPATCH_PAT` - used by the image workflow to trigger the deploy and prune old images

### How Deployment Works

1. A push to `main` runs CI, builds and pushes the web image, then sends an `image-built-event`.
2. The "Deploy to Production" workflow connects to the server over SSH as `deploy`. It refuses
   to connect unless the server's host key matches `SERVER_SSH_HOST_FINGERPRINT`.
3. On the server, the script runs `git pull`, which brings the encrypted `secrets/.env.production`.
4. It decrypts with the key passed in the environment, never written to disk:
   `SOPS_AGE_KEY="$AGE_PRIVATE_KEY" sops -d secrets/.env.production > .env.new`, then moves
   `.env.new` over `.env` and sets mode 0600. A failed decrypt stops the script and leaves the
   previous `.env` in place.
5. It pulls the web and worker images, rebuilds nginx, and runs `docker compose up -d`. Compose
   reads `.env` automatically.

```

- [ ] **Step 3: `deployment/SERVER-UPGRADE-GUIDE.md`**

(a) Insert a new step after step 5 ("Generate SSL Certificates") and before the current `### 6. Deploy the Application`. Renumber `### 6. Deploy the Application` → `### 7.` and `### 7. Verify` → `### 8.`.

````markdown
### 6. Update the Host-Key Fingerprint Secret

A new server has a new SSH host key. The deploy workflow checks the server's key against the
`SERVER_SSH_HOST_FINGERPRINT` Actions secret and refuses to connect on a mismatch, so update it
before the first deploy:

```bash
ssh deploy@<NEW_IP> 'for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f"; done'
gh secret set SERVER_SSH_HOST_FINGERPRINT --body 'SHA256:...'   # the ECDSA line
```

Use the **ECDSA** line: the deploy action negotiates ECDSA ahead of ED25519. If a future version
of the action negotiates a different key type, the deploy fails at connect with a fingerprint
mismatch, and the fix is to set the secret to that key type's line.

Your first SSH connection to a new server trusts its key on first use. To check that key, compare
it with the host-key fingerprints cloud-init prints to the server's console, in your provider's
web console.

````

(b) Replace the whole `## Decrypting Secrets` section body (the paragraph and the code block, up to the following `---`) with:

````markdown
Secrets are encrypted with SOPS/age. To decrypt manually on the server, pass the key in the
environment, so it never lands on disk or in shell history:

```bash
cd /home/deploy/apps/the-greatest

# Paste the AGE-SECRET-KEY-1... line at the prompt (input is hidden), then press Enter
read -rs SOPS_AGE_KEY && export SOPS_AGE_KEY

sops -d secrets/.env.production > .env
chmod 600 .env

unset SOPS_AGE_KEY
```
````

(c) In `## Troubleshooting`, add this as the first entry:

```markdown
### Deploy fails at the SSH connect after a server rebuild

The `SERVER_SSH_HOST_FINGERPRINT` secret still holds the old server's host key. See step 6.

```

(d) In the `## Quick Reference` table, add this row directly before the `| Deploy app |` row:

```markdown
| Update host-key secret | `gh secret set SERVER_SSH_HOST_FINGERPRINT` (step 6) |
```

- [ ] **Step 4: Check the docs**

```bash
R=/home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/deployment
grep -n 'keys.txt\|Rsyncs\|echo "AGE-SECRET' $R/SECRETS.md $R/SERVER-UPGRADE-GUIDE.md
# expect: no output. (SECRETS.md's key-management sections use ~/.config/sops/age/production.txt
#  on the maintainer's own machine; those are unchanged and do not match.)
grep -n '^### [0-9]' $R/SERVER-UPGRADE-GUIDE.md
# expect: 1..8 in order, each number once
```

- [ ] **Step 5: Commit**

```bash
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes add .gitignore deployment/SECRETS.md deployment/SERVER-UPGRADE-GUIDE.md
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes commit -m "Docs: describe the real deploy decrypt, keep age keys out of history

SECRETS.md now describes the server-side SOPS_AGE_KEY decrypt the
workflow actually runs, and lists the host-key fingerprint secret. The
upgrade guide adds the fingerprint step for a rebuilt server and decrypts
with a hidden prompt instead of echoing the key into a file. The root
.gitignore covers the plaintext names the docs use.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Whole-branch verification and hand-off (controller, plus Shane)

Not dispatched to an implementer. The controller runs Steps 1–2. Steps 3–6 are Shane's, or need his explicit OK.

- [ ] **Step 1: Full suite and lint on the branch head**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/web-app && bin/rails test 2>&1 | tail -5 && bundle exec standardrb
```

- [ ] **Step 2: Diff sanity**

`git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes diff --stat origin/main...HEAD` must show only the files named in Tasks 1–4. No nginx files, no `app/` files, and no Cloudflare config.

- [ ] **Step 3 (Shane): add the secret before merging.**

`gh secret set SERVER_SSH_HOST_FINGERPRINT --body 'SHA256:N21xW1UBEL1ah+TNfjk/YdtN105gUidJwjMHxxwJUYk'`.
If the secret is absent, the deploy skips the host-key check (today's behaviour). If it is wrong, the deploy fails at connect and nothing is deployed.

- [ ] **Step 4 (needs Shane's OK): push and open the PR.** The PR body describes fixes, not attack paths.

- [ ] **Step 5 (optional, needs Shane's OK): exercise the new deploy script before merging.**

`gh workflow run "Deploy to Production" --ref security-audit-pr2-deploy-hygiene` runs this branch's workflow file against production. The server still pulls `main` and the current `:latest` images, so it redeploys what is live, using the new SSH pin, the fingerprint check and the `SOPS_AGE_KEY` decrypt. This is a real production deploy (nginx is rebuilt, as on every deploy). It catches a bad fingerprint or decrypt before the merge depends on them.

- [ ] **Step 6 (after merge): read the deploy run.** In `gh run view --log` for the "Deploy to Production" run: the connect succeeds with the fingerprint set, `sops -d` produces no error, and `up -d` completes. Shane checks the three sites in a browser, because Cloudflare challenges `curl`.

Shane's own follow-up, not part of this PR: recreate the dev containers whenever convenient (`docker compose up -d` at the repo root) so the loopback bindings take effect. The volumes persist.
