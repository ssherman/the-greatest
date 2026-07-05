# Books Categories Migration (categories + category_items) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate legacy `categories` → STI `Books::Category` (fresh id + `LegacyIdMap`, slug preserved verbatim) and legacy `book_categories` → the polymorphic `category_items` join, via a new reusable `BulkUpsertMigrator` base.

**Architecture:** A new `BulkUpsertMigrator < Migrator` base streams legacy rows, maps each to 0+ target-row hashes (`build_rows`), and bulk-`upsert_all`s them in batches (no per-row callbacks). `CategoryMigrator < Migrator` writes categories through the real `Books::Category` model, pinning the legacy slug with a per-instance FriendlyId override and remapping the self-referential `parent_id` in `finalize`. `CategoryItemMigrator < BulkUpsertMigrator` preloads an active-only category id-map (so the 915 `book_categories` pointing at soft-deleted categories are dropped) and recomputes `item_count` in `finalize`.

**Tech Stack:** Rails 8.1, PostgreSQL 17, Minitest + Mocha + fixtures, `Services::BooksMigration` migrators, FriendlyId, `LegacyBooks::` read-only replica models.

**Spec:** `docs/superpowers/specs/2026-07-05-books-categories-migration-design.md`.

## Global Constraints

- Run all commands from `/home/shane/dev/the-greatest/web-app`. Lint with `bundle exec standardrb` (NOT rubocop). Tests `bin/rails test`.
- Legacy volumes: `categories` 73,913 (21,182 soft-deleted, 51 parented, slugs globally unique); `book_categories` 1,828,730 (0 self-deleted; 915 point at a soft-deleted category → **dropped**; net **1,827,815**).
- **Enums are direct integer copies — NO re-encoding.** `category_type` (`genre:0, location:1, subject:2`) and `import_source` (`amazon:0, open_library:1, openai:2, goodreads:3`, nil allowed) assign the SAME integers old↔new (new enums are supersets). Assigning the raw integer to the Rails enum attribute maps it correctly. This is unlike `List.status`/`Edition.book_binding`.
- **Slug is preserved verbatim.** `Books::Category` FriendlyId regenerates the slug from `name` on save (`should_generate_new_friendly_id?` is true when `name_changed?`). Pin the legacy slug with a per-instance override: `def category.should_generate_new_friendly_id? = false` before `save!`.
- **Categories get fresh ids** (shared table with music/games/movies) recorded in `LegacyIdMap` under model key `"Books::Category"`. **category_items** dedupe on the unique index `(category_id, item_type, item_id)` — no `LegacyIdMap` for the join.
- **Soft-deleted categories ARE migrated** (`deleted` flag preserved). **book_categories pointing at them are NOT** — the active-only category map naturally drops them.
- Write categories through the real `Books::Category`; load `category_items` via `upsert_all(rows, unique_by:, record_timestamps: true)` (satisfies NOT-NULL timestamps, idempotent, preserves `created_at`). Both paths run inside `without_search_indexing`; `upsert_all` bypasses `CategoryItem`'s `counter_cache` + reindex callback, so `item_count` is recomputed once in `finalize`.
- Migrator tests are **connection-free**: stub `legacy_each` (Mocha `multiple_yields`); never open the legacy connection. `finalize` in both migrators touches only the new DB, so it runs in tests.
- Framework already on the branch base (off `main`): `Services::BooksMigration::Migrator`, `LegacyBooks::Record`, `LegacyIdMap.record/lookup`, `Services::BooksMigration.without_search_indexing`, `data_migration:*` rake.

---

### Task 1: `BulkUpsertMigrator` base

**Files:**
- Create: `web-app/app/lib/services/books_migration/bulk_upsert_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/bulk_upsert_migrator_test.rb`

