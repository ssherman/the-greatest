# Books Legacy Sync, Increment 2: Redirects and the Catalog Sync — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record every merge and delete of a legacy-origin book or author, and add `data_migration:sync_init`, `data_migration:sync` (catalog half) and `data_migration:sync_report` (catalog half), so the weekly production run brings over only what is new on legacy and never undoes cleanup.

**Architecture:** A new `record_redirects` table is written by the two mergers and by an `after_destroy` on `Books::Book`/`Books::Author`, and read by `Services::BooksMigration::Redirects`. A `legacy_sync_watermarks` table holds the last legacy id each run processed. `SyncPlan` computes one run's scope (new legacy books, authors and book_identifiers, past the 24h delay) into a `SyncScope`, which the existing migrators accept as `sync:` and use to switch to insert-only, scoped behavior. `Sync` runs the migrators in `:all`'s order, queues search indexing, and advances the watermarks; `SyncReport` prints the plan, which is all `sync_report` does.

**Tech Stack:** Rails 8.1, PostgreSQL, Minitest 6 + Mocha + fixtures, standardrb.

**Spec:** `docs/superpowers/specs/2026-10-08-books-legacy-sync-design.md` (§4 redirects, §5 catalog sync, the catalog half of §7). Increment 1 (§3, id reservation) is merged (#365).

## Global Constraints

- Ceilings (merged in increment 1, `Services::BooksMigration::RESERVED_CEILINGS`): `books_books` 250,000; `books_authors` 120,000. "Legacy-origin" = id below the ceiling.
- Watermark keys: exactly `books`, `authors`, `book_identifiers`.
- Delay: a legacy row waits until its `created_at` is more than 24 hours old. `FINAL=1` drops the delay.
- `data_migration:all` aborts with a message containing "use data_migration:sync" once `legacy_sync_watermarks` has rows; it stays usable on an empty table (dev rebuilds, the test suite).
- Legacy-deleted books and authors are reported, never deleted.
- No test ever opens the legacy connection (in test, `LegacyBooks::*` models fall back to the primary connection, which has no legacy tables). Stub `legacy_each`, or pass a `FakeLegacySource`.
- Run Rails commands from `web-app/`. Lint is `bundle exec standardrb` (not rubocop). Do not run brakeman.
- Use Rails generators for models (`bin/rails generate model ...`).
- After `db:migrate` (always `ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate`), `git diff db/schema.rb` must show only this task's table and the version line. The dev DB is shared with other worktrees: if the dump picked up someone else's tables or indexes, `git checkout -- db/schema.rb` and add your `create_table` block and version line by hand.
- Never run a destructive command against the development database. Fixtures truncate tables, so tests run only against the worktree's own test DB.
- Merging to main deploys to production, and a raising migration takes down all four sites: the two migrations here only create tables.
- `Books::Book::Merger.call` / `Books::Author::Merger.call` must never be wrapped in a caller transaction.
- Minitest 6: `assert_equal nil, x` is a hard failure; use `assert_nil`.
- No new pages, so no Playwright spec (spec §9).

## Decisions this plan makes (spec silent or amended)

1. **Increment 2's `data_migration:sync` runs the catalog and `users` only.** `UserListItemMigrator` and `ReviewMigrator` raise on a book that is not here, and under the 24h delay legacy users will always have list items on books still waiting. The user-data tasks join the sync in increment 3 (spec §6). `users` runs because `external_links.submitted_by_id` and `news_posts.user_id` need it, and spec §6 leaves `UserMigrator` unchanged. The switch-over (final `:all`, then `sync_init`) still waits for increment 3, per spec §8. If `sync_init` runs earlier, user data stops syncing until increment 3 ships. Increment 3 reconciles every legacy-origin row against legacy, so the gap closes on its first run.
2. **The redirect writer also repoints existing rows.** Spec §4 records legacy-origin ids only. That breaks a chain through a new-app book: legacy A merges into new-app B (A→B recorded), then B merges into C. B is not legacy-origin, so nothing would record B→C, and A would resolve to a book that is gone. So every merge or delete also rewrites rows whose `to_id` is the departing record (to the survivor, or NULL), whatever its id. The reader still follows chains and guards against cycles, as the spec says.
3. **Routing through redirects is needed in exactly two places:** `book_authors.author_id` (a new book naming an existing author) and `book_identifiers.book_id` (an identifier on any book). Every other synced row hangs off a book or author the run itself inserts, and the plan excludes redirected ids from the run.
4. **A book or author that is neither here nor redirected fails the run**, naming the legacy row. Today's migrators do the same: the `book_authors` foreign key and `Identifier`'s presence validation. Only a redirect to deleted drops a row, and those drops are counted.
5. **`BookImageMigrator` runs inside the sync**, scoped to the run's books, so spec §8's after-each-sync step 5 disappears. It only enqueues `MigrateCoverImageJob`, which needs `LEGACY_R2_*` in Sidekiq. Production has it.
6. **"Never seen" uses `LegacyIdMap` where one exists (languages, categories).** Countries keep legacy ids, so they are insert-if-absent by id. News posts are already insert-if-absent by slug and stay unchanged. A country or news post deleted here comes back on the next sync, and Shane deletes it again.
7. **Every catalog task refuses after `sync_init`, not only `:all`.** That covers each catalog and list task in `:all`, plus `book_descriptions`, `author_descriptions` and `book_images`, so running one by hand cannot undo cleanup either. The user-data tasks, `description_safety_net` and `penalties:reconcile` are left runnable.
8. **The `book_identifiers` scope is "above the watermark, OR belonging to one of the run's new books".** The identifier watermark is legacy's max at `sync_init` time, so a book created between the final `:all` and `sync_init` would otherwise lose its identifiers. The migrator is find-or-create, so overlap is harmless.
9. **The description migrators and the safety net run inside the sync.** They are not in `:all` today (they are the separate `data_migration:descriptions` task), but spec §5 lists them.
10. **`CategoryItemMigrator` drops an item whose mapped category no longer exists here**, instead of raising, in both modes. A category Shane deletes or merges here keeps its `LegacyIdMap` entry.
11. **The 24h window is a strict prefix.** Everything from the first row still inside the delay waits, even an older row behind it, so a watermark never passes a row that was not copied.
12. **A partial watermark set raises.** If the table holds some keys but not all three, `SyncPlan` raises and names the missing ones.

## Review Focus

1. **A book or author removed without callbacks** (`delete_all`, raw SQL, or a deletion from before this ships) has no redirect. An above-watermark identifier on that book, or a new book naming that author, must fail the run and name the legacy row, never write an orphan. A merge that commits while a sync is running looks the same, because the run's redirects snapshot is stale. Pinned in Task 7: `fails the run naming the legacy row when the author is neither here nor redirected`, and the identifier equivalent.
2. **A retry after a failed run** must give the books the failed run inserted their editions and search requests, and must not duplicate anything. Pinned in Task 9: `a retry after a failed run finishes the books that run inserted`.
3. **A category deleted or merged here after being mapped:** a new legacy book's item in it is dropped, not raised. Pinned in Task 8: `drops a book_category whose mapped category no longer exists here`.
4. **An incomplete watermark set** (one row deleted by hand) must refuse with the missing keys named, not crash on `nil`. Pinned in Task 5: `raises naming the missing keys when the watermarks are incomplete`.
5. **`FINAL=true` / `FINAL=yes`** count as final, and `FINAL=0` or unset does not. Pinned in Task 9: `sync passes FINAL through as a boolean`.

Not unit-testable, so checked in the dev rehearsal (spec §9): `LegacySource`'s queries against the real legacy schema, and a July-sized spike (30k new books). Those 30k ids end up in legacy `IN` lists, re-sent once per 1,000-row batch.

## Notes for increment 3 (carry forward)

- **MUST:** the user-data migrators must *skip and count*, not raise, on a book that is not here yet but sits above the books watermark (waiting on the delay). It arrives on a later run, and the item or review is picked up then.
- `UserMigrator` already runs in the sync (decision 1). Increment 3 appends the user-data steps after `news_posts` in `Sync#steps`.

---

## File Structure

| File | Responsibility |
|---|---|
| `web-app/db/migrate/<ts>_create_record_redirects.rb` (create) | `record_redirects` table |
| `web-app/app/models/record_redirect.rb` (create) | validations, `ITEM_TYPES` |
| `web-app/app/lib/services/books_migration/redirect_recorder.rb` (create) | writes merge/delete rows, repoints |
| `web-app/app/models/books/book.rb`, `books/author.rb` (modify) | one-line `after_destroy` |
| `web-app/app/lib/books/book/merger.rb`, `books/author/merger.rb` (modify) | `record_redirect` before the destroy |
| `web-app/app/lib/services/books_migration/redirects.rb` (create) | reader: resolve, redirected ids, counts |
| `web-app/db/migrate/<ts>_create_legacy_sync_watermarks.rb` (create) | `legacy_sync_watermarks` table |
| `web-app/app/models/legacy_sync_watermark.rb` (create) | validations, `KEYS` |
| `web-app/app/lib/services/books_migration.rb` (modify) | `max_legacy_origin_id` |
| `web-app/app/lib/services/books_migration/legacy_source.rb` (create) | the legacy queries a plan needs (thin, untested) |
| `web-app/app/lib/services/books_migration/sync_init.rb` (create) | writes the watermarks once |
| `web-app/app/lib/services/books_migration/sync_scope.rb` (create) | what one run may write |
| `web-app/app/lib/services/books_migration/sync_plan.rb` (create) | scope + next watermarks + report numbers |
| `web-app/app/lib/services/books_migration/migrator.rb`, `bulk_upsert_migrator.rb` (modify) | `sync:` plumbing, scope filter |
| 21 migrators + `app/lib/services/books/edition_identifier_backfill.rb` (modify) | per-migrator sync behavior |
| `web-app/app/lib/services/books_migration/sync.rb` (create) | runs a sync |
| `web-app/app/lib/services/books_migration/sync_report.rb` (create) | prints a plan |
| `web-app/lib/tasks/data_migration.rake` (modify) | `sync_init`, `sync`, `sync_report`, the guard |
| `web-app/test/support/books_legacy_sync_helper.rb` (create) | `FakeLegacySource`, `sync_scope`, `init_watermarks` |
| `docs/features/books-legacy-sync.md` (create), `docs/features/record-merge.md` (modify) | feature docs |

---

### Task 1: The `record_redirects` table and its writers

**Files:**
- Create: `web-app/db/migrate/<ts>_create_record_redirects.rb` (generated)
- Create: `web-app/app/models/record_redirect.rb` (generated, then replaced)
- Create: `web-app/app/lib/services/books_migration/redirect_recorder.rb`
- Modify: `web-app/app/models/books/book.rb` (after line 140, the `before_validation :derive_book_length` call)
- Modify: `web-app/app/models/books/author.rb` (after line 74, `before_validation :normalize_alternate_names`)
- Modify: `web-app/test/fixtures/record_redirects.yml` (generated, emptied)
- Test: `web-app/test/models/record_redirect_test.rb` (generated, replaced)
- Test: `web-app/test/lib/services/books_migration/redirect_recorder_test.rb` (create)
- Test: `web-app/test/models/books/book_test.rb`, `web-app/test/models/books/author_test.rb` (append)

**Interfaces:**
- Produces: `RecordRedirect` (`item_type`, `from_id`, `to_id`, timestamps; `RecordRedirect::ITEM_TYPES = %w[Books::Book Books::Author]`).
- Produces: `Services::BooksMigration::RedirectRecorder.merged(item_type:, from_id:, to_id:)` and `.deleted(item_type:, from_id:)`, both returning nothing useful. Also `.legacy_origin?(item_type, id)` → Boolean.

- [ ] **Step 1: Generate the model**

```bash
cd web-app
bin/rails generate model RecordRedirect item_type:string from_id:bigint to_id:bigint
```

Edit the generated migration so it reads exactly (keep the generated class name and `[8.1]`):

```ruby
class CreateRecordRedirects < ActiveRecord::Migration[8.1]
  def change
    create_table :record_redirects do |t|
      t.string :item_type, null: false
      t.bigint :from_id, null: false
      t.bigint :to_id
      t.timestamps
    end
    add_index :record_redirects, [:item_type, :from_id], unique: true
  end
end
```

Replace `test/fixtures/record_redirects.yml` with a comment only. The generated rows would load into every test:

```yaml
# Intentionally empty: tests create the redirects they need.
```

- [ ] **Step 2: Migrate and check the schema diff**

```bash
ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate
git diff db/schema.rb
```

Expected: only the `record_redirects` table, its index, and the version line. Anything else came from another worktree's migrations in the shared dev DB; restore and hand-add (see Global Constraints).

- [ ] **Step 3: Write the failing tests**

`test/models/record_redirect_test.rb` (replace the generated file):

```ruby
require "test_helper"

class RecordRedirectTest < ActiveSupport::TestCase
  test "accepts a books book or author" do
    assert RecordRedirect.new(item_type: "Books::Book", from_id: 5, to_id: 9).valid?
    assert RecordRedirect.new(item_type: "Books::Author", from_id: 5, to_id: nil).valid?
  end

  test "rejects any other item type" do
    refute RecordRedirect.new(item_type: "Music::Album", from_id: 5).valid?
  end

  test "allows one row per item type and from id" do
    RecordRedirect.create!(item_type: "Books::Book", from_id: 5, to_id: 9)

    refute RecordRedirect.new(item_type: "Books::Book", from_id: 5, to_id: nil).valid?
    assert RecordRedirect.new(item_type: "Books::Author", from_id: 5).valid?
  end
end
```

`test/lib/services/books_migration/redirect_recorder_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::RedirectRecorderTest < ActiveSupport::TestCase
  Recorder = Services::BooksMigration::RedirectRecorder

  def fate(item_type, from_id)
    RecordRedirect.find_by(item_type: item_type, from_id: from_id)
  end

  test "records a legacy-origin merge" do
    Recorder.merged(item_type: "Books::Book", from_id: 1_001, to_id: 2_002)

    assert_equal 2_002, fate("Books::Book", 1_001).to_id
  end

  test "records a legacy-origin delete with no survivor" do
    Recorder.deleted(item_type: "Books::Author", from_id: 1_001)

    row = fate("Books::Author", 1_001)
    assert row
    assert_nil row.to_id
  end

  test "records nothing for an id at or above the ceiling" do
    ceiling = Services::BooksMigration::RESERVED_CEILINGS.fetch("books_books")

    Recorder.merged(item_type: "Books::Book", from_id: ceiling, to_id: 7)
    Recorder.deleted(item_type: "Books::Book", from_id: ceiling + 1)

    assert_equal 0, RecordRedirect.count
  end

  test "uses each item type's own ceiling" do
    author_ceiling = Services::BooksMigration::RESERVED_CEILINGS.fetch("books_authors")

    Recorder.deleted(item_type: "Books::Book", from_id: author_ceiling)
    Recorder.deleted(item_type: "Books::Author", from_id: author_ceiling)

    assert fate("Books::Book", author_ceiling)
    assert_nil fate("Books::Author", author_ceiling)
  end

  test "a delete after a merge keeps the merge" do
    Recorder.merged(item_type: "Books::Book", from_id: 1_001, to_id: 2_002)
    Recorder.deleted(item_type: "Books::Book", from_id: 1_001)

    assert_equal 2_002, fate("Books::Book", 1_001).to_id
  end

  test "a merge overwrites an earlier delete" do
    Recorder.deleted(item_type: "Books::Book", from_id: 1_001)
    Recorder.merged(item_type: "Books::Book", from_id: 1_001, to_id: 2_002)

    assert_equal 2_002, fate("Books::Book", 1_001).to_id
  end

  test "repoints rows that named a record merged away, even a new-app one" do
    new_app_id = Services::BooksMigration::RESERVED_CEILINGS.fetch("books_books") + 5
    Recorder.merged(item_type: "Books::Book", from_id: 1_001, to_id: new_app_id)

    Recorder.merged(item_type: "Books::Book", from_id: new_app_id, to_id: 3_003)

    assert_equal 3_003, fate("Books::Book", 1_001).to_id
    assert_nil fate("Books::Book", new_app_id)
  end

  test "repoints rows that named a deleted record to deleted" do
    new_app_id = Services::BooksMigration::RESERVED_CEILINGS.fetch("books_books") + 5
    Recorder.merged(item_type: "Books::Book", from_id: 1_001, to_id: new_app_id)

    Recorder.deleted(item_type: "Books::Book", from_id: new_app_id)

    assert_nil fate("Books::Book", 1_001).to_id
  end

  test "repoints within the item type only" do
    Recorder.merged(item_type: "Books::Author", from_id: 1_001, to_id: 2_002)

    Recorder.deleted(item_type: "Books::Book", from_id: 2_002)

    assert_equal 2_002, fate("Books::Author", 1_001).to_id
  end
end
```

Append inside `class BookTest` in `test/models/books/book_test.rb` (before its closing `end`s):

```ruby
    test "destroying a legacy-origin book records it as deleted" do
      book = ::Books::Book.create!(id: 1_001, title: "Legacy Origin Book")

      book.destroy!

      row = RecordRedirect.find_by!(item_type: "Books::Book", from_id: 1_001)
      assert_nil row.to_id
    end

    test "destroying a new-app book records nothing" do
      book = ::Books::Book.create!(title: "New App Book")
      assert_operator book.id, :>=, Services::BooksMigration::RESERVED_CEILINGS.fetch("books_books")

      assert_no_difference -> { RecordRedirect.count } do
        book.destroy!
      end
    end
```

Append inside `class AuthorTest` in `test/models/books/author_test.rb`:

```ruby
    test "destroying a legacy-origin author records it as deleted" do
      author = ::Books::Author.create!(id: 1_001, name: "Legacy Origin Author")

      author.destroy!

      row = RecordRedirect.find_by!(item_type: "Books::Author", from_id: 1_001)
      assert_nil row.to_id
    end
```

- [ ] **Step 4: Run the tests to verify they fail**

```bash
bin/rails test test/models/record_redirect_test.rb test/lib/services/books_migration/redirect_recorder_test.rb test/models/books/book_test.rb test/models/books/author_test.rb
```

Expected: the model tests fail on validations ("rejects any other item type"), the recorder tests error with `uninitialized constant Services::BooksMigration::RedirectRecorder`, and the two "records it as deleted" tests fail with `ActiveRecord::RecordNotFound`. "destroying a new-app book records nothing" passes already (it is the negative class).

- [ ] **Step 5: Implement**

`app/models/record_redirect.rb` (replace the generated body, keeping any annotation header the generator wrote):

```ruby
# What became of a legacy-origin Books::Book or Books::Author that no longer
# exists here: merged into to_id, or deleted (to_id nil). The books legacy sync
# reads it so it never brings either back (spec 2026-10-08-books-legacy-sync §4).
class RecordRedirect < ApplicationRecord
  ITEM_TYPES = %w[Books::Book Books::Author].freeze

  validates :item_type, inclusion: {in: ITEM_TYPES}
  validates :from_id, presence: true, uniqueness: {scope: :item_type}
end
```

`app/lib/services/books_migration/redirect_recorder.rb`:

```ruby
module Services
  module BooksMigration
    # Writes record_redirects (spec §4). Only a legacy-origin id (below its
    # table's ceiling) gets a row of its own: nothing else can be brought back by
    # the sync. Rows already pointing AT the departing record are repointed
    # whatever its id, so a legacy book merged into a new-app book still resolves
    # after that book is merged or deleted in turn.
    class RedirectRecorder
      TABLES = {"Books::Book" => "books_books", "Books::Author" => "books_authors"}.freeze

      # A merge overwrites any row already there: it is the more specific fate.
      def self.merged(item_type:, from_id:, to_id:)
        repoint(item_type, from_id, to_id)
        return unless legacy_origin?(item_type, from_id)

        RecordRedirect.upsert({item_type: item_type, from_id: from_id, to_id: to_id}, unique_by: [:item_type, :from_id])
      end

      # ON CONFLICT DO NOTHING: a merger records its row before destroying the
      # source, and the destroy that follows must not turn it into a delete.
      def self.deleted(item_type:, from_id:)
        repoint(item_type, from_id, nil)
        return unless legacy_origin?(item_type, from_id)

        RecordRedirect.insert({item_type: item_type, from_id: from_id, to_id: nil}, unique_by: [:item_type, :from_id])
      end

      def self.legacy_origin?(item_type, id)
        id.to_i < RESERVED_CEILINGS.fetch(TABLES.fetch(item_type))
      end

      def self.repoint(item_type, from_id, to_id)
        RecordRedirect.where(item_type: item_type, to_id: from_id).update_all(to_id: to_id, updated_at: Time.current)
      end
      private_class_method :repoint
    end
  end
end
```

In `app/models/books/book.rb`, after the `before_validation :derive_book_length, ...` call:

```ruby
  after_destroy { Services::BooksMigration::RedirectRecorder.deleted(item_type: "Books::Book", from_id: id) }
```

In `app/models/books/author.rb`, after `before_validation :normalize_alternate_names`:

```ruby
  after_destroy { Services::BooksMigration::RedirectRecorder.deleted(item_type: "Books::Author", from_id: id) }
```

- [ ] **Step 6: Run the tests to verify they pass**

Same command as Step 4. Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add db/migrate/*_create_record_redirects.rb db/schema.rb app/models/record_redirect.rb app/lib/services/books_migration/redirect_recorder.rb app/models/books/book.rb app/models/books/author.rb test/fixtures/record_redirects.yml test/models/record_redirect_test.rb test/lib/services/books_migration/redirect_recorder_test.rb test/models/books/book_test.rb test/models/books/author_test.rb
git commit -m "Record what became of legacy-origin books and authors"
```

---

### Task 2: The mergers record `from → survivor`

**Files:**
- Modify: `web-app/app/lib/books/book/merger.rb` (the `call` transaction block, ~line 63; new private method beside `destroy_source_book`, ~line 639)
- Modify: `web-app/app/lib/books/author/merger.rb` (the `call` transaction block, ~line 62; beside `destroy_source_author`, ~line 471)
- Test: `web-app/test/lib/books/book/merger_test.rb`, `web-app/test/lib/books/author/merger_test.rb` (append)

**Interfaces:**
- Consumes: `Services::BooksMigration::RedirectRecorder.merged(item_type:, from_id:, to_id:)` (Task 1).

- [ ] **Step 1: Write the failing tests**

Append inside `class MergerTest` in `test/lib/books/book/merger_test.rb`:

```ruby
      test "records a legacy-origin source as merged into the target, and the destroy keeps it" do
        GenerateUserFavoritesListsJob.stubs(:perform_async)
        source = ::Books::Book.create!(id: 1_002, title: "Legacy Duplicate")

        result = ::Books::Book::Merger.call(source: source, target: @target)

        assert result.success?, result.errors.inspect
        assert_equal @target.id, RecordRedirect.find_by!(item_type: "Books::Book", from_id: 1_002).to_id
      end
```

Append inside `class MergerTest` in `test/lib/books/author/merger_test.rb`:

```ruby
      test "records a legacy-origin source as merged into the target, and the destroy keeps it" do
        source = ::Books::Author.create!(id: 1_003, name: "Legacy Pen Name")

        result = ::Books::Author::Merger.call(source: source, target: @target)

        assert result.success?, result.errors.inspect
        assert_equal @target.id, RecordRedirect.find_by!(item_type: "Books::Author", from_id: 1_003).to_id
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/lib/books/book/merger_test.rb test/lib/books/author/merger_test.rb -n "/records a legacy-origin source/"
```

Expected: both FAIL. Task 1's `after_destroy` already wrote a row, but with `to_id` nil: `Expected: <target id> Actual: nil`.

- [ ] **Step 3: Implement**

In `app/lib/books/book/merger.rb`, inside `call`'s transaction, insert `record_redirect` immediately before `destroy_source_book`:

```ruby
          resolve_duplicate_candidates
          record_redirect
          destroy_source_book
```

and add, above `def destroy_source_book`:

```ruby
      # Before the destroy, so the after_destroy delete row that follows finds this
      # one and leaves it. Inside the transaction, so a rollback takes it too.
      def record_redirect
        ::Services::BooksMigration::RedirectRecorder.merged(item_type: "Books::Book", from_id: @source_book_id, to_id: target_book.id)
      end
```

In `app/lib/books/author/merger.rb`, the same in `call`:

```ruby
          resolve_duplicate_candidates
          record_redirect
          destroy_source_author
```

and above `def destroy_source_author`:

```ruby
      # Before the destroy, so the after_destroy delete row that follows finds this
      # one and leaves it. Inside the transaction, so a rollback takes it too.
      def record_redirect
        ::Services::BooksMigration::RedirectRecorder.merged(item_type: "Books::Author", from_id: @source_author_id, to_id: target_author.id)
      end
```

- [ ] **Step 4: Run both merger test files in full**

```bash
bin/rails test test/lib/books/book/merger_test.rb test/lib/books/author/merger_test.rb
```

Expected: all pass, including every existing merger test.

- [ ] **Step 5: Commit**

```bash
git add app/lib/books/book/merger.rb app/lib/books/author/merger.rb test/lib/books/book/merger_test.rb test/lib/books/author/merger_test.rb
git commit -m "Book and author mergers record the survivor before the destroy"
```

---

### Task 3: The `Redirects` reader

**Files:**
- Create: `web-app/app/lib/services/books_migration/redirects.rb`
- Test: `web-app/test/lib/services/books_migration/redirects_test.rb`

**Interfaces:**
- Consumes: `RecordRedirect` (Task 1).
- Produces: `Services::BooksMigration::Redirects.load` → instance (reads the table once). `Redirects.new(rows)` where rows are `[[item_type, from_id, to_id], ...]`. Instance methods:
  - `#resolve(item_type, id)` → Integer (the id itself, or the final survivor) or the Symbol `:deleted`; raises `RuntimeError` on a cycle.
  - `#redirected?(item_type, id)` → Boolean.
  - `#redirected_ids(item_type)` → `Set` of from_ids.
  - `#counts` → `{"Books::Book" => {merged: Integer, deleted: Integer}, "Books::Author" => {...}}`.

- [ ] **Step 1: Write the failing tests**

```ruby
require "test_helper"

class Services::BooksMigration::RedirectsTest < ActiveSupport::TestCase
  Redirects = Services::BooksMigration::Redirects

  test "an id with no redirect resolves to itself" do
    assert_equal 5, Redirects.new([]).resolve("Books::Book", 5)
  end

  test "a merged id resolves to its survivor" do
    redirects = Redirects.new([["Books::Book", 5, 9]])

    assert_equal 9, redirects.resolve("Books::Book", 5)
  end

  test "follows a chain of merges to the final survivor" do
    redirects = Redirects.new([["Books::Book", 5, 9], ["Books::Book", 9, 12]])

    assert_equal 12, redirects.resolve("Books::Book", 5)
  end

  test "a deleted id resolves to :deleted, including at the end of a chain" do
    redirects = Redirects.new([["Books::Book", 5, nil], ["Books::Book", 6, 7], ["Books::Book", 7, nil]])

    assert_equal :deleted, redirects.resolve("Books::Book", 5)
    assert_equal :deleted, redirects.resolve("Books::Book", 6)
  end

  test "a cycle raises, naming the ids" do
    redirects = Redirects.new([["Books::Book", 5, 9], ["Books::Book", 9, 5]])

    error = assert_raises(RuntimeError) { redirects.resolve("Books::Book", 5) }
    assert_includes error.message, "5 -> 9 -> 5"
  end

  test "keeps books and authors apart" do
    redirects = Redirects.new([["Books::Author", 5, 9]])

    assert_equal 5, redirects.resolve("Books::Book", 5)
    refute redirects.redirected?("Books::Book", 5)
    assert redirects.redirected?("Books::Author", 5)
  end

  test "lists the redirected ids of one type" do
    redirects = Redirects.new([["Books::Book", 5, 9], ["Books::Book", 6, nil], ["Books::Author", 7, nil]])

    assert_equal Set[5, 6], redirects.redirected_ids("Books::Book")
  end

  test "counts merges and deletes per type" do
    redirects = Redirects.new([["Books::Book", 5, 9], ["Books::Book", 6, nil], ["Books::Author", 7, nil]])

    assert_equal(
      {"Books::Book" => {merged: 1, deleted: 1}, "Books::Author" => {merged: 0, deleted: 1}},
      redirects.counts
    )
  end

  test "load reads the record_redirects table" do
    RecordRedirect.create!(item_type: "Books::Book", from_id: 5, to_id: 9)

    assert_equal 9, Redirects.load.resolve("Books::Book", 5)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
bin/rails test test/lib/services/books_migration/redirects_test.rb
```

Expected: errors, `uninitialized constant Services::BooksMigration::Redirects`.

- [ ] **Step 3: Implement**

```ruby
module Services
  module BooksMigration
    # Read side of record_redirects (spec §4), loaded once per sync run.
    class Redirects
      def self.load
        new(RecordRedirect.pluck(:item_type, :from_id, :to_id))
      end

      # rows: [[item_type, from_id, to_id], ...]; to_id nil means deleted.
      def initialize(rows)
        @targets = rows.to_h { |item_type, from_id, to_id| [[item_type, from_id], to_id] }
      end

      # The id to write in place of +id+: itself when nothing happened to it, the
      # final survivor of a chain of merges, or :deleted.
      def resolve(item_type, id)
        seen = []
        current = id
        while @targets.key?([item_type, current])
          raise "record_redirects cycle for #{item_type}: #{(seen + [current]).join(" -> ")}" if seen.include?(current)

          seen << current
          current = @targets[[item_type, current]]
          return :deleted if current.nil?
        end
        current
      end

      def redirected?(item_type, id)
        @targets.key?([item_type, id])
      end

      def redirected_ids(item_type)
        @targets.each_key.filter_map { |type, from_id| from_id if type == item_type }.to_set
      end

      def counts
        RecordRedirect::ITEM_TYPES.index_with do |item_type|
          fates = @targets.filter_map { |(type, _from_id), to_id| [to_id] if type == item_type }.map(&:first)
          {merged: fates.count { |to_id| !to_id.nil? }, deleted: fates.count(&:nil?)}
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Same command. Expected: 9 pass.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books_migration/redirects.rb test/lib/services/books_migration/redirects_test.rb
git commit -m "Read record_redirects: resolve merge chains and deletes"
```

---

### Task 4: Watermarks, `sync_init`, and the full-migration guard

**Files:**
- Create: `web-app/db/migrate/<ts>_create_legacy_sync_watermarks.rb` (generated)
- Create: `web-app/app/models/legacy_sync_watermark.rb` (generated, replaced)
- Modify: `web-app/test/fixtures/legacy_sync_watermarks.yml` (generated, emptied)
- Modify: `web-app/app/lib/services/books_migration.rb` (add `max_legacy_origin_id` after `raise_if_at_ceiling!`)
- Create: `web-app/app/lib/services/books_migration/legacy_source.rb`
- Create: `web-app/app/lib/services/books_migration/sync_init.rb`
- Create: `web-app/test/support/books_legacy_sync_helper.rb`; Modify: `web-app/test/test_helper.rb` (require it)
- Modify: `web-app/lib/tasks/data_migration.rake`
- Test: `web-app/test/models/legacy_sync_watermark_test.rb` (generated, replaced), `web-app/test/lib/services/books_migration/sync_init_test.rb` (create), `web-app/test/lib/services/books_migration/sequence_floor_test.rb` (append), `web-app/test/lib/tasks/data_migration_test.rb` (modify)

**Interfaces:**
- Produces: `LegacySyncWatermark` (`key`, `value`, timestamps; `LegacySyncWatermark::KEYS = %w[books authors book_identifiers]`).
- Produces: `Services::BooksMigration.max_legacy_origin_id(table)` → Integer (0 when none).
- Produces: `Services::BooksMigration::LegacySource` with:
  - `#book_rows_above(id)`, `#author_rows_above(id)`, `#book_identifier_rows_above(id)` → `[[id, created_at], ...]` in id order
  - `#book_ids`, `#author_ids`, `#category_ids` → `Array<Integer>`
  - `#books_updated_since(time, through_id:)` → Integer
  - `#max_book_identifier_id` → Integer
- Produces: `Services::BooksMigration::SyncInit.call(legacy: LegacySource.new)` → `Result(success?, data: {"books" => Integer, "authors" => Integer, "book_identifiers" => Integer}, errors: [String])`.
- Produces: `BooksLegacySyncHelper` (test support), with `FakeLegacySource.new(book_rows: [], author_rows: [], book_identifier_rows: [], book_ids: nil, author_ids: nil, category_ids: [], books_updated_count: 0, max_book_identifier_id: 0)` (same methods as `LegacySource`) and `init_watermarks(books:, authors:, book_identifiers:)`.
- Produces: rake `data_migration:refuse_after_sync_init`, `data_migration:sync_init`.

- [ ] **Step 1: Generate the model, migrate, empty the fixture**

```bash
bin/rails generate model LegacySyncWatermark key:string value:bigint
```

Migration body:

```ruby
class CreateLegacySyncWatermarks < ActiveRecord::Migration[8.1]
  def change
    create_table :legacy_sync_watermarks do |t|
      t.string :key, null: false
      t.bigint :value, null: false
      t.timestamps
    end
    add_index :legacy_sync_watermarks, :key, unique: true
  end
end
```

`test/fixtures/legacy_sync_watermarks.yml`. This must stay empty: one row here would make every test see a synced database, and `:all` would refuse:

```yaml
# Intentionally empty: any row here would make data_migration:all refuse in every test.
```

```bash
ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate
git diff db/schema.rb
```

Expected: only `legacy_sync_watermarks` and the version line (see Global Constraints).

- [ ] **Step 2: Write the test helper**

`test/support/books_legacy_sync_helper.rb`:

```ruby
# Test doubles for the books legacy sync. No test opens the legacy connection:
# FakeLegacySource answers the same questions Services::BooksMigration::LegacySource
# asks legacy. Rows are [id, created_at] pairs in id order.
module BooksLegacySyncHelper
  class FakeLegacySource
    def initialize(book_rows: [], author_rows: [], book_identifier_rows: [], book_ids: nil, author_ids: nil,
      category_ids: [], books_updated_count: 0, max_book_identifier_id: 0)
      @book_rows = book_rows
      @author_rows = author_rows
      @book_identifier_rows = book_identifier_rows
      @book_ids = book_ids
      @author_ids = author_ids
      @category_ids = category_ids
      @books_updated_count = books_updated_count
      @max_book_identifier_id = max_book_identifier_id
    end

    def book_rows_above(id) = @book_rows.select { |row_id, _| row_id > id }

    def author_rows_above(id) = @author_rows.select { |row_id, _| row_id > id }

    def book_identifier_rows_above(id) = @book_identifier_rows.select { |row_id, _| row_id > id }

    def book_ids = @book_ids || @book_rows.map(&:first)

    def author_ids = @author_ids || @author_rows.map(&:first)

    attr_reader :category_ids, :max_book_identifier_id

    def books_updated_since(_time, through_id:) = @books_updated_count
  end

  def init_watermarks(books:, authors:, book_identifiers:)
    {"books" => books, "authors" => authors, "book_identifiers" => book_identifiers}.each do |key, value|
      LegacySyncWatermark.create!(key: key, value: value)
    end
  end
end
```

In `test/test_helper.rb`, after `require_relative "support/sequence_isolation"`:

```ruby
require_relative "support/books_legacy_sync_helper"
```

- [ ] **Step 3: Write the failing tests**

`test/models/legacy_sync_watermark_test.rb` (replace the generated file):

```ruby
require "test_helper"

class LegacySyncWatermarkTest < ActiveSupport::TestCase
  test "accepts the three sync keys" do
    LegacySyncWatermark::KEYS.each do |key|
      assert LegacySyncWatermark.new(key: key, value: 1).valid?, key
    end
  end

  test "rejects an unknown key and a missing value" do
    refute LegacySyncWatermark.new(key: "editions", value: 1).valid?
    refute LegacySyncWatermark.new(key: "books", value: nil).valid?
  end

  test "allows one row per key" do
    LegacySyncWatermark.create!(key: "books", value: 1)

    refute LegacySyncWatermark.new(key: "books", value: 2).valid?
  end
end
```

Append to `test/lib/services/books_migration/sequence_floor_test.rb` (inside the class):

```ruby
  test "max_legacy_origin_id is the highest id below the ceiling" do
    ceiling = Services::BooksMigration::RESERVED_CEILINGS.fetch("books_books")
    ::Books::Book.create!(id: 1_500, title: "Legacy Origin")
    ::Books::Book.create!(id: ceiling + 3, title: "New App")

    assert_equal 1_500, Services::BooksMigration.max_legacy_origin_id("books_books")
  end
```

`test/lib/services/books_migration/sync_init_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::SyncInitTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  test "records the highest legacy-origin book and author ids and legacy's max book_identifiers id" do
    ::Books::Book.create!(id: 1_500, title: "Last Legacy Book")
    ::Books::Author.create!(id: 700, name: "Last Legacy Author")

    result = Services::BooksMigration::SyncInit.call(legacy: FakeLegacySource.new(max_book_identifier_id: 88_000))

    assert result.success?, result.errors.inspect
    expected = {"books" => 1_500, "authors" => 700, "book_identifiers" => 88_000}
    assert_equal expected, result.data
    assert_equal expected, LegacySyncWatermark.pluck(:key, :value).to_h
  end

  test "ignores new-app rows above the ceiling" do
    ceiling = Services::BooksMigration::RESERVED_CEILINGS.fetch("books_books")
    ::Books::Book.create!(id: 1_500, title: "Last Legacy Book")
    ::Books::Book.create!(id: ceiling + 1, title: "Goodreads Import")

    result = Services::BooksMigration::SyncInit.call(legacy: FakeLegacySource.new)

    assert_equal 1_500, result.data["books"]
  end

  test "refuses when watermarks already exist" do
    init_watermarks(books: 1, authors: 2, book_identifiers: 3)

    result = Services::BooksMigration::SyncInit.call(legacy: FakeLegacySource.new(max_book_identifier_id: 99))

    refute result.success?
    assert_match(/already exist/, result.errors.first)
    assert_equal 3, LegacySyncWatermark.find_by!(key: "book_identifiers").value
  end
end
```

In `test/lib/tasks/data_migration_test.rb`, replace the reenable list in `setup` with:

```ruby
    %w[
      data_migration:reading_goals
      data_migration:verify_reading_goals
      data_migration:num_years_covered:derive
      data_migration:penalties
      data_migration:list_penalties
      data_migration:penalties:reconcile
      data_migration:all
      data_migration:refuse_after_sync_init
      data_migration:sync_init
      data_migration:books
      data_migration:languages
    ].each { |name| Rake::Task[name].reenable if Rake::Task.task_defined?(name) }
```

add `include BooksLegacySyncHelper` under the class line, and append these tests:

```ruby
  test "all checks for sync watermarks before anything else" do
    assert_equal "refuse_after_sync_init", Rake::Task["data_migration:all"].prerequisites.first
  end

  test "all refuses once the sync watermarks exist" do
    init_watermarks(books: 1, authors: 1, book_identifiers: 1)
    Services::BooksMigration::LanguageMigrator.expects(:call).never

    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:all"].invoke }
    end
    assert_match(/use data_migration:sync/, err)
  end

  test "a catalog task refuses on its own once the sync watermarks exist" do
    init_watermarks(books: 1, authors: 1, book_identifiers: 1)
    Services::BooksMigration::BookMigrator.expects(:call).never

    capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:books"].invoke }
    end
  end

  test "a catalog task runs normally before sync_init" do
    Services::BooksMigration::BookMigrator.expects(:call).once.returns(success: true, data: {model: "Books::Book", count: 0})

    capture_io { Rake::Task["data_migration:books"].invoke }
  end

  test "the user-data tasks are not guarded" do
    %w[users user_lists user_list_items reading_goals saved_searches recommendation_configs reviews corrections news_posts description_safety_net].each do |name|
      refute_includes Rake::Task["data_migration:#{name}"].prerequisites, "refuse_after_sync_init", name
    end
  end

  test "sync_init prints the watermarks" do
    Services::BooksMigration::SyncInit.expects(:call).returns(
      Services::BooksMigration::SyncInit::Result.new(success?: true, data: {"books" => 5}, errors: [])
    )

    out, _err = capture_io { Rake::Task["data_migration:sync_init"].invoke }

    assert_match(/"books" => 5/, out)
  end

  test "sync_init aborts when it refuses" do
    Services::BooksMigration::SyncInit.stubs(:call).returns(
      Services::BooksMigration::SyncInit::Result.new(success?: false, data: {}, errors: ["sync watermarks already exist"])
    )

    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:sync_init"].invoke }
    end
    assert_match(/sync_init failed: sync watermarks already exist/, err)
  end
```

- [ ] **Step 4: Run to verify they fail**

```bash
bin/rails test test/models/legacy_sync_watermark_test.rb test/lib/services/books_migration/sync_init_test.rb test/lib/services/books_migration/sequence_floor_test.rb test/lib/tasks/data_migration_test.rb
```

Expected:
- Model validations fail.
- `max_legacy_origin_id` raises NoMethodError.
- `SyncInit` raises NameError.
- The rake tests fail: no `refuse_after_sync_init` prerequisite, and `Don't know how to build task 'data_migration:sync_init'`.
- "a catalog task runs normally" and "the user-data tasks are not guarded" pass already (negative class).

- [ ] **Step 5: Implement**

`app/models/legacy_sync_watermark.rb`:

```ruby
# The highest legacy id data_migration:sync has processed, per legacy table
# (spec 2026-10-08-books-legacy-sync §5). Written once by sync_init, advanced by
# each successful sync.
class LegacySyncWatermark < ApplicationRecord
  KEYS = %w[books authors book_identifiers].freeze

  validates :key, inclusion: {in: KEYS}, uniqueness: true
  validates :value, presence: true
end
```

In `app/lib/services/books_migration.rb`, after `raise_if_at_ceiling!`:

```ruby
    # The highest id below the table's ceiling: the last legacy-origin row here.
    def self.max_legacy_origin_id(table)
      connection = ActiveRecord::Base.connection
      connection.select_value(
        "SELECT COALESCE(MAX(id), 0) FROM #{connection.quote_table_name(table)} WHERE id < #{RESERVED_CEILINGS.fetch(table).to_i}"
      ).to_i
    end
```

`app/lib/services/books_migration/legacy_source.rb`:

```ruby
module Services
  module BooksMigration
    # Every legacy query a sync plan needs, in one place so tests can swap in a
    # fake (no test database has the legacy tables). Exercised for real by the dev
    # rehearsal (spec §9).
    class LegacySource
      def book_rows_above(id) = rows_above(LegacyBooks::Book, id)

      def author_rows_above(id) = rows_above(LegacyBooks::Author, id)

      def book_identifier_rows_above(id) = rows_above(LegacyBooks::BookIdentifier, id)

      def book_ids = LegacyBooks::Book.pluck(:id)

      def author_ids = LegacyBooks::Author.pluck(:id)

      def category_ids = LegacyBooks::Category.pluck(:id)

      def books_updated_since(time, through_id:)
        LegacyBooks::Book.where("id <= ? AND updated_at > ?", through_id, time).count
      end

      def max_book_identifier_id = LegacyBooks::BookIdentifier.maximum(:id).to_i

      private

      def rows_above(model, id)
        model.where("id > ?", id).order(:id).pluck(:id, :created_at)
      end
    end
  end
end
```

`app/lib/services/books_migration/sync_init.rb`:

```ruby
module Services
  module BooksMigration
    # Run once, right after the final data_migration:all (spec §5). Books and
    # authors start from the last legacy-origin id here, which is what :all just
    # loaded. book_identifiers starts from legacy's current max, because legacy
    # keeps adding identifiers to books that already exist.
    class SyncInit
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(legacy: LegacySource.new)
        new(legacy: legacy).call
      end

      def initialize(legacy:)
        @legacy = legacy
      end

      def call
        if LegacySyncWatermark.exists?
          return Result.new(
            success?: false,
            data: LegacySyncWatermark.pluck(:key, :value).to_h,
            errors: ["sync watermarks already exist; data_migration:sync_init runs once"]
          )
        end

        values = {
          "books" => Services::BooksMigration.max_legacy_origin_id("books_books"),
          "authors" => Services::BooksMigration.max_legacy_origin_id("books_authors"),
          "book_identifiers" => @legacy.max_book_identifier_id
        }
        LegacySyncWatermark.transaction do
          values.each { |key, value| LegacySyncWatermark.create!(key: key, value: value) }
        end
        Result.new(success?: true, data: values, errors: [])
      end
    end
  end
end
```

In `lib/tasks/data_migration.rake`, near the top of the namespace (after the `languages` task):

```ruby
  desc "Abort when data_migration:sync_init has run (a full migration would undo cleanup)"
  task refuse_after_sync_init: :environment do
    if LegacySyncWatermark.exists?
      abort "data_migration: the legacy sync watermarks exist, so a full migration would undo cleanup -- use data_migration:sync"
    end
  end

  desc "Record the legacy sync watermarks (once, right after the final data_migration:all)"
  task sync_init: :environment do
    result = Services::BooksMigration::SyncInit.call
    pp result.data
    abort "sync_init failed: #{result.errors.join("; ")}" unless result.success?
  end
```

Make `refuse_after_sync_init` the first prerequisite of `:all`:

```ruby
  task all: [:refuse_after_sync_init, :languages, :users, :authors, :books, :book_authors, :editions, :identifiers, :edition_amazon_identifiers,
```

(rest of the list unchanged). After the `all` task, still inside the namespace:

```ruby
  # Each task the sync replaces or retires refuses on its own as well, so running
  # one by hand after sync_init cannot undo cleanup either. The user-data tasks,
  # the description safety net and penalties:reconcile stay runnable.
  %i[languages authors books book_authors editions identifiers edition_amazon_identifiers categories
    category_items book_attributes book_type_categories countries author_countries book_countries
    external_links lists list_items ranking_configurations ranked_lists penalties list_penalties
    book_descriptions author_descriptions book_images].each do |name|
    task name => :refuse_after_sync_init
  end
```

- [ ] **Step 6: Run to verify they pass**

Same command as Step 4. Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add db/migrate/*_create_legacy_sync_watermarks.rb db/schema.rb app/models/legacy_sync_watermark.rb app/lib/services/books_migration.rb app/lib/services/books_migration/legacy_source.rb app/lib/services/books_migration/sync_init.rb lib/tasks/data_migration.rake test/fixtures/legacy_sync_watermarks.yml test/support/books_legacy_sync_helper.rb test/test_helper.rb test/models/legacy_sync_watermark_test.rb test/lib/services/books_migration/sync_init_test.rb test/lib/services/books_migration/sequence_floor_test.rb test/lib/tasks/data_migration_test.rb
git commit -m "Add sync watermarks, data_migration:sync_init, and refuse full runs after it"
```

---

### Task 5: `SyncScope` and `SyncPlan`

**Files:**
- Create: `web-app/app/lib/services/books_migration/sync_scope.rb`
- Create: `web-app/app/lib/services/books_migration/sync_plan.rb`
- Modify: `web-app/test/support/books_legacy_sync_helper.rb` (add `sync_scope`)
- Test: `web-app/test/lib/services/books_migration/sync_plan_test.rb`

**Interfaces:**
- Consumes: `Redirects.load`, `#redirected_ids`, `#counts` (Task 3); `LegacySyncWatermark`, `max_legacy_origin_id`, `LegacySource` / `FakeLegacySource` (Task 4).
- Produces: `Services::BooksMigration::SyncScope = Struct.new(:book_ids, :author_ids, :identifier_ids, :redirects, keyword_init: true)`. The three id fields are `Set<Integer>`; `redirects` is a `Redirects`.
- Produces: `Services::BooksMigration::SyncPlan.build(final: false, now: Time.current, legacy: LegacySource.new)` → `SyncPlan`, with:
  - `#initialized?` → Boolean
  - `#watermarks` → `{"books" => Integer, "authors" => Integer, "book_identifiers" => Integer|nil}`
  - `#scope` → `SyncScope`
  - `#next_watermarks` → same shape as `#watermarks`
  - `#report` → Hash with:
    - `:initialized`, `:watermarks`
    - `:books`, `:authors` → `{legacy:, here:, would_insert:, waiting:, skipped_redirected:, legacy_deleted_still_here: [Integer]}`
    - `:book_identifiers` → `{would_insert: Integer|nil, waiting:}`
    - `:categories_unmapped` → Integer
    - `:redirects` → `Redirects#counts`
    - `:legacy_edits_not_synced` → Integer|nil
- Produces (test helper): `sync_scope(book_ids: [], author_ids: [], identifier_ids: [], redirects: [])` → `SyncScope` (redirects as rows for `Redirects.new`).

- [ ] **Step 1: Add the test helper method**

In `test/support/books_legacy_sync_helper.rb`, inside `module BooksLegacySyncHelper` after `init_watermarks`:

```ruby
  # redirects: rows for Services::BooksMigration::Redirects.new, [[item_type, from_id, to_id], ...]
  def sync_scope(book_ids: [], author_ids: [], identifier_ids: [], redirects: [])
    Services::BooksMigration::SyncScope.new(
      book_ids: book_ids.to_set,
      author_ids: author_ids.to_set,
      identifier_ids: identifier_ids.to_set,
      redirects: Services::BooksMigration::Redirects.new(redirects)
    )
  end
```

- [ ] **Step 2: Write the failing tests**

`test/lib/services/books_migration/sync_plan_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::SyncPlanTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  NOW = Time.zone.parse("2026-10-08 12:00:00")
  OLD = NOW - 2.days
  RECENT = NOW - 1.hour

  def plan(final: false, **legacy)
    Services::BooksMigration::SyncPlan.build(final: final, now: NOW, legacy: FakeLegacySource.new(**legacy))
  end

  test "scopes legacy books above the watermark that are more than a day old" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)

    result = plan(book_rows: [[100, OLD], [101, OLD], [102, OLD]])

    assert result.initialized?
    assert_equal Set[101, 102], result.scope.book_ids
    assert_equal 102, result.next_watermarks["books"]
  end

  test "waits on a book inside the delay and on every id after it" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)

    result = plan(book_rows: [[101, OLD], [102, RECENT], [103, OLD]])

    assert_equal Set[101], result.scope.book_ids
    assert_equal 101, result.next_watermarks["books"]
    assert_equal 2, result.report[:books][:waiting]
  end

  test "FINAL takes every row above the watermark" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)

    result = plan(final: true, book_rows: [[101, OLD], [102, RECENT], [103, OLD]])

    assert_equal Set[101, 102, 103], result.scope.book_ids
    assert_equal 0, result.report[:books][:waiting]
  end

  test "scopes authors and book identifiers the same way" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)

    result = plan(author_rows: [[51, OLD], [52, RECENT]], book_identifier_rows: [[500, OLD], [501, OLD], [502, RECENT]])

    assert_equal Set[51], result.scope.author_ids
    assert_equal Set[501], result.scope.identifier_ids
    assert_equal({"books" => 100, "authors" => 51, "book_identifiers" => 501}, result.next_watermarks)
  end

  test "leaves a redirected id out of the run but moves the watermark past it" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)
    RecordRedirect.create!(item_type: "Books::Book", from_id: 101, to_id: nil)
    RecordRedirect.create!(item_type: "Books::Author", from_id: 51, to_id: 9)

    result = plan(book_rows: [[101, OLD], [102, OLD]], author_rows: [[51, OLD]])

    assert_equal Set[102], result.scope.book_ids
    assert_empty result.scope.author_ids
    assert_equal 102, result.next_watermarks["books"]
    assert_equal 51, result.next_watermarks["authors"]
    assert_equal 1, result.report[:books][:skipped_redirected]
  end

  test "keeps every watermark when legacy has nothing new" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)

    result = plan

    assert_equal({"books" => 100, "authors" => 50, "book_identifiers" => 500}, result.next_watermarks)
  end

  test "before sync_init it starts from the highest legacy-origin ids here and scopes no identifiers" do
    ::Books::Book.create!(id: 1_500, title: "Last Legacy Book")
    ::Books::Author.create!(id: 700, name: "Last Legacy Author")

    result = plan(book_rows: [[1_501, OLD]], book_identifier_rows: [[9, OLD]])

    refute result.initialized?
    assert_equal({"books" => 1_500, "authors" => 700, "book_identifiers" => nil}, result.watermarks)
    assert_equal Set[1_501], result.scope.book_ids
    assert_empty result.scope.identifier_ids
    assert_nil result.report[:book_identifiers][:would_insert]
    assert_nil result.report[:legacy_edits_not_synced]
  end

  test "raises naming the missing keys when the watermarks are incomplete" do
    LegacySyncWatermark.create!(key: "books", value: 100)

    error = assert_raises(RuntimeError) { plan }

    assert_includes error.message, "authors"
    assert_includes error.message, "book_identifiers"
  end

  test "would insert counts scoped books that are not already here" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)
    ::Books::Book.create!(id: 101, title: "Inserted By A Failed Run")

    result = plan(book_rows: [[101, OLD], [102, OLD]])

    assert_equal 1, result.report[:books][:would_insert]
  end

  test "reports legacy-origin rows here that legacy no longer has" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)
    ::Books::Book.create!(id: 90, title: "Deleted On Legacy")
    ::Books::Book.create!(id: 91, title: "Still On Legacy")
    ::Books::Author.create!(id: 40, name: "Deleted Author On Legacy")

    result = plan(book_ids: [91], author_ids: [])

    assert_equal [90], result.report[:books][:legacy_deleted_still_here]
    assert_equal [40], result.report[:authors][:legacy_deleted_still_here]
    assert_equal 2, result.report[:books][:here]
    assert_equal 1, result.report[:books][:legacy]
  end

  test "counts legacy categories with no map entry" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)
    LegacyIdMap.record(model: "Books::Category", legacy_id: 7, new_id: 1)

    assert_equal 1, plan(category_ids: [7, 8]).report[:categories_unmapped]
  end

  test "reports legacy edits to existing books once initialized" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)

    assert_equal 4, plan(books_updated_count: 4).report[:legacy_edits_not_synced]
  end

  test "reports the recorded redirects" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)
    RecordRedirect.create!(item_type: "Books::Book", from_id: 5, to_id: 9)

    assert_equal({merged: 1, deleted: 0}, plan.report[:redirects]["Books::Book"])
  end
end
```

- [ ] **Step 3: Run to verify it fails**

```bash
bin/rails test test/lib/services/books_migration/sync_plan_test.rb
```

Expected: errors, `uninitialized constant Services::BooksMigration::SyncPlan`.

- [ ] **Step 4: Implement**

`app/lib/services/books_migration/sync_scope.rb`:

```ruby
module Services
  module BooksMigration
    # What one data_migration:sync run may write (spec §5): the legacy books,
    # authors and book_identifiers rows it brings over, and the redirects that
    # every other book or author id is routed through. Built by SyncPlan, read by
    # the migrators through their sync: argument.
    SyncScope = Struct.new(:book_ids, :author_ids, :identifier_ids, :redirects, keyword_init: true)
  end
end
```

`app/lib/services/books_migration/sync_plan.rb`:

```ruby
module Services
  module BooksMigration
    # One sync run's plan (spec §5, §7), built once at the start. data_migration:sync
    # applies its scope and data_migration:sync_report only prints it, so the two
    # cannot drift. Building it writes nothing.
    class SyncPlan
      DELAY = 24.hours
      TABLES = {"books" => "books_books", "authors" => "books_authors"}.freeze

      Window = Struct.new(:ids, :waiting, keyword_init: true)

      attr_reader :watermarks, :scope, :next_watermarks, :report

      def self.build(final: false, now: Time.current, legacy: LegacySource.new)
        new(final: final, now: now, legacy: legacy)
      end

      def initialize(final:, now:, legacy:)
        @legacy = legacy
        @cutoff = final ? nil : now - DELAY
        @initialized_at = LegacySyncWatermark.minimum(:created_at)
        @watermarks = initialized? ? stored_watermarks : provisional_watermarks
        redirects = Redirects.load

        books = window(legacy.book_rows_above(@watermarks["books"]))
        authors = window(legacy.author_rows_above(@watermarks["authors"]))
        identifiers = if @watermarks["book_identifiers"]
          window(legacy.book_identifier_rows_above(@watermarks["book_identifiers"]))
        else
          Window.new(ids: [], waiting: 0)
        end

        @scope = SyncScope.new(
          book_ids: books.ids.to_set - redirects.redirected_ids("Books::Book"),
          author_ids: authors.ids.to_set - redirects.redirected_ids("Books::Author"),
          identifier_ids: identifiers.ids.to_set,
          redirects: redirects
        )
        @next_watermarks = {
          "books" => books.ids.max || @watermarks["books"],
          "authors" => authors.ids.max || @watermarks["authors"],
          "book_identifiers" => identifiers.ids.max || @watermarks["book_identifiers"]
        }
        @report = build_report(books, authors, identifiers, redirects)
      end

      def initialized?
        !@initialized_at.nil?
      end

      private

      def stored_watermarks
        stored = LegacySyncWatermark.pluck(:key, :value).to_h
        missing = LegacySyncWatermark::KEYS - stored.keys
        raise "legacy_sync_watermarks is missing #{missing.join(", ")}; restore the rows before syncing" if missing.any?

        stored
      end

      # Before sync_init (sync_report only): the last legacy-origin ids here stand
      # in for the books and authors watermarks. There is no identifier watermark yet.
      def provisional_watermarks
        {
          "books" => Services::BooksMigration.max_legacy_origin_id("books_books"),
          "authors" => Services::BooksMigration.max_legacy_origin_id("books_authors"),
          "book_identifiers" => nil
        }
      end

      # Rows above a watermark, in id order. Legacy ids grow with created_at, so
      # the rows old enough to copy are a prefix. Everything from the first row
      # still inside the delay waits, even an older row behind it, so a watermark
      # never passes a row that has not been copied.
      def window(rows)
        first_waiting = @cutoff && rows.index { |_id, created_at| created_at > @cutoff }
        eligible = first_waiting ? rows.first(first_waiting) : rows
        Window.new(ids: eligible.map(&:first), waiting: rows.size - eligible.size)
      end

      def build_report(books, authors, identifiers, redirects)
        {
          initialized: initialized?,
          watermarks: @watermarks,
          books: record_counts("books", ::Books::Book, books, @scope.book_ids, @legacy.book_ids),
          authors: record_counts("authors", ::Books::Author, authors, @scope.author_ids, @legacy.author_ids),
          book_identifiers: {
            would_insert: (@watermarks["book_identifiers"] ? identifiers.ids.size : nil),
            waiting: identifiers.waiting
          },
          categories_unmapped: (@legacy.category_ids - LegacyIdMap.where(model: "Books::Category").pluck(:legacy_id)).size,
          redirects: redirects.counts,
          legacy_edits_not_synced: (initialized? ? @legacy.books_updated_since(@initialized_at, through_id: @watermarks["books"]) : nil)
        }
      end

      def record_counts(key, model, window, scoped_ids, legacy_ids)
        here_ids = model.where("id < ?", RESERVED_CEILINGS.fetch(TABLES.fetch(key))).pluck(:id)
        {
          legacy: legacy_ids.size,
          here: here_ids.size,
          would_insert: scoped_ids.size - model.where(id: scoped_ids.to_a).count,
          waiting: window.waiting,
          skipped_redirected: window.ids.size - scoped_ids.size,
          legacy_deleted_still_here: (here_ids - legacy_ids).sort
        }
      end
    end
  end
end
```

- [ ] **Step 5: Run to verify it passes**

Same command. Expected: 13 pass.

- [ ] **Step 6: Commit**

```bash
git add app/lib/services/books_migration/sync_scope.rb app/lib/services/books_migration/sync_plan.rb test/support/books_legacy_sync_helper.rb test/lib/services/books_migration/sync_plan_test.rb
git commit -m "Plan a sync run: scope past the 24h delay, next watermarks, report numbers"
```

---

### Task 6: Sync mode in the migrator bases and the record-level migrators

**Files:**
- Modify: `web-app/app/lib/services/books_migration/migrator.rb`
- Modify: `web-app/app/lib/services/books_migration/bulk_upsert_migrator.rb` (the `legacy_each` loop in `call`)
- Modify: `book_migrator.rb`, `author_migrator.rb`, `language_migrator.rb`, `country_migrator.rb`, `category_migrator.rb` (all in `web-app/app/lib/services/books_migration/`)
- Test: `web-app/test/lib/services/books_migration/migrator_sync_test.rb` (create); append to `book_migrator_test.rb`, `author_migrator_test.rb`, `language_migrator_test.rb`, `country_migrator_test.rb`, `category_migrator_test.rb`

**Interfaces:**
- Consumes: `SyncScope`, `sync_scope(...)` helper (Task 5).
- Produces: every `Migrator` subclass accepts `.call(sync: nil)` and `.new(sync: nil)`. It has private `sync` (the `SyncScope` or nil), `sync_filter` (`[Symbol, String]` or nil), `in_sync_scope?(attrs)`, and `sync_narrowed(relation)`. `BulkUpsertMigrator#call` applies `in_sync_scope?`.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/books_migration/migrator_sync_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::MigratorSyncTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  class Probe < Services::BooksMigration::Migrator
    attr_reader :seen

    private

    def model_key = "Probe"

    def sync_filter = [:book_ids, "book_id"]

    def upsert_row(attrs) = (@seen ||= []) << attrs["id"]
  end

  class BulkProbe < Services::BooksMigration::BulkUpsertMigrator
    attr_reader :seen

    private

    def model_key = "BulkProbe"

    def sync_filter = [:author_ids, "id"]

    def build_rows(attrs) = ((@seen ||= []) << attrs["id"]) && []
  end

  ROWS = [{"id" => 1, "book_id" => 10}, {"id" => 2, "book_id" => 20}]

  def run(klass, sync)
    migrator = klass.new(sync: sync)
    migrator.stubs(:legacy_each).multiple_yields(*ROWS.zip)
    [migrator.call, migrator.seen]
  end

  test "without a sync scope every legacy row is processed" do
    result, seen = run(Probe, nil)

    assert result[:success], result[:error]
    assert_equal [1, 2], seen
    assert_equal 2, result[:data][:count]
  end

  test "with a sync scope only the run's rows are processed and counted" do
    result, seen = run(Probe, sync_scope(book_ids: [20]))

    assert_equal [2], seen
    assert_equal 1, result[:data][:count]
  end

  test "bulk migrators filter the same way" do
    _result, seen = run(BulkProbe, sync_scope(author_ids: [1]))

    assert_equal [1], seen
  end

  test "call passes the scope through" do
    scope = sync_scope(book_ids: [20])
    Probe.any_instance.stubs(:legacy_each).multiple_yields(*ROWS.zip)

    assert_equal 1, Probe.call(sync: scope)[:data][:count]
  end
end
```

Append to `test/lib/services/books_migration/book_migrator_test.rb` (inside the class; add `include BooksLegacySyncHelper` under `include SequenceIsolation`):

```ruby
  def run_sync(rows, scope)
    migrator = Services::BooksMigration::BookMigrator.new(sync: scope)
    migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
    migrator.call
  end

  test "sync mode inserts only the run's new books" do
    result = run_sync([
      {"id" => 90020, "title" => "In The Run", "original_language_id" => nil},
      {"id" => 90021, "title" => "Not In The Run", "original_language_id" => nil}
    ], sync_scope(book_ids: [90020]))

    assert result[:success], result[:error]
    assert ::Books::Book.exists?(90020)
    refute ::Books::Book.exists?(90021)
  end

  test "sync mode never overwrites a book that is already here" do
    ::Books::Book.create!(id: 90022, title: "Cleaned Title")

    result = run_sync([{"id" => 90022, "title" => "Legacy Title", "original_language_id" => nil}], sync_scope(book_ids: [90022]))

    assert result[:success], result[:error]
    assert_equal "Cleaned Title", ::Books::Book.find(90022).title
  end
```

Append to `test/lib/services/books_migration/author_migrator_test.rb` (add `include BooksLegacySyncHelper`):

```ruby
  def run_sync(rows, scope)
    migrator = Services::BooksMigration::AuthorMigrator.new(sync: scope)
    migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
    migrator.call
  end

  test "sync mode inserts only the run's new authors and never overwrites one here" do
    ::Books::Author.create!(id: 90031, name: "Cleaned Name")

    result = run_sync([
      {"id" => 90030, "name" => "New Legacy Author", "family_name" => "Author", "alternative_names" => nil},
      {"id" => 90031, "name" => "Legacy Name", "family_name" => "Name", "alternative_names" => nil},
      {"id" => 90032, "name" => "Outside The Run", "family_name" => "Run", "alternative_names" => nil}
    ], sync_scope(author_ids: [90030, 90031]))

    assert result[:success], result[:error]
    assert ::Books::Author.exists?(90030)
    assert_equal "Cleaned Name", ::Books::Author.find(90031).name
    refute ::Books::Author.exists?(90032)
  end
```

Append to `test/lib/services/books_migration/language_migrator_test.rb` (add `include BooksLegacySyncHelper`):

```ruby
  test "sync mode skips a legacy language already mapped and adds a new one" do
    renamed = Language.create!(name: "Renamed Here")
    LegacyIdMap.record(model: "Language", legacy_id: 801, new_id: renamed.id)
    migrator = Services::BooksMigration::LanguageMigrator.new(sync: sync_scope)
    migrator.stubs(:legacy_each).multiple_yields([{"id" => 801, "name" => "Legacy Name"}], [{"id" => 802, "name" => "Brand New Tongue"}])

    result = migrator.call

    assert result[:success], result[:error]
    refute Language.exists?(name: "Legacy Name")
    assert_equal renamed.id, LegacyIdMap.lookup(model: "Language", legacy_id: 801)
    assert LegacyIdMap.lookup(model: "Language", legacy_id: 802)
  end
```

Append to `test/lib/services/books_migration/country_migrator_test.rb` (add `include BooksLegacySyncHelper`):

```ruby
  test "sync mode inserts a new country and leaves one already here alone" do
    ::Books::Country.create!(id: 9001, name: "Edited Here")
    migrator = Services::BooksMigration::CountryMigrator.new(sync: sync_scope)
    migrator.stubs(:legacy_each).multiple_yields([legacy_row], [legacy_row("id" => 9002, "name" => "Chilean", "slug" => "chilean")])

    result = migrator.call

    assert result[:success], result[:error]
    assert_equal "Edited Here", ::Books::Country.find(9001).name
    assert_equal "Chilean", ::Books::Country.find(9002).name
  end
```

Append to `test/lib/services/books_migration/category_migrator_test.rb` (add `include BooksLegacySyncHelper`):

```ruby
  def run_sync(rows)
    m = Services::BooksMigration::CategoryMigrator.new(sync: sync_scope)
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "sync mode leaves a mapped category as it is here, even one deleted here" do
    run_migrator([legacy(9101), legacy(9102)])
    edited = ::Books::Category.find(LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9101))
    edited.update!(name: "Edited Here")
    ::Books::Category.where(id: LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9102)).delete_all

    result = run_sync([legacy(9101, "name" => "Legacy Name"), legacy(9102)])

    assert result[:success], result[:error]
    assert_equal "Edited Here", edited.reload.name
    refute ::Books::Category.exists?(name: "Cat 9102")
  end

  test "sync mode adds a new category under a parent mapped earlier" do
    run_migrator([legacy(9103)])

    result = run_sync([legacy(9104, "parent_category_id" => 9103)])

    assert result[:success], result[:error]
    child = ::Books::Category.find(LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9104))
    assert_equal LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9103), child.parent_id
  end
```

- [ ] **Step 2: Run to verify they fail**

```bash
bin/rails test test/lib/services/books_migration/migrator_sync_test.rb test/lib/services/books_migration/book_migrator_test.rb test/lib/services/books_migration/author_migrator_test.rb test/lib/services/books_migration/language_migrator_test.rb test/lib/services/books_migration/country_migrator_test.rb test/lib/services/books_migration/category_migrator_test.rb
```

Expected: `ArgumentError: unknown keyword: :sync` (or wrong number of arguments) in every new test, and the existing tests still pass.

- [ ] **Step 3: Implement the base**

`app/lib/services/books_migration/migrator.rb`: replace `self.call` and add `initialize`:

```ruby
      def self.call(sync: nil)
        new(sync: sync).call
      end

      # sync: a SyncScope when data_migration:sync runs this migrator (spec §5), nil
      # for the full migration.
      def initialize(sync: nil)
        @sync = sync
      end
```

In `call`, make the loop's first line the scope check:

```ruby
          legacy_each do |attrs|
            next unless in_sync_scope?(attrs)

            upsert_row(attrs)
            @count += 1
          rescue => e
```

Replace the private `legacy_each` and add the sync helpers after it:

```ruby
      attr_reader :sync

      # Yields each legacy row's attributes (String keys). Stubbed in tests so the
      # legacy connection is never opened.
      def legacy_each(&block)
        sync_narrowed(legacy_model).find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      # [SyncScope id set, legacy column] naming the rows that belong to a sync run,
      # e.g. [:book_ids, "book_id"]. nil: every row (the migrator decides per row).
      def sync_filter
        nil
      end

      def in_sync_scope?(attrs)
        return true unless sync && sync_filter

        ids, column = sync_filter
        sync.public_send(ids).include?(attrs[column])
      end

      # Asks legacy for the run's rows only. in_sync_scope? still decides; this just
      # keeps a weekly run from reading every legacy row.
      def sync_narrowed(relation)
        return relation unless sync && sync_filter

        ids, column = sync_filter
        relation.where(column => sync.public_send(ids).to_a)
      end
```

`app/lib/services/books_migration/bulk_upsert_migrator.rb`, in `call`:

```ruby
          legacy_each do |attrs|
            next unless in_sync_scope?(attrs)

            build_rows(attrs).each { |row| buffer << row }
```

- [ ] **Step 4: Implement the record-level migrators**

`book_migrator.rb`, `upsert_row` becomes:

```ruby
      def upsert_row(attrs)
        Services::BooksMigration.raise_if_at_ceiling!("books_books", attrs["id"])
        # Insert-only in sync mode: the catalog here is the master (spec §5).
        return if sync && ::Books::Book.exists?(attrs["id"])

        book = ::Books::Book.find_or_initialize_by(id: attrs["id"])
        book.assign_attributes(BookTransformer.call(attrs))
        book.original_language_id = remap_language(attrs["original_language_id"])
        book.save!
      end

      def sync_filter
        [:book_ids, "id"]
      end
```

`author_migrator.rb`:

```ruby
      def upsert_row(attrs)
        Services::BooksMigration.raise_if_at_ceiling!("books_authors", attrs["id"])
        # Insert-only in sync mode: the catalog here is the master (spec §5).
        return if sync && ::Books::Author.exists?(attrs["id"])

        author = ::Books::Author.find_or_initialize_by(id: attrs["id"])
        author.assign_attributes(AuthorTransformer.call(attrs))
        author.save!
      end

      def sync_filter
        [:author_ids, "id"]
      end
```

`language_migrator.rb`:

```ruby
      def upsert_row(attrs)
        # Insert-only in sync mode: a language with a map entry was seen before.
        return if sync && LegacyIdMap.lookup(model: model_key, legacy_id: attrs["id"])

        target = LanguageTransformer.call(attrs)
        language = Language.find_or_create_by!(name: target[:name])
        LegacyIdMap.record(model: model_key, legacy_id: attrs["id"], new_id: language.id)
      end
```

`country_migrator.rb`, first line of `upsert_row`:

```ruby
        # Insert-only in sync mode. Countries keep legacy ids and have no map, so a
        # country deleted here comes back; editing one here sticks.
        return if sync && ::Books::Country.exists?(attrs["id"])
```

`category_migrator.rb`, first line of `upsert_row`:

```ruby
        # Insert-only in sync mode: a legacy id with a map entry was seen before, so
        # a category edited or deleted here stays that way (spec §5).
        return if sync && LegacyIdMap.lookup(model: model_key, legacy_id: attrs["id"])
```

- [ ] **Step 5: Run to verify they pass**

Same command as Step 2. Expected: all pass, old and new.

- [ ] **Step 6: Run the whole migration test directory**

```bash
bin/rails test test/lib/services/books_migration/
```

Expected: all pass. The base change touches every migrator.

- [ ] **Step 7: Commit**

```bash
git add app/lib/services/books_migration/migrator.rb app/lib/services/books_migration/bulk_upsert_migrator.rb app/lib/services/books_migration/book_migrator.rb app/lib/services/books_migration/author_migrator.rb app/lib/services/books_migration/language_migrator.rb app/lib/services/books_migration/country_migrator.rb app/lib/services/books_migration/category_migrator.rb test/lib/services/books_migration/
git commit -m "Migrators take a sync scope; books, authors, languages, countries, categories insert-only in sync mode"
```

---

### Task 7: Sync mode for book authors, editions and identifiers

**Files:**
- Modify (all in `web-app/app/lib/services/books_migration/`): `book_author_migrator.rb`, `edition_migrator.rb`, `book_identifier_migrator.rb`, `book_work_identifier_migrator.rb`, `author_identifier_migrator.rb`, `edition_identifier_migrator.rb`, `edition_isbn_identifier_migrator.rb`
- Modify: `web-app/app/lib/services/books/edition_identifier_backfill.rb`
- Test: append to the matching `*_test.rb` files in `web-app/test/lib/services/books_migration/` and to `web-app/test/lib/services/books/edition_identifier_backfill_test.rb`

**Interfaces:**
- Consumes: `sync`, `sync_filter`, `in_sync_scope?`, `sync_narrowed` (Task 6); `Redirects#resolve` (Task 3).
- Produces: `Services::Books::EditionIdentifierBackfill.call(batch_size: 1_000, book_ids: nil)`; nil means every edition, as today. The sync results of `BookAuthorMigrator` and `BookIdentifierMigrator` add `data[:dropped_deleted]` (Integer).

- [ ] **Step 1: Write the failing tests**

Each file gets `include BooksLegacySyncHelper` under its class line.

`book_author_migrator_test.rb`:

```ruby
  def run_sync(rows, scope)
    m = Services::BooksMigration::BookAuthorMigrator.new(sync: scope)
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "sync mode links a new book to the survivor of its merged author" do
    book = ::Books::Book.create!(id: 90100, title: "New Legacy Book")
    survivor = books_authors(:king)

    result = run_sync([{"book_id" => book.id, "author_id" => 1_201, "position" => 1}],
      sync_scope(book_ids: [book.id], redirects: [["Books::Author", 1_201, survivor.id]]))

    assert result[:success], result[:error]
    assert ::Books::BookAuthor.exists?(book_id: book.id, author_id: survivor.id)
  end

  test "sync mode drops and counts a link to a deleted author" do
    book = ::Books::Book.create!(id: 90101, title: "New Legacy Book")

    result = run_sync([{"book_id" => book.id, "author_id" => 1_202, "position" => 1}],
      sync_scope(book_ids: [book.id], redirects: [["Books::Author", 1_202, nil]]))

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:dropped_deleted]
    assert_empty ::Books::BookAuthor.where(book_id: book.id)
  end

  test "sync mode ignores links of books outside the run and keeps an existing link as it is" do
    in_run = ::Books::Book.create!(id: 90102, title: "In The Run")
    existing = ::Books::Book.create!(id: 90103, title: "Already Here")
    author = books_authors(:king)
    ::Books::BookAuthor.create!(book: in_run, author: author, position: 3)

    result = run_sync([
      {"book_id" => in_run.id, "author_id" => author.id, "position" => 1},
      {"book_id" => existing.id, "author_id" => author.id, "position" => 1}
    ], sync_scope(book_ids: [in_run.id]))

    assert result[:success], result[:error]
    assert_equal 3, ::Books::BookAuthor.find_by!(book_id: in_run.id, author_id: author.id).position
    refute ::Books::BookAuthor.exists?(book_id: existing.id)
  end

  test "fails the run naming the legacy row when the author is neither here nor redirected" do
    book = ::Books::Book.create!(id: 90104, title: "Orphan Risk")

    result = run_sync([{"id" => 77, "book_id" => book.id, "author_id" => 1_203, "position" => 1}], sync_scope(book_ids: [book.id]))

    refute result[:success]
    assert_includes result[:error], "legacy id=77"
  end
```

`edition_migrator_test.rb`:

```ruby
  def run_sync(rows, scope)
    m = Services::BooksMigration::EditionMigrator.new(sync: scope)
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def edition_row(id, book_id, popularity:, title: "Ed #{id}")
    {"id" => id, "book_id" => book_id, "title" => title, "publication_year" => 2000,
     "popularity" => popularity, "book_binding" => 1, "metadata" => {}}
  end

  test "sync mode adds editions for the run's books only" do
    new_book = ::Books::Book.create!(id: 90200, title: "New Legacy Book")
    old_book = ::Books::Book.create!(id: 90201, title: "Existing Book")

    result = run_sync([
      edition_row(6002, new_book.id, popularity: 1),
      edition_row(6003, old_book.id, popularity: 9)
    ], sync_scope(book_ids: [new_book.id]))

    assert result[:success], result[:error]
    assert LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 6002)
    assert_nil LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 6003)
  end

  # A retry after a failed run meets editions that run already mapped.
  test "sync mode leaves an edition already mapped as it is here" do
    new_book = ::Books::Book.create!(id: 90204, title: "New Legacy Book")
    run_migrator([edition_row(6001, new_book.id, popularity: 5, title: "Original")])
    mapped = ::Books::Edition.find(LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 6001))
    mapped.update!(title: "Edited Here")

    result = run_sync([edition_row(6001, new_book.id, popularity: 5, title: "Legacy Title")], sync_scope(book_ids: [new_book.id]))

    assert result[:success], result[:error]
    assert_equal "Edited Here", mapped.reload.title
  end

  test "sync mode sets the default edition of the run's books only" do
    new_book = ::Books::Book.create!(id: 90202, title: "New Legacy Book")
    old_book = ::Books::Book.create!(id: 90203, title: "Existing Book")
    run_migrator([edition_row(6010, old_book.id, popularity: 1), edition_row(6011, old_book.id, popularity: 9)])
    chosen = LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 6010)
    old_book.update_columns(default_edition_id: chosen)

    run_sync([edition_row(6012, new_book.id, popularity: 4)], sync_scope(book_ids: [new_book.id]))

    assert_equal chosen, old_book.reload.default_edition_id
    assert_equal LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 6012), new_book.reload.default_edition_id
  end
```

`book_identifier_migrator_test.rb`:

```ruby
  def run_sync(rows, scope)
    m = Services::BooksMigration::BookIdentifierMigrator.new(sync: scope)
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def goodreads_ids(book_id)
    Identifier.where(identifiable_type: "Books::Book", identifiable_id: book_id, identifier_type: :books_work_goodreads_id).pluck(:value)
  end

  test "sync mode adds a new identifier row to a book already here" do
    book = ::Books::Book.create!(id: 90300, title: "Existing Book")

    result = run_sync([
      {"id" => 601, "book_id" => book.id, "identifier_type" => 5, "identifier" => "111"},
      {"id" => 602, "book_id" => book.id, "identifier_type" => 5, "identifier" => "222"}
    ], sync_scope(identifier_ids: [601]))

    assert result[:success], result[:error]
    assert_equal ["111"], goodreads_ids(book.id)
  end

  test "sync mode takes every identifier of a new book, even below the identifier watermark" do
    book = ::Books::Book.create!(id: 90301, title: "New Legacy Book")

    run_sync([{"id" => 10, "book_id" => book.id, "identifier_type" => 5, "identifier" => "333"}], sync_scope(book_ids: [book.id]))

    assert_equal ["333"], goodreads_ids(book.id)
  end

  test "sync mode puts an identifier of a merged book on the survivor" do
    survivor = ::Books::Book.create!(id: 90302, title: "Survivor")

    run_sync([{"id" => 603, "book_id" => 1_301, "identifier_type" => 5, "identifier" => "444"}],
      sync_scope(identifier_ids: [603], redirects: [["Books::Book", 1_301, survivor.id]]))

    assert_equal ["444"], goodreads_ids(survivor.id)
  end

  test "sync mode drops and counts an identifier of a deleted book" do
    result = run_sync([{"id" => 604, "book_id" => 1_302, "identifier_type" => 5, "identifier" => "555"}],
      sync_scope(identifier_ids: [604], redirects: [["Books::Book", 1_302, nil]]))

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:dropped_deleted]
    assert_empty goodreads_ids(1_302)
  end

  test "fails the run naming the legacy row when the book is neither here nor redirected" do
    result = run_sync([{"id" => 605, "book_id" => 1_303, "identifier_type" => 5, "identifier" => "666"}], sync_scope(identifier_ids: [605]))

    refute result[:success]
    assert_includes result[:error], "legacy id=605"
  end
```

`book_work_identifier_migrator_test.rb`:

```ruby
  test "sync mode reads only the run's books" do
    in_run = ::Books::Book.create!(id: 90310, title: "In The Run")
    outside = ::Books::Book.create!(id: 90311, title: "Outside")
    m = Services::BooksMigration::BookWorkIdentifierMigrator.new(sync: sync_scope(book_ids: [in_run.id]))
    m.stubs(:legacy_each).multiple_yields(
      [{"id" => in_run.id, "ol_work_id" => "/works/OL1W", "goodreads_id" => nil}],
      [{"id" => outside.id, "ol_work_id" => "/works/OL2W", "goodreads_id" => nil}]
    )

    m.call

    assert Identifier.exists?(identifiable_type: "Books::Book", identifiable_id: in_run.id)
    refute Identifier.exists?(identifiable_type: "Books::Book", identifiable_id: outside.id)
  end
```

`author_identifier_migrator_test.rb`:

```ruby
  test "sync mode reads only the run's authors" do
    in_run = ::Books::Author.create!(id: 90320, name: "In The Run")
    outside = ::Books::Author.create!(id: 90321, name: "Outside")
    m = Services::BooksMigration::AuthorIdentifierMigrator.new(sync: sync_scope(author_ids: [in_run.id]))
    m.stubs(:legacy_each).multiple_yields(
      [{"id" => in_run.id, "ol_author_id" => "/authors/OL1A"}],
      [{"id" => outside.id, "ol_author_id" => "/authors/OL2A"}]
    )

    m.call

    assert Identifier.exists?(identifiable_type: "Books::Author", identifiable_id: in_run.id)
    refute Identifier.exists?(identifiable_type: "Books::Author", identifiable_id: outside.id)
  end
```

`edition_identifier_migrator_test.rb`:

```ruby
  test "sync mode reads only editions of the run's books" do
    in_run = ::Books::Book.create!(id: 90330, title: "In The Run")
    outside = ::Books::Book.create!(id: 90331, title: "Outside")
    e1 = ::Books::Edition.create!(book: in_run, title: "E1")
    e2 = ::Books::Edition.create!(book: outside, title: "E2")
    LegacyIdMap.record(model: "Books::Edition", legacy_id: 930, new_id: e1.id)
    LegacyIdMap.record(model: "Books::Edition", legacy_id: 931, new_id: e2.id)
    m = Services::BooksMigration::EditionIdentifierMigrator.new(sync: sync_scope(book_ids: [in_run.id]))
    m.stubs(:legacy_each).multiple_yields(
      [{"id" => 930, "book_id" => in_run.id, "ol_edition_id" => "/books/OL1M"}],
      [{"id" => 931, "book_id" => outside.id, "ol_edition_id" => "/books/OL2M"}]
    )

    m.call

    assert Identifier.exists?(identifiable_type: "Books::Edition", identifiable_id: e1.id)
    refute Identifier.exists?(identifiable_type: "Books::Edition", identifiable_id: e2.id)
  end
```

(`Books::Edition` requires only `book`; `edition_type` defaults to `standard`.)

`edition_isbn_identifier_migrator_test.rb`:

```ruby
  test "sync mode reads only editions of the run's books" do
    in_run = ::Books::Book.create!(id: 90340, title: "In The Run")
    outside = ::Books::Book.create!(id: 90341, title: "Outside")
    m = Services::BooksMigration::EditionIsbnIdentifierMigrator.new(sync: sync_scope(book_ids: [in_run.id]))
    m.stubs(:legacy_each).multiple_yields(
      [{"id" => 940, "book_id" => in_run.id, "identifiers" => {"isbn_13" => ["9780000000017"]}}],
      [{"id" => 941, "book_id" => outside.id, "identifiers" => {"isbn_13" => ["9780000000024"]}}]
    )

    m.call

    assert Identifier.exists?(identifiable_type: "Books::Book", identifiable_id: in_run.id)
    refute Identifier.exists?(identifiable_type: "Books::Book", identifiable_id: outside.id)
  end
```

`test/lib/services/books/edition_identifier_backfill_test.rb`:

```ruby
      test "limits the backfill to the given books" do
        EditionIdentifierBackfill.call(book_ids: [@edition.book_id + 1])

        assert_empty @edition.identifiers

        EditionIdentifierBackfill.call(book_ids: [@edition.book_id])

        assert_not_empty @edition.identifiers
      end
```

- [ ] **Step 2: Run to verify they fail**

```bash
bin/rails test test/lib/services/books_migration/book_author_migrator_test.rb test/lib/services/books_migration/edition_migrator_test.rb test/lib/services/books_migration/book_identifier_migrator_test.rb test/lib/services/books_migration/book_work_identifier_migrator_test.rb test/lib/services/books_migration/author_identifier_migrator_test.rb test/lib/services/books_migration/edition_identifier_migrator_test.rb test/lib/services/books_migration/edition_isbn_identifier_migrator_test.rb test/lib/services/books/edition_identifier_backfill_test.rb
```

Expected: the new tests fail. Rows outside the run get written (no `sync_filter` yet), routing doesn't happen, `dropped_deleted` is nil, and `EditionIdentifierBackfill` raises `unknown keyword: :book_ids`. The "fails the run naming the legacy row" tests pass already, because the FK and validation raise today; they pin the behavior.

- [ ] **Step 3: Implement**

`book_author_migrator.rb`, replacing `upsert_row` and adding below it:

```ruby
      def upsert_row(attrs)
        author_id = attrs["author_id"]
        if sync
          # A new book may name an author that was merged or deleted here (spec §5).
          author_id = sync.redirects.resolve("Books::Author", author_id)
          if author_id == :deleted
            @dropped_deleted = @dropped_deleted.to_i + 1
            return
          end
        end

        book_author = ::Books::BookAuthor.find_or_initialize_by(book_id: attrs["book_id"], author_id: author_id)
        return if sync && book_author.persisted?

        book_author.assign_attributes(BookAuthorTransformer.call(attrs))
        book_author.save!
      end

      def sync_filter
        [:book_ids, "book_id"]
      end

      def extra_result_data
        sync ? {dropped_deleted: @dropped_deleted.to_i} : {}
      end
```

`edition_migrator.rb`: first line of `upsert_row`:

```ruby
        # Insert-only in sync mode: an edition already mapped stays as it is here.
        return if sync && LegacyIdMap.lookup(model: model_key, legacy_id: attrs["id"])
```

add:

```ruby
      def sync_filter
        [:book_ids, "book_id"]
      end
```

and replace `finalize`:

```ruby
      # In sync mode only the run's books get a default edition, so one chosen
      # during cleanup is never reset (spec §5).
      def finalize
        return if sync && sync.book_ids.empty?

        only_run = sync ? "WHERE book_id IN (#{sync.book_ids.map(&:to_i).join(", ")})" : ""
        ::Books::Book.connection.execute(<<~SQL)
          UPDATE books_books b
          SET default_edition_id = e.id
          FROM (
            SELECT DISTINCT ON (book_id) id, book_id
            FROM books_editions
            #{only_run}
            ORDER BY book_id, popularity DESC NULLS LAST, id ASC
          ) e
          WHERE e.book_id = b.id
        SQL
      end
```

Also update the end of the class comment above `finalize`: "Authoritative: recomputes on every run" stays true for the full migration only. Add: "In sync mode it is limited to the run's new books."

`book_identifier_migrator.rb`, replacing `upsert_row` and adding below it:

```ruby
      def upsert_row(attrs)
        value = attrs["identifier"]
        legacy_type = attrs["identifier_type"]
        identifier_type =
          (legacy_type == ASIN_TYPE) ? self.class.asin_identifier_type(value) : TYPE_MAP[legacy_type]
        return if identifier_type.nil?

        book_id = attrs["book_id"]
        if sync
          book_id = sync.redirects.resolve("Books::Book", book_id)
          if book_id == :deleted
            @dropped_deleted = @dropped_deleted.to_i + 1
            return
          end
        end

        upsert_identifier(
          identifiable_type: "Books::Book",
          identifiable_id: book_id,
          identifier_type: identifier_type,
          value: value
        )
      end

      # The run's new book_identifiers rows on any book, plus every row of the run's
      # new books: one created between the final :all and sync_init sits below the
      # identifier watermark (spec §5; find_or_create makes the overlap harmless).
      def in_sync_scope?(attrs)
        return true unless sync

        sync.identifier_ids.include?(attrs["id"]) || sync.book_ids.include?(attrs["book_id"])
      end

      def legacy_each(&block)
        relation = legacy_model
        if sync
          relation = legacy_model.where(id: sync.identifier_ids.to_a).or(legacy_model.where(book_id: sync.book_ids.to_a))
        end
        relation.find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      def extra_result_data
        sync ? {dropped_deleted: @dropped_deleted.to_i} : {}
      end
```

`book_work_identifier_migrator.rb`:

```ruby
      def sync_filter
        [:book_ids, "id"]
      end
```

`author_identifier_migrator.rb`:

```ruby
      def sync_filter
        [:author_ids, "id"]
      end
```

`edition_identifier_migrator.rb` and `edition_isbn_identifier_migrator.rb`, each:

```ruby
      def sync_filter
        [:book_ids, "book_id"]
      end
```

`app/lib/services/books/edition_identifier_backfill.rb`:

```ruby
      # book_ids: limit to these books' editions (the legacy sync passes its new
      # books, so identifiers removed during cleanup are never re-added).
      def self.call(batch_size: 1_000, book_ids: nil)
        new(batch_size: batch_size, book_ids: book_ids).call
      end

      def initialize(batch_size: 1_000, book_ids: nil)
        @batch_size = batch_size
        @book_ids = book_ids
      end
```

and `scope`:

```ruby
      def scope
        editions = ::Books::Edition.where("metadata -> 'amazon' IS NOT NULL")
        @book_ids ? editions.where(book_id: @book_ids) : editions
      end
```

- [ ] **Step 4: Run to verify they pass**

Same command as Step 2. Expected: all pass, old and new.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books_migration/book_author_migrator.rb app/lib/services/books_migration/edition_migrator.rb app/lib/services/books_migration/book_identifier_migrator.rb app/lib/services/books_migration/book_work_identifier_migrator.rb app/lib/services/books_migration/author_identifier_migrator.rb app/lib/services/books_migration/edition_identifier_migrator.rb app/lib/services/books_migration/edition_isbn_identifier_migrator.rb app/lib/services/books/edition_identifier_backfill.rb test/lib/services/books_migration/ test/lib/services/books/edition_identifier_backfill_test.rb
git commit -m "Sync mode for book authors, editions and identifiers, routed through redirects"
```

---

### Task 8: Sync mode for categories, countries, attributes, links, descriptions and images

**Files:**
- Modify (all in `web-app/app/lib/services/books_migration/`): `category_item_migrator.rb`, `book_type_category_migrator.rb`, `book_country_migrator.rb`, `book_attributes_migrator.rb`, `external_link_migrator.rb`, `book_description_migrator.rb`, `author_description_migrator.rb`, `author_country_migrator.rb`, `book_image_migrator.rb`
- Test: append to the matching `*_test.rb` in `web-app/test/lib/services/books_migration/`

**Interfaces:**
- Consumes: `sync`, `sync_filter`, `in_sync_scope?`, `sync_narrowed` (Task 6).
- Produces: nothing new. Each migrator accepts `sync:` and writes only rows of the run's books or authors.

- [ ] **Step 1: Write the failing tests**

Each file gets `include BooksLegacySyncHelper` under its class line. Each test below sits inside that file's class and reuses its helpers (`make_category`, `make_country`, `legacy_row`, `legacy_book`, `legacy_author`, `row`).

`category_item_migrator_test.rb`:

```ruby
  test "sync mode writes items of the run's books only" do
    category = make_category(8101)
    in_run = ::Books::Book.create!(title: "In The Run")
    outside = ::Books::Book.create!(title: "Outside")
    m = Services::BooksMigration::CategoryItemMigrator.new(sync: sync_scope(book_ids: [in_run.id]))
    m.stubs(:legacy_each).multiple_yields(
      [{"id" => 1, "category_id" => 8101, "book_id" => in_run.id}],
      [{"id" => 2, "category_id" => 8101, "book_id" => outside.id}]
    )

    m.call

    assert CategoryItem.exists?(category_id: category.id, item_id: in_run.id)
    refute CategoryItem.exists?(category_id: category.id, item_id: outside.id)
  end

  test "drops a book_category whose mapped category no longer exists here" do
    category = make_category(8102)
    ::Books::Category.where(id: category.id).delete_all
    book = ::Books::Book.create!(title: "Gone Category Book")

    result = run_migrator([{"id" => 9, "category_id" => 8102, "book_id" => book.id}])

    assert result[:success], result[:error]
    assert_empty CategoryItem.where(item_id: book.id, item_type: "Books::Book")
  end
```

`book_type_category_migrator_test.rb` (the existing `setup` maps the four type categories and builds `@book`):

```ruby
  test "sync mode links the run's books only" do
    outside = ::Books::Book.create!(title: "Outside")
    m = Services::BooksMigration::BookTypeCategoryMigrator.new(sync: sync_scope(book_ids: [@book.id]))
    m.stubs(:legacy_each).multiple_yields([{"id" => @book.id, "book_type" => 0}], [{"id" => outside.id, "book_type" => 0}])

    m.call

    assert CategoryItem.exists?(category_id: @fiction.id, item_type: "Books::Book", item_id: @book.id)
    refute CategoryItem.exists?(category_id: @fiction.id, item_type: "Books::Book", item_id: outside.id)
  end
```

`book_country_migrator_test.rb`:

```ruby
  test "sync mode links the run's books only" do
    country = make_country(9150, name: "Uruguayan")
    in_run = ::Books::Book.create!(title: "In The Run")
    outside = ::Books::Book.create!(title: "Outside")
    m = Services::BooksMigration::BookCountryMigrator.new(sync: sync_scope(book_ids: [in_run.id]))
    m.stubs(:legacy_each).multiple_yields(
      [{"id" => 1, "book_id" => in_run.id, "country_id" => country.id}],
      [{"id" => 2, "book_id" => outside.id, "country_id" => country.id}]
    )

    m.call

    assert ::Books::BookCountry.exists?(book_id: in_run.id, country_id: country.id)
    refute ::Books::BookCountry.exists?(book_id: outside.id)
  end
```

`book_attributes_migrator_test.rb` (the existing `setup` blanks `@book`'s three columns):

```ruby
  test "sync mode updates the run's books only" do
    m = Services::BooksMigration::BookAttributesMigrator.new(sync: sync_scope(book_ids: []))
    m.stubs(:legacy_each).multiple_yields([legacy_row])

    m.call

    assert_nil @book.reload.word_count

    m = Services::BooksMigration::BookAttributesMigrator.new(sync: sync_scope(book_ids: [@book.id]))
    m.stubs(:legacy_each).multiple_yields([legacy_row])

    m.call

    assert_equal 90_000, @book.reload.word_count
  end
```

`external_link_migrator_test.rb` (module-style test; `ExternalLinkMigrator` resolves inside it):

```ruby
      test "sync mode adds links of the run's books only" do
        outside = ::Books::Book.create!(title: "Outside")
        migrator = ExternalLinkMigrator.new(sync: sync_scope(book_ids: [@book.id]))
        migrator.stubs(:legacy_each).multiple_yields([legacy_row], [legacy_row("id" => 2, "book_id" => outside.id)])

        migrator.call

        assert ExternalLink.exists?(parent_type: "Books::Book", parent_id: @book.id)
        refute ExternalLink.exists?(parent_type: "Books::Book", parent_id: outside.id)
      end
```

`book_description_migrator_test.rb`:

```ruby
  test "sync mode describes the run's books only" do
    m = Services::BooksMigration::BookDescriptionMigrator.new(sync: sync_scope(book_ids: [@book.id]))
    m.stubs(:legacy_each).multiple_yields(
      [legacy_book(@book.id, "ai_generated_description" => "In the run.")],
      [legacy_book(@other_book.id, "ai_generated_description" => "Outside the run.")]
    )

    m.call

    assert_equal ["In the run."], descriptions_for(@book).pluck(:content)
    refute Description.exists?(describable: @other_book, content: "Outside the run.")
  end
```

`author_description_migrator_test.rb`:

```ruby
  test "sync mode describes the run's authors only" do
    m = Services::BooksMigration::AuthorDescriptionMigrator.new(sync: sync_scope(author_ids: [@author.id]))
    m.stubs(:legacy_each).multiple_yields(
      [legacy_author(@author.id, "ai_description" => "In the run.")],
      [legacy_author(@other_author.id, "ai_description" => "Outside the run.")]
    )

    m.call

    assert Description.exists?(describable: @author, content: "In the run.")
    refute Description.exists?(describable: @other_author, content: "Outside the run.")
  end
```

`author_country_migrator_test.rb`:

```ruby
  test "sync mode maps the run's authors only" do
    country("Russian")
    in_run = ::Books::Author.create!(name: "In The Run")
    outside = ::Books::Author.create!(name: "Outside")
    m = Services::BooksMigration::AuthorCountryMigrator.new(sync: sync_scope(author_ids: [in_run.id]))
    m.stubs(:legacy_each).multiple_yields(
      [{"id" => in_run.id, "nationality_text" => "Russian"}],
      [{"id" => outside.id, "nationality_text" => "Russian"}]
    )

    m.call

    assert ::Books::AuthorCountry.exists?(author_id: in_run.id)
    refute ::Books::AuthorCountry.exists?(author_id: outside.id)
  end
```

`book_image_migrator_test.rb` (module-style):

```ruby
      test "sync mode enqueues covers of the run's books only" do
        ::Books::MigrateCoverImageJob.expects(:perform_async).with(1, "blobkey", "cover.jpg", "image/jpeg").once
        migrator = BookImageMigrator.new(sync: sync_scope(book_ids: [1]))
        migrator.stubs(:legacy_each).multiple_yields([row("book_id" => 1)], [row("book_id" => 2)])

        migrator.call
      end
```

- [ ] **Step 2: Run to verify they fail**

```bash
bin/rails test test/lib/services/books_migration/category_item_migrator_test.rb test/lib/services/books_migration/book_type_category_migrator_test.rb test/lib/services/books_migration/book_country_migrator_test.rb test/lib/services/books_migration/book_attributes_migrator_test.rb test/lib/services/books_migration/external_link_migrator_test.rb test/lib/services/books_migration/book_description_migrator_test.rb test/lib/services/books_migration/author_description_migrator_test.rb test/lib/services/books_migration/author_country_migrator_test.rb test/lib/services/books_migration/book_image_migrator_test.rb
```

Expected: each new "sync mode" test fails because rows outside the run are written. "drops a book_category whose mapped category no longer exists here" fails with `no LegacyIdMap for Books::Category legacy_id=8102`. `BookAttributesMigrator` fails on its own `call` loop (no scope check).

- [ ] **Step 3: Implement**

`category_item_migrator.rb`: replace `preload_context`:

```ruby
      def preload_context
        @active_category_map = LegacyIdMap
          .where(model: "Books::Category")
          .joins("INNER JOIN categories ON categories.id = legacy_id_maps.new_id")
          .where(categories: {deleted: false})
          .pluck(:legacy_id, :new_id)
          .to_h
        # Every mapped legacy id, including categories soft-deleted, or deleted or
        # merged here since they were mapped: dropping their items is deliberate.
        # Only an id with no map entry at all is a missing prerequisite.
        @known_category_ids = LegacyIdMap.where(model: "Books::Category").pluck(:legacy_id).to_set
      end

      def sync_filter
        [:book_ids, "book_id"]
      end
```

In the class comment, change "the full set of migrated legacy ids (active + soft-deleted) is remembered" to "every mapped legacy id is remembered (active, soft-deleted, or since deleted here)".

`book_type_category_migrator.rb`:

```ruby
      def legacy_each(&block)
        sync_narrowed(legacy_model.select(:id, :book_type))
          .find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      def sync_filter
        [:book_ids, "id"]
      end
```

`book_country_migrator.rb`:

```ruby
      def sync_filter
        [:book_ids, "book_id"]
      end
```

`book_attributes_migrator.rb`, in `call`:

```ruby
          legacy_each do |attrs|
            next unless in_sync_scope?(attrs)

            buffer << row_for(attrs)
```

and:

```ruby
      def legacy_each(&block)
        sync_narrowed(legacy_model.select(:id, :book_length, :page_range, :word_count))
          .find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      def sync_filter
        [:book_ids, "id"]
      end
```

`external_link_migrator.rb`:

```ruby
      def sync_filter
        [:book_ids, "book_id"]
      end
```

`book_description_migrator.rb`:

```ruby
      def legacy_each(&block)
        sync_narrowed(legacy_model.select(*LEGACY_COLUMNS)).find_each(batch_size: BATCH_SIZE) do |record|
          block.call(record.attributes)
        end
      end

      def sync_filter
        [:book_ids, "id"]
      end
```

`author_description_migrator.rb`:

```ruby
      def legacy_each(&block)
        sync_narrowed(legacy_model.select(*LEGACY_COLUMNS)).find_each(batch_size: BATCH_SIZE) do |record|
          block.call(record.attributes)
        end
      end

      def sync_filter
        [:author_ids, "id"]
      end
```

`author_country_migrator.rb`:

```ruby
      def legacy_each(&block)
        sync_narrowed(legacy_model.where.not(nationality_text: [nil, ""]).select(:id, :nationality_text))
          .find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      def sync_filter
        [:author_ids, "id"]
      end
```

`book_image_migrator.rb`: the legacy column is `record_id`, but the yielded key is `"book_id"`, so it narrows by hand:

```ruby
      def legacy_each
        attachments = LegacyBooks::ActiveStorageAttachment.where(record_type: "Book", name: "primary_image")
        attachments = attachments.where(record_id: sync.book_ids.to_a) if sync
        attachments.includes(:blob).find_each(batch_size: BATCH_SIZE) do |attachment|
          yield({
            "book_id" => attachment.record_id,
            "key" => attachment.blob.key,
            "filename" => attachment.blob.filename,
            "content_type" => attachment.blob.content_type
          })
        end
      end

      def sync_filter
        [:book_ids, "book_id"]
      end
```

- [ ] **Step 4: Run to verify they pass**

Same command as Step 2. Expected: all pass, old and new.

- [ ] **Step 5: Run the whole migration test directory**

```bash
bin/rails test test/lib/services/books_migration/ test/lib/services/books/
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add app/lib/services/books_migration/ test/lib/services/books_migration/
git commit -m "Sync mode for category, country, attribute, link, description and image migrators"
```

---

### Task 9: `Sync`, `SyncReport`, the rake tasks, and the docs

**Files:**
- Create: `web-app/app/lib/services/books_migration/sync.rb`
- Create: `web-app/app/lib/services/books_migration/sync_report.rb`
- Modify: `web-app/lib/tasks/data_migration.rake` (add `sync`, `sync_report`)
- Create: `docs/features/books-legacy-sync.md`
- Modify: `docs/features/record-merge.md` (a short "Redirects (books)" section)
- Test: `web-app/test/lib/services/books_migration/sync_test.rb`, `web-app/test/lib/services/books_migration/sync_report_test.rb` (create); `web-app/test/lib/tasks/data_migration_test.rb` (append)

**Interfaces:**
- Consumes: `SyncPlan.build(final:, legacy:)` → `#initialized?`, `#scope`, `#next_watermarks`, `#report` (Task 5); every migrator's `call(sync:)` (Tasks 6–8); `EditionIdentifierBackfill.call(book_ids:)` (Task 7); `Services::BooksDescriptionSafetyNet.call` (existing, returns `Result` with `success?`/`errors`); `NewsPostMigrator.call` (existing, returns `Result`); `UserMigrator.call` (existing, returns Hash).
- Produces: `Services::BooksMigration::Sync.call(final: false, legacy: LegacySource.new)` → `Sync::Result(success?, data: {plan: SyncPlan|nil, steps: [[label, outcome]], indexed: {"Books::Book" => Integer, "Books::Author" => Integer}}, errors: [String])`.
- Produces: `Services::BooksMigration::SyncReport.render(plan)` → String.
- Produces: rake `data_migration:sync`, `data_migration:sync_report`.

- [ ] **Step 1: Write the failing `Sync` tests**

`test/lib/services/books_migration/sync_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::SyncTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  SYNC_MIGRATORS = %w[
    LanguageMigrator AuthorMigrator BookMigrator BookAuthorMigrator EditionMigrator BookIdentifierMigrator
    BookWorkIdentifierMigrator AuthorIdentifierMigrator EditionIdentifierMigrator EditionIsbnIdentifierMigrator
    CategoryMigrator CategoryItemMigrator BookAttributesMigrator BookTypeCategoryMigrator CountryMigrator
    AuthorCountryMigrator BookCountryMigrator ExternalLinkMigrator BookDescriptionMigrator
    AuthorDescriptionMigrator BookImageMigrator
  ].freeze

  OLD = 3.days.ago
  RECENT = 1.hour.ago

  setup do
    init_watermarks(books: 1_000, authors: 500, book_identifiers: 5_000)
    @existing = ::Books::Book.create!(id: 900, title: "Cleaned Here")
    map_book_type_categories
    Services::BooksMigration::UserMigrator.stubs(:call).returns(success: true, data: {model: "User", count: 0})
    Services::BooksMigration::NewsPostMigrator.stubs(:call).returns(
      Services::BooksMigration::NewsPostMigrator::Result.new(success?: true, data: {}, errors: [])
    )
    stub_legacy(
      "AuthorMigrator" => [{"id" => 501, "name" => "New Legacy Author", "family_name" => "Author", "alternative_names" => nil}],
      "BookMigrator" => [
        {"id" => 900, "title" => "Legacy Title", "original_language_id" => nil},
        {"id" => 1_001, "title" => "New Legacy Book", "original_language_id" => nil},
        {"id" => 1_002, "title" => "Too Fresh", "original_language_id" => nil}
      ],
      "BookAuthorMigrator" => [{"id" => 1, "book_id" => 1_001, "author_id" => 501, "position" => 1}],
      "EditionMigrator" => [
        {"id" => 7_001, "book_id" => 1_001, "title" => "HC", "publication_year" => 2026, "popularity" => 1, "book_binding" => 1, "metadata" => {}},
        {"id" => 7_002, "book_id" => 900, "title" => "Late Edition", "publication_year" => 2026, "popularity" => 1, "book_binding" => 1, "metadata" => {}}
      ],
      "BookIdentifierMigrator" => [{"id" => 5_001, "book_id" => 900, "identifier_type" => 5, "identifier" => "424242"}]
    )
  end

  def legacy
    FakeLegacySource.new(
      book_rows: [[1_001, OLD], [1_002, RECENT]],
      author_rows: [[501, OLD]],
      book_identifier_rows: [[5_001, OLD]],
      book_ids: [900, 1_001, 1_002],
      author_ids: [501]
    )
  end

  def stub_legacy(rows)
    SYNC_MIGRATORS.each do |name|
      stub = Services::BooksMigration.const_get(name).any_instance.stubs(:legacy_each)
      stub.multiple_yields(*rows[name].zip) if rows[name]
    end
  end

  def map_book_type_categories
    Services::BooksMigration::BookTypeCategoryMigrator::LEGACY_CATEGORY_IDS.each_value do |legacy_id|
      category = ::Books::Category.create!(name: "Type #{legacy_id}", category_type: :genre)
      LegacyIdMap.record(model: "Books::Category", legacy_id: legacy_id, new_id: category.id)
    end
  end

  def watermarks = LegacySyncWatermark.pluck(:key, :value).to_h

  test "brings over a new legacy book with its author and edition, and nothing for a book already here but its new identifier" do
    result = Services::BooksMigration::Sync.call(legacy: legacy)

    assert result.success?, result.errors.inspect
    assert_equal "New Legacy Book", ::Books::Book.find(1_001).title
    assert ::Books::BookAuthor.exists?(book_id: 1_001, author_id: 501)
    assert_equal 1_001, ::Books::Edition.find(LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 7_001)).book_id
    assert_equal "Cleaned Here", @existing.reload.title
    assert_nil LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 7_002)
    assert Identifier.exists?(identifiable_type: "Books::Book", identifiable_id: 900, value: "424242")
    refute ::Books::Book.exists?(1_002)
  end

  test "advances the watermarks to the last rows it processed" do
    Services::BooksMigration::Sync.call(legacy: legacy)

    assert_equal({"books" => 1_001, "authors" => 501, "book_identifiers" => 5_001}, watermarks)
  end

  test "FINAL takes the book still inside the delay" do
    Services::BooksMigration::Sync.call(final: true, legacy: legacy)

    assert ::Books::Book.exists?(1_002)
    assert_equal 1_002, watermarks["books"]
  end

  test "queues search indexing for the books and authors it inserted only" do
    result = Services::BooksMigration::Sync.call(legacy: legacy)

    assert SearchIndexRequest.exists?(parent_type: "Books::Book", parent_id: 1_001, action: :index_item)
    assert SearchIndexRequest.exists?(parent_type: "Books::Author", parent_id: 501, action: :index_item)
    refute SearchIndexRequest.exists?(parent_type: "Books::Book", parent_id: 900)
    assert_equal({"Books::Book" => 1, "Books::Author" => 1}, result.data[:indexed])
  end

  test "a merged or deleted book is not brought back" do
    RecordRedirect.create!(item_type: "Books::Book", from_id: 1_001, to_id: 900)

    result = Services::BooksMigration::Sync.call(legacy: legacy)

    assert result.success?, result.errors.inspect
    refute ::Books::Book.exists?(1_001)
    assert_equal 1_001, watermarks["books"]
  end

  test "a failed step leaves the watermarks and queues no indexing" do
    Services::BooksMigration::EditionMigrator.stubs(:call).returns(success: false, error: "boom", data: {})

    result = Services::BooksMigration::Sync.call(legacy: legacy)

    refute result.success?
    assert_match(/editions failed: boom/, result.errors.first)
    assert_equal({"books" => 1_000, "authors" => 500, "book_identifiers" => 5_000}, watermarks)
    refute SearchIndexRequest.exists?(parent_type: "Books::Book", parent_id: 1_001)
  end

  test "a step that raises fails the run without moving the watermarks" do
    Services::BooksMigration::NewsPostMigrator.stubs(:call).raises(RuntimeError, "legacy gone")

    result = Services::BooksMigration::Sync.call(legacy: legacy)

    refute result.success?
    assert_match(/news_posts raised: legacy gone/, result.errors.first)
    assert_equal 1_000, watermarks["books"]
  end

  test "a retry after a failed run finishes the books that run inserted" do
    Services::BooksMigration::EditionMigrator.stubs(:call).returns(success: false, error: "boom", data: {})
    Services::BooksMigration::Sync.call(legacy: legacy)
    assert ::Books::Book.exists?(1_001)
    Services::BooksMigration::EditionMigrator.unstub(:call)

    result = Services::BooksMigration::Sync.call(legacy: legacy)

    assert result.success?, result.errors.inspect
    assert LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 7_001)
    assert_equal 1, ::Books::BookAuthor.where(book_id: 1_001).count
    assert SearchIndexRequest.exists?(parent_type: "Books::Book", parent_id: 1_001, action: :index_item)
    assert_equal 1_001, watermarks["books"]
  end

  test "refuses to run before sync_init" do
    LegacySyncWatermark.delete_all
    Services::BooksMigration::BookMigrator.expects(:call).never

    result = Services::BooksMigration::Sync.call(legacy: legacy)

    refute result.success?
    assert_match(/sync_init/, result.errors.first)
  end

  test "the report's would-insert numbers equal what the sync inserts" do
    plan = Services::BooksMigration::SyncPlan.build(legacy: legacy)

    assert_difference -> { ::Books::Book.count } => plan.report[:books][:would_insert],
      -> { ::Books::Author.count } => plan.report[:authors][:would_insert] do
      Services::BooksMigration::Sync.call(legacy: legacy)
    end
    assert_equal 1, plan.report[:books][:would_insert]
  end
end
```

`test/lib/services/books_migration/sync_report_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::SyncReportTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  def render(**legacy)
    plan = Services::BooksMigration::SyncPlan.build(now: Time.current, legacy: FakeLegacySource.new(**legacy))
    Services::BooksMigration::SyncReport.render(plan)
  end

  test "shows the catalog numbers, redirects and legacy edits" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)
    RecordRedirect.create!(item_type: "Books::Book", from_id: 5, to_id: 9)

    out = render(book_rows: [[101, 3.days.ago], [102, 1.hour.ago]], book_identifier_rows: [[501, 3.days.ago]], books_updated_count: 87)

    assert_match(/books \(above watermark\)\s+2\s+0\s+1\s+1/, out)
    assert_includes out, "book_identifiers (new)"
    assert_includes out, "redirects recorded: books merged 1, deleted 0; authors merged 0, deleted 0"
    assert_includes out, "legacy edits to existing books, not synced: 87"
  end

  test "before sync_init it says so" do
    out = render

    assert_includes out, "Before sync_init"
    assert_includes out, "n/a before sync_init"
  end

  test "lists at most twenty legacy-deleted ids" do
    init_watermarks(books: 100, authors: 50, book_identifiers: 500)
    22.times { |i| ::Books::Book.create!(id: 10 + i, title: "Gone #{i}") }

    out = render(book_ids: [])

    assert_includes out, "books 22 (ids: 10, 11"
    assert_includes out, "and 2 more"
  end
end
```

Append to `test/lib/tasks/data_migration_test.rb` (add `data_migration:sync` and `data_migration:sync_report` to the setup reenable list):

```ruby
  def sync_result(success: true, errors: [])
    Services::BooksMigration::Sync::Result.new(success?: success, data: {plan: nil, steps: [], indexed: {}}, errors: errors)
  end

  def with_env(name, value)
    previous = ENV[name]
    ENV[name] = value
    yield
  ensure
    ENV[name] = previous
  end

  test "sync passes FINAL through as a boolean" do
    {"1" => true, "true" => true, "yes" => true, "0" => false, nil => false}.each do |value, final|
      Rake::Task["data_migration:sync"].reenable
      Services::BooksMigration::Sync.expects(:call).with(final: final).returns(sync_result)

      with_env("FINAL", value) { capture_io { Rake::Task["data_migration:sync"].invoke } }
    end
  end

  test "sync aborts when the run fails" do
    Services::BooksMigration::Sync.stubs(:call).returns(sync_result(success: false, errors: ["editions failed: boom"]))

    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:sync"].invoke }
    end
    assert_match(/data_migration:sync failed: editions failed: boom/, err)
  end

  test "sync_report prints the plan and runs nothing" do
    Services::BooksMigration::Sync.expects(:call).never
    plan = mock("plan")
    Services::BooksMigration::SyncPlan.expects(:build).with(final: false).returns(plan)
    Services::BooksMigration::SyncReport.expects(:render).with(plan).returns("REPORT")

    out, _err = capture_io { Rake::Task["data_migration:sync_report"].invoke }

    assert_includes out, "REPORT"
  end
```

- [ ] **Step 2: Run to verify they fail**

```bash
bin/rails test test/lib/services/books_migration/sync_test.rb test/lib/services/books_migration/sync_report_test.rb test/lib/tasks/data_migration_test.rb
```

Expected: `uninitialized constant Services::BooksMigration::Sync` / `SyncReport`, and `Don't know how to build task 'data_migration:sync'`.

- [ ] **Step 3: Implement `Sync`**

`app/lib/services/books_migration/sync.rb`:

```ruby
module Services
  module BooksMigration
    # data_migration:sync (spec §5): brings over only what is new on legacy, in
    # :all's dependency order, then queues search indexing for what it inserted and
    # advances the watermarks. Any failed step stops the run with the watermarks
    # unchanged; every step is insert-only here, so the next run retries safely.
    # The user-data steps join after news_posts in increment 3 (spec §6).
    class Sync
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(final: false, legacy: LegacySource.new)
        new(final: final, legacy: legacy).call
      end

      def initialize(final:, legacy:)
        @final = final
        @legacy = legacy
      end

      def call
        plan = SyncPlan.build(final: @final, legacy: @legacy)
        return failure(plan, [], "run data_migration:sync_init first (no sync watermarks)") unless plan.initialized?

        outcomes = []
        steps(plan.scope).each do |label, step|
          outcome = begin
            step.call
          rescue => e
            outcomes << [label, e.message]
            return failure(plan, outcomes, "#{label} raised: #{e.message}")
          end
          outcomes << [label, outcome]
          return failure(plan, outcomes, "#{label} failed: #{error_of(outcome)}") unless succeeded?(outcome)
        end

        indexed = queue_search_indexing(plan.scope)
        advance_watermarks(plan.next_watermarks)
        Result.new(success?: true, data: {plan: plan, steps: outcomes, indexed: indexed}, errors: [])
      end

      private

      def steps(scope)
        [
          ["languages", -> { LanguageMigrator.call(sync: scope) }],
          ["users", -> { UserMigrator.call }],
          ["authors", -> { AuthorMigrator.call(sync: scope) }],
          ["books", -> { BookMigrator.call(sync: scope) }],
          ["book_authors", -> { BookAuthorMigrator.call(sync: scope) }],
          ["editions", -> { EditionMigrator.call(sync: scope) }],
          ["book_identifiers", -> { BookIdentifierMigrator.call(sync: scope) }],
          ["book_work_identifiers", -> { BookWorkIdentifierMigrator.call(sync: scope) }],
          ["author_identifiers", -> { AuthorIdentifierMigrator.call(sync: scope) }],
          ["edition_identifiers", -> { EditionIdentifierMigrator.call(sync: scope) }],
          ["edition_isbn_identifiers", -> { EditionIsbnIdentifierMigrator.call(sync: scope) }],
          ["edition_amazon_identifiers", -> { ::Services::Books::EditionIdentifierBackfill.call(book_ids: scope.book_ids.to_a) }],
          ["categories", -> { CategoryMigrator.call(sync: scope) }],
          ["category_items", -> { CategoryItemMigrator.call(sync: scope) }],
          ["book_attributes", -> { BookAttributesMigrator.call(sync: scope) }],
          ["book_type_categories", -> { BookTypeCategoryMigrator.call(sync: scope) }],
          ["countries", -> { CountryMigrator.call(sync: scope) }],
          ["author_countries", -> { AuthorCountryMigrator.call(sync: scope) }],
          ["book_countries", -> { BookCountryMigrator.call(sync: scope) }],
          ["external_links", -> { ExternalLinkMigrator.call(sync: scope) }],
          ["book_descriptions", -> { BookDescriptionMigrator.call(sync: scope) }],
          ["author_descriptions", -> { AuthorDescriptionMigrator.call(sync: scope) }],
          ["description_safety_net", -> { ::Services::BooksDescriptionSafetyNet.call }],
          ["news_posts", -> { NewsPostMigrator.call }],
          ["book_images", -> { BookImageMigrator.call(sync: scope) }]
        ]
      end

      # The migrators return a Hash, the older services a Result, and the edition
      # backfill a count.
      def succeeded?(outcome)
        case outcome
        when Hash then outcome[:success]
        when Integer then true
        else outcome.success?
        end
      end

      def error_of(outcome)
        outcome.is_a?(Hash) ? outcome[:error] : Array(outcome.errors).join("; ")
      end

      # The migrators load with indexing suppressed (spec §5), so the run indexes
      # what it inserted. Ids are read back from the table, which also covers books
      # a failed earlier run inserted.
      def queue_search_indexing(scope)
        inserted = {
          "Books::Book" => ::Books::Book.where(id: scope.book_ids.to_a).pluck(:id),
          "Books::Author" => ::Books::Author.where(id: scope.author_ids.to_a).pluck(:id)
        }
        rows = inserted.flat_map do |type, ids|
          ids.map { |id| {parent_type: type, parent_id: id, action: SearchIndexRequest.actions[:index_item]} }
        end
        SearchIndexRequest.insert_all(rows) if rows.any?
        inserted.transform_values(&:size)
      end

      def advance_watermarks(values)
        LegacySyncWatermark.transaction do
          values.each { |key, value| LegacySyncWatermark.find_by!(key: key).update!(value: value) }
        end
      end

      def failure(plan, outcomes, message)
        Result.new(success?: false, data: {plan: plan, steps: outcomes, indexed: {}}, errors: [message])
      end
    end
  end
end
```

- [ ] **Step 4: Implement `SyncReport`**

`app/lib/services/books_migration/sync_report.rb`:

```ruby
module Services
  module BooksMigration
    # Prints a SyncPlan's report (spec §7): what data_migration:sync would do now.
    class SyncReport
      SHOWN_IDS = 20

      def self.render(plan)
        new(plan.report).render
      end

      def initialize(report)
        @report = report
      end

      def render
        [
          header,
          format("%-32s %10s %10s %14s %16s", "Catalog", "legacy", "here", "would insert", "waiting (<24h)"),
          record_line("books (above watermark)", @report[:books]),
          record_line("authors", @report[:authors]),
          format("  %-30s %10s %10s %14s %16s", "book_identifiers (new)", "", "", number(@report[:book_identifiers][:would_insert]), number(@report[:book_identifiers][:waiting])),
          "  categories (unmapped): #{number(@report[:categories_unmapped])}",
          "  skipped (redirected): books #{@report[:books][:skipped_redirected]}, authors #{@report[:authors][:skipped_redirected]}",
          "  legacy deleted, still here: books #{ids(@report[:books][:legacy_deleted_still_here])}; " \
            "authors #{ids(@report[:authors][:legacy_deleted_still_here])}",
          "  redirects recorded: #{redirects}",
          "  legacy edits to existing books, not synced: #{number(@report[:legacy_edits_not_synced])}"
        ].join("\n")
      end

      private

      def header
        return "Before sync_init: the highest legacy-origin ids here stand in for the watermarks." unless @report[:initialized]

        "Watermarks: " + @report[:watermarks].map { |key, value| "#{key} #{number(value)}" }.join(", ")
      end

      def record_line(label, counts)
        format("  %-30s %10s %10s %14s %16s", label, number(counts[:legacy]), number(counts[:here]),
          number(counts[:would_insert]), number(counts[:waiting]))
      end

      def ids(list)
        return "0" if list.empty?

        shown = list.first(SHOWN_IDS).join(", ")
        more = (list.size > SHOWN_IDS) ? ", and #{list.size - SHOWN_IDS} more" : ""
        "#{list.size} (ids: #{shown}#{more})"
      end

      def redirects
        @report[:redirects].map do |item_type, counts|
          "#{(item_type == "Books::Book") ? "books" : "authors"} merged #{counts[:merged]}, deleted #{counts[:deleted]}"
        end.join("; ")
      end

      def number(value)
        value.nil? ? "n/a before sync_init" : ActiveSupport::NumberHelper.number_to_delimited(value)
      end
    end
  end
end
```

- [ ] **Step 5: Add the rake tasks**

In `lib/tasks/data_migration.rake`, after `sync_init`:

```ruby
  desc "Bring over what is new on legacy since the last run: catalog + users (FINAL=1 drops the 24h delay)"
  task sync: :environment do
    result = Services::BooksMigration::Sync.call(final: ActiveModel::Type::Boolean.new.cast(ENV["FINAL"]) || false)
    puts Services::BooksMigration::SyncReport.render(result.data[:plan]) if result.data[:plan]
    result.data[:steps].each { |label, outcome| pp(label => outcome) }
    abort "data_migration:sync failed: #{result.errors.join("; ")}" unless result.success?
    pp(indexed: result.data[:indexed])
  end

  desc "Print what data_migration:sync would do now (read-only; safe in production at any time)"
  task sync_report: :environment do
    plan = Services::BooksMigration::SyncPlan.build(final: ActiveModel::Type::Boolean.new.cast(ENV["FINAL"]) || false)
    puts Services::BooksMigration::SyncReport.render(plan)
  end
```

- [ ] **Step 6: Run to verify they pass**

```bash
bin/rails test test/lib/services/books_migration/sync_test.rb test/lib/services/books_migration/sync_report_test.rb test/lib/tasks/data_migration_test.rb
```

Expected: all pass. The report's books line reads legacy 2, here 0, would insert 1, waiting 1.

- [ ] **Step 7: Write the docs**

`docs/features/books-legacy-sync.md`:

```markdown
# Books legacy sync

From the switch-over on, the books catalog in this database is the master. Legacy
(thegreatestbooks.org) keeps running until launch, and `data_migration:sync` brings
over only what is new there. Design: `docs/superpowers/specs/2026-10-08-books-legacy-sync-design.md`.

## Tasks

| Task | What it does |
|---|---|
| `data_migration:sync_report` | Read-only. Prints what a sync would do now. Safe in production at any time, before or after `sync_init`. |
| `data_migration:sync_init` | Once, right after the final `data_migration:all`. Records the watermarks. Refuses if they exist. |
| `data_migration:sync` | Weekly. New legacy books, authors and their rows, new `book_identifiers` on any book, new categories/languages/countries/news posts, and users. `FINAL=1` drops the 24h delay (the cutover run). |

After `sync_init`, `data_migration:all` and every catalog task abort with "use data_migration:sync".

## How it decides what is new

- `legacy_sync_watermarks` holds the last legacy id processed for `books`, `authors`, `book_identifiers`.
- A legacy row above its watermark is copied once it is more than 24 hours old, because legacy enriches new books with background jobs first. A row inside the delay holds back every id after it.
- A successful run advances each watermark to the last id it processed. A failed run moves nothing, and the next run retries; every step is insert-only.
- Rows of a new book or author come with it: editions, identifiers, categories, countries, attributes, links, descriptions, cover image. Existing books get nothing from legacy except new `book_identifiers` rows.

## Redirects

`record_redirects` records what became of a legacy-origin book or author (id below
its ceiling) that no longer exists: merged into `to_id`, or deleted (`to_id` NULL).
The mergers write it before destroying the source; an `after_destroy` on
`Books::Book`/`Books::Author` records every other delete. A merge or delete also
repoints rows that named the departing record, so chains through new-app books
resolve. The sync never re-inserts a redirected id, and routes a new book's author
or a new identifier's book through `Services::BooksMigration::Redirects`.

A book removed without callbacks (`delete_all`, raw SQL) leaves no redirect. A later
sync that meets its id fails and names the legacy row.

## Not synced

Legacy edits to existing catalog records; books legacy deleted (reported as "legacy
deleted, still here"); lists, rankings and penalties. User lists, list items,
reviews, saved searches and corrections are increment 3.
```

In `docs/features/record-merge.md`, add a short section after the books merger section:

```markdown
### Redirects (books)

`Books::Book::Merger` and `Books::Author::Merger` record `source → survivor` in
`record_redirects` inside the merge transaction, before the destroy, so the books
legacy sync never brings a merged-away legacy book or author back. See
`docs/features/books-legacy-sync.md`.
```

- [ ] **Step 8: Full suite and lint**

```bash
bin/rails test > /tmp/inc2-suite.txt 2>&1; tail -30 /tmp/inc2-suite.txt
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
```

Expected: 0 failures, 0 errors. No warnings beyond the two known upstream sources (AGENTS.md). standardrb clean. zeitwerk "All is good!" (new files in `app/lib/services/books_migration/` and `sync_scope.rb` defining a Struct constant).

- [ ] **Step 9: Commit**

```bash
git add app/lib/services/books_migration/sync.rb app/lib/services/books_migration/sync_report.rb lib/tasks/data_migration.rake test/lib/services/books_migration/sync_test.rb test/lib/services/books_migration/sync_report_test.rb test/lib/tasks/data_migration_test.rb ../docs/features/books-legacy-sync.md ../docs/features/record-merge.md
git commit -m "Add data_migration:sync and data_migration:sync_report (catalog)"
```
