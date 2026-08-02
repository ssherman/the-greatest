# GitHub CI Test and Lint Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every pull request runs `bin/rails test` and `bundle exec standardrb` and cannot be merged while either is red, and a merge to `main` cannot build an image or deploy to production unless both pass.

**Architecture:** A new reusable workflow `.github/workflows/ci.yml` (triggered by `pull_request` and `workflow_call`) defines two parallel jobs, `test` and `lint`. The existing `build-web-image.yml` calls that same workflow and gates its build job behind it with `needs: ci`, so one definition serves both the PR gate and the deploy gate. The dead `web-app/.github/` directory is deleted and two docs that describe CI inaccurately are corrected.

**Tech Stack:** GitHub Actions, `ruby/setup-ruby@v1`, Postgres 17 and OpenSearch 3 service containers, Rails 8 / Minitest, Ruby 4.0.6, standardrb.

**Spec:** `docs/superpowers/specs/2026-08-02-github-ci-test-gate-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **Workflows live at the repository root** in `.github/workflows/`. A `.github/` directory nested in a subdirectory is never read by GitHub. This is the bug being fixed; do not recreate it.
- **The Rails app is in `web-app/`.** All `run:` steps need `working-directory: web-app`, and `ruby/setup-ruby` needs its own `working-directory: web-app` **input** — job-level `defaults` do not apply to actions.
- **Ruby version comes from `web-app/.ruby-version`** (currently `ruby-4.0.6`). Never hardcode a version string in a workflow.
- **Lint is `bundle exec standardrb`**, never `bin/rubocop` (omakase, conflicting style).
- **Never add brakeman.** `CLAUDE.md` forbids it.
- **Never add `bin/rails test:system`, Playwright, or E2E** to CI. Explicit non-goals in the spec.
- **Postgres service maps host port `6543`**, because `config/database.yml` hardcodes `port: 6543`. Do not modify `database.yml`.
- **OpenSearch image is pinned to `opensearchproject/opensearch:3`**, never `:latest`.
- **`ci.yml` must not have a `push:` trigger.** `main` is covered through the caller; a `push` trigger would run the suite twice per merge.
- Commit messages end with:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

## File Structure

| File | Responsibility |
|---|---|
| `.github/workflows/ci.yml` | **Create.** Sole definition of the test and lint gate. Consumed by the PR trigger and by `build-web-image.yml`. |
| `.github/workflows/build-web-image.yml` | **Modify.** Add a `ci` job that calls `ci.yml`; add `needs: ci` to `build-and-push-image`. No other change. |
| `web-app/.github/` | **Delete.** Contains `workflows/ci.yml` and `dependabot.yml`, both inert. |
| `CLAUDE.md` | **Modify.** Lines 23 and 29 describe a CI that never ran. |
| `docs/testing.md` | **Modify.** "CI Requirements" section (~lines 224-228) describes enforcement that does not exist. |
| *(repo settings)* | Branch protection on `main` via `gh api`. Not a file. |

Tasks 1 and 2 build `ci.yml` incrementally — lint first, then test — because lint is fast and proves the scaffolding (root location, working directory, Ruby setup, bundler cache) before service containers are added on top. A reviewer can meaningfully approve the lint job and reject the test job.

---

### Task 1: Create `ci.yml` with the lint job and prove it runs

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: a workflow named `CI` with a job id `lint`, triggered on `pull_request`. Task 2 adds a `test` job to the same file. Task 3 adds the `workflow_call` trigger. Task 5 requires the check names `lint` and `test` verbatim.

- [ ] **Step 1: Write the workflow with only the lint job**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  pull_request:

permissions:
  contents: read

defaults:
  run:
    working-directory: web-app

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: .ruby-version
          working-directory: web-app
          bundler-cache: true

      - name: Lint code for consistent style
        run: bundle exec standardrb --format github
```

Note `working-directory: web-app` appears **twice** on purpose: once under `defaults.run` (for `run:` steps) and once as an input to `ruby/setup-ruby` (actions ignore `defaults`). Removing either breaks the job.

- [ ] **Step 2: Verify the YAML parses before pushing**

Run from the repo root:

```bash
ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml"); puts "ci.yml OK"'
```

Expected: `ci.yml OK`

- [ ] **Step 3: Commit and push the branch**

```bash
git add .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
Add root CI workflow with a standardrb lint job

GitHub only reads .github/workflows/ at the repository root, so
web-app/.github/workflows/ci.yml has never run. This adds a real one.

Lint lands first to prove the scaffolding (root location, web-app working
directory, Ruby from .ruby-version, bundler cache) before the test job's
service containers are stacked on top.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin worktree-github-ci-test-gate
```

