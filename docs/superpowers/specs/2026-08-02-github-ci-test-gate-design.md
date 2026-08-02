# GitHub CI: Test and Lint Gate on PRs and Deploys

**Date:** 2026-08-02
**Branch:** `worktree-github-ci-test-gate` (off `main`)
**Worktree:** `.claude/worktrees/github-ci-test-gate`

## Context

The repository has **no CI**. Not "weak CI" — none.

`web-app/.github/workflows/ci.yml` looks like CI and has never run once. GitHub Actions
reads workflows only from `.github/workflows/` at the **repository root**; a
`.github/` directory nested inside a subdirectory is inert. `gh workflow list` confirms
exactly two registered workflows, both at the root:

| Workflow | Trigger | Effect |
|---|---|---|
| `build-web-image.yml` | `push` to `main` | Builds the Docker image, pushes to ghcr, fires `repository_dispatch` |
| `deploy-production.yml` | `repository_dispatch: image-built-event` | SSHes to prod and restarts the stack |

So today: **merge to `main` → image built → production deployed, with nothing checking
tests or lint anywhere in between.** Anything that must be verified "before shipping"
has to happen before the merge button is pressed, by hand.

That ghost `ci.yml` would not have worked even if GitHub had read it. Three independent
defects:

1. No `working-directory`. The Rails app is in `web-app/`; every step would fail to find
   `.ruby-version`, `Gemfile`, or `bin/rails`.
2. No OpenSearch service. Around fifteen test files create and delete **real** indices,
   and `Search::Base::Index` calls `ENV.fetch("OPENSEARCH_URL")` with no default — an
   unset variable is a hard `KeyError`.
3. It runs `bin/brakeman`, which the owner does not use and `CLAUDE.md` explicitly
   forbids.

It is a decent record of intent and a bad record of fact. It gets deleted.

## Goals

- Every pull request runs `bin/rails test` and `bundle exec standardrb`, and cannot be
  merged while either is red.
- A merge to `main` cannot build an image or deploy to production unless those same two
  checks pass.
- One definition of the test environment, consumed by both paths.

## Non-goals

Named explicitly so the implementation does not grow:

- **Playwright / E2E.** Decided against. The suite needs the dev machine's whole world:
  Caddy with Cloudflare DNS-01 certs on real hostnames, a live Firebase email/password
  login, and dev-only book data that takes hours to rebuild. Neither a self-hosted
  runner (the repo is **public** — a forked PR could execute code on the dev box and
  reach the dev DB) nor an ephemeral CI copy is worth the cost right now.
- **System tests.** `bin/rails test:system` is excluded. There is exactly one system
  test and it sets `Capybara.app_host` to a hostname whose public DNS record points at
  `172.18.93.203`, a private address meaningful only on the dev machine.
- **brakeman.** Per `CLAUDE.md`.
- **Dependabot.** `web-app/.github/dependabot.yml` is dead for the same nesting reason
  and *also* misconfigured (`directory: "/"`, where no `Gemfile` exists). Enabling it
  is a separate decision with real ongoing PR noise; it is not smuggled into a CI change
  on a repo that auto-deploys.
- Asset/JS builds, coverage reporting, security scanning.

## Architecture

Three files at the repository root:

```
.github/workflows/
  ci.yml                  # NEW      — on: [pull_request, workflow_call]
  build-web-image.yml     # MODIFIED — calls ci.yml; build gated behind it
  deploy-production.yml   # UNCHANGED
```

`ci.yml` is a **reusable workflow**. Its trigger is `pull_request` and `workflow_call`,
deliberately **not** `push: main` — main is already covered through the caller, and a
`push` trigger would run the suite twice on every merge.

`build-web-image.yml` gains one job and one line:

```yaml
jobs:
  ci:
    uses: ./.github/workflows/ci.yml
  build-and-push-image:
    needs: ci
    # ... every existing step unchanged
```

