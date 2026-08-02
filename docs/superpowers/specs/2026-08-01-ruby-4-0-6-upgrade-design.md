# Ruby 4.0.6 Upgrade in an Isolated Worktree

**Date:** 2026-08-01
**Branch:** `ruby-4-0-6` (off `main`)
**Worktree:** `~/dev/the-greatest-ruby4`

## Context

The app runs Ruby 3.4.7. We want 4.0.6. The complication is that another agent is
working concurrently in the same repo, and the Ruby version is pinned in three places —
two inside the repo and one **outside** it:

| Location | Value | Scope |
|---|---|---|
| `web-app/.ruby-version` | `3.4.7` | repo |
| `web-app/Dockerfile` (`ARG RUBY_VERSION`) | `3.4.7` | repo |
| `~/dev/mise.toml` | `3.4.7` | **the entire `~/dev` tree** |

That third file is the hazard. Editing it to `4.0.6` would silently switch the other
agent's workspace to a Ruby with zero gems installed, and their next `bin/rails test`
would fail for reasons invisible from inside their branch.

Two things isolate for free and are worth stating so nobody re-solves them:

- **Gems.** There is no `web-app/.bundle/config`, so each mise-managed Ruby gets its
  own `GEM_HOME`. Gems built for 4.0.6 cannot touch 3.4.7's.
- **Working files.** A git worktree has its own checkout of every tracked file,
  including `Gemfile.lock`.

One thing does **not** isolate: `config/database.yml` hard-codes the test database as
`the_greatest_test`, and `test_helper.rb` runs `parallelize(workers: :number_of_processors)`,
fanning that out to `the_greatest_test-0..N`. Two suites running at once truncate each
other's tables. **Decision: coordinate rather than isolate** (see Verification).

## Goals

- Ruby 4.0.6 running the app, with `bin/rails test` and `bundle exec standardrb` green.
- Zero disruption to the agent working in `~/dev/the-greatest`.

## Non-goals

- System tests (`bin/rails test:system`) and Playwright E2E are not run.
- ~~The Docker image is not built and the deploy path is not exercised.~~ **Closed
  2026-08-02** — this was originally a non-goal, but because merging auto-deploys to
  production with no human gate (see "Pre-merge gate" below), it was promoted to a
  pre-merge requirement and satisfied. The image builds on `ruby:4.0.6-slim` and the
  whole app eager-loads under `RAILS_ENV=production`. Details in "Pre-merge gate".
  Still **not** exercised: an actual deploy, and the app serving real traffic.
- `~/dev/mise.toml` is not modified by this worktree's own work — see "Merge-time
  actions" below for when and why it must move.
- No opportunistic gem updates. Only versions that actively block 4.0.6 move.

## Approach

A git worktree with a worktree-local mise config.

```bash
git worktree add ~/dev/the-greatest-ruby4 -b ruby-4-0-6 main
```

The worktree root gets an **untracked** `mise.toml`:

```toml
[tools]
node = "24.11.1"   # identical to ~/dev/mise.toml so nothing else shifts
ruby = "4.0.6"
```

mise resolves nearest-config-first, so this file wins inside the worktree and is
invisible outside it. It is added to `.git/info/exclude`, so it can never reach a
commit. **Keep it until after merge** — deleting it strands the worktree back on Ruby
3.4.7. Its removal is a post-merge step (see "Merge-time actions").

Note that `info/exclude` lives in the shared common git dir, so that one entry is
visible to the main repo too. It is inert there — `~/dev/the-greatest` has no
`mise.toml` to ignore — but it is the one piece of shared state this plan writes to.

**A global mise setting is not a substitute for this file.** Because `~/dev/mise.toml`
pins `3.4.7` and sits nearer than `~/.config/mise/config.toml`, it overrides the global
config for everything under `~/dev`, the worktree included. Setting Ruby 4.0.6 globally
leaves the worktree resolving 3.4.7 — verified directly, `mise current ruby` returned
`3.4.7` inside the worktree while 4.0.6 was installed. The only ways to win are a
nearer config (this plan) or editing `~/dev/mise.toml` (rejected — it breaks the other
agent).