- [ ] **Step 4: Open the pull request**

```bash
gh pr create --base main --title "Add GitHub CI test and lint gate" --body "$(cat <<'EOF'
Adds a real root-level CI workflow (test + lint) and gates the image build
and production deploy behind it.

Spec: docs/superpowers/specs/2026-08-02-github-ci-test-gate-design.md
Plan: docs/superpowers/plans/2026-08-02-github-ci-test-gate.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5: Watch the lint check and confirm it passes**

```bash
sleep 10
gh run watch "$(gh run list --workflow=ci.yml --branch worktree-github-ci-test-gate --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

The `sleep` matters: GitHub takes a few seconds to register a run, and querying too
early returns an empty id, which makes `gh run watch` fail confusingly. If the id
comes back empty, wait and re-run rather than assuming the workflow did not trigger.
This same pattern is used in Tasks 2, 3, and 5.

Expected: the run completes with `lint` succeeded, exit code 0.

If it fails, read the failure before changing anything:

```bash
gh run view "$(gh run list --workflow=ci.yml --branch worktree-github-ci-test-gate --limit 1 --json databaseId --jq '.[0].databaseId')" --log-failed
```

The two likely first-run failures and their fixes:
- `Could not find .ruby-version` → the `working-directory: web-app` input on `ruby/setup-ruby` is missing or misspelled.
- `bundle: command not found` or a `Gemfile not found` error → `defaults.run.working-directory` is missing.

Fix, commit, push, and re-run this step until green. Do not proceed to Task 2 with a red lint job.

---

### Task 2: Add the test job with Postgres and OpenSearch

**Files:**
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: the `ci.yml` file created in Task 1, including its `defaults.run.working-directory` and `permissions` blocks.
- Produces: a job id `test` in the same workflow, running `bin/rails db:test:prepare test`. Task 5 requires this check name verbatim.

- [ ] **Step 1: Add the `test` job**

Append this job to the `jobs:` block in `.github/workflows/ci.yml`, as a sibling of `lint`:

```yaml
  test:
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:17
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
        ports:
          - 6543:5432
        options: >-
          --health-cmd="pg_isready -U postgres"
          --health-interval=10s
          --health-timeout=5s
          --health-retries=5

      opensearch:
        image: opensearchproject/opensearch:3
        env:
          discovery.type: single-node
          plugins.security.disabled: "true"
          OPENSEARCH_INITIAL_ADMIN_PASSWORD: Ci_OpenSearch_2026!
          OPENSEARCH_JAVA_OPTS: -Xms1g -Xmx1g
        ports:
          - 9200:9200

    steps:
      - name: Install system packages
        run: sudo apt-get update -qq && sudo apt-get install --no-install-recommends -y libpq-dev libvips

      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: .ruby-version
          working-directory: web-app
          bundler-cache: true

      - name: Wait for OpenSearch
        run: |
          for i in $(seq 1 60); do
            if curl -sf http://localhost:9200/_cluster/health > /dev/null; then
              echo "OpenSearch is up:"
              curl -s http://localhost:9200
              exit 0
            fi
            echo "waiting for OpenSearch ($i/60)"
            sleep 2
          done
          echo "OpenSearch did not become ready within 120s"
          exit 1

      - name: Run tests
        env:
          RAILS_ENV: test
          POSTGRES_PASSWORD: postgres
          OPENSEARCH_URL: http://localhost:9200
        run: bin/rails db:test:prepare test
```

Four things that are load-bearing and easy to get wrong:

1. **`ports: - 6543:5432`.** `config/database.yml` hardcodes `port: 6543`. Mapping the conventional `5432:5432` will fail to connect.
2. **`POSTGRES_PASSWORD: postgres` in the *step* env, not just the service env.** `database.yml` reads `password: ENV["POSTGRES_PASSWORD"]` on the Rails side.
3. **`OPENSEARCH_URL` must be set.** `Search::Base::Index` calls `ENV.fetch("OPENSEARCH_URL")` with no default; unset is a hard `KeyError`, not a skipped test.
4. **The apt step runs before `setup-ruby`.** `bundler-cache: true` compiles the `pg` native extension, which needs `libpq-dev` already present.

Do not add a `--health-cmd` to the OpenSearch service; that would depend on `curl` existing inside the image. The `Wait for OpenSearch` step is the readiness gate.

- [ ] **Step 2: Verify the YAML parses**

```bash
ruby -ryaml -e 'c = YAML.load_file(".github/workflows/ci.yml"); puts c["jobs"].keys.inspect'
```

