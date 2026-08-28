# Category Reindex Callbacks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an edit to a `Category` requeue every item carrying it for search reindexing, so a `category_type` change or a `soft_delete!` stops leaving stale indexed documents behind.

**Architecture:** An `after_update_commit` callback on `Category` guards on an overridable `search_relevant_change?` predicate — `deleted` for every domain, plus `category_type` and Fiction/Nonfiction name membership for `Books::Category` — and calls `Categories::ItemReindexer`, which batch-inserts `SearchIndexRequest` rows. `Search::IndexerJob` drains them unchanged. No background job: inserting all 68,333 rows for the largest category in the app measures 3.2s, and it runs after commit.

**Tech Stack:** Rails 8.1.3.1, Minitest + fixtures + Mocha, Sidekiq (`Sidekiq.testing!(:inline)` set globally), OpenSearch via `Search::*` classes, PostgreSQL.

**Spec:** `docs/superpowers/specs/2026-08-28-category-reindex-callbacks-design.md`

## Global Constraints

- **Working directory is `web-app/`.** Run every `bin/rails` and `bundle exec` command from there. Docs live at the project root in `docs/`, not `web-app/docs/`.
- **Worktree:** `/home/shane/dev/the-greatest/.claude/worktrees/category-reindex-callbacks`, branch `worktree-category-reindex-callbacks`. Do not `cd` to the main checkout.
- **Gate:** `bin/rails test` and `bundle exec standardrb`. **Do not run brakeman.** No system tests, no E2E — this change adds no user-facing page or flow.
- **Linter is `standardrb`, never `bin/rubocop`** (the omakase config conflicts).
- **The development database is not disposable.** Books data exists only in dev and takes hours to rebuild. Never run `db:drop`, `db:reset`, `db:schema:load`, `create_fixtures`, or bulk `delete_all`/`destroy_all`/`update_all` in `rails runner`. A `PreToolUse` hook blocks these. Tests run against the per-worktree test database and are safe.
- **Skinny models, fat services.** Business logic goes in service objects using `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`. `keyword_init` is deliberate; a Standard cop is disabled for it.
- **Root-anchor nested constants** (`::Books::Book`, `::Search::IndexerJob`) inside `module Categories` / `module Services`. This repo has been bitten by STI/namespace constant shadowing 3+ times; it presents as a confusing `NameError`.
- **Rails 8 enum syntax** is `enum :status, {active: 0}` with a colon prefix.
- **Fixture names are semantic**, never `one`/`two`. The ones this plan uses are listed per task; do not invent others without checking `test/fixtures/categories.yml` and `test/fixtures/category_items.yml` first.
- **Never inspect a fixture with `ActiveRecord::FixtureSet.create_fixtures` — it TRUNCATES every table it names.** Read the YAML instead: `sed -n '/^name:/,/^$/p' test/fixtures/<file>.yml`.
- **Trust no new test until you have watched it fail.** For every test added here, delete or invert the line under test, confirm red, restore, confirm green. This repo has had 7 tests pass against code with the feature deleted.
- **Commit after every task.** Do not push and do not open a PR — merging to `main` deploys to production. Ask before either.

---

### Task 1: `Categories::ItemReindexer`

The service that does the actual queueing, plus the single source of truth for which model types are indexed. Nothing calls it yet — Task 2 wires up the callback.

**Files:**
- Create: `web-app/app/lib/categories/item_reindexer.rb`
- Modify: `web-app/app/sidekiq/search/indexer_job.rb` (extract the model-type list to a constant)
- Test: `web-app/test/lib/categories/item_reindexer_test.rb`

**Interfaces:**
- Consumes: `SearchIndexRequest` (`parent_type`, `parent_id`, `action` enum `{index_item: 0, unindex_item: 1}`), `CategoryItem` (`category_id`, `item_type`, `item_id`), `Services::BooksMigration.search_indexing_suppressed?`.
- Produces:
  - `Search::IndexerJob::INDEXED_MODEL_TYPES` — frozen `Array<String>`.
  - `Categories::ItemReindexer.call(category:) -> Result` where `Result` responds to `success?`, `data`, `errors`. `data` is `{queued: Integer}`, or `{queued: 0, suppressed: true}` when migration suppression is active.