Branch is cut from `main`, not `lists-public-ui-inc3` — the upgrade is independent of
the lists work.

### Rejected alternatives

- **Docker (`--build-arg RUBY_VERSION=4.0.6`).** Doesn't solve the problem: you'd still
  edit the same working tree the other agent is editing. The `Dockerfile` is also a
  production target (`RAILS_ENV=production`, precompiled assets, no test gems), so
  running the suite in it needs real plumbing plus networking to host Postgres on `:6543`.
- **Worktree + flipping `~/dev/mise.toml`.** Breaks the other agent, as described above.
- **In-place on the current branch.** Mixes an infrastructure change into unrelated
  feature work and hands the other agent a half-upgraded toolchain.

### Gitignored files the worktree will not have

A fresh worktree checks out tracked files only. These exist in the main repo, are
gitignored, and are required for the app to boot and reach Postgres:

- `web-app/.env` — contains `POSTGRES_PASSWORD`
- `web-app/config/master.key` — credentials decryption

Symlink both from `~/dev/the-greatest`. They are gitignored in the worktree too, so
they create no git noise.

## Repo changes

| File | Change |
|---|---|
| `web-app/.ruby-version` | `3.4.7` → `4.0.6` |
| `web-app/Dockerfile` | `ARG RUBY_VERSION=3.4.7` → `4.0.6` (its own comment requires these match) |
| `web-app/Gemfile.lock` | `BUNDLED WITH` → Bundler 4.x, plus blocker gem bumps |
| `web-app/Gemfile` | only if a blocker requires an explicit constraint change |

## Implementation sequence

1. Create the worktree; write the local `mise.toml`; add it to `.git/info/exclude`;
   symlink `.env` and `config/master.key`.
2. `mise install ruby@4.0.6` — already installed as of 2026-08-01, so this is a no-op;
   no compile needed. **Assert `ruby -v` reports 4.0.6 from inside the worktree before
   proceeding.** The failure mode to guard against is silently bundling under 3.4.7 and
   believing the result. This guard is not theoretical: with 4.0.6 installed but no
   worktree-local config, the worktree measurably still resolved 3.4.7.
3. Bump `.ruby-version` and the `Dockerfile` ARG.
4. `bundle install`. Triage blockers one at a time: bump each to the *minimum* version
   that works, record every bump for the final report.
5. `bin/rails test` (see coordination guard below).
6. `bundle exec standardrb`.
7. Fix fallout, re-run both to green.
8. Commit on `ruby-4-0-6`. **Keep** the local `mise.toml` — it is in `info/exclude` and
   cannot be committed accidentally, and deleting it now would strand the worktree back
   on 3.4.7. Its removal belongs to the post-merge follow-up, once `~/dev/mise.toml`
   carries 4.0.6.

## Risk register

Rails is already at **8.1.3.1**, and Rails added Ruby 4.0 support in 8.1.3 — the
framework itself is not a risk. Ruby 4.0 is also a mild language-level upgrade from 3.4.
The real exposure is in the toolchain:

1. **Precompiled native gems** — `nokogiri 1.19.4`, `pg 1.6.3`, `ffi 1.17.4`, `msgpack`,
   `bootsnap`, `ruby-vips`, `prism`, `puma`, `racc`, `json`, `websocket-driver`. These
   ship per-ABI binaries; any released before Ruby 4.0 has no 4.0 build. **This is where
   most bumps will land.**
2. **`standard` / `rubocop` `TargetRubyVersion`** — both read `.ruby-version`. A version
   that doesn't recognise Ruby 4.0 errors out before linting anything. Likely a bump.
3. **Bundler 4** — Ruby 4.0 ships Bundler 4.0.16; the lock currently says
   `BUNDLED WITH 2.6.2`. That line will change and Bundler 4 has its own behaviour deltas.