**Interfaces:**
- Consumes: `Services::BooksMigration::Migrator` (base — `legacy_each`, `without_search_indexing`), any target model responding to `upsert_all`.
- Produces: `BulkUpsertMigrator < Migrator`. Overrides `call` (streams → buffers → `upsert_all` per `upsert_batch`). Subclass contract (all private): `legacy_model`, `model_key`, `target_model`, `unique_by`, `build_rows(attrs) -> [Hash, ...]`; optional `preload_context`, `finalize`, `upsert_batch` (default `UPSERT_BATCH = 1000`). Returns `{success:, data: {model:, count:}}` where `count` = rows upserted.

- [ ] **Step 1: Write the failing test**

`test/lib/services/books_migration/bulk_upsert_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::BulkUpsertMigratorTest < ActiveSupport::TestCase
  # Minimal concrete subclass over the real category_items table: one legacy row ->
  # one category_item; book_id nil -> [] (skip); book_id "boom" -> raises. upsert_batch
  # is shrunk to 2 to force a flush mid-stream plus a final flush.
  class TestJoinMigrator < Services::BooksMigration::BulkUpsertMigrator
    def initialize(category_id)
      @category_id = category_id
    end

    private

    def legacy_model
      raise "legacy_each is stubbed in tests"
    end

    def model_key
      "TestJoin"
    end

    def target_model
      CategoryItem
    end

    def unique_by
      :index_category_items_on_category_id_and_item_type_and_item_id
    end

    def upsert_batch
      2
    end

    def build_rows(attrs)
      raise "boom row" if attrs["book_id"] == "boom"
      return [] if attrs["book_id"].nil?
      [{category_id: @category_id, item_type: "Books::Book", item_id: attrs["book_id"]}]
    end
  end

  def setup
    @category = Books::Category.create!(name: "Bulk Base Cat")
  end

  def run_migrator(rows)
    m = TestJoinMigrator.new(@category.id)
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "bulk-inserts every mapped row, flushing across the batch boundary" do
    result = run_migrator([
      {"id" => 1, "book_id" => 101},
      {"id" => 2, "book_id" => 102},
      {"id" => 3, "book_id" => 103}
    ])
    assert result[:success], result[:error]
    assert_equal 3, result[:data][:count]
    assert_equal [101, 102, 103], CategoryItem.where(category_id: @category.id).order(:item_id).pluck(:item_id)
  end

  test "build_rows returning [] contributes no rows" do
    result = run_migrator([{"id" => 1, "book_id" => nil}, {"id" => 2, "book_id" => 200}])
    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]
    assert_equal [200], CategoryItem.where(category_id: @category.id).pluck(:item_id)
  end

  test "is idempotent on the target unique key" do
    rows = [{"id" => 1, "book_id" => 301}, {"id" => 2, "book_id" => 302}]
    run_migrator(rows)
    assert_no_difference -> { CategoryItem.count } do
      run_migrator(rows)
    end
  end

  test "reports per-row error context with the legacy id and returns success: false" do
    result = run_migrator([{"id" => 42, "book_id" => "boom"}])
    assert_not result[:success]
    assert_match "legacy id=42", result[:error]
  end

  test "suppresses search indexing during the load" do
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([{"id" => 1, "book_id" => 401}])
    end
  end
end
```