---

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/categories/item_reindexer_test.rb`:

```ruby
require "test_helper"

class Categories::ItemReindexerTest < ActiveSupport::TestCase
  def setup
    @category = categories(:books_novels_genre)
    # The three books_novels_genre fixtures each fired CategoryItem's own
    # after_save when the fixtures loaded; start from a clean slate so the
    # counts below measure only what the service inserted.
    SearchIndexRequest.where(parent_type: "Books::Book").delete_all
  end

  test "queues one index_item request per category item" do
    result = Categories::ItemReindexer.call(category: @category)

    book_ids = CategoryItem.where(category_id: @category.id, item_type: "Books::Book").pluck(:item_id)
    assert_equal 3, book_ids.size, "fixture drift: books_novels_genre should hold 3 books"

    queued = SearchIndexRequest.where(parent_type: "Books::Book", action: :index_item).pluck(:parent_id)
    assert_equal book_ids.sort, queued.sort
    assert result.success?
    assert_equal 3, result.data[:queued]
    assert_empty result.errors
  end

  test "queues index_item, never unindex_item" do
    Categories::ItemReindexer.call(category: @category)

    assert_equal 0, SearchIndexRequest.where(action: :unindex_item).count
  end

  test "queues nothing while migration suppression is active" do
    assert_no_difference -> { SearchIndexRequest.count } do
      Services::BooksMigration.without_search_indexing do
        result = Categories::ItemReindexer.call(category: @category)
        assert result.success?
        assert_equal 0, result.data[:queued]
        assert result.data[:suppressed]
      end
    end
  end

  test "skips item types the indexer does not drain" do
    # Books::Series has as_indexed_json but is absent from
    # Search::IndexerJob::INDEXED_MODEL_TYPES, so a request for one would never
    # be drained and would sit in the queue forever.
    assert_not_includes Search::IndexerJob::INDEXED_MODEL_TYPES, "Books::Series"

    series = books_series(:asoiaf)
    CategoryItem.create!(category: @category, item: series)
    SearchIndexRequest.delete_all

    Categories::ItemReindexer.call(category: @category)

    assert_equal 0, SearchIndexRequest.where(parent_type: "Books::Series").count
  end

  test "inserts across the batch boundary" do
    # Mocha, not stub_const: Minitest 6 has no stub_const and minitest/mock is a
    # separate gem this app does not use. The service reads self.class.batch_size
    # rather than the constant so this stub can reach it.
    Categories::ItemReindexer.stubs(:batch_size).returns(2)

    Categories::ItemReindexer.call(category: @category)

    assert_equal 3, SearchIndexRequest.where(parent_type: "Books::Book").count
  end

  test "returns a zero result for a category with no items" do
    empty = categories(:books_nonfiction_genre)
    assert_equal 0, CategoryItem.where(category_id: empty.id).count, "fixture drift: expected no items"

    result = Categories::ItemReindexer.call(category: empty)

    assert result.success?
    assert_equal 0, result.data[:queued]
  end
end
```

Fixture references used above, all verified to exist: `categories(:books_novels_genre)` (3 books), `categories(:books_nonfiction_genre)` (0 items), `books_series(:asoiaf)` (the only series fixture).

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd web-app && bin/rails test test/lib/categories/item_reindexer_test.rb
```

Expected: `NameError: uninitialized constant Categories::ItemReindexer`.

- [ ] **Step 3: Extract the model-type constant**

In `web-app/app/sidekiq/search/indexer_job.rb`, replace the inline array in `perform` with a constant. The array currently reads `%w[Music::Artist Music::Album Music::Song Games::Game Books::Book Books::Author]`.

