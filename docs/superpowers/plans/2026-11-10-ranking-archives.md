# Ranking Archives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store a frozen ranking as one flat row, create one automatically each month from the books primary, migrate the 43 legacy archives into the same shape, and give books public pages, CSV export and admin screens for them.

**Architecture:** A shared `RankingArchive` model (STI, `Books::RankingArchive` the only subclass) holds three parallel Postgres arrays: item ids, positions, scores. Nothing ever updates them. A read-side service resolves ids at read time against live books and `record_redirects`, so merges and deletes never touch an archive. One capture service feeds both the daily Sidekiq job and the admin "Archive now" action; a standalone migrator copies legacy rows.

**Tech Stack:** Rails 8, PostgreSQL arrays, Sidekiq + sidekiq-cron (`config/schedule.yml`), Pagy 43, Pundit, ViewComponent, DaisyUI 5 / Tailwind 4, Minitest 6 + Mocha, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-10-ranking-archives-design.md` — read it before any task.

## Global Constraints

- Run every Rails and yarn command from `web-app/`. Docs live in `docs/` at the project root.
- **Never commit to `main`.** Work on a branch in a worktree made with the `EnterWorktree` tool. Do not push or open a PR without asking the owner.
- The spec and this plan are untracked files in the main checkout. Copy both into the worktree and commit them first (Task 1, Step 1).
- Use Rails generators for models, controllers, jobs and components. Jobs: `bin/rails generate sidekiq:job …`. Services and query objects have no generator.
- `bin/rails db:migrate` runs annotaterb. Never set `ANNOTATERB_SKIP_ON_DB_TASKS`. Never hand-write a `# == Schema Information` block. The dev database is shared between worktrees: delete from the annotation diff only lines for columns this branch's `schema.rb` does not have.
- Never run a destructive command against the development database.
- Services use `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Root-anchor constants inside `Services::`, `CsvExports::` and `Api::`: `::RankingConfiguration`, `::RankingArchive`, `::Books::Book`, `::RecordRedirect`, `::RankedItem`. `Services::RankingConfiguration` is an existing module and shadows the model.
- The three arrays (`item_ids`, `positions`, `scores`) and `items_count` are written at creation and never updated. No code path may rewrite them, and no merge, refresh or sync may reach an archive.
- Archive pages are `noindex` and carry no canonical tag. The books layout already emits `noindex, follow` whenever `@indexable` is unset; do not set it.
- DaisyUI is 5.x: no `form-control`, `label-text`, `input-bordered`, `select-bordered`, `table-hover`. Use `fieldset` + `fieldset-legend`, `label`, bare `input`. Links use `link`, not `link link-hover`.
- Minitest 6: `assert_nil`, never `assert_equal nil`. Stub external calls with Mocha. Controller tests assert behaviour (status, assigns, records), never HTML copy.
- Lint with `bundle exec standardrb`. Do not run brakeman.
- A clean `bin/rails test` prints no new warnings.

## Review Focus

Inputs the spec implies but does not spell out. Each has a test in the task named.

1. **Every book on a page is gone** (all ids deleted, no redirects): the page renders an empty state with a 200, not an error. → Task 6.
2. **A name that slugs to nothing** ("!!!", "一月"): the archive is still created, with slug `archive` (suffixed if taken). → Task 1.
3. **The month's slug is already taken** by a manual archive named "January 2027": the monthly job still creates its archive, as `january-2027-2`. → Task 5.
4. **`/page/0` and an absurdly large page number**: same status the live ranking gives for the same input, never a 500. → Task 6.
5. **An admin saves a slug that is taken or malformed**: the form re-renders with a 422 and the archive is unchanged. → Task 8.

## File Map

| File | Responsibility |
|---|---|
| `app/models/ranking_archive.rb`, `app/models/books/ranking_archive.rb` | The record, its validations and immutability. |
| `app/lib/services/ranking_archives/capture.rb` | Turn a configuration's current ranking into an archive. |
| `app/lib/services/ranking_archives/entries.rb` | Read a slice of an archive, resolving merged and deleted ids. |
| `app/lib/services/books_migration/redirect_recorder.rb` | Widened: every book merge and delete gets a row. |
| `app/sidekiq/books/archive_monthly_ranking_job.rb` | Daily "does this month have an archive?" check. |
| `app/controllers/books/ranking_archives_controller.rb` + views | Public index, show, CSV export. |
| `app/lib/csv_exports/archived_ranking.rb` | CSV rows from an archive. |
| `app/controllers/admin/books/ranking_archives_controller.rb` + views, `app/policies/books/ranking_archive_policy.rb` | Admin list, show, edit, delete. |
| `app/lib/actions/admin/archive_ranking.rb` | "Archive now". |
| `app/models/legacy_books/ranked_book.rb`, `app/lib/services/books_migration/ranking_archive_migrator.rb` | Legacy copy. |

---

### Task 1: The `RankingArchive` model

**Files:**
- Create (generator): `app/models/ranking_archive.rb`, `db/migrate/*_create_ranking_archives.rb`, `test/models/ranking_archive_test.rb`, `test/fixtures/ranking_archives.yml`
- Create (generator): `app/models/books/ranking_archive.rb`, `test/models/books/ranking_archive_test.rb`
- Modify: `app/models/ranking_configuration.rb`, `app/models/books/ranking_configuration.rb`
- Test: `test/models/ranking_archive_test.rb`, `test/models/books/ranking_configuration_test.rb`

**Interfaces — Produces:**
- `RankingArchive` columns: `type`, `name`, `slug`, `description`, `item_ids bigint[]`, `positions integer[]`, `scores decimal(10,2)[]`, `items_count`, `captured_at`, `period date`, `ranking_configuration_id`, `legacy_ranking_configuration_id`, `hidden`.
- Scopes `RankingArchive.visible`, `.newest_first` (`captured_at DESC, id DESC`), `.summaries` (selects every column except the three arrays).
- `RankingArchive.item_type` (raises `NotImplementedError`), `Books::RankingArchive.item_type → "Books::Book"`, `#item_class`, `#origin → :legacy | :monthly | :manual`.
- `RankingConfiguration#ranking_archive_class → nil`; `Books::RankingConfiguration#ranking_archive_class → ::Books::RankingArchive`.
- Fixtures `ranking_archives(:books_january_2027)` (visible, monthly, two fixture books) and `ranking_archives(:books_hidden_legacy)` (hidden, `legacy_ranking_configuration_id: 33`).

- [ ] **Step 1: Worktree and documents.** Create the worktree with `EnterWorktree`. Copy `docs/superpowers/specs/2026-11-10-ranking-archives-design.md` and this plan from the main checkout into it and commit them: `git commit -m "Add ranking archives design and plan"`.

- [ ] **Step 2: Generate.**

```bash
bin/rails generate model RankingArchive type:string name:string slug:string description:text items_count:integer captured_at:datetime period:date legacy_ranking_configuration_id:integer hidden:boolean
bin/rails generate model Books::RankingArchive --parent=RankingArchive
```

- [ ] **Step 3: Edit the generated migration** so the table is exactly:

```ruby
create_table :ranking_archives do |t|
  t.string :type, null: false
  t.string :name, null: false
  t.string :slug, null: false
  t.text :description
  t.bigint :item_ids, array: true, null: false, default: []
  t.integer :positions, array: true, null: false, default: []
  t.decimal :scores, array: true, precision: 10, scale: 2, null: false, default: []
  t.integer :items_count, null: false, default: 0
  t.datetime :captured_at, null: false
  t.date :period
  t.references :ranking_configuration, null: true, foreign_key: {on_delete: :nullify}
  t.integer :legacy_ranking_configuration_id
  t.boolean :hidden, null: false, default: false
  t.timestamps
end
add_index :ranking_archives, [:type, :slug], unique: true
add_index :ranking_archives, [:ranking_configuration_id, :period], unique: true, where: "period IS NOT NULL",
  name: "index_ranking_archives_on_config_and_period"
add_index :ranking_archives, :legacy_ranking_configuration_id, unique: true,
  where: "legacy_ranking_configuration_id IS NOT NULL", name: "index_ranking_archives_on_legacy_config"
add_index :ranking_archives, [:type, :hidden, :captured_at]
```

Run `bin/rails db:migrate`. Check the annotation diff per Global Constraints.

- [ ] **Step 4: Write the fixtures.** Two rows in `test/fixtures/ranking_archives.yml`, both `type: Books::RankingArchive`. `books_january_2027`: `slug: january-2027`, `period: 2027-01-01`, `captured_at: 2027-01-01 05:15:00`, `ranking_configuration: books_global`, `item_ids` = the fixture ids of `books_books(:war_and_peace)` and `books_books(:crime_and_punishment)` via `ActiveRecord::FixtureSet.identify`, `positions: [1, 2]`, `scores: [100.0, 90.0]`, `items_count: 2`. `books_hidden_legacy`: `name: List Dates V7`, `slug: list-dates-v7`, `hidden: true`, `legacy_ranking_configuration_id: 33`, one book. Read `test/fixtures/books/books.yml` (or wherever `books_books` lives) for the real fixture names first. If a YAML sequence is rejected for an array column, use the Postgres literal `"{1,2}"`.

- [ ] **Step 5: Write the failing tests** in `test/models/ranking_archive_test.rb`:

```ruby
test "arrays cannot change after creation" do
  archive = ranking_archives(:books_january_2027)
  before = archive.item_ids.dup
  assert_not archive.update(item_ids: [1], positions: [1], scores: [1], items_count: 1)
  assert_equal before, archive.reload.item_ids
end
test "an in-place array mutation is refused too" do
  archive = ranking_archives(:books_january_2027)
  archive.item_ids << 5
  assert_not archive.save
end
test "name, slug, description and hidden can change" do
  assert ranking_archives(:books_january_2027).update(name: "Jan", slug: "jan", description: "x", hidden: true)
end
test "an empty archive is invalid" do            # item_ids: []
test "arrays must be the same length" do          # 2 ids, 1 position
test "items_count is set from item_ids on create" do
test "slug comes from the name" do                # "List Dates v1" -> "list-dates-v1"
test "a taken slug gets a numeric suffix" do      # second "January 2027" -> "january-2027-2", third -> "-3"
test "a name that slugs to nothing falls back to archive" do   # "!!!" -> "archive"; "一月" -> "archive-2"
test "slug format is enforced on update" do       # "My Slug!" invalid
test "slug is unique within a type" do
test "period must be the first of a month" do     # 2027-01-15 invalid
test "one monthly archive per configuration and period" do     # RecordNotUnique or invalid on the second
test "summaries leaves the arrays unloaded" do
  row = RankingArchive.summaries.first
  assert_raises(ActiveModel::MissingAttributeError) { row.item_ids }
  assert_equal 2, ranking_archives(:books_january_2027).items_count
end
test "origin" do   # legacy id -> :legacy, period -> :monthly, neither -> :manual
test "destroying the source configuration keeps the archive" do
  # a freshly created global Books::RankingConfiguration, not a fixture other rows hang off
  archive = Books::RankingArchive.create!(name: "T", captured_at: Time.current, ranking_configuration: config,
    item_ids: [1], positions: [1], scores: [1])
  config.destroy!
  assert_nil archive.reload.ranking_configuration_id
end
```

And in `test/models/books/ranking_configuration_test.rb`: `ranking_archive_class` is `Books::RankingArchive` for books and `nil` for a music configuration fixture.

- [ ] **Step 6: Run** `bin/rails test test/models/ranking_archive_test.rb` — expect failures.

- [ ] **Step 7: Implement.** In `RankingArchive`: `belongs_to :ranking_configuration, optional: true`; the scopes; `before_validation` on create for `items_count` and slug (base = `name.parameterize.presence || "archive"`, then `base`, `base-2`, `base-3`… first one free within `type`, only when `slug` is blank); validations for name, slug (`/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/`, unique within type), `captured_at`, non-empty `item_ids`, equal array lengths, first-of-month `period`; an update-only validation that adds an error when `item_ids`, `positions`, `scores` or `items_count` would change. In `RankingConfiguration`: `has_many :ranking_archives, dependent: :nullify` and `def ranking_archive_class = nil`; override in `Books::RankingConfiguration`.

- [ ] **Step 8: Run** the two test files — expect PASS. Run `bundle exec standardrb`.

- [ ] **Step 9: Commit** — `git commit -m "Add RankingArchive: a frozen ranking stored as one row"`.

---

### Task 2: Capture service

**Files:**
- Create: `app/lib/services/ranking_archives/capture.rb`
- Test: `test/lib/services/ranking_archives/capture_test.rb`

**Interfaces:**
- Consumes: `RankingConfiguration#ranking_archive_class`, `RankingArchive.item_type`.
- Produces: `Services::RankingArchives::Capture.call(config:, name:, period: nil, captured_at: Time.current) → Result`. Success: `data` is the persisted archive. Failure messages (constants on the class): `UNSUPPORTED = "This ranking cannot be archived."`, `NOT_GLOBAL = "Only global rankings can be archived."`, `EMPTY = "This ranking has no ranked items, so nothing was archived."`, `ALREADY_ARCHIVED = "An archive already exists for this month."`; anything else is the record's `errors.full_messages`.

- [ ] **Step 1: Write the failing tests.**

```ruby
test "captures every ranked item in rank order with its rank and score" do
  # books_global with RankedItem rows rank 2/score 90 and rank 1/score 100, plus one with rank nil
  result = Services::RankingArchives::Capture.call(config: @config, name: "Snapshot")
  archive = result.data
  assert result.success?
  assert_equal [first.id, second.id], archive.item_ids
  assert_equal [1, 2], archive.positions
  assert_equal [100, 90], archive.scores.map(&:to_i)
  assert_equal @config.id, archive.ranking_configuration_id
  assert_nil archive.period
  assert_instance_of Books::RankingArchive, archive
end
test "ties keep both items, ordered by item id" do          # two items at rank 1
test "items of another item_type are ignored" do
test "sets the period when given" do
test "refuses a configuration with no ranked items and writes nothing" do   # errors == [Capture::EMPTY]
test "refuses a configuration whose domain has no archive class" do          # music fixture -> UNSUPPORTED
test "refuses a user-owned configuration" do                                  # NOT_GLOBAL
test "a second capture for the same period fails with ALREADY_ARCHIVED" do
test "does not change the configuration or request a refresh" do
  ::Services::RankingConfigurations::RequestRefresh.expects(:call).never
  assert_no_changes -> { @config.reload.attributes } do
    Services::RankingArchives::Capture.call(config: @config, name: "Snapshot")
  end
end
```

- [ ] **Step 2: Run** — expect FAIL (`uninitialized constant`).

- [ ] **Step 3: Implement.** Read the ranking in **one statement**, which is what makes it a consistent snapshot while a refresh runs:

```ruby
::RankedItem.where(ranking_configuration_id: config.id, item_type: archive_class.item_type)
  .where.not(rank: nil).order(:rank, :item_id).pluck(:item_id, :rank, :score)
```

A nil score is stored as 0. Rescue `ActiveRecord::RecordNotUnique` into `ALREADY_ARCHIVED`.

- [ ] **Step 4: Run** — expect PASS. `bundle exec standardrb`.

- [ ] **Step 5: Commit** — `git commit -m "Add the ranking archive capture service"`.

---

### Task 3: Record a redirect for every book merge and delete

The spec requires confirming the readers of `record_redirects` first. Confirmed by reading (2026-11-10):

- `Services::BooksMigration::Redirects#resolve` and `#redirected_ids` are only ever asked about legacy ids (`sync_plan.rb:39-40`, `book_route.rb:17`, `book_identifier_migrator.rb:38`, `book_author_migrator.rb:22`). A row whose `from_id` is a new-app id is never looked up. `RedirectRecorder.repoint` already keeps rows flat, so no chain gets longer.
- `SyncInit` (`sync_init.rb:44`) deletes rows whose `from_id` is a live record. A merged-away or deleted id is not live.
- `Leftovers#follow` (`leftovers.rb:224-235`) will now resolve a merged-away new-app book to its survivor. Its own comment says a redirect "can only make more rows count as touching the book, which keeps items or makes the sweep wait".
- One visible change: `Redirects#counts`, printed by the sync report as "redirects recorded", now includes new-app books.

Authors are **not** widened. Only `Books::Book`.

**Files:**
- Modify: `app/lib/services/books_migration/redirect_recorder.rb`, `app/models/record_redirect.rb` (header comment only), `docs/features/books-legacy-sync.md` ("Redirects" section, lines ~45-54)
- Test: `test/lib/services/books_migration/redirect_recorder_test.rb`, `test/models/books/book_test.rb`, `test/lib/services/books/goodreads_reimport/apply/leftovers_test.rb`

**Interfaces — Produces:** `RedirectRecorder.merged` and `.deleted` write a row for any `Books::Book` id; for `Books::Author` only below the ceiling, as today. `RedirectRecorder.legacy_origin?` keeps its meaning.

- [ ] **Step 1: Change the tests that pin the old rule.**
  - `redirect_recorder_test.rb` "records nothing for an id at or above the ceiling": split in two. A book at and above the books ceiling **is** recorded by `merged` (row to the survivor) and by `deleted` (row with nil target). An author at the authors ceiling records nothing.
  - Same file, "repoints rows that named a record merged away, even a new-app one": the final `assert_nil fate("Books::Book", new_app_id)` becomes an assertion that the new-app id's own row points at the survivor.
  - `book_test.rb` "destroying a new-app book records nothing" becomes "destroying a new-app book records it as deleted": one new row, `to_id` nil.
  - `leftovers_test.rb:199`: `assert_not RecordRedirect.exists?(from_id: new_book.id)` becomes `assert RecordRedirect.exists?(from_id: new_book.id, to_id: @from.id)`. The rest of that test must still pass unchanged.

- [ ] **Step 2: Add one new test** to `redirect_recorder_test.rb`:

```ruby
test "a legacy id still resolves in one hop after its new-app survivor is merged on" do
  legacy, new_app, final = 1_002, books_ceiling + 5, books_ceiling + 6
  Recorder.merged(item_type: "Books::Book", from_id: legacy, to_id: new_app)
  Recorder.merged(item_type: "Books::Book", from_id: new_app, to_id: final)
  redirects = Services::BooksMigration::Redirects.load
  assert_equal final, redirects.resolve("Books::Book", legacy)
  assert_equal final, redirects.resolve("Books::Book", new_app)
end
```

- [ ] **Step 3: Run** the three files — expect the changed and new tests to FAIL.

- [ ] **Step 4: Implement.** Replace the two `return unless legacy_origin?(item_type, from_id)` guards with a private `recordable?(item_type, id)` that is true for `"Books::Book"` and otherwise `legacy_origin?`. Rewrite the class comment and the `RecordRedirect` header comment to say books record every merge and delete because ranking archives resolve through them, and authors stay legacy-only. Update the "Redirects" section of `docs/features/books-legacy-sync.md` the same way, including that the sync report's "redirects recorded" figure now counts new-app books.

- [ ] **Step 5: Run** `bin/rails test test/lib/services/books_migration test/lib/services/books/goodreads_reimport test/lib/services/books/goodreads_replay test/lib/books test/models/books` — expect PASS. If any reader test fails for a reason other than the three assertions above, stop and report to the owner; do not adapt the reader.

- [ ] **Step 6: Commit** — `git commit -m "Record a redirect for every book merge and delete, not only legacy ids"`.

---

### Task 4: Reading an archive

**Files:**
- Create: `app/lib/services/ranking_archives/entries.rb`
- Test: `test/lib/services/ranking_archives/entries_test.rb`

**Interfaces:**
- Consumes: Task 1 model; Task 3 (the real-merger test needs new-app books to leave a redirect).
- Produces: `Services::RankingArchives::Entries.call(archive:, offset:, limit:, preload: []) → Array<Entry>`, `Entry = Struct.new(:item, :rank, :score, keyword_init: true)`. Entries are in archive order. `rank` and `score` are the archived values. The result can be shorter than `limit`.

- [ ] **Step 1: Write the failing tests.** Build archives directly with `Books::RankingArchive.create!` over fixture books and freshly created books.

```ruby
test "a live book is returned with its archived rank and score" do
test "positions are the archived ones, gaps included" do            # positions [1, 3] -> ranks [1, 3]
test "a merged id is shown as its survivor at the archived position" do
  # item_ids [gone_id], RecordRedirect gone_id -> survivor.id
  entry = entries(archive).sole
  assert_equal survivor, entry.item
  assert_equal 7, entry.rank
end
test "a survivor already archived at a better position drops the merged slot" do
  # item_ids [survivor.id, gone_id], redirect gone_id -> survivor: one entry, rank 1
test "a survivor archived at a worse position is dropped there and kept at the merged slot" do
  # item_ids [gone_id, survivor.id], positions [1, 2]: one entry, rank 1, item survivor
test "the dedupe holds across pages" do
  # 3 items [gone_id, other.id, survivor.id]; offset: 2, limit: 1 returns []
test "an id redirected to nothing is skipped" do                    # to_id nil
test "an id with no book and no redirect is skipped" do
test "every id gone returns an empty array" do
test "an offset past the end returns an empty array" do
test "offset and limit slice the archive" do
test "preload is applied" do   # preload: [:book_authors]; assert entry.item.association(:book_authors).loaded?
test "through the real merger: an archived new-app book is shown as its survivor and the archive is untouched" do
  source = Books::Book.create!(title: "Archived Then Merged", book_kind: :standalone)
  archive = Books::RankingArchive.create!(name: "T", captured_at: Time.current,
    item_ids: [source.id], positions: [1], scores: [10])
  target = Books::Book.create!(title: "Survivor", book_kind: :standalone)
  ::Services::RankingConfigurations::RequestRefresh.expects(:call_for_ids).with([], delay: 5.minutes)
  assert_no_changes -> { archive.reload.attributes } do
    Books::Book::Merger.call(source: source, target: target)
  end
  assert_equal [target], entries(archive).map(&:item)
end
```

In the last test both books are freshly created and have no `ranked_items`, so the merger must request a refresh of no configuration at all. If `call_for_ids` is not called with an empty array in that case, read `merger.rb:621-626` and assert what it does do; the point is that the archive adds nothing to the list.

- [ ] **Step 2: Run** — expect FAIL.

- [ ] **Step 3: Implement.** The algorithm, because the tests alone do not fix it:

```ruby
ids, ranks, scores = %i[item_ids positions scores].map { |a| archive.public_send(a)[offset, limit] || [] }
live = item_class.where(id: ids).pluck(:id).to_set
forward = ::RecordRedirect.where(item_type: item_type, from_id: ids.reject { |id| live.include?(id) })
  .where.not(to_id: nil).pluck(:from_id, :to_id).to_h
resolved = ids.map { |id| live.include?(id) ? id : forward[id] }          # nil = skip

# A book appears once in an archive, at the best slot of any id that resolves to it.
first_index = {}
archive.item_ids.each_with_index { |id, i| first_index[id] ||= i }
aliases = ::RecordRedirect.where(item_type: item_type, to_id: resolved.compact.uniq)
  .pluck(:to_id, :from_id).group_by(&:first).transform_values { |rows| rows.map(&:last) }
best = ->(id) { [id, *aliases.fetch(id, [])].filter_map { |candidate| first_index[candidate] }.min }

kept = resolved.each_with_index.select { |id, i| id && best.call(id) == offset + i }
records = item_class.where(id: kept.map(&:first)).preload(preload).index_by(&:id)
kept.filter_map { |id, i| records[id] && Entry.new(item: records[id], rank: ranks[i], score: scores[i]) }
```

`first_index` is built from ids only; it must never load 21,000 records.

- [ ] **Step 4: Run** — expect PASS. `bundle exec standardrb`.

- [ ] **Step 5: Commit** — `git commit -m "Resolve merged and deleted books when reading a ranking archive"`.

---

### Task 5: The monthly job

**Files:**
- Create (generator): `app/sidekiq/books/archive_monthly_ranking_job.rb`, `test/sidekiq/books/archive_monthly_ranking_job_test.rb` — `bin/rails generate sidekiq:job books/archive_monthly_ranking`
- Modify: `config/schedule.yml`

**Interfaces:**
- Consumes: `Capture.call(config:, name:, period:)`.
- Produces: `Books::ArchiveMonthlyRankingJob#perform` (no arguments), `sidekiq_options queue: :low`. Schedule entry `books_monthly_ranking_archive`, cron `"15 5 * * *"`.

- [ ] **Step 1: Write the failing tests.** The primary is whatever `Books::RankingConfiguration.default_primary` returns in fixtures; read `test/fixtures/ranking_configurations.yml` and give it `RankedItem` rows in setup the way `test/controllers/books/ranked_items_controller_test.rb` does.

```ruby
test "creates the month's archive from the primary, named for the month" do
  travel_to Time.utc(2027, 1, 1, 5, 15) do
    assert_difference -> { Books::RankingArchive.count }, 1 do
      Books::ArchiveMonthlyRankingJob.new.perform
    end
  end
  archive = Books::RankingArchive.order(:id).last
  assert_equal ["January 2027", Date.new(2027, 1, 1), @primary.id],
    [archive.name, archive.period, archive.ranking_configuration_id]
end
test "does nothing when the month already has an archive" do        # perform twice; second: assert_no_difference
test "a first run mid-month archives that month" do                  # 2026-11-10 -> "November 2026", period 2026-11-01
test "the month is the UTC month" do                                 # Time.utc(2027, 1, 31, 23, 59) -> "January 2027"
test "an archive from last month does not satisfy this month" do
test "raises and writes nothing when the primary has no ranked items" do
test "raises when there is no primary books configuration" do
test "still creates the archive when a manual archive holds the month's slug" do
  Books::RankingArchive.create!(name: "January 2027", captured_at: Time.current, item_ids: [1], positions: [1], scores: [1])
  travel_to(Time.utc(2027, 1, 1, 5, 15)) { Books::ArchiveMonthlyRankingJob.new.perform }
  assert_equal "january-2027-2", Books::RankingArchive.find_by!(period: Date.new(2027, 1, 1)).slug
end
test "never requests a refresh" do   # RequestRefresh.expects(:call).never
```

- [ ] **Step 2: Run** — expect FAIL.

- [ ] **Step 3: Implement `perform`:** find the primary (raise if nil); `period = Time.now.utc.to_date.beginning_of_month`; return if `Books::RankingArchive.exists?(ranking_configuration_id:, period:)`; call `Capture` with `name: period.strftime("%B %Y")`; on failure, return if the archive exists now, otherwise raise with the errors. Add the schedule entry with description "Make sure the books primary ranking has an archive for the current month".

- [ ] **Step 4: Run** — expect PASS. `bundle exec standardrb`.

- [ ] **Step 5: Commit** — `git commit -m "Archive the books primary ranking once a month"`.

---

### Task 6: Public pages

**Files:**
- Create (generator): `app/controllers/books/ranking_archives_controller.rb`, `app/views/books/ranking_archives/{index,show}.html.erb`, `test/controllers/books/ranking_archives_controller_test.rb` — `bin/rails generate controller Books::RankingArchives index show --skip-routes --no-helper`
- Modify: `config/routes.rb` (directly after `get "rankings", to: "books/default#rankings"`, ~line 1044), `app/components/rankings/page_component.html.erb` (the link list near line 203), `app/views/books/ranked_items/index.html.erb` (below the "Page X of Y" paragraph)

**Interfaces:**
- Consumes: `Entries.call`, `RankingArchive.visible/.newest_first/.summaries`, `PathBasedPagination#pagy_path_count(count, limit:)`, `Books::CardComponent.new(book:, rank:, index:)`.
- Produces: routes `books_ranking_archives_path` (`/rankings/archive`), `books_ranking_archive_path(slug:)`, `books_ranking_archive_page_path(slug:, page:)`; assigns `@archives`, `@archive`, `@pagy`, `@entries`.

- [ ] **Step 1: Add the routes.**

```ruby
get "rankings/archive", to: "books/ranking_archives#index", as: :books_ranking_archives,
  constraints: {format: /html/}
get "rankings/archive/:slug", to: "books/ranking_archives#show", as: :books_ranking_archive,
  constraints: {format: /html/}
get "rankings/archive/:slug/page/:page", to: "books/ranking_archives#show", as: :books_ranking_archive_page,
  constraints: {page: /\d+/, format: /html/}
```

- [ ] **Step 2: Write the failing tests.** `host! "dev-new.thegreatestbooks.org"`. A helper builds an archive of `n` freshly created books. For URLs the router rejects, assert a 404 the way `test/controllers/books/ranked_items_controller_test.rb` already does for its own unroutable URLs.

```ruby
test "index lists visible archives newest first and leaves hidden ones out" do
  get "/rankings/archive"
  assert_response :success
  ids = @controller.view_assigns["archives"].map(&:id)
  assert_includes ids, ranking_archives(:books_january_2027).id
  assert_not_includes ids, ranking_archives(:books_hidden_legacy).id
end
test "index is publicly cacheable and noindex" do
  # response.headers["Cache-Control"] includes "public"; assert_select "meta[name=robots][content='noindex, follow']"
test "show renders the archive's entries" do   # view_assigns["entries"].map(&:item) == the two fixture books
test "show is publicly cacheable, noindex, and has no canonical" do   # assert_select "link[rel=canonical]", 0
test "a hidden archive is a 404" do
test "an unknown slug is a 404" do
test "page 2 shows entries 101 onward" do      # 101-book archive; pagy.page == 2; one entry, rank 101
test "a page past the last is a 404" do
test "a non-numeric page is a 404" do          # /page/abc
test "a json request is a 404" do              # /rankings/archive/january-2027.json
test "page 0 and a huge page behave as they do on the live ranking" do
  %w[0 99999999999999999999].each do |page|
    get "/page/#{page}"
    live = response.status
    get "/rankings/archive/january-2027/page/#{page}"
    assert_equal live, response.status
    assert_operator response.status, :<, 500
  end
end
test "an archive whose books are all gone renders an empty page" do
  # item_ids of destroyed books; assert_response :success; view_assigns["entries"] == []
test "a merged book is shown as its survivor" do
test "the session is skipped" do               # no Set-Cookie header on show
```

- [ ] **Step 3: Run** — expect FAIL.

- [ ] **Step 4: Implement the controller.** `include Pagy::Method`, `Cacheable`, `PathBasedPagination`; `layout "books/application"`; `cache_for_index_page` on `index`, `cache_for_show_page` on `show`. `index`: `::Books::RankingArchive.visible.summaries.newest_first`. `show`: `visible.find_by!(slug: params[:slug])`, `@pagy = pagy_path_count(@archive.items_count, limit: 100)`, then `Entries.call(archive:, offset: @pagy.offset, limit: @pagy.limit, preload: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}])` — the same preload `Books::RankedBooksQuery` uses. Never set `@indexable` or a canonical.

- [ ] **Step 5: Implement the views.**
  - `index`: page title "Past rankings"; one row per archive with its name linked to the show page, `captured_at` as "January 1, 2027", and the book count; an empty state.
  - `show`: `h1` with the archive name; `<div role="status" class="alert alert-info" data-testid="archived-ranking-notice">` reading "This is an archived ranking from {date}. It no longer changes." with a link "See the current ranking" to `books_root_path`; a line `data-testid="archive-no-filters"` reading "Filters are not available on archived rankings."; the description when present; the grid `Books::CardComponent::GRID_CONTAINER_CLASS` rendering `Books::CardComponent.new(book: entry.item, rank: entry.rank, index: index)` with **no** `ranking_configuration`; the same pagination block as `books/ranked_items/index.html.erb:43-48`; an empty state reading "None of the books in this part of the ranking are still in the catalogue."; a link back to Past rankings.
  - `Rankings::PageComponent`: a "Past rankings" item in the link list, rendered for the books domain only.
  - `books/ranked_items/index.html.erb`: a quiet `link` to Past rankings under the page count.

- [ ] **Step 6: Run** the controller test plus `bin/rails test test/controllers/books/default_controller_test.rb test/controllers/books/ranked_items_controller_test.rb test/components/rankings test/lint` — expect PASS. `bundle exec standardrb`.

- [ ] **Step 7: Commit** — `git commit -m "Add public pages for ranking archives on books"`.

---

### Task 7: CSV export

**Files:**
- Create: `app/lib/csv_exports/archived_ranking.rb`
- Modify: `app/controllers/books/ranking_archives_controller.rb`, `app/views/books/ranking_archives/show.html.erb`, `config/routes.rb`
- Test: `test/lib/csv_exports/archived_ranking_test.rb`, `test/controllers/books/ranking_archives_controller_test.rb`

**Interfaces:**
- Consumes: `Entries.call`, `CsvExports::Writer.new(io, headers:)`, `CsvExports::Books::RankedBookRow.row_for_book(book, rank:, score:, ctx:)`, `.context(book_ids)`, `.preloads`, `CsvExportable#export_limit`, `#send_csv(data, filename:)`.
- Produces: `CsvExports::ArchivedRanking.call(archive:, row_class:, limit:, io:, batch: 1000) → Integer` (rows written). Route `books_ranking_archive_export_path(slug:, format: :csv)`.

The module is `ArchivedRanking`, not `RankingArchive`, so it does not shadow the model inside `CsvExports`.

- [ ] **Step 1: Add the route**, above the `:slug` show route:

```ruby
get "rankings/archive/:slug/export", to: "books/ranking_archives#export", as: :books_ranking_archive_export,
  format: true, constraints: {format: /csv/}
```

- [ ] **Step 2: Write the failing tests.** Library (model on `test/lib/csv_exports/saved_search_test.rb`: `io = StringIO.new`, parse `io.string.delete_prefix(CsvExports::Writer::BOM)`):

```ruby
test "rows follow archive order with the archived rank and score" do
  # Rank and Score columns == ["1", "2"] and the archived scores; ID column == the two book ids
test "limit caps the rows written" do                 # limit: 1 -> returns 1, one data row
test "a nil limit writes everything" do
test "a merged id is exported as its survivor at the archived rank" do
test "deleted ids are left out and do not count toward the limit" do
test "batches do not repeat or drop rows" do          # 5 books, batch: 2 -> 5 rows in order
```

Controller:

```ruby
test "export requires sign in" do                     # same response an anonymous GET /export.csv gets
test "a non-member gets the capped export" do
  sign_in_as users(:user_with_expired_membership), stub_auth: true
  CsvExports::ArchivedRanking.expects(:call).with(has_entries(limit: 500)).returns(0)
  get "/rankings/archive/january-2027/export.csv"
end
test "a member gets every row" do                     # users(:regular_user); has_entries(limit: nil)
test "export sends a csv attachment that is never cached" do
  # media_type text/csv; body starts with the BOM; Cache-Control includes no-store; X-Robots-Tag noindex
  # filename "the-greatest-books-january-2027.csv"
test "exporting a hidden archive is a 404" do
```

- [ ] **Step 3: Run** — expect FAIL.

- [ ] **Step 4: Implement.** `ArchivedRanking.call` walks the archive in `batch`-sized offsets, calling `Entries.call(..., preload: row_class.preloads)`, one `row_class.context` per batch, stopping when `limit` rows are written or the archive ends. The controller gets `include CsvExportable` and an `export` action that finds the visible archive, writes to a `StringIO` with `limit: export_limit`, and calls `send_csv` with filename `"the-greatest-books-#{archive.slug}.csv"`. On the show page render `CsvExports::DownloadButtonComponent.new(export_path: books_ranking_archive_export_path(slug: @archive.slug, format: :csv), noun: "books")` beside the no-filters line.

- [ ] **Step 5: Run** both test files — expect PASS. `bundle exec standardrb`.

- [ ] **Step 6: Commit** — `git commit -m "Add CSV export for books ranking archives"`.

---

### Task 8: Admin list, show, edit, delete

Model everything on Series: `app/controllers/admin/books/series_controller.rb`, `app/views/admin/books/series/`, `app/policies/books/series_policy.rb`, `test/controllers/admin/books/series_controller_test.rb`, `test/policies/books/series_policy_test.rb`.

**Files:**
- Create (generator): `app/controllers/admin/books/ranking_archives_controller.rb` and views — `bin/rails generate controller Admin::Books::RankingArchives index show edit --skip-routes --no-helper`
- Create: `app/policies/books/ranking_archive_policy.rb`, `app/views/admin/books/ranking_archives/{_table,_form}.html.erb`
- Modify: `config/routes.rb` (admin books namespace, beside `resources :ranking_configurations`, ~line 942), `app/lib/admin/domain_nav.rb` (books items, after "Rankings")
- Test: `test/controllers/admin/books/ranking_archives_controller_test.rb`, `test/policies/books/ranking_archive_policy_test.rb`

**Interfaces — Produces:** `resources :ranking_archives, only: [:index, :show, :edit, :update, :destroy]` → `admin_books_ranking_archives_path`, `admin_books_ranking_archive_path(archive)`, `edit_admin_books_ranking_archive_path(archive)`. Form param key `books_ranking_archive`, permitted `:name, :slug, :description, :hidden`. Nav entry `{label: "Ranking Archives", icon: :chart, path: -> { URL_HELPERS.admin_books_ranking_archives_path }}`.

- [ ] **Step 1: Write the failing tests.** `host! Rails.application.config.domains[:books]`; `sign_in_as(users(:admin_user), stub_auth: true)`.

```ruby
test "index lists archives, hidden ones included" do
test "index does not load the arrays" do              # view_assigns rows raise MissingAttributeError on item_ids
test "show renders for a hidden archive" do
test "update changes name, slug, description and hidden" do
test "update ignores ranked data in the params" do
  patch admin_books_ranking_archive_path(@archive), params: {books_ranking_archive: {name: "N", item_ids: [1], items_count: 1}}
  assert_equal @before_ids, @archive.reload.item_ids
end
test "a taken slug re-renders the form with 422 and changes nothing" do
test "a malformed slug re-renders the form with 422 and changes nothing" do   # "My Slug!"
test "destroy deletes the archive" do
test "a signed-out visitor is redirected to the books root" do
test "a regular user is redirected to the books root" do
test "a books viewer can read but not update or destroy" do
  # users(:regular_user).domain_roles.create!(domain: :books, permission_level: :viewer); assert what series_controller_test asserts for the same role
```

Policy test: copy `series_policy_test.rb` with the class swapped.

- [ ] **Step 2: Run** — expect FAIL.

- [ ] **Step 3: Implement.** Controller `< Admin::Books::BaseController`, shaped like `SeriesController`: `authorize ::Books::RankingArchive` in `index`, `authorize @archive` elsewhere, `pagy(..., limit: 25)` over `summaries.newest_first`. Policy: copy `SeriesPolicy`. Views:
  - `index` / `_table`: name, captured-at, book count, origin ("Monthly", "Manual", "Legacy"), Hidden/Visible, links to show and edit.
  - `show`: the same fields, the source configuration linked when present, the legacy configuration id when present, a link to the public page when visible, and the first 25 entries from `Entries.call(archive:, offset: 0, limit: 25)` so a hidden archive can be checked. No control edits the list.
  - `_form`: name, slug, description, a hidden checkbox. Under the checkbox: "Pages already cached can stay reachable for up to 24 hours after an archive is hidden or deleted."
  - Delete button with `turbo_confirm`. For an archive whose `period` is the current UTC month: "This is this month's automatic archive. If you delete it, tomorrow's run creates it again. Hide it instead to keep it off the site." Otherwise: "Delete this archive? This cannot be undone."

- [ ] **Step 4: Run** the two test files and `bin/rails test test/lint test/lib/admin` — expect PASS. `bundle exec standardrb`.

- [ ] **Step 5: Commit** — `git commit -m "Add books admin screens for ranking archives"`.

---

### Task 9: "Archive now"

**Files:**
- Create: `app/lib/actions/admin/archive_ranking.rb`
- Modify: `app/controllers/admin/ranking_configurations_controller.rb` (`execute_action` ~line 55, `allowed_action_names`), `app/views/admin/ranking_configurations/show.html.erb`
- Test: `test/lib/actions/admin/archive_ranking_test.rb`, `test/controllers/admin/books/ranking_configurations_controller_test.rb`

**Interfaces:**
- Consumes: `Capture.call(config:, name:)`; `Actions::Admin::BaseAction` (`self.call(user:, models:, fields: {})`, `succeed`, `error`).
- Produces: `Actions::Admin::ArchiveRanking`, reading `fields[:name]`. `"ArchiveRanking"` in the shared `allowed_action_names`. The shared `execute_action` now passes `fields: params.except(:controller, :action, :id, :action_name)`, the same expression `admin/books/books_controller.rb:68` uses.

- [ ] **Step 1: Write the failing tests.** Action:

```ruby
test "archives the configuration under the given name" do
  result = Actions::Admin::ArchiveRanking.call(user: users(:admin_user), models: [@config], fields: {name: " Before the algorithm change "})
  assert result.success?
  archive = Books::RankingArchive.order(:id).last
  assert_equal ["Before the algorithm change", nil, @config.id], [archive.name, archive.period, archive.ranking_configuration_id]
end
test "a blank name is an error and archives nothing" do
test "a configuration with no ranked items is an error" do
test "a music configuration is an error" do
test "more than one model is an error" do
test "a manual archive does not block the monthly one" do
  # Archive now in January 2027, then Books::ArchiveMonthlyRankingJob.new.perform: two archives
```

Controller: `post execute_action_admin_books_ranking_configuration_path(@rc, action_name: "ArchiveRanking"), params: {name: "Manual"}` creates one archive for an admin; a books viewer creates none; an unlisted `action_name` is still rejected.

- [ ] **Step 2: Run** — expect FAIL.

- [ ] **Step 3: Implement.** Action modelled on `Actions::Admin::RefreshRankings`: `self.name` "Archive Now", visible on `:show`; strip the name, error "Give the archive a name." when blank; success message `Archived #{config.name} as "#{archive.name}" (#{archive.items_count} items).`; a `Capture` failure becomes `error(result.errors.join(" "))`. In the shared show view, when `@ranking_configuration.ranking_archive_class && @ranking_configuration.global? && ranking_configuration_policy.execute_action?`, render a small form posting to `execute_action_ranking_configuration_path(@ranking_configuration, action_name: "ArchiveRanking")` with one required text input `name` (label "Archive name") and a submit "Archive now". Use DaisyUI 5 markup only.

- [ ] **Step 4: Run** both files plus `bin/rails test test/controllers/admin test/lint` — expect PASS (the shared controller serves music and games too). `bundle exec standardrb`.

- [ ] **Step 5: Commit** — `git commit -m "Let an admin archive a books ranking on demand"`.

---

### Task 10: Migrating the legacy archives

**Files:**
- Create: `app/models/legacy_books/ranked_book.rb` (mirror `app/models/legacy_books/ranked_list.rb`: `class RankedBook < Record`, `self.table_name = "ranked_books"`; generate with `bin/rails generate model LegacyBooks::RankedBook --parent=LegacyBooks::Record`, then **delete the generated fixture file** — the table does not exist in the test database and `fixtures :all` would fail on it — and delete the generated test, as `RankedList` has neither; run `bundle exec annotaterb models`)
- Create: `app/lib/services/books_migration/ranking_archive_migrator.rb`
- Modify: `lib/tasks/data_migration.rake`
- Test: `test/lib/services/books_migration/ranking_archive_migrator_test.rb`

**Interfaces — Produces:**
- `Services::BooksMigration::RankingArchiveMigrator.call → Hash`:
  - success: `{success: true, data: {model: "Books::RankingArchive", count:, skipped_existing:, skipped_empty: [legacy ids], books: {live:, redirected:, deleted:, unknown: 0}}}`
  - failure: `{success: false, error: "…", data: {…same keys…, unknown_ids: [up to 50]}}`
- Two instance methods tests stub, because the legacy database does not exist in test:
  - `legacy_configs → Array<Hash>` — String-keyed attributes of legacy `ranking_configurations` where `archived = true AND global = true`, ordered by id.
  - `legacy_ranked_rows(legacy_id) → Array<[book_id, combined_position, score]>` — rows with a non-null `combined_position`, ordered by `combined_position, book_id`. `calculated_score` is never read.
- Rake task `data_migration:ranking_archives`.

- [ ] **Step 1: Write the failing tests.** Stub with Mocha: `m.stubs(:legacy_configs).returns([...])`, `m.stubs(:legacy_ranked_rows).with(26).returns([[book.id, 1, BigDecimal("12.5")], ...])`.

```ruby
test "creates one archive per legacy configuration" do
  # name, description carried; legacy_ranking_configuration_id 26; type Books::RankingArchive;
  # ranking_configuration_id nil; period nil; item_ids / positions / scores in row order
test "captured_at is published_at, falling back to created_at" do
test "a configuration with no published_at arrives hidden" do
test "a published configuration arrives visible" do
test "ties and gaps in position are kept as they are" do     # positions [1, 1, 3]
test "a nil score is stored as 0" do
test "book ids are stored as they are, merged and deleted ones included" do
  # one id with a RecordRedirect to a survivor, one with a nil target: both in item_ids; books == {live: 1, redirected: 1, deleted: 1, unknown: 0}
test "an id that is neither a book nor a redirect aborts before anything is written" do
  # success false; unknown_ids == [that id]; Books::RankingArchive.count unchanged, including for the other, clean configuration
test "a second run creates and changes nothing" do           # count 0, skipped_existing 1; updated_at unchanged
test "a configuration with no positioned rows is skipped and reported" do   # skipped_empty == [id]
test "two legacy configurations with the same name get different slugs" do
test "writes no ranked_lists, penalties or legacy id maps" do
```

- [ ] **Step 2: Run** — expect FAIL.

- [ ] **Step 3: Implement.** Two passes so 600,000 rows are never held at once. Pass 1: for each config, collect the distinct book ids; classify the union against `::Books::Book` ids and `::RecordRedirect` (`item_type: "Books::Book"`) in slices; return the failure hash if any id is unknown. Pass 2, in one transaction: for each config without an archive (`legacy_ranking_configuration_id`), re-read its rows and create the archive. Existing archives are never updated. Rake task, outside `all` and outside the `refuse_after_sync_init` list:

```ruby
desc "Migrate archived legacy ranking_configurations into Books::RankingArchive (re-runnable; safe after sync_init)"
task ranking_archives: :environment do
  result = Services::BooksMigration::RankingArchiveMigrator.call
  pp result
  abort "ranking_archives migration failed: #{result[:error]}" unless result[:success]
end
```

- [ ] **Step 4: Run** the test file and `bin/rails test test/lib/services/books_migration` — expect PASS. `bundle exec standardrb`.

- [ ] **Step 5: Run it for real against development.** It only inserts. `bin/rails data_migration:ranking_archives`. Expected against the 2026-11-10 legacy restore: `count: 43`, `unknown: 0`, `skipped_empty: []`, about 23,900 live and 159 redirected. Run it again: `count: 0`, `skipped_existing: 43`. Then in `bin/rails runner`: `Books::RankingArchive.where.not(legacy_ranking_configuration_id: nil).sum(:items_count)` should be 616,728 and `.where(hidden: true).pluck(:name)` should be `["List Dates V7", "No Recency Bias"]`. If the legacy database is not restored, say so and skip this step rather than restoring it. Report the numbers you got; a newer restore will differ.

- [ ] **Step 6: Commit** — `git commit -m "Migrate archived legacy rankings into ranking archives"`.

---

### Task 11: Playwright

**Files:**
- Create: `e2e/tests/books/admin/ranking-archives.spec.ts` (runs in the `books-admin` project, already signed in as an admin)

- [ ] **Step 1: Confirm port 3000 is this checkout's.** Run the check in `AGENTS.md` ("Running agents in parallel"). If another checkout holds it, stop and tell the owner. Start the app with `yarn build:all` then `bin/rails server`.

- [ ] **Step 2: Write one serial spec** modelled on `e2e/tests/books/admin/series.spec.ts`:
  1. Open `/admin/ranking_configurations`, open the primary configuration, type `E2E Archive ${Date.now()}` into "Archive name", press "Archive now", expect the success flash.
  2. Open `/admin/ranking_archives`, expect the new name; open it and read its slug.
  3. Visit `/rankings/archive`: the name is listed. Follow it: `archived-ranking-notice` and `archive-no-filters` are visible, at least one book card shows `#1`, the `download-csv` button is present, and `meta[name=robots]` has `noindex, follow`.
  4. Go to `/rankings/archive/<slug>/page/2`: it loads and the first card is `#101`.
  5. In admin, edit the archive, tick Hidden, save. Then `page.request.get('/rankings/archive/<slug>')` returns 404. Use `page.request`, not `page.goto`: the page was served with a 24-hour `Cache-Control` and the browser would answer from its own cache.
  6. Delete the archive in admin (accept the confirm); it is gone from the list.

- [ ] **Step 3: Run** `yarn test:e2e --project=books-admin e2e/tests/books/admin/ranking-archives.spec.ts` — expect PASS. Then run it a second time to prove it cleans up after itself.

- [ ] **Step 4: Commit** — `git commit -m "Add an end-to-end test for ranking archives"`.

---

### Task 12: Documentation and the final check

**Files:**
- Create: `docs/features/ranking-archives.md`
- Modify: `docs/features/csv-exports.md` (the "What a user gets" table), `docs/features/rankings.md` (a pointer), `docs/launch-todo.md` (new `## 16.`)
- Check: `docs/object_models/` — follow its README if it describes where a books model goes; if it holds only music and no rule, keep the data model as a section of the feature doc and say so in the commit message.

- [ ] **Step 1: Write `docs/features/ranking-archives.md`.** Cover: what an archive is and why it is not a ranking configuration (the merger recalculates every configuration it finds); the record's fields; the immutability rule; how ids resolve at read time and why books now record every redirect; the monthly job (daily check, UTC month, hide-don't-delete for the current month); admin and "Archive now"; public URLs, noindex, the 24-hour cache after hide or delete; CSV; the legacy migration and its report; what music and games would need (`RecordRedirect::ITEM_TYPES`, a subclass, a job, pages). No per-class documentation.

- [ ] **Step 2: Add the CSV row** ("Archived ranking | on demand, full | on demand, top 500 | sign-in modal") and the pointer in `rankings.md`.

- [ ] **Step 3: Add `## 16. Ranking archives (the migration once; the monthly job needs nothing)` to `docs/launch-todo.md`**, in the format of sections 14 and 15, with these steps:
  1. After deploy, the next 05:15 UTC run creates an archive named for the current month. Check `/admin/ranking_archives`. If it should not be public, hide it; do not delete it.
  2. **Shane runs with `!`:** `bin/rails data_migration:ranking_archives` in production. Expect `unknown: 0` and `count: 43`. If it aborts with unknown ids, the books sync is behind legacy: run `data_migration:sync` and retry.
  3. Re-running it at cutover is harmless: `count: 0`.
  4. Spot-check `/rankings/archive` and one old archive.

- [ ] **Step 4: Run everything.**

```bash
bin/rails test
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
```

Expected: all green, no new warning lines, zeitwerk "All is good!". System tests are not required (`test:system` is red on `main` for unrelated reasons); the Playwright spec from Task 11 covers the UI.

- [ ] **Step 5: Commit** — `git commit -m "Document ranking archives and add the launch steps"`. Tell the owner the branch has unpushed commits and ask before pushing or opening a PR.