- [ ] **Step 2: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/bulk_upsert_migrator_test.rb`
Expected: FAIL — `uninitialized constant ...BulkUpsertMigrator`.

- [ ] **Step 3: Write the base**

`app/lib/services/books_migration/bulk_upsert_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Base for high-volume join/child tables: streams legacy rows, maps each to zero
    # or more target row hashes (build_rows), and bulk-upserts them with upsert_all in
    # batches — no per-row AR callbacks, no giant wrapping transaction (each batch is
    # its own statement, so a mid-run failure leaves prior batches committed and the
    # run resumes idempotently). Idempotent on the target's unique index. Subclasses
    # define: legacy_model, model_key, target_model, unique_by, build_rows(attrs);
    # optionally preload_context / finalize / upsert_batch.
    class BulkUpsertMigrator < Migrator
      UPSERT_BATCH = 1000

      def call
        @count = 0
        buffer = []
        preload_context
        Services::BooksMigration.without_search_indexing do
          legacy_each do |attrs|
            build_rows(attrs).each { |row| buffer << row }
            if buffer.size >= upsert_batch
              flush(buffer)
              buffer = []
            end
          rescue => e
            raise "#{model_key} migration failed at legacy id=#{attrs["id"]} (#{@count} rows upserted): #{e.message}"
          end
          flush(buffer) if buffer.any?
        end
        finalize
        {success: true, data: {model: model_key, count: @count}}
      rescue => e
        {success: false, error: e.message, data: {model: model_key, count: @count}}
      end

      private

      def upsert_batch
        UPSERT_BATCH
      end

      def preload_context
      end

      def flush(rows)
        target_model.upsert_all(rows, unique_by: unique_by, record_timestamps: true)
        @count += rows.size
      end
    end
  end
end
```

- [ ] **Step 4: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/bulk_upsert_migrator_test.rb`
Expected: PASS (5 runs).

- [ ] **Step 5: Lint + commit**

```bash
bundle exec standardrb --fix app/lib/services/books_migration/bulk_upsert_migrator.rb test/lib/services/books_migration/bulk_upsert_migrator_test.rb
git add app/lib/services/books_migration/bulk_upsert_migrator.rb test/lib/services/books_migration/bulk_upsert_migrator_test.rb
git commit -m "Add BulkUpsertMigrator base (batched upsert_all for join tables)"
```

---

### Task 2: `CategoryTransformer`

**Files:**
- Create: `web-app/app/lib/services/books_migration/category_transformer.rb`
- Test: `web-app/test/lib/services/books_migration/category_transformer_test.rb`

**Interfaces:**
- Consumes: nothing (pure).
- Produces: `CategoryTransformer.call(attrs) -> Hash` with symbol keys `{name:, description:, category_type:, import_source:, deleted:, slug:, alternative_names:}`. `category_type`/`import_source` are the raw legacy integers (or nil); `slug` is passed through for the migrator to preserve; `parent_category_id` is intentionally NOT in the output (the migrator remaps it).

- [ ] **Step 1: Write the failing test**

`test/lib/services/books_migration/category_transformer_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::CategoryTransformerTest < ActiveSupport::TestCase
  T = Services::BooksMigration::CategoryTransformer

  def legacy(overrides = {})
    {
      "name" => "Speculative Fiction",
      "description" => "desc",
      "category_type" => 0,
      "import_source" => 1,
      "deleted" => false,
      "slug" => "metaphysical-visionary-fiction",
      "merged_category_names" => ["Sci-Fi", "SF"]
    }.merge(overrides)
  end

  test "maps core fields straight through" do
    out = T.call(legacy)
    assert_equal "Speculative Fiction", out[:name]
    assert_equal "desc", out[:description]
    assert_equal false, out[:deleted]
    assert_equal "metaphysical-visionary-fiction", out[:slug]
  end

  test "copies category_type and import_source as raw integers (identical enums, no re-encoding)" do
    out = T.call(legacy("category_type" => 2, "import_source" => 3))
    assert_equal 2, out[:category_type]
    assert_equal 3, out[:import_source]
  end

  test "keeps a nil import_source as nil" do
    assert_nil T.call(legacy("import_source" => nil))[:import_source]
  end

  test "maps merged_category_names to alternative_names" do
    assert_equal ["Sci-Fi", "SF"], T.call(legacy)[:alternative_names]
  end

  test "coerces a nil merged_category_names to an empty array" do
    assert_equal [], T.call(legacy("merged_category_names" => nil))[:alternative_names]
  end
end
```