```ruby
class Search::IndexerJob
  include Sidekiq::Job

  # The model types this job drains, and the single source of truth for that list.
  # Categories::ItemReindexer filters against it so it never queues a request for a
  # model nothing indexes -- such a row would never be drained and would sit in the
  # queue forever. Books::Series has as_indexed_json but is deliberately absent.
  INDEXED_MODEL_TYPES = %w[
    Music::Artist
    Music::Album
    Music::Song
    Games::Game
    Books::Book
    Books::Author
  ].freeze

  def perform
    Rails.logger.info "Starting search indexing job"

    INDEXED_MODEL_TYPES.each do |model_type|
      process_requests_for_type(model_type)
    end

    Rails.logger.info "Completed search indexing job"
  end
```

Leave everything below `private` in that file exactly as it is.

- [ ] **Step 4: Write the service**

Create `web-app/app/lib/categories/item_reindexer.rb`:

```ruby
# frozen_string_literal: true

module Categories
  # Queues every item carrying a category for search reindexing after a change to the
  # category row itself that as_indexed_json reads -- see Category#search_relevant_change?
  # for what qualifies.
  #
  # Inserts the SearchIndexRequest rows synchronously rather than through a background
  # job. Measured against Books "Fiction", the largest category in the app at 68,333
  # items: 31ms to pluck the ids, 3.2s to insert every row in 1000-row slices. The only
  # caller is an after_update_commit callback, so those inserts sit outside the
  # category's own transaction -- a slower admin response, not a held lock. A job would
  # buy nothing and add a commit/enqueue race.
  class ItemReindexer
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    BATCH_SIZE = 1000

    # Indirection so tests can shrink the batch size without stubbing a constant.
    def self.batch_size
      BATCH_SIZE
    end

    def self.call(category:)
      new(category: category).call
    end

    def initialize(category:)
      @category = category
    end

    def call
      return suppressed_result if ::Services::BooksMigration.search_indexing_suppressed?

      # One timestamp for the whole flood, so all of a large category's rows sort as a
      # single group under Search::IndexerJob's oldest_first scope instead of
      # interleaving with requests that arrive mid-insert.
      now = Time.current
      queued = 0

      @category.category_items
        .where(item_type: ::Search::IndexerJob::INDEXED_MODEL_TYPES)
        .in_batches(of: self.class.batch_size) do |batch|
          rows = batch.pluck(:item_type, :item_id).map do |item_type, item_id|
            {
              parent_type: item_type,
              parent_id: item_id,
              action: ::SearchIndexRequest.actions[:index_item],
              created_at: now,
              updated_at: now
            }
          end
          next if rows.empty?

          ::SearchIndexRequest.insert_all(rows)
          queued += rows.size
        end

      Result.new(success?: true, data: {queued: queued}, errors: [])
    end

    private

    # Bulk migrations run inside Services::BooksMigration.without_search_indexing and
    # reindex explicitly at the end. SearchIndexable honours the same flag; so does this.
    def suppressed_result
      Result.new(success?: true, data: {queued: 0, suppressed: true}, errors: [])
    end
  end
end
```

Only `index_item` is ever queued: soft-deleting a category does not remove its books from the index, it re-renders them without that category.

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd web-app && bin/rails test test/lib/categories/item_reindexer_test.rb
```

Expected: all tests PASS, no warnings.

- [ ] **Step 6: Prove the tests can fail**

For each test, break the thing it claims to check, confirm red, then restore:

```bash
cd web-app
# Delete the `where(item_type: ...)` filter line -> "skips item types" must fail.
# Delete the suppression guard line          -> "queues nothing while ... suppressed" must fail.
# Change index_item to unindex_item          -> "queues index_item, never" must fail.
bin/rails test test/lib/categories/item_reindexer_test.rb
```

Restore the file to the Step 4 version afterwards and confirm green again. A test that stays green through this is not testing anything.

- [ ] **Step 7: Confirm Zeitwerk can still boot**

`app/lib` is eager-loaded in production but not in test, so a green suite does not prove the constant resolves.

```bash
cd web-app && CI=1 bin/rails zeitwerk:check
```

Expected: `All is good!`

- [ ] **Step 8: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/lib/categories/item_reindexer.rb app/sidekiq/search/indexer_job.rb test/lib/categories/item_reindexer_test.rb
```