Expected: `["lint", "test"]`

- [ ] **Step 3: Commit and push**

```bash
git add .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
Add CI test job with Postgres and OpenSearch services

The suite needs a live OpenSearch: ~15 test files create and delete real
indices, and Search::Base::Index does ENV.fetch("OPENSEARCH_URL") with no
default, so an unset var is a hard KeyError. Pinned to :3 (dev's floating
:latest currently resolves to 3.1.0) so an upstream release cannot turn the
deploy gate red overnight.

Postgres maps 6543:5432 because config/database.yml hardcodes port 6543,
which avoids touching database.yml at all.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

- [ ] **Step 4: Watch the test check and confirm it passes**

```bash
gh run watch "$(gh run list --workflow=ci.yml --branch worktree-github-ci-test-gate --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

Expected: both `lint` and `test` succeed. The `test` job should report roughly 4,500 runs with 0 failures and 0 errors.

**Compare the runs count to a local baseline, not just the failure count.** A collection-time crash can report zero failures while running almost nothing — this is exactly how the Ruby 4.0 `ostruct` break presented.

- [ ] **Step 5: Diagnose against the known checkpoints if it fails**

Pull the failing log first:

```bash
gh run view "$(gh run list --workflow=ci.yml --branch worktree-github-ci-test-gate --limit 1 --json databaseId --jq '.[0].databaseId')" --log-failed
```

Match the symptom to its fix:

- **`FATAL: database "the_greatest_books_legacy_test" does not exist`** — the spec's flagged unknown. `db:test:prepare` was expected to skip the `legacy_books` config because it is `replica: true`. It did not. Fix by creating an empty database before the test step:

  ```yaml
      - name: Create the legacy books test database
        env:
          PGPASSWORD: postgres
        run: psql -h localhost -p 6543 -U postgres -c 'CREATE DATABASE the_greatest_books_legacy_test'
  ```

  Place it immediately after `Wait for OpenSearch`.

- **The `Wait for OpenSearch` step times out** — the service container never started. Check the container log via the run's "Initialize containers" step. If OpenSearch died on a bootstrap check for `vm.max_map_count`, drop the service container and start it from a step instead, since service containers boot before any step can raise the sysctl:

  ```yaml
      - name: Start OpenSearch
        run: |
          sudo sysctl -w vm.max_map_count=262144
          docker run -d --name opensearch -p 9200:9200 \
            -e discovery.type=single-node \
            -e plugins.security.disabled=true \
            -e OPENSEARCH_INITIAL_ADMIN_PASSWORD=Ci_OpenSearch_2026! \
            -e OPENSEARCH_JAVA_OPTS="-Xms1g -Xmx1g" \
            opensearchproject/opensearch:3
  ```

  Place it before `Wait for OpenSearch` and delete the `opensearch` service block.

- **Failures that do not reproduce locally** — remember CI eager-loads (`config.eager_load = ENV["CI"].present?` and GitHub sets `CI=true`). A green local run does not guarantee a green CI run. Reproduce locally with `CI=true bin/rails test` before assuming CI is at fault.

Iterate until green. Do not proceed with a red test job.

---

### Task 3: Gate the image build and production deploy behind CI

**Files:**
- Modify: `.github/workflows/ci.yml` (add the `workflow_call` trigger)
- Modify: `.github/workflows/build-web-image.yml`

**Interfaces:**
- Consumes: the `CI` workflow from Tasks 1 and 2, at path `./.github/workflows/ci.yml`.
- Produces: a job id `ci` in `build-web-image.yml` that `build-and-push-image` depends on.

- [ ] **Step 1: Add the `workflow_call` trigger to `ci.yml`**

Change the `on:` block in `.github/workflows/ci.yml` from:

```yaml
on:
  pull_request:
```

to:

```yaml
on:
  pull_request:
  workflow_call:
```

Do **not** add `push:`. A reusable workflow with no inputs needs nothing else under `workflow_call:`.

- [ ] **Step 2: Add the `ci` job to `build-web-image.yml` and gate the build on it**

In `.github/workflows/build-web-image.yml`, the `jobs:` block currently begins:

```yaml
jobs:
  build-and-push-image:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
```

Change it to:

```yaml
jobs:
  ci:
    uses: ./.github/workflows/ci.yml

  build-and-push-image:
    needs: ci
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
```

Every existing step in `build-and-push-image` stays exactly as it is. `deploy-production.yml` is not touched — it is already decoupled behind the `repository_dispatch` event.

- [ ] **Step 3: Verify both files parse and the wiring is correct**