- [ ] **Step 2: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/category_transformer_test.rb`
Expected: FAIL — `uninitialized constant ...CategoryTransformer`.

- [ ] **Step 3: Write the transformer**

`app/lib/services/books_migration/category_transformer.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `categories` row -> new Books::Category attributes. PURE (String-keyed
    # hash in -> symbol-keyed attrs out, no DB). category_type and import_source are
    # copied as RAW INTEGERS — the old and new enums assign the same integers to the
    # shared names (genre/location/subject; amazon/open_library/openai/goodreads), so
    # unlike List.status/Edition.book_binding there is no re-encoding; import_source
    # nil stays nil. slug is passed through for the migrator to preserve verbatim;
    # parent_id is resolved by the migrator (self-referential remap), not here.
    # alternative_names is NOT NULL default [], so a nil merged_category_names -> [].
    class CategoryTransformer
      def self.call(attrs)
        {
          name: attrs["name"],
          description: attrs["description"],
          category_type: attrs["category_type"],
          import_source: attrs["import_source"],
          deleted: attrs["deleted"],
          slug: attrs["slug"],
          alternative_names: Array(attrs["merged_category_names"])
        }
      end
    end
  end
end
```

- [ ] **Step 4: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/category_transformer_test.rb`
Expected: PASS (5 runs).

- [ ] **Step 5: Lint + commit**

```bash
bundle exec standardrb --fix app/lib/services/books_migration/category_transformer.rb test/lib/services/books_migration/category_transformer_test.rb
git add app/lib/services/books_migration/category_transformer.rb test/lib/services/books_migration/category_transformer_test.rb
git commit -m "Add CategoryTransformer (legacy categories -> Books::Category attrs)"
```

---

### Task 3: `LegacyBooks::Category` + `CategoryMigrator`

**Files:**
- Create: `web-app/app/models/legacy_books/category.rb`
- Create: `web-app/app/lib/services/books_migration/category_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/category_migrator_test.rb`

**Interfaces:**
- Consumes: `Migrator` base, `CategoryTransformer.call` (Task 2), `LegacyIdMap.record/lookup`, `Books::Category`, `LegacyBooks::Category`.
- Produces: `CategoryMigrator` — fresh-id migrator, model key `"Books::Category"`. Writes each legacy category through `Books::Category` with the slug pinned; records `LegacyIdMap`; stashes parented rows and sets `parent_id` in `finalize`.

- [ ] **Step 1: Create the legacy model**

`app/models/legacy_books/category.rb`:

```ruby
module LegacyBooks
  class Category < Record
    self.table_name = "categories"
  end
end
```

- [ ] **Step 2: Write the failing migrator test**

`test/lib/services/books_migration/category_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::CategoryMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::CategoryMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def legacy(id, overrides = {})
    {
      "id" => id, "name" => "Cat #{id}", "description" => nil,
      "category_type" => 0, "import_source" => 1, "deleted" => false,
      "slug" => "cat-#{id}-slug", "merged_category_names" => [],
      "parent_category_id" => nil
    }.merge(overrides)
  end

  test "creates a Books::Category with a fresh id, records the map, decodes enums" do
    result = run_migrator([legacy(9001)])
    assert result[:success], result[:error]
    new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9001)
    assert_not_nil new_id
    category = Books::Category.find(new_id)
    assert_equal "Cat 9001", category.name
    assert_equal "Books::Category", category.type
    assert_equal "genre", category.category_type
    assert_equal "open_library", category.import_source
  end

  test "preserves the legacy slug verbatim instead of regenerating from the name" do
    run_migrator([legacy(9002, "name" => "Speculative Fiction", "slug" => "metaphysical-visionary-fiction")])
    new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9002)
    assert_equal "metaphysical-visionary-fiction", Books::Category.find(new_id).slug
  end

  test "migrates a soft-deleted category with the deleted flag set" do
    run_migrator([legacy(9003, "deleted" => true)])
    new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9003)
    assert Books::Category.find(new_id).deleted
  end

  test "maps merged_category_names onto alternative_names" do
    run_migrator([legacy(9004, "merged_category_names" => ["Alt A", "Alt B"])])
    new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9004)
    assert_equal ["Alt A", "Alt B"], Books::Category.find(new_id).alternative_names
  end

  test "is idempotent: re-running updates in place, keeps the map, and keeps the slug" do
    run_migrator([legacy(9005, "name" => "V1")])
    first_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9005)
    assert_no_difference -> { Books::Category.count } do
      run_migrator([legacy(9005, "name" => "V2")])
    end
    assert_equal first_id, LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9005)
    reloaded = Books::Category.find(first_id)
    assert_equal "V2", reloaded.name
    assert_equal "cat-9005-slug", reloaded.slug
  end

  test "remaps the self-referential parent_id through the id map in finalize" do
    run_migrator([
      legacy(9006, "name" => "Parent"),
      legacy(9007, "name" => "Child", "parent_category_id" => 9006)
    ])
    parent_new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9006)
    child_new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: 9007)
    assert_equal parent_new_id, Books::Category.find(child_new_id).parent_id
  end

  test "suppresses search indexing during the load" do
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([legacy(9008)])
    end
  end
end
```

- [ ] **Step 3: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/category_migrator_test.rb`
Expected: FAIL — `uninitialized constant ...CategoryMigrator`.

- [ ] **Step 4: Write the migrator**

`app/lib/services/books_migration/category_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Fresh-id migrator: legacy categories -> STI Books::Category. categories is a
    # SHARED table (music/games/movies categories occupy low ids), so category ids are
    # fresh and the LegacyIdMap ("Books::Category") is the dedup key + the FK source
    # for category_items and for the self-referential parent remap. The slug is
    # PRESERVED verbatim: FriendlyId would otherwise regenerate it from name on insert
    # (should_generate_new_friendly_id? is true when name_changed?), so a per-instance
    # override pins it. parent_id is remapped in finalize (both ends through the map),
    # after every category is mapped.
    class CategoryMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Category
      end

      def model_key
        "Books::Category"
      end

      def upsert_row(attrs)
        Books::Category.transaction do
          new_id = LegacyIdMap.lookup(model: model_key, legacy_id: attrs["id"])
          category = new_id ? Books::Category.find(new_id) : Books::Category.new
          category.assign_attributes(CategoryTransformer.call(attrs))
          def category.should_generate_new_friendly_id? = false
          category.save!
          LegacyIdMap.record(model: model_key, legacy_id: attrs["id"], new_id: category.id)
        end
        stash_parent_link(attrs)
      end

      def stash_parent_link(attrs)
        parent_legacy_id = attrs["parent_category_id"]
        (@parent_links ||= []) << [attrs["id"], parent_legacy_id] if parent_legacy_id
      end

      # Second pass (new DB only): resolve child + parent legacy ids through the map
      # and set parent_id. update_all bypasses FriendlyId (no slug regen) and
      # callbacks. Runs after the full pass, so every parent is already mapped.
      def finalize
        (@parent_links || []).each do |child_legacy_id, parent_legacy_id|
          child_new_id = LegacyIdMap.lookup(model: model_key, legacy_id: child_legacy_id)
          parent_new_id = LegacyIdMap.lookup(model: model_key, legacy_id: parent_legacy_id)
          next unless child_new_id && parent_new_id
          Books::Category.where(id: child_new_id).update_all(parent_id: parent_new_id)
        end
      end
    end
  end
end
```

- [ ] **Step 5: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/category_migrator_test.rb`
Expected: PASS (7 runs).

- [ ] **Step 6: Lint + commit**

```bash
bundle exec standardrb --fix app/models/legacy_books/category.rb app/lib/services/books_migration/category_migrator.rb test/lib/services/books_migration/category_migrator_test.rb
git add app/models/legacy_books/category.rb app/lib/services/books_migration/category_migrator.rb test/lib/services/books_migration/category_migrator_test.rb
git commit -m "Add CategoryMigrator (legacy categories -> Books::Category, slug + parent preserved)"
```

---

### Task 4: `LegacyBooks::BookCategory` + `CategoryItemMigrator`

**Files:**
- Create: `web-app/app/models/legacy_books/book_category.rb`
- Create: `web-app/app/lib/services/books_migration/category_item_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/category_item_migrator_test.rb`

**Interfaces:**
- Consumes: `BulkUpsertMigrator` base (Task 1), `LegacyBooks::BookCategory`, `LegacyIdMap`, `CategoryItem`, `Books::Category`, `Books::Book`.
- Produces: `CategoryItemMigrator < BulkUpsertMigrator` — model key `"CategoryItem"`, target `CategoryItem`, `unique_by :index_category_items_on_category_id_and_item_type_and_item_id`. `preload_context` builds the active-only `{legacy_category_id => new_id}` map; `build_rows` emits one row per book_category with a mapped active category; `finalize` recomputes `item_count`.

- [ ] **Step 1: Create the legacy model**

`app/models/legacy_books/book_category.rb`:

```ruby
module LegacyBooks
  class BookCategory < Record
    self.table_name = "book_categories"
  end
end
```

- [ ] **Step 2: Write the failing migrator test**

`test/lib/services/books_migration/category_item_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::CategoryItemMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::CategoryItemMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  # Create a Books::Category and record its LegacyIdMap entry (as CategoryMigrator would).
  def make_category(legacy_id, deleted: false)
    category = Books::Category.create!(name: "Cat #{legacy_id}", deleted: deleted)
    LegacyIdMap.record(model: "Books::Category", legacy_id: legacy_id, new_id: category.id)
    category
  end

  test "creates a category_item on the mapped category for a Books::Book" do
    category = make_category(8001)
    book = Books::Book.create!(title: "Cat Item Book")
    result = run_migrator([{"id" => 1, "category_id" => 8001, "book_id" => book.id}])
    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]
    item = CategoryItem.find_by(category_id: category.id, item_id: book.id, item_type: "Books::Book")
    assert_not_nil item
  end

  test "skips a book_category whose category is soft-deleted (absent from the active map)" do
    make_category(8002, deleted: true)
    book = Books::Book.create!(title: "Orphan Item Book")
    assert_no_difference -> { CategoryItem.count } do
      result = run_migrator([{"id" => 2, "category_id" => 8002, "book_id" => book.id}])
      assert result[:success], result[:error]
    end
  end

  test "is idempotent on the (category, item_type, item_id) key" do
    make_category(8003)
    book = Books::Book.create!(title: "Idem Item Book")
    rows = [{"id" => 3, "category_id" => 8003, "book_id" => book.id}]
    run_migrator(rows)
    assert_no_difference -> { CategoryItem.count } do
      run_migrator(rows)
    end
  end

  test "finalize recomputes item_count for a populated Books::Category" do
    category = make_category(8004)
    b1 = Books::Book.create!(title: "IC Book 1")
    b2 = Books::Book.create!(title: "IC Book 2")
    run_migrator([
      {"id" => 4, "category_id" => 8004, "book_id" => b1.id},
      {"id" => 5, "category_id" => 8004, "book_id" => b2.id}
    ])
    assert_equal 2, category.reload.item_count
  end

  test "a soft-deleted category ends up with item_count 0 after finalize" do
    deleted = make_category(8005, deleted: true)
    book = Books::Book.create!(title: "Deleted Cat Book")
    run_migrator([{"id" => 6, "category_id" => 8005, "book_id" => book.id}])
    assert_equal 0, deleted.reload.item_count
  end

  test "suppresses search indexing during the load" do
    make_category(8006)
    book = Books::Book.create!(title: "Quiet Item Book")
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([{"id" => 7, "category_id" => 8006, "book_id" => book.id}])
    end
  end
end
```

- [ ] **Step 3: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/category_item_migrator_test.rb`
Expected: FAIL — `uninitialized constant ...CategoryItemMigrator`.

- [ ] **Step 4: Write the migrator**

`app/lib/services/books_migration/category_item_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Bulk join migrator: legacy book_categories -> polymorphic category_items, via
    # BulkUpsertMigrator (batched upsert_all). The category id-map is preloaded from
    # LegacyIdMap joined to ACTIVE (deleted: false) categories only, so the ~915 legacy
    # book_categories that point at a soft-deleted category get no map hit and are
    # dropped (legacy data corruption). item_id is book_id directly (books preserve
    # their id). finalize recomputes categories.item_count (upsert_all bypasses the
    # counter_cache), scoped to Books::Category.
    class CategoryItemMigrator < BulkUpsertMigrator
      private

      def legacy_model
        LegacyBooks::BookCategory
      end

      def model_key
        "CategoryItem"
      end

      def target_model
        CategoryItem
      end

      def unique_by
        :index_category_items_on_category_id_and_item_type_and_item_id
      end

      def preload_context
        @category_map = LegacyIdMap
          .where(model: "Books::Category")
          .joins("INNER JOIN categories ON categories.id = legacy_id_maps.new_id")
          .where(categories: {deleted: false})
          .pluck(:legacy_id, :new_id)
          .to_h
      end

      def build_rows(attrs)
        new_category_id = @category_map[attrs["category_id"]]
        return [] unless new_category_id
        [{category_id: new_category_id, item_type: "Books::Book", item_id: attrs["book_id"]}]
      end

      def finalize
        CategoryItem.connection.execute(<<~SQL)
          UPDATE categories c
          SET item_count = (SELECT COUNT(*) FROM category_items ci WHERE ci.category_id = c.id)
          WHERE c.type = 'Books::Category'
        SQL
      end
    end
  end
end
```

- [ ] **Step 5: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/category_item_migrator_test.rb`
Expected: PASS (6 runs). Also run the whole migration suite for no regression:
`bin/rails test test/lib/services/books_migration/`
Expected: all pass.

- [ ] **Step 6: Lint + commit**

```bash
bundle exec standardrb --fix app/models/legacy_books/book_category.rb app/lib/services/books_migration/category_item_migrator.rb test/lib/services/books_migration/category_item_migrator_test.rb
git add app/models/legacy_books/book_category.rb app/lib/services/books_migration/category_item_migrator.rb test/lib/services/books_migration/category_item_migrator_test.rb
git commit -m "Add CategoryItemMigrator (book_categories -> category_items, active-only, item_count)"
```

---

### Task 5: Orchestrator wiring + end-to-end dev run

**Files:**
- Modify: `web-app/lib/tasks/data_migration.rake`

**Interfaces:**
- Consumes: `CategoryMigrator` (Task 3), `CategoryItemMigrator` (Task 4).
- Produces: `data_migration:categories`, `data_migration:category_items`; `:all` runs `[:languages, :authors, :books, :book_authors, :editions, :identifiers, :categories, :category_items]`.

- [ ] **Step 1: Add the tasks + update `:all`**

In `lib/tasks/data_migration.rake`, add after the `identifiers` task:

```ruby
  desc "Migrate legacy categories into Books::Category (fresh ids + map; preserves slug + parent)"
  task categories: :environment do
    pp Services::BooksMigration::CategoryMigrator.call
  end

  desc "Migrate legacy book_categories into category_items (bulk upsert; recomputes item_count)"
  task category_items: :environment do
    pp Services::BooksMigration::CategoryItemMigrator.call
  end
```

and change the `:all` line to:

```ruby
  task all: [:languages, :authors, :books, :book_authors, :editions, :identifiers, :categories, :category_items]
```

- [ ] **Step 2: Verify the tasks register**

Run: `bin/rails -T data_migration`
Expected: lists `languages`, `authors`, `books`, `book_authors`, `editions`, `identifiers`, `categories`, `category_items`, `all`.

- [ ] **Step 3: Commit**

```bash
git add lib/tasks/data_migration.rake
git commit -m "Wire categories + category_items into data_migration orchestrator"
```

- [ ] **Step 4: End-to-end dev run against the real legacy DB**

> Run against the populated dev DB (books/authors/editions already migrated). `categories` is ~74k AR upserts (a few minutes); `category_items` streams 1,828,730 legacy rows and bulk-`upsert_all`s ~1,827,815 in ~1,828 batches. **The orchestrator runs this step — a subagent must not.**

Run:
```bash
bin/rails data_migration:categories
bin/rails data_migration:category_items
bin/rails runner 'puts "cats=#{Books::Category.count} deleted=#{Books::Category.where(deleted: true).count} parented=#{Books::Category.where.not(parent_id: nil).count} items=#{CategoryItem.where(item_type: "Books::Book").count} pending_book_index=#{SearchIndexRequest.where(parent_type: "Books::Book").count}"'
```
Expected: both migrators `{success: true, ...}`; then `cats=73913 deleted=21182 parented=51 items=1827815 pending_book_index=` unchanged from before the run.

Spot-checks:
```bash
bin/rails runner 'c = Books::Category.find_by(slug: "metaphysical-visionary-fiction"); puts "slug-preserved: #{c&.name.inspect} (want \"Speculative Fiction\")"'
bin/rails runner 'puts "orphaned-items-on-deleted-cats: #{CategoryItem.joins(:category).where(item_type: "Books::Book", categories: {deleted: true}).count} (want 0)"'
bin/rails runner 'puts Books::Category.where(deleted: false).order(item_count: :desc).limit(3).pluck(:name, :item_count).inspect'
```
Expected: the slug resolves to "Speculative Fiction"; 0 category_items reference a soft-deleted category; top categories by `item_count` are the high-volume ones (Fiction, Nonfiction, …).

> If a run returns `{success: false, ...}`, the error names the offending legacy source-row id and the count that succeeded — report it; the run is idempotent, so it resumes.

---

## Self-Review

**1. Spec coverage:**
- Reusable `BulkUpsertMigrator` (batched `upsert_all`, `record_timestamps: true`, per-row error context, `without_search_indexing`) → Task 1. ✓
- `CategoryTransformer` (int-copy enums, nil import_source, merged→alternative_names, slug passthrough) → Task 2. ✓
- `CategoryMigrator` fresh id + `LegacyIdMap`, slug preserved via override, deleted flag, parent remap in finalize, idempotent → Task 3. ✓
- `CategoryItemMigrator` active-only map (drops the 915), item_id=book_id, idempotent on unique key, item_count recompute (incl. 0 for deleted), search suppressed → Task 4. ✓
- Orchestrator `:categories`/`:category_items` + `:all` order (after `:identifiers`) + e2e counts/spot-checks → Task 5. ✓
- Legacy models `LegacyBooks::Category` / `LegacyBooks::BookCategory` → Tasks 3/4. ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code. E2e `items=1827815` and `pending_book_index unchanged` are exact/relative as the spec states.

**3. Type consistency:** `LegacyIdMap.record/lookup(model:, legacy_id:[, new_id:])` and model key `"Books::Category"` identical across Tasks 3/4. `CategoryTransformer.call(attrs) -> Hash` symbol keys consumed by `assign_attributes` in Task 3. `BulkUpsertMigrator` subclass hooks (`legacy_model`, `model_key`, `target_model`, `unique_by`, `build_rows`, `preload_context`, `finalize`, `upsert_batch`) defined in Task 1 and implemented identically in Task 4. `unique_by :index_category_items_on_category_id_and_item_type_and_item_id` matches the DB unique index. `should_generate_new_friendly_id?` override matches the `Books::Category`/`Category` method name. Rake task symbols in Task 5 match the class names in Tasks 3/4.