```bash
git add web-app/app/lib/categories/item_reindexer.rb web-app/app/sidekiq/search/indexer_job.rb web-app/test/lib/categories/item_reindexer_test.rb
git commit -m "Add Categories::ItemReindexer to queue a category's items for reindexing

Batch-inserts one index_item SearchIndexRequest per CategoryItem, filtered to
the model types Search::IndexerJob actually drains -- now a constant on that
job rather than an inline array, so there is one list instead of two.

Honours Services::BooksMigration.without_search_indexing, as SearchIndexable
does, so a bulk migration does not queue a request per row.

Nothing calls this yet.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: The base `Category` callback

Wires the service to `Category`, watching `deleted` only. `Music::Category` and `Games::Category` inherit this and need nothing further — `deleted` is genuinely all their `as_indexed_json` reads.

**Files:**
- Modify: `web-app/app/models/category.rb`
- Test: `web-app/test/models/category_test.rb` (append to the existing file)
- Test: `web-app/test/models/music/category_test.rb` (append; create only if absent)

**Interfaces:**
- Consumes: `Categories::ItemReindexer.call(category:)` from Task 1.
- Produces: `Category#search_relevant_change?` — public predicate, returns boolean, overridden by `Books::Category` in Task 3.

---

- [ ] **Step 1: Write the failing tests**

Append to `web-app/test/models/category_test.rb`, inside `class CategoryTest`:

```ruby
  test "flipping deleted queues every item for reindexing" do
    category = categories(:music_rock_genre)
    album_ids = CategoryItem.where(category_id: category.id, item_type: "Music::Album").pluck(:item_id)
    assert_equal 2, album_ids.size, "fixture drift: music_rock_genre should hold 2 albums"
    SearchIndexRequest.delete_all

    category.soft_delete!

    queued = SearchIndexRequest.where(parent_type: "Music::Album", action: :index_item).pluck(:parent_id)
    assert_equal album_ids.sort, queued.sort
  end

  test "un-deleting a category also queues its items" do
    category = categories(:music_deleted_genre)
    SearchIndexRequest.delete_all

    category.update!(deleted: false)

    assert category.search_relevant_change?
  end

  test "editing description, slug or parent queues nothing" do
    category = categories(:music_rock_genre)
    SearchIndexRequest.delete_all

    assert_no_difference -> { SearchIndexRequest.count } do
      category.update!(description: "a different description")
      category.update!(slug: "rock-renamed-slug")
      category.update!(parent: categories(:music_progressive_rock_genre))
    end
  end

  test "creating a category queues nothing" do
    assert_no_difference -> { SearchIndexRequest.count } do
      Music::Category.create!(name: "Shoegaze", category_type: "genre")
    end
  end

  test "a deleted flip inside without_search_indexing queues nothing" do
    category = categories(:music_rock_genre)

    assert_no_difference -> { SearchIndexRequest.count } do
      Services::BooksMigration.without_search_indexing do
        category.soft_delete!
      end
    end
  end
```

`web-app/test/models/music/category_test.rb` **already exists** — `module Music` / `class CategoryTest < ActiveSupport::TestCase` starts at line 35, after the schema-annotation comment block, with a `def setup` at line 37. Append these two tests inside that existing class; do not create a new file or a second class.

```ruby
    test "changing category_type queues nothing for music" do
      category = categories(:music_rock_genre)
      assert_equal 2, CategoryItem.where(category_id: category.id).count, "fixture drift"
      SearchIndexRequest.delete_all

      assert_no_difference -> { SearchIndexRequest.count } do
        category.update!(category_type: "subject")
      end
    end

    test "renaming queues nothing for music" do
      category = categories(:music_rock_genre)
      SearchIndexRequest.delete_all

      assert_no_difference -> { SearchIndexRequest.count } do
        category.update!(name: "Rock and Roll")
      end
    end
```