4. **stdlib `openssl 4.0.0`** — bites anything pinning an older openssl.
5. **`Set#inspect` / `Proc#parameters` output formats changed** — only matters if a test
   asserts on them.
6. **ZJIT requires Rust 1.85+** at build time. A `mise install` failure here is a build
   concern, not a runtime one; ZJIT is opt-in and experimental, so it stays off.

## Verification

Gate: `bin/rails test` and `bundle exec standardrb`, both green.

Because the test database is shared with the other agent — and note that **putting them
in a worktree too does not change this**. Worktrees isolate files, gems, and toolchain;
they do not isolate Postgres. Every worktree resolves `database.yml` to the same
`the_greatest_test`, so the collision risk scales with the number of concurrent
worktrees, not away from it. If this becomes routine, the env-override on the `test`
primary (mirroring the existing `LEGACY_BOOKS_TEST_DATABASE`) is the fix.

- **Skip `db:test:prepare` unless a migration says otherwise.** This branch adds no
  migrations, so the existing test schema is already correct for it, and skipping the
  step removes the only destructive operation — leaving the suite run as the sole
  collision window. This is now a **run-time check, not a pre-verified fact**: the other
  agent's next branch is unknown, so before running the suite confirm
  `git diff main...HEAD -- web-app/db/` is empty on this branch and that no newer
  migration has landed on `main`. If the shared test schema has drifted, stop and
  coordinate rather than running `db:test:prepare` underneath someone else.
- Guard before running: `pgrep -af "rails test"` to check whether the other agent is
  mid-suite.
- Re-run once before believing any red result — a shared-database collision and a real
  regression look identical on the first run.
- Nothing in this plan reads or writes `the_greatest_development`.

## Rollback

Ruby 3.4.7 and its gems are untouched throughout. Reverting is
`git worktree remove ~/dev/the-greatest-ruby4` and deleting the branch; the main repo
never changes.

## Pre-merge gate (required — read before merging to `main`)

This repo has **no automated test or lint CI**. The only workflows GitHub Actions
actually discovers (root-level `.github/workflows/`) are:

- `.github/workflows/build-web-image.yml` — triggers `on: push: branches: [main]`
  (lines 3-6), builds the image, tags it `latest`, and pushes to `ghcr.io` (lines 38-41),
  then on success fires a `repository_dispatch` with `image-built-event` (lines 78-84).
- `.github/workflows/deploy-production.yml` — listens for that event (lines 5-6, 46-48),
  SSHes into production, and runs `docker compose pull` + `docker compose up -d` against
  `ghcr.io/ssherman/the-greatest:latest`.

Chained together: **merging `ruby-4-0-6` into `main` builds the Ruby 4.0.6 image and
ships it to production automatically, with no human approval step in between.**
`web-app/.github/workflows/ci.yml` looks like it would catch a regression first, but it
never runs — GitHub only reads workflows under the repository **root's**
`.github/workflows/`, and this file is nested one directory too deep, inside `web-app/`.
It would also need editing before it could run here regardless, since it invokes
`bin/brakeman`, a tool this project does not use. So there is no automated gate between
merge and production; the only gate is whatever a human verifies before merging.

**Therefore: build the Docker image on 4.0.6 and confirm it boots before merging** — the
non-goal this spec deliberately deferred belongs here, not after. Context that narrows
what is actually unknown, so this isn't a shot in the dark:

- `docker.io/library/ruby:4.0.6-slim` exists, so the base image resolves.
- `Gemfile.lock` has no `RUBY VERSION` stanza to go stale.
- `PLATFORMS` still lists `x86_64-linux` and `aarch64-linux`, so `BUNDLE_DEPLOYMENT="1"`
  (`Dockerfile:24`) will not trip on a missing platform entry.