```bash
ruby -ryaml -e '
  ci = YAML.load_file(".github/workflows/ci.yml")
  build = YAML.load_file(".github/workflows/build-web-image.yml")
  raise "ci.yml missing workflow_call" unless ci[true].key?("workflow_call")
  raise "ci.yml must not have a push trigger" if ci[true].key?("push")
  raise "build missing ci job" unless build["jobs"]["ci"]["uses"] == "./.github/workflows/ci.yml"
  raise "build not gated" unless build["jobs"]["build-and-push-image"]["needs"] == "ci"
  puts "wiring OK"
'
```

Expected: `wiring OK`

(`ci[true]` is not a typo — YAML parses the bare key `on:` as the boolean `true`.)

- [ ] **Step 4: Confirm the PR checks are still green**

```bash
git add .github/workflows/ci.yml .github/workflows/build-web-image.yml
git commit -m "$(cat <<'EOF'
Gate the image build and production deploy on CI

Merging to main currently builds an image and SSH-deploys it to production
with nothing checking tests or lint in between. build-web-image.yml now calls
ci.yml as a reusable workflow and will not build unless it passes.

Failure mode is fail-safe: a broken gate means no image and no deploy, so
production keeps serving what it already serves. It cannot produce a bad
deploy, only a missing one.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push
gh run watch "$(gh run list --workflow=ci.yml --branch worktree-github-ci-test-gate --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

Expected: `lint` and `test` both green. Adding `workflow_call` does not change PR behavior.

The `needs: ci` wiring itself cannot be exercised until merge, because `build-web-image.yml` only triggers on `push` to `main`. That is verified in Task 5, Step 1.

---

### Task 4: Delete the dead `web-app/.github/` and correct the docs

**Files:**
- Delete: `web-app/.github/workflows/ci.yml`
- Delete: `web-app/.github/dependabot.yml`
- Modify: `CLAUDE.md` lines 23 and 29
- Modify: `docs/testing.md`, the "CI Requirements" section

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Delete the inert directory**

```bash
git rm -r web-app/.github
```

Both files are unreachable: GitHub reads workflows only from the root `.github/workflows/`, and Dependabot reads only the root `.github/dependabot.yml`. The Dependabot config is additionally wrong — it declares `directory: "/"`, where no `Gemfile` exists. Enabling Dependabot is a deliberate non-goal of this change.

- [ ] **Step 2: Correct `CLAUDE.md` line 23**

Replace:

```
bin/rails db:test:prepare test test:system   # what CI runs (system tests included)
```

with:

```
bin/rails db:test:prepare test   # what CI runs (no system tests)
```

- [ ] **Step 3: Correct `CLAUDE.md` line 29**

Replace:

```
Before claiming work is done, run `bin/rails test` (plus `test:system` for UI changes) and `bundle exec standardrb`, and add a Playwright E2E test for any new user-facing page/flow. The owner does **not** use brakeman — do not run it.
```

with:

```
Before claiming work is done, run `bin/rails test` (plus `test:system` for UI changes) and `bundle exec standardrb`, and add a Playwright E2E test for any new user-facing page/flow. The owner does **not** use brakeman — do not run it. CI runs `bin/rails test` and `standardrb` on every PR and blocks the merge if either fails; it also gates the image build, so a red suite on `main` means no deploy. CI does **not** run system tests or E2E — those stay local.
```

- [ ] **Step 4: Rewrite the "CI Requirements" section of `docs/testing.md`**

Replace:

```
### CI Requirements
- 100% test coverage enforced
- All tests must pass before merge
- No skipped tests without documented reason
- Coverage reports generated on each run
```

with:

```
### CI Requirements

CI is `.github/workflows/ci.yml` at the **repository root** (a `.github/` directory
nested under `web-app/` is never read by GitHub). It runs on every pull request and
is also called by `build-web-image.yml`, so a red suite blocks both the merge and
the production deploy.

Two jobs run in parallel:

- `lint` — `bundle exec standardrb --format github`
- `test` — `bin/rails db:test:prepare test`, against Postgres and OpenSearch service containers

What CI does **not** do:

- No system tests (`bin/rails test:system`) — the one system test targets a hostname
  that only resolves on the dev machine.
- No Playwright E2E — the suite needs Caddy, real certs, a live Firebase login, and
  dev-only book data.
- No brakeman, and no coverage enforcement or reporting.