These two negative tests are the point of the per-domain split: `Music::Album#as_indexed_json` reads only `deleted`, so requeueing 3,658 albums for a rename would be pure waste. If someone later "simplifies" the predicate into one shared list, these go red.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd web-app && bin/rails test test/models/category_test.rb test/models/music/category_test.rb
```

Expected: the `deleted` tests FAIL (nothing is queued yet) and `search_relevant_change?` raises `NoMethodError`. The "queues nothing" tests will pass vacuously — that is expected at this step and is exactly why Step 5 exists.

- [ ] **Step 3: Add the callback and predicate**

In `web-app/app/models/category.rb`, add the callback below the existing associations and above the validations:

```ruby
  # Search indexing: requeue this category's items when the category row itself
  # changes in a way as_indexed_json reads. CategoryItem covers adding and removing
  # an item; without this, editing the category left every item it holds with a stale
  # indexed document until something unrelated reindexed it.
  after_update_commit :queue_items_for_reindexing
```

and add the predicate as a public method, next to `soft_delete!`:

```ruby
  # Which attribute changes actually invalidate an indexed document. Overridden per
  # STI subclass to mirror exactly what that domain's as_indexed_json reads -- every
  # indexed model filters category_ids by `deleted`, and only Books::Book reads any
  # more than that. Public so tests can assert on it directly.
  def search_relevant_change?
    saved_change_to_deleted?
  end
```

and the callback body in the `private` section at the bottom:

```ruby
  def queue_items_for_reindexing
    return unless search_relevant_change?

    Categories::ItemReindexer.call(category: self)
  end
```

`after_update_commit`, not `after_save`, for two reasons: a create has no items yet (importers call `find_or_create_by!` on categories constantly, and an `after_save` would run the service for every one of them), and running after commit keeps a potential 3.2s of inserts outside the update's transaction.

The `item_count` counter cache needs no exclusion — `counter_cache` writes through `update_counters`, which fires no callbacks.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd web-app && bin/rails test test/models/category_test.rb test/models/music/category_test.rb
```

Expected: all PASS.

- [ ] **Step 5: Prove the negative tests can fail**

The "queues nothing" tests passed before the feature existed, so they have proven nothing yet. Temporarily widen the predicate:

```ruby
  def search_relevant_change?
    saved_change_to_deleted? || saved_changes.any?
  end
```

```bash
cd web-app && bin/rails test test/models/category_test.rb test/models/music/category_test.rb
```

Expected: "editing description, slug or parent queues nothing", "changing category_type queues nothing for music" and "renaming queues nothing for music" all FAIL. Restore the real predicate and confirm green. If any stayed green, that test is not reaching the callback — fix it before continuing.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/models/category.rb test/models/category_test.rb test/models/music/category_test.rb
```

```bash
git add web-app/app/models/category.rb web-app/test/models/category_test.rb web-app/test/models/music/category_test.rb
git commit -m "Requeue a category's items for reindexing when deleted changes

Category had no callbacks at all, so soft_delete! left every item carrying the
category with a stale indexed document. Every indexed model -- books, music and
games alike -- filters category_ids by deleted, so this belongs on the base class.

search_relevant_change? is the overridable seam; Music and Games want nothing
more than deleted, and the negative tests assert that rather than leaving it to
chance.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: The `Books::Category` override

Books is the domain that reads more than `deleted`: `category_type` splits `genre_category_ids` / `subject_category_ids` / `location_category_ids`, and `name` decides whether a category is excluded from `similarity_category_count`, the denominator the similarity query divides by.

**Files:**
- Modify: `web-app/app/models/books/category.rb`
- Test: `web-app/test/models/books/category_test.rb` (append to the existing class)

**Interfaces:**
- Consumes: `Category#search_relevant_change?` from Task 2, `::Books::Book::BOOK_TYPE_CATEGORY_NAMES` (`%w[Fiction Nonfiction].freeze`, defined at `app/models/books/book.rb:78`).
- Produces: nothing new for later tasks.

---

- [ ] **Step 1: Write the failing tests**

`web-app/test/models/books/category_test.rb` **already exists** — `module Books` / `class CategoryTest < ActiveSupport::TestCase` starts at line 36, after the schema-annotation comment block. It has no `def setup`; add the one below alongside the new tests, or fold its two lines into each test if a `setup` already appeared by the time you get there.

