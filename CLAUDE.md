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
bin/rails db:test:prepare test   # what CI runs (no system tests)
bundle exec standardrb        # lint (Ruby Standard style, see .standard.yml); `--fix` autocorrects. NOT bin/rubocop (omakase — conflicting style)
yarn test:e2e                 # Playwright E2E (needs local dev server + e2e/.env)
yarn build:all                # JS (Rollup) + per-domain CSS (Tailwind)
```

Before claiming work is done, run `bin/rails test` (plus `test:system` for UI changes) and `bundle exec standardrb`, and add a Playwright E2E test for any new user-facing page/flow. The owner does **not** use brakeman — do not run it. CI runs `bin/rails test` and `standardrb` on every PR and blocks the merge if either fails; it also gates the image build, so a red suite on `main` means no deploy. CI does **not** run system tests or E2E — those stay local.

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
- **AI response schemas are `OpenAI::BaseModel` subclasses.** `to_json_schema` is a **class** method —
  `schema.new.to_json_schema` raises `NoMethodError`. There is no `RubyLLM::Schema` in this app.
- **Build OpenSearch clients through `Search::Shared::Client.instance`**, never `OpenSearch::Client.new`.
  It carries the serializer that avoids multi_json's deprecated API; the serializer only needs
  configuring in one place, and the three separately-constructed clients this replaced (`Search::Base::Index`,
  `Search::Base::Search`, and the shared client) were three places that had to be kept in sync.

## Testing (Minitest + fixtures + Mocha)

- 100% coverage of public methods; never test private methods. Stub all external APIs (Mocha).
- **Check actual fixture names** before referencing — they are semantic (`regular_user`), not `one`/`two`.
- Auth in integration tests: `sign_in_as(@user, stub_auth: true)`. JSON requests use `as: :json`.
- Controller tests assert **behavior** (status codes, params, no errors) — never HTML/CSS/copy. If a
  designer could change it freely, don't test it.
- **Every new user-facing page/flow needs a Playwright E2E test** in `web-app/e2e/tests/`. Add
  `data-testid` (kebab-case) only when role/text/label can't target an element.
- **Minitest is 6.x.** `assert_equal nil, x` is a **hard failure**, not a warning — use `assert_nil`, or
  compare tuples (`assert_equal [a, b], [x, y]`) when the intent is "these did not change" and one of
  them may be nil. Also gone in 6: `assert_send`, `minitest/mock` (its own gem now — we don't use it),
  the `MiniTest` namespace, and spec expectations on `Object`.
- **Sidekiq test mode is `Sidekiq.testing!(:inline)`** (set globally in `test_helper.rb`); never
  `require "sidekiq/testing"`, which Sidekiq 9 removes. `Sidekiq::Testing.fake! { }` blocks still work
  and are how you stop a job from running inline inside one test.
- **A clean `bin/rails test` emits no warnings** beyond two known upstream sources (`weighted_list_rank`'s
  position `puts`, and npm/yarn during `test:prepare`). A new warning line is a regression — fix the
  cause, don't filter the output. ~190 lines of noise accumulated once because nobody was watching.

## Frontend

Server-first + progressive enhancement: Turbo Frames, minimal Stimulus controllers, ViewComponents,
DaisyUI 5 on Tailwind CSS 4. JS bundled by Rollup into per-domain IIFE bundles; CSS built per domain.
No Rails asset pipeline — builds are served from `public/`.

**DaisyUI is 5.7.x, Tailwind is v4.** These classes were removed in v5 and fail **silently** — absent
from the compiled CSS, no build error, no visual change: `form-control`, `label-text`,
`label-text-alt`, `input-bordered`, `select-bordered`, `textarea-bordered`, `file-input-bordered`,
`input-disabled`, `table-hover`, `tabs-boxed`. Use `fieldset` + `fieldset-legend`, `label`, and bare
`input`/`select`/`checkbox` instead. `.select` is single-line only — on `<select multiple>` it sets
`display:inline-flex` and renders the options as an unreadable row; there is no daisyUI multi-select.
**A branch-wide sweep already removed every occurrence of these ten classes from the codebase**, so
copying form markup from a neighbouring view or component is safe again — for anything new or
unfamiliar, `docs/external-libraries/daisyui-llms.txt` (pinned at the installed version) remains the
authority. `test/lint/daisyui_v4_classes_test.rb` scans `app/views/**`, `app/components/**`,
`app/javascript/**`, and `app/helpers/**` for the removed classes and fails on any new occurrence; its
allowlist is empty and is meant to stay that way — the fix when it fails is to remove the class, not
to add an entry.

**Turbo Frames trap links.** Every `<a>` inside a `turbo_frame_tag` navigates *that frame*, so a
link to another page renders "Content missing". Put `target: "_top"` on any frame whose contents
link off-page, and opt pagination back in with
`@pagy.series_nav(anchor_string: 'data-turbo-frame="<frame_id>"')`. The
`assert_no_frame_trapped_links` integration assertion guards this.
`target: "_top"` releases **forms** inside the frame as well as links; a form that must update the
frame in place needs `data: {turbo_frame: "<frame_id>"}`. The guard checks anchors only.

## Specs and planning

**Use the superpowers defaults. Specs go in `docs/superpowers/specs/`**, named
`YYYY-MM-DD-<topic>-design.md`. Plan non-trivial work there via the `superpowers:brainstorming` →
`superpowers:writing-plans` flow. That is the only live spec location.

**`docs/specs/` and `docs/spec-instructions.md` are the OLD way and are archived data.** They
describe a numbered-spec workflow (`060-album-merge-feature.md`, a `templates/` dir, a `completed/`
dir) that this project no longer follows. Read them for historical context on shipped features —
never add to them, never follow their instructions, and do not treat `docs/spec-instructions.md` as
current guidance. It still says to create specs in `docs/specs/`; that instruction is dead.

This note exists because the previous wording here actively told agents to plan in `docs/specs/`,
and CLAUDE.md overrides skill defaults — so every agent correctly obeyed it and put specs in the
wrong place.

## Deeper docs

- `docs/dev-core-values.md` — full development principles
- `docs/testing.md` — complete testing guide · `docs/features/e2e-testing.md` — Playwright
- `docs/summary.md` — architecture & goals · `docs/dev_setup.md` — local setup
- `docs/features/` — feature docs (data_importers, authentication, rankings, search,
  saved_searches, ...)
- `docs/documentation.md` — documentation philosophy. **Code is the source of truth: we do NOT write
  class-level docs.** Features go in `docs/features/`, data models in `docs/object_models/`.
