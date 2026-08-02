# Ruby 4.0.6 Upgrade in an Isolated Worktree

**Date:** 2026-08-01
**Branch:** `ruby-4-0-6` (off `main`)
**Worktree:** `~/dev/the-greatest-ruby4`

## Context

The app runs Ruby 3.4.7. We want 4.0.6. The complication is that another agent is
actively working in `~/dev/the-greatest` on branch `lists-public-ui-inc3`, and the
Ruby version is pinned in three places — two inside the repo and one **outside** it:

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
- The Docker image is **not** built and the deploy path is **not** exercised. The
  `Dockerfile` ARG is bumped for consistency, but production correctness on 4.0.6 is
  unverified by this work. This is the known gap.
- `~/dev/mise.toml` is not modified. Flipping it is a post-merge action for the owner.
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
invisible outside it. It is added to `.git/info/exclude` and deleted before the branch
is finished, so it never reaches a commit.

Note that `info/exclude` lives in the shared common git dir, so that one entry is
visible to the main repo too. It is inert there — `~/dev/the-greatest` has no
`mise.toml` to ignore — but it is the one piece of shared state this plan writes to.

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
2. `mise install ruby@4.0.6`. **Assert `ruby -v` reports 4.0.6 from inside the worktree
   before proceeding.** The failure mode to guard against is silently bundling under
   3.4.7 and believing the result.
3. Bump `.ruby-version` and the `Dockerfile` ARG.
4. `bundle install`. Triage blockers one at a time: bump each to the *minimum* version
   that works, record every bump for the final report.
5. `bin/rails test` (see coordination guard below).
6. `bundle exec standardrb`.
7. Fix fallout, re-run both to green.
8. Delete the local `mise.toml`; commit on `ruby-4-0-6`.

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
3. **Bundler 4** — Ruby 4.0 ships Bundler 4.0.3; the lock currently says
   `BUNDLED WITH 2.6.2`. That line will change and Bundler 4 has its own behaviour deltas.
4. **stdlib `openssl 4.0.0`** — bites anything pinning an older openssl.
5. **`Set#inspect` / `Proc#parameters` output formats changed** — only matters if a test
   asserts on them.
6. **ZJIT requires Rust 1.85+** at build time. A `mise install` failure here is a build
   concern, not a runtime one; ZJIT is opt-in and experimental, so it stays off.

## Verification

Gate: `bin/rails test` and `bundle exec standardrb`, both green.

Because the test database is shared with the other agent:

- **Skip `db:test:prepare`.** `git diff main...lists-public-ui-inc3 -- web-app/db/` is
  empty, so the existing test schema is already correct for this branch. Skipping it
  removes the destructive step and leaves only the suite run as a collision window.
  Verified as of `fca796f` on their branch — **re-run that diff before relying on it**,
  since they are still committing. If they land a migration, the shared test schema can
  drift and this assumption dies.
- Guard before running: `pgrep -af "rails test"` to check whether the other agent is
  mid-suite.
- Re-run once before believing any red result — a shared-database collision and a real
  regression look identical on the first run.
- Nothing in this plan reads or writes `the_greatest_development`.

## Rollback

Ruby 3.4.7 and its gems are untouched throughout. Reverting is
`git worktree remove ~/dev/the-greatest-ruby4` and deleting the branch; the main repo
never changes.

## Follow-ups (owner)

- Flip `~/dev/mise.toml` to `ruby = "4.0.6"` after merge, once the other agent's branch
  is finished. It is the shared file, so the timing is a coordination decision.
- Build the Docker image on 4.0.6 and verify the deploy path before shipping to
  production — the non-goal called out above.
- `git worktree remove ~/dev/the-greatest-ruby4` after merge.