```ruby
    def setup
      @novels = categories(:books_novels_genre)
      SearchIndexRequest.delete_all
    end

    test "changing category_type queues every book" do
      book_ids = CategoryItem.where(category_id: @novels.id, item_type: "Books::Book").pluck(:item_id)
      assert_equal 3, book_ids.size, "fixture drift: books_novels_genre should hold 3 books"

      @novels.update!(category_type: "subject")

      queued = SearchIndexRequest.where(parent_type: "Books::Book", action: :index_item).pluck(:parent_id)
      assert_equal book_ids.sort, queued.sort
    end

    test "renaming a category into Fiction queues its books" do
      assert_difference -> { SearchIndexRequest.count }, 3 do
        @novels.update!(name: "Fiction")
      end
    end

    test "renaming a category out of Nonfiction queues its books" do
      nonfiction = categories(:books_nonfiction_genre)
      CategoryItem.create!(category: nonfiction, item: books_books(:war_and_peace))
      SearchIndexRequest.delete_all

      assert_difference -> { SearchIndexRequest.count }, 1 do
        nonfiction.update!(name: "General Nonfiction")
      end
    end

    test "an unrelated rename queues nothing" do
      assert_no_difference -> { SearchIndexRequest.count } do
        @novels.update!(name: "Long Novels")
      end
    end

    test "editing description queues nothing" do
      assert_no_difference -> { SearchIndexRequest.count } do
        @novels.update!(description: "Fiction of novel length")
      end
    end
```

`books_books(:war_and_peace)` and `categories(:books_nonfiction_genre)` are both verified to exist; nonfiction carries no fixture items, which is why that test adds one.

"an unrelated rename queues nothing" is the load-bearing one. Name reaches `as_indexed_json` **only** through `BOOK_TYPE_CATEGORY_NAMES.include?(c.name)`, so a typo fix on a 30,000-item category must not requeue 30,000 books.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd web-app && bin/rails test test/models/books/category_test.rb
```

Expected: the `category_type` and both Fiction/Nonfiction tests FAIL (the base predicate watches `deleted` only). The two "queues nothing" tests pass vacuously; Step 5 fixes that.

- [ ] **Step 3: Add the override**

In `web-app/app/models/books/category.rb`, inside `class Category < ::Category`:

```ruby
    # Books reads more of the category row than any other domain.
    # Books::Book#as_indexed_json splits genre_category_ids / subject_category_ids /
    # location_category_ids by category_type, and similarity_category_count -- the
    # denominator the similarity query divides by -- excludes the Fiction and
    # Nonfiction genre rows by NAME.
    #
    # Name is compared as membership rather than as a string on purpose: it only ever
    # reaches the indexed document through BOOK_TYPE_CATEGORY_NAMES.include?, so
    # fixing a typo on a 30,000-item category requeues nothing, while renaming one
    # into or out of Fiction/Nonfiction requeues everything it holds.
    def search_relevant_change?
      super || saved_change_to_category_type? || book_type_membership_changed?
    end

    private

    def book_type_membership_changed?
      return false unless saved_change_to_name?

      before, after = saved_change_to_name
      ::Books::Book::BOOK_TYPE_CATEGORY_NAMES.include?(before) !=
        ::Books::Book::BOOK_TYPE_CATEGORY_NAMES.include?(after)
    end
```

`::Books::Book` is root-anchored deliberately. A bare `Books::Book` happens to resolve correctly from inside `module Books` today, but this repo has been bitten three-plus times by sibling shadowing — creating `Services::Books` once broke 95 tests, because inside `module Services` a bare `Books::Book` resolved to `Services::Books::Book`. Root-anchoring costs nothing and is the standing convention here; it presents as a confusing `NameError` when it goes wrong.

Watch where `private` lands — the existing file has `has_many` declarations and scopes above; put the `private` keyword after the public predicate so the scopes stay public.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd web-app && bin/rails test test/models/books/category_test.rb
```

Expected: all PASS.

- [ ] **Step 5: Prove the negative tests can fail**

Temporarily replace `book_type_membership_changed?` with the naive version this design deliberately rejected:

