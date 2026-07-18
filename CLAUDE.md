# CLAUDE.md

The Greatest — one Rails 8 app serving four sites (books, music, movies, games) from a single
codebase, switched by hostname. The Rails app lives in **`web-app/`**. This file is the canonical
guide; deeper detail lives in `docs/` (linked at the bottom).

## Working directory (read first)

Run **all** Rails/yarn commands from `web-app/`. Docs live in `docs/` at the **project root**, not
`web-app/docs/`. When in doubt, `pwd` first.

```bash
cd web-app
```

## Commands

```bash
bin/dev                       # start dev (foreman: web + sidekiq + JS/CSS watchers, Procfile.dev)
bin/setup                     # install deps, prepare db, boot
bin/rails test                # unit/integration (Minitest)
bin/rails test test/models/music/   # scope to a namespace/dir
bin/rails db:test:prepare test test:system   # what CI runs (system tests included)
bundle exec standardrb        # lint (Ruby Standard style, see .standard.yml); `--fix` autocorrects. NOT bin/rubocop (omakase — conflicting style)
yarn test:e2e                 # Playwright E2E (needs local dev server + e2e/.env)
yarn build:all                # JS (Rollup) + per-domain CSS (Tailwind)
```

Before claiming work is done, run `bin/rails test` (plus `test:system` for UI changes) and `bundle exec standardrb`, and add a Playwright E2E test for any new user-facing page/flow. The owner does **not** use brakeman — do not run it.

## Where code actually lives

```
web-app/app/
  models/<domain>/        # Music::Album, Books::Book, ...  (shared models like user.rb at root)
  lib/services/<domain>/  # business logic — services live HERE, NOT app/services/
  lib/data_importers/     # external-source importers (see docs/features/data_importers.md)
  lib/{search,rankings,item_rankings,actions,filters}/   # more domain logic
  sidekiq/                # background jobs (Sidekiq) — NOT app/jobs/
  components/             # ViewComponents
  policies/               # authorization
  controllers/            # + admin/ namespace
  javascript/             # {application,books,music,movies,games}.js entrypoints + Stimulus controllers/
  assets/stylesheets/<domain>/application.css  # built to assets/builds/ (no Rails asset pipeline)
web-app/test/             # mirrors app/, namespaced to match (module Music; class AlbumTest)
docs/                     # project root, NOT web-app/
```

## The development database is not disposable

**The books data exists ONLY in development.** It is not in production, so `bin/refresh-dev-db.sh`
cannot bring it back — rebuilding it means re-running `data_migration:all` against the legacy DB,
which takes **hours**.

- **Never run a destructive command against development.** A `PreToolUse` hook
  (`.claude/hooks/block-destructive-db.sh`) hard-blocks `create_fixtures`, `db:drop`/`db:reset`/
  `db:schema:load`, bulk `delete_all`/`destroy_all`/`update_all` in `rails runner`, and raw
  `DROP`/`TRUNCATE`/`DELETE FROM`, unless `RAILS_ENV=test` is explicit.
- **`ActiveRecord::FixtureSet.create_fixtures` TRUNCATES every table it names.** It is not a read.
  To inspect a fixture, read the YAML: `sed -n '/^name:/,/^$/p' test/fixtures/<file>.yml`.
- **Snapshot before bulk work:** `bin/snapshot-dev-db.sh --label pre-migration`, restore with
  `bin/snapshot-dev-db.sh --restore`. Turns an hours-long rebuild into a ~1 minute restore.
- `bin/refresh-dev-db.sh` restores music/games/movies from the production backup. It does **not**
  restore books.

## Non-negotiable conventions

- **Use Rails generators** — never hand-create models/controllers/jobs/components. Generators create
  the matching test file. Jobs: `bin/rails generate sidekiq:job music/foo` (NOT `generate job`).
- **Namespace all media code** (`Books::`, `Movies::`, `Games::`, `Music::`); shared models (`User`,
  `List`, `RankingConfiguration`) stay in the global namespace. Tests must mirror the namespace.
- **Skinny models, fat services.** Models hold only validations/associations/scopes. Business logic
  goes in service objects under `app/lib/services/<domain>/` using the Result pattern:
  `Result = Struct.new(:success?, :data, :errors, keyword_init: true)` (`keyword_init` is kept on
  purpose — a Standard cop is disabled for it).
- **Rails 8 enum syntax:** `enum :status, { active: 0 }` (colon prefix), never `enum status: {...}`.
- **Polymorphic associations** use the `_able` suffix (`reviewable`, `listable`). In fixtures use
  `listable: dark_side (Music::Album)` — never set `_type` manually.
- **DataImporters:** for identifiers always `find_or_initialize_by`, never `build` (avoids dupes on
  provider re-runs). See `docs/features/data_importers.md`.
- **No code comments** unless asked; write self-documenting code and follow existing patterns.

## Testing (Minitest + fixtures + Mocha)

- 100% coverage of public methods; never test private methods. Stub all external APIs (Mocha).
- **Check actual fixture names** before referencing — they are semantic (`regular_user`), not `one`/`two`.
- Auth in integration tests: `sign_in_as(@user, stub_auth: true)`. JSON requests use `as: :json`.
- Controller tests assert **behavior** (status codes, params, no errors) — never HTML/CSS/copy. If a
  designer could change it freely, don't test it.
- **Every new user-facing page/flow needs a Playwright E2E test** in `web-app/e2e/tests/`. Add
  `data-testid` (kebab-case) only when role/text/label can't target an element.

## Frontend

Server-first + progressive enhancement: Turbo Frames, minimal Stimulus controllers, ViewComponents,
DaisyUI 5 on Tailwind CSS 4. JS bundled by Rollup into per-domain IIFE bundles; CSS built per domain.
No Rails asset pipeline — builds are served from `public/`.

## Deeper docs

- `docs/dev-core-values.md` — full development principles
- `docs/testing.md` — complete testing guide · `docs/features/e2e-testing.md` — Playwright
- `docs/summary.md` — architecture & goals · `docs/dev_setup.md` — local setup
- `docs/features/` — feature docs (data_importers, authentication, rankings, search, ...)
- `docs/documentation.md` & `docs/spec-instructions.md` — docs/spec workflow (every model/service
  gets a doc in `docs/`; plan non-trivial work in `docs/specs/`)