Rejected alternatives:

- **Duplicating the jobs** into `build-web-image.yml`. Simpler to read, but the service
  containers and env would be defined twice and drift.
- **`workflow_run` trigger.** Keeps the files independent, but always evaluates the
  *default branch's* workflow definition and adds a layer of indirection when debugging
  a deploy that did not happen.

### Data flow

**Pull request:** `pull_request` → `ci.yml` runs `test` and `lint` in parallel → branch
protection blocks merge until both are green.

**Merge to `main`:** `push` → `build-web-image.yml` → `ci` job (test + lint) → on success
`build-and-push-image` → ghcr push → `repository_dispatch` → `deploy-production.yml`.

`deploy-production.yml` needs no changes; it is already decoupled behind the dispatch
event.

## The `test` job environment

Every fact below was verified against the repo, not assumed.

### Working directory

`defaults.run.working-directory: web-app` covers `run:` steps but **not actions**.
`ruby/setup-ruby` needs its own `working-directory: web-app` input, or it cannot find
`.ruby-version` (`ruby-4.0.6`) or `Gemfile.lock` for `bundler-cache: true`.

### Postgres

`config/database.yml` hardcodes `host: localhost`, `port: 6543`, `username: postgres`,
`password: ENV["POSTGRES_PASSWORD"]`. The service container therefore maps **`6543:5432`**
and the job sets `POSTGRES_PASSWORD`, and `database.yml` needs no change.

This is deliberately not the `DATABASE_URL` approach the ghost file used: with a
multi-database config, `DATABASE_URL` merges into `primary` only and interacts poorly
with the named `legacy_books` entry.

### OpenSearch (required)

Mirrors `docker-compose.yml`: `discovery.type=single-node`,
`plugins.security.disabled=true`, `OPENSEARCH_INITIAL_ADMIN_PASSWORD`,
`OPENSEARCH_JAVA_OPTS=-Xms1g -Xmx1g`. The job sets
`OPENSEARCH_URL=http://localhost:9200`.

Two specifics:

- **Pin the image to `opensearchproject/opensearch:3`, not `:latest`.** Dev's container
  is `:latest`, which currently resolves to **3.1.0** — that is the version the search
  tests are known to pass against, so CI pins to the same major. `:latest` in CI would
  let an upstream release turn the production deploy gate red overnight. Accept that dev
  and CI can drift, since dev keeps floating on `:latest`; if a search test ever fails
  only in CI, compare `curl localhost:9200` against the pinned tag first.
- **Readiness is an explicit polling step, not a service `--health-cmd`.** A health
  command depends on `curl` existing inside that image; a job step polling
  `localhost:9200` does not.

Index isolation needs no work: `Search::Base::Index#index_name` already appends
`Process.pid` in the test environment, so the parallel test workers
(`parallelize(workers: :number_of_processors)`) cannot collide on a shared cluster.

### Not needed

| Dependency | Why not |
|---|---|
| Redis | `test_helper.rb` sets `Sidekiq::Testing.inline!` |
| `RAILS_MASTER_KEY` | Nothing in `app/`, `config/`, or `lib/` reads `Rails.application.credentials` |
| `.env` | `dotenv-rails` tolerates a missing file |
| Chrome | No system tests in CI |
| Node / yarn | No asset build in the test path |
| annotaterb workaround | `lib/tasks/annotate_rb.rake` is guarded by `Rails.env.development?` |

Two apt packages go in as cheap insurance: `libpq-dev` (the `pg` native extension) and
`libvips` (ActiveStorage's default variant processor in Rails 8, and present in the
production `Dockerfile`).

### Command

```
bin/rails db:test:prepare test
```

## Risks and known checkpoints

**CI is stricter than a local run.** `config/environments/test.rb` sets
`config.eager_load = ENV["CI"].present?`, and GitHub sets `CI=true`. CI eager-loads the
whole application. This is a feature — it is exactly the check that caught Ruby 4.0
dropping `ostruct` — but a green local `bin/rails test` does **not** guarantee a green
CI run.