```ruby
    def book_type_membership_changed?
      saved_change_to_name?
    end
```

```bash
cd web-app && bin/rails test test/models/books/category_test.rb
```

Expected: "an unrelated rename queues nothing" FAILS while the two Fiction/Nonfiction tests still pass. That is the whole difference between the two implementations — if the unrelated-rename test stays green, it is not exercising the predicate. Restore and confirm green.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/models/books/category.rb test/models/books/category_test.rb
```

```bash
git add web-app/app/models/books/category.rb web-app/test/models/books/category_test.rb
git commit -m "Requeue books when a category's type or book-type name changes

Books::Book#as_indexed_json splits the similarity category ids by category_type
and excludes Fiction/Nonfiction from similarity_category_count by name, so a
retype or a rename across that boundary silently corrupts both similarity
filtering and similarity scoring.

Name is compared as BOOK_TYPE_CATEGORY_NAMES membership, not as a string: a
typo fix on a 68,000-item category should requeue nothing.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Close the `Categories::Deleter` callback bypass

`Categories::Deleter#soft_delete` writes `update_column(:deleted, true)`, which fires no callbacks at all — the callback added in Task 2 would be silently skipped there. The service has no app callers today (tests only), but a callback-bypassing writer sitting next to a callback-dependent fix is how this defect comes back.

**Files:**
- Modify: `web-app/app/lib/categories/deleter.rb`
- Test: `web-app/test/lib/categories/deleter_test.rb` (append)

**Interfaces:**
- Consumes: the `Category` callback from Task 2.
- Produces: nothing new.

---

- [ ] **Step 1: Write the failing test**

Append to `web-app/test/lib/categories/deleter_test.rb`, inside the existing class:

```ruby
  test "soft delete queues the category's items for reindexing" do
    category = categories(:books_novels_genre)
    book_ids = CategoryItem.where(category_id: category.id, item_type: "Books::Book").pluck(:item_id)
    assert_equal 3, book_ids.size, "fixture drift: books_novels_genre should hold 3 books"
    SearchIndexRequest.delete_all

    Categories::Deleter.new(category: category, soft: true).delete

    queued = SearchIndexRequest.where(parent_type: "Books::Book", action: :index_item).distinct.pluck(:parent_id)
    assert_equal book_ids.sort, queued.sort
  end
```

`distinct` is deliberate: `soft_delete` also calls `category_items.destroy_all`, and `CategoryItem`'s own `after_destroy` queues a second request per book. The test asserts which books were queued, not how many rows exist.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd web-app && bin/rails test test/lib/categories/deleter_test.rb
```

This test passes **before** the fix, because `category_items.destroy_all` already queues all three books through `CategoryItem`'s own `after_destroy`. That makes it useless on its own, so isolate the bypass being fixed: comment out the `@category.category_items.destroy_all` line in `app/lib/categories/deleter.rb` and re-run.

```bash
cd web-app && bin/rails test test/lib/categories/deleter_test.rb
```

Expected with that line commented out: FAIL — nothing queues, which is exactly the `update_column` bypass. Uncomment the line before Step 3, and re-run this same isolation check after Step 3 to confirm it now passes on the strength of the callback alone.

- [ ] **Step 3: Replace the callback bypass**

In `web-app/app/lib/categories/deleter.rb`:

```ruby
    def soft_delete
      Category.transaction do
        # update! rather than update_column: update_column fires no callbacks, which
        # would silently skip Category#queue_items_for_reindexing and reintroduce the
        # stale-index defect this service is meant to be safe for.
        @category.update!(deleted: true)
        @category.category_items.destroy_all
      end
    end
```

Note what this does **not** change: `destroy_all` still fires one `SearchIndexRequest.create!` per row, which for a large category is far slower than `ItemReindexer`'s single batched pass and now duplicates it. That is pre-existing behaviour in a service with no app callers, and it is out of scope — see the spec's "Out of scope" section.

Because the callback is `after_update_commit`, the reindex runs when the surrounding transaction commits, not inside it.

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd web-app && bin/rails test test/lib/categories/deleter_test.rb
```