Note that CI is stricter than a local run: `config.eager_load = ENV["CI"].present?`
and GitHub sets `CI=true`, so CI eager-loads the whole application. Reproduce a
CI-only failure locally with `CI=true bin/rails test`.
```

- [ ] **Step 5: Verify the docs no longer describe the old behavior**

```bash
grep -n "test:system   # what CI runs" CLAUDE.md; \
grep -n "100% test coverage enforced" docs/testing.md; \
ls web-app/.github 2>/dev/null; \
echo "--- all three should print nothing above ---"
```

Expected: no output before the marker line.

- [ ] **Step 6: Commit and confirm the PR is still green**

```bash
git add -A CLAUDE.md docs/testing.md web-app/.github
git commit -m "$(cat <<'EOF'
Delete the inert web-app/.github and correct the CI docs

web-app/.github/workflows/ci.yml has never run and web-app/.github/dependabot.yml
has never been read; both are nested too deep for GitHub to see. The dependabot
config also pointed at directory "/" where no Gemfile exists.

CLAUDE.md claimed test:system was "what CI runs" and docs/testing.md claimed 100%
coverage was enforced. Neither was ever true. Both now describe the real gate.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push
gh run watch "$(gh run list --workflow=ci.yml --branch worktree-github-ci-test-gate --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

Expected: `lint` and `test` both green.

---

### Task 5: Merge, verify the deploy gate, and apply branch protection

**Files:**
- No files. Repository settings only.

**Interfaces:**
- Consumes: check names `test` and `lint` from `ci.yml`, and the `ci` job from `build-web-image.yml`.
- Produces: nothing.

This is the only task that touches production. Do not start it until Tasks 1-4 are green on the PR.

- [ ] **Step 1: Merge the PR and watch the deploy gate fire for the first time**

```bash
gh pr merge --merge
sleep 10
gh run watch "$(gh run list --workflow=build-web-image.yml --branch main --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

Do **not** pass `--delete-branch`. The branch is checked out in a worktree, and git
refuses to delete a branch that a worktree is on. Clean up afterwards with
`ExitWorktree`, or `git worktree remove` from the main checkout.

Expected, in order: the `ci` job runs `test` and `lint` → both pass → `build-and-push-image` starts → image pushed → `repository_dispatch` fires.

Confirm the gate actually gated, rather than the build merely happening to succeed:

```bash
gh run view "$(gh run list --workflow=build-web-image.yml --branch main --limit 1 --json databaseId --jq '.[0].databaseId')" --json jobs --jq '.jobs[] | {name, conclusion, startedAt}'
```

Expected: `test` and `lint` both have an earlier `startedAt` than `build-and-push-image`.

- [ ] **Step 2: Confirm production still deployed**

```bash
gh run list --workflow=deploy-production.yml --limit 1
```

Expected: a `Deploy to Production` run triggered by `repository_dispatch`, concluded `success`. If it is missing, the dispatch did not fire — check the build run's "Trigger Deploy Workflow" step.

- [ ] **Step 3: Apply branch protection to `main`**

```bash
gh api -X PUT repos/ssherman/the-greatest/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["test", "lint"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
```

Every one of those four top-level keys is required by the API even when null.

`"strict": true` requires a branch to be up to date with `main` before merging, so a PR cannot pass against a stale base.

`"enforce_admins": false` is deliberate: it leaves an escape hatch to merge or push directly in an emergency. It does **not** weaken the deploy gate, because that gate is enforced by `needs: ci` inside the workflow, which nothing can bypass. Note that required status checks otherwise block direct pushes to `main` as well as merges — the admin exemption is what keeps a direct push possible.

Do not add review requirements or push restrictions; this is a solo repository and neither was asked for.

- [ ] **Step 4: Read the protection back and verify it**

```bash
gh api repos/ssherman/the-greatest/branches/main/protection \
  --jq '{checks: .required_status_checks.contexts, strict: .required_status_checks.strict, enforce_admins: .enforce_admins.enabled}'
```

Expected exactly:

```json
{"checks":["test","lint"],"strict":true,"enforce_admins":false}
```

If `checks` is empty or missing an entry, the context names do not match the job ids in `ci.yml`. They must be `test` and `lint` verbatim.

- [ ] **Step 5: Confirm the gate is live on the next PR**

There is nothing to commit for this task. Verify on the next real pull request that the "Merge pull request" button is disabled until `test` and `lint` report green, and that the PR page lists both as **Required**.

---

## Post-Implementation

After Task 5 completes, one memory file is now wrong and should be corrected: `merging-to-main-deploys-to-production.md` states "there is **no** test/lint CI at all" and that `web-app/.github/workflows/ci.yml` is nested too deep to ever run. Both facts changed. Update it to record that CI now gates both the merge and the deploy, and that the nested directory is gone.