**The legacy replica is a first-run unknown.** `db:test:prepare` should skip the
`legacy_books` configuration because it is `replica: true`, and the only two tests that
touch `LegacyBooks` assert `abstract_class?` and `table_name` without ever opening a
connection. This is expected, not proven. If schema preparation does try to reach
`the_greatest_books_legacy_test`, the fallback is a `psql -c 'CREATE DATABASE ...'` step
before the test command, or setting `LEGACY_BOOKS_TEST_DATABASE`.

**A red `main` is a silent non-deploy.** Today every merge ships. After this change, a
failing merge builds no image and prod keeps serving the previous one. Nothing breaks
and nothing bad deploys, but the merge quietly does not ship. GitHub emails on workflow
failure by default, which is the notification path.

**Suite runtime becomes deploy latency.** ~4,500 tests plus eager load plus OpenSearch
startup, so roughly 5–8 minutes added before an image is built. A flaky test blocks a
deploy until re-run. This is the accepted cost of the gate.

## Branch protection

A check that runs is not a check that blocks. Merging stays possible with a red `test`
job until `main` carries a rule requiring both checks. This is a repository *settings*
change, applied via `gh api` as an explicit final step:

- Require status checks `test` and `lint` to pass before merging.
- Require branches to be up to date before merging.

Scope it to those two requirements only — do not add review requirements or restrict
pushes, which would change the solo workflow beyond what was asked.

## Verification

There is an inherent chicken-and-egg problem: a workflow cannot be tested without
pushing it, and pushing to `main` deploys. The split resolves cleanly.

**Fully verifiable before merge.** The `pull_request` trigger fires on this branch's own
PR, so `ci.yml` is exercised end to end — real service containers, real suite — and
watched green before the merge button is touched. Expect several push-fix-push rounds;
this is normal for first CI setup and carries zero production risk.

**Not verifiable before merge.** The `workflow_call` path, because
`build-web-image.yml` only triggers on `push` to `main`. This is four lines of YAML and
its failure mode is fail-safe: a mistake means the build workflow does not start, so no
image and no deploy, and production continues serving what it already serves. It cannot
produce a *bad* deploy, only a missing one.

**First merge is watched.** Confirm the `ci` job appears in the `build-web-image` run,
that the build waits for it, and that the deploy still fires.

**Rollback** is deleting the `ci:` job and the `needs: ci` line — a return to exactly
today's behavior.

Note on baseline: no local test-suite run was taken for this spec. The change adds no
Ruby code, only YAML and documentation, and worktrees share the `the_greatest_test`
database, so a local run would not be informative here. Verification happens on GitHub.

## Documentation to correct

Both are wrong the moment this ships, and are fixed in the same change:

- **`CLAUDE.md`** presents `bin/rails db:test:prepare test test:system` as "what CI
  runs". It is not, and never was — and system tests remain excluded. Replace with a
  description of the actual gate, including the fact that merging to `main` now requires
  green CI.
- **`docs/testing.md`** has a "CI Requirements" section claiming 100% coverage is
  enforced and coverage reports are generated on each run. None of that has ever
  existed and none of it is being added. Rewrite it to state what actually runs.

## Files changed

| File | Change |
|---|---|
| `.github/workflows/ci.yml` | New — `test` + `lint` jobs, `pull_request` + `workflow_call` |
| `.github/workflows/build-web-image.yml` | Add `ci` job, add `needs: ci` to the build job |
| `web-app/.github/` | Delete the directory (`workflows/ci.yml`, `dependabot.yml`) |
| `CLAUDE.md` | Correct the CI description |
| `docs/testing.md` | Rewrite the "CI Requirements" section |
| *(repo settings)* | Branch protection on `main` via `gh api` |