Expected: all PASS, including the file's pre-existing tests.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/lib/categories/deleter.rb test/lib/categories/deleter_test.rb
```

```bash
git add web-app/app/lib/categories/deleter.rb web-app/test/lib/categories/deleter_test.rb
git commit -m "Soft-delete a category through update! so callbacks fire

update_column skips callbacks entirely, so Deleter would have silently bypassed
the reindex callback. The service has no app callers today, but leaving a
callback-bypassing writer next to a callback-dependent fix is how this defect
comes back.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Full-suite regression sweep

Every existing test that flips a category's `deleted` or `category_type` now inserts `SearchIndexRequest` rows synchronously. This task finds what that broke.

**Files:**
- Modify: whatever the sweep turns up. Expected candidates below.
- Test: the whole suite.

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: a green `bin/rails test` and a clean `standardrb`.

---

- [ ] **Step 1: Run the full suite**

```bash
cd web-app && bin/rails db:test:prepare test
```

This is what CI runs. Do not run it concurrently with another `bin/rails test` **in this same worktree** — concurrent runs in one checkout truncate each other's fixtures and manufacture phantom failures. Other worktrees have their own test databases and are safe.

- [ ] **Step 2: Triage failures against the expected list**

Likely breakages, all of which are the new callback doing its job:

- `test/lib/categories/updater_test.rb` — `Categories::Updater#merge_with_existing_category` calls `existing.update!(deleted: false)`, which now queues. Any `assert_no_difference -> { SearchIndexRequest.count }` there needs updating to the new expected count.
- `test/lib/services/books_migration/*_test.rb` — these assert `assert_no_difference` around migrator runs. They should still pass because `ItemReindexer` honours `without_search_indexing`; if one fails, the suppression guard is wrong, not the test.
- Any test asserting an exact `SearchIndexRequest.count`.
- `assert_queries_count` assertions near category updates — the callback adds queries.

For each failure, decide whether the new behaviour is correct (update the assertion) or a genuine bug (fix the code). Do not weaken an assertion to make it pass without establishing which of the two it is.

- [ ] **Step 3: Check for new warnings**

A clean run emits no warnings beyond two known upstream sources: `weighted_list_rank`'s position `puts`, and npm/yarn output during `test:prepare`. A new warning line is a regression — fix the cause rather than filtering the output.

```bash
cd web-app && bin/rails test 2>&1 | grep -i "warning" | grep -v "weighted_list_rank"
```

- [ ] **Step 4: Lint the whole diff**

```bash
cd web-app && bundle exec standardrb
```

Expected: no offenses. Use `bundle exec standardrb --fix` for autocorrectable ones. **Do not run brakeman.**

- [ ] **Step 5: Confirm Zeitwerk**

```bash
cd web-app && CI=1 bin/rails zeitwerk:check
```

Expected: `All is good!`

- [ ] **Step 6: Commit the sweep**

```bash
git add -A
git commit -m "Update tests for the new Category reindex callback

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 7: Report, do not push**

Report the final `bin/rails test` line (runs, assertions, failures, errors) and the `standardrb` result verbatim. **Do not push and do not open a PR without asking** — merging to `main` deploys to production.

---

## Manual verification (optional, dev database)

Read-only and safe. Confirms the callback fires end to end against real data without changing any category:

```bash
cd web-app && bin/rails runner '
cat = Books::Category.find_by(name: "Novels")
puts "category=#{cat&.id} items=#{cat&.item_count}"
before = SearchIndexRequest.count
ActiveRecord::Base.transaction do
  cat.update!(category_type: cat.genre? ? "subject" : "genre")
  puts "queued inside transaction: #{SearchIndexRequest.count - before}"
  raise ActiveRecord::Rollback
end
puts "after rollback: #{SearchIndexRequest.count - before}"
'
```

Expect **0 queued inside the transaction** — the callback is `after_update_commit`, and a rolled-back transaction never commits. That is the correct result and confirms the callback is not firing on uncommitted writes. To see it actually queue, the update has to commit; do that only against a category you are willing to reindex, and remember the drain runs every 30 seconds in dev only if Sidekiq is running.