- The local (non-Docker) `bundle install` in this worktree resolved the same
  precompiled `x86_64-linux` artifacts the Docker build would use.

### Status: satisfied 2026-08-02

The image was built and boot-checked. Results:

```
docker build -t tg-ruby4-verify:local .        # exit 0, 1.15GB
```

- Base resolved to `docker.io/library/ruby:4.0.6-slim`.
- `bundle install` succeeded under `BUNDLE_DEPLOYMENT="1"` / `BUNDLE_WITHOUT="development"`.
- Both previously-unexercised steps ran clean: `bundle exec bootsnap precompile --gemfile`
  and `bundle exec bootsnap precompile app/ lib/` (`Dockerfile:49`, `:59`), and
  `SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile` (`Dockerfile:62`).
- In-image versions confirmed: `ruby 4.0.6`, Bundler `4.0.16`, `RAILS_ENV=production`,
  assets present under `public/assets`.
- **Every class in the app eager-loaded under `RAILS_ENV=production`**:
  `./bin/rails zeitwerk:check` → `All is good!`

One thing to know if you repeat this: a bare `docker run` of `zeitwerk:check` fails with
`ArgumentError: missing required option :name` plus an AWS instance-profile credential
error. That is **not** a Ruby 4.0 problem — `config.active_storage.service = :cloudflare`
(`config/environments/production.rb:25`) resolves `bucket: <%= ENV['STORAGE_BUCKET'] %>`
to `nil` in a bare container. Pass dummy `STORAGE_ENDPOINT` / `STORAGE_ACCESS_KEY_ID` /
`STORAGE_SECRET_ACCESS_KEY` / `STORAGE_BUCKET` values and it eager-loads cleanly.

**Still unverified:** an actual deploy, and the app serving real traffic on 4.0.6. The
build and boot path are proven; runtime behaviour under load is not.

## Merge-time actions (owner)

`~/dev/mise.toml` must flip to `ruby = "4.0.6"` **at merge time**, not as an unhurried
afterwards. The moment `main` carries this `Gemfile.lock`, every worktree still
resolving Ruby 3.4.7 is affected, regardless of whether `mise.toml` has been flipped yet:

- Ruby 3.4.7's shared `GEM_HOME` has `ostruct-0.6.1` installed; this lockfile pins
  `ostruct (0.6.3)`. `bundle check` fails in any 3.4.7 worktree, which makes
  `bundle install` mandatory there before `bin/rails` will boot at all.
- `web-app/bin/bundle` derives its version requirement from `BUNDLED WITH` (`4.0.16` →
  `~> 4.0`). Ruby 3.4.7 only has Bundler 2.6.2 and 2.6.9 available, and that binstub does
  not auto-install a matching Bundler — it warns and `exit 42`
  (`web-app/bin/bundle:88-95`). This is narrower than it sounds: nothing in the repo
  actually invokes `bin/bundle` — `bin/setup:16` and `Procfile.dev` both call bare
  `bundle` — so it only bites someone who types `bin/bundle` explicitly.

Practical steps, in order:

1. At merge, flip `~/dev/mise.toml`'s `ruby` value to `4.0.6`. This is what actually
   moves every other worktree onto the new Ruby — it is not optional and not a
   convenience to get to later.
2. Any worktree that intentionally stays on 3.4.7 needs `bundle install` run once,
   deliberately, before its `bin/rails` will boot again.
3. **Caution:** the first `bundle install` run under Bundler 2.6.x (i.e. from a 3.4.7
   worktree, after the mise flip) may rewrite `BUNDLED WITH` back down to `2.6.x` in
   that worktree's checkout of `Gemfile.lock`. If it does, that rewrite must **not** be
   committed — it would silently downgrade the Bundler pin for everyone else.
4. Delete the worktree-local `mise.toml` once `~/dev/mise.toml` carries `4.0.6` — it is
   then redundant.

## Follow-ups (owner)

- `git worktree remove ~/dev/the-greatest-ruby4` after merge.
