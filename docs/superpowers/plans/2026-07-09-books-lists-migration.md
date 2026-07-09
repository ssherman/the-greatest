# Lists Migration Implementation Plan (Phase 2a)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate legacy `lists` (1,030 rows) into STI `Books::List` preserving ids, and legacy `list_items` (65,252 rows) into the polymorphic `list_items` with `listable = Books::Book`.

**Architecture:** Two `BulkUpsertMigrator` subclasses. `ListMigrator` upserts keyed on `:id` (bypassing `List` callbacks/validations so the legacy `formatted_text` survives as `simplified_content` and the `status` enum is symbol-remapped). `ListItemMigrator` upserts on the natural-key unique index `[list_id, listable_type, listable_id]`, guarding the polymorphic `listable` with a preloaded `Books::Book` id set (fail-loud). No schema change.

**Tech Stack:** Rails 8, Minitest + Mocha, PostgreSQL. Reuses `Services::BooksMigration::BulkUpsertMigrator` (batched `upsert_all` + `record_timestamps?` hook) and `LegacyBooks::Record` (read-only legacy replica).

## Global Constraints

- Run **all** Rails commands from `web-app/` (`cd web-app` first). Docs live at repo root under `docs/`.
- Lint with `bundle exec standardrb` (NOT rubocop); must be clean.
- Namespace `Services::BooksMigration::` (migrators) and `LegacyBooks::` (legacy models); tests mirror the namespace (`module Services; module BooksMigration; class …Test`).
- **No schema change.** `lists` and `list_items` already have every needed column.
- **Both migrators are `BulkUpsertMigrator` subclasses**, `record_timestamps?` = false (preserve legacy `created_at`/`updated_at`).
- **`status` symbol-remap** (the landmine): old `{unapproved:0, approved:1, active:2, rejected:3, inactive:4, pending:5}` → new `{unapproved:0, approved:1, rejected:2, active:3}`, via `{0=>0, 1=>1, 2=>3, 3=>2, 4=>0, 5=>0}`. **Raise** on any unmapped status (fail-loud).
- `raw_content ← raw_html`; `simplified_content ← formatted_text`; `items_json` **nil** (skip `books_json`).
- `list_items`: `listable = Books::Book` / `listable_id = book_id`; `metadata ← parse(pending_book_data)`; `verified = false`; **fail-loud** on a `book_id` with no migrated `Books::Book`.
- Each migrator carries ONE class-level doc comment (house style — every sibling migrator has one); no other code comments.

## File Structure

- **Create** `web-app/app/models/legacy_books/list.rb` — read-only legacy `lists` model.
- **Create** `web-app/app/lib/services/books_migration/list_migrator.rb` — the lists migrator (Task 1).
- **Create** `web-app/test/lib/services/books_migration/list_migrator_test.rb` (Task 1).
- **Create** `web-app/app/models/legacy_books/list_item.rb` — read-only legacy `list_items` model.
- **Create** `web-app/app/lib/services/books_migration/list_item_migrator.rb` — the list_items migrator (Task 2).
- **Create** `web-app/test/lib/services/books_migration/list_item_migrator_test.rb` (Task 2).
- **Modify** `web-app/lib/tasks/data_migration.rake` — `:lists` + `:list_items` tasks + `:all` insertion (Task 3).

---

## Task 1: `LegacyBooks::List` + `ListMigrator`

**Files:**
- Create: `web-app/app/models/legacy_books/list.rb`
- Create: `web-app/app/lib/services/books_migration/list_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/list_migrator_test.rb`

**Interfaces:**
- Consumes: `BulkUpsertMigrator` base (`call` → `{success:, data:{model:, count:}}`; hooks `legacy_model`/`model_key`/`target_model`/`unique_by`/`build_rows`/`record_timestamps?`); `List`/`Books::List` (target; `enum :status, {unapproved:0, approved:1, rejected:2, active:3}`).
- Produces: `Services::BooksMigration::ListMigrator.call`; `LegacyBooks::List` (`table_name = "lists"`).

- [ ] **Step 1: Create the read-only legacy model**

Create `web-app/app/models/legacy_books/list.rb`:

```ruby
module LegacyBooks
  class List < Record
    self.table_name = "lists"
  end
end
```

- [ ] **Step 2: Write the failing test file**

Create `web-app/test/lib/services/books_migration/list_migrator_test.rb`:

```ruby
require "test_helper"

module Services
  module BooksMigration
    class ListMigratorTest < ActiveSupport::TestCase
      setup do
        @user = users(:regular_user)
      end

      def run_migrator(rows)
        migrator = ListMigrator.new
        migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
        migrator.call
      end

      def legacy_row(overrides = {})
        {
          "id" => 990001,
          "name" => "Best Books",
          "description" => "desc",
          "source" => "example.com",
          "url" => "https://example.com/list",
          "status" => 2,
          "year_published" => 2020,
          "number_of_voters" => 100,
          "estimated_quality" => 5,
          "submitted_by_id" => @user.id,
          "high_quality_source" => true,
          "category_specific" => false,
          "location_specific" => nil,
          "yearly_award" => false,
          "voter_count_unknown" => nil,
          "voter_names_unknown" => nil,
          "raw_html" => "<ol><li>A</li></ol>",
          "formatted_text" => "A",
          "created_at" => Time.utc(2015, 1, 2, 3, 4, 5),
          "updated_at" => Time.utc(2016, 2, 3, 4, 5, 6)
        }.merge(overrides)
      end

      test "maps a legacy list to Books::List, preserving id" do
        result = run_migrator([legacy_row])

        assert result[:success], result[:error]
        assert_equal 1, result[:data][:count]
        assert_equal "Books::List", result[:data][:model]

        list = List.find(990001)
        assert_instance_of Books::List, list
        assert_equal "Best Books", list.name
        assert_equal "desc", list.description
        assert_equal "example.com", list.source
        assert_equal "https://example.com/list", list.url
        assert list.active?
        assert_equal 2020, list.year_published
        assert_equal 100, list.number_of_voters
        assert_equal 5, list.estimated_quality
        assert_equal @user, list.submitted_by
        assert_equal true, list.high_quality_source
        assert_equal false, list.category_specific
        assert_nil list.location_specific
        assert_equal "<ol><li>A</li></ol>", list.raw_content
        assert_equal "A", list.simplified_content
        assert_nil list.items_json
        assert_equal Time.utc(2015, 1, 2, 3, 4, 5), list.created_at
        assert_equal Time.utc(2016, 2, 3, 4, 5, 6), list.updated_at
      end

      test "remaps status by symbol" do
        expected = {0 => "unapproved", 1 => "approved", 2 => "active", 3 => "rejected", 4 => "unapproved", 5 => "unapproved"}
        expected.each_with_index do |(old, want), i|
          run_migrator([legacy_row("id" => 991000 + i, "status" => old)])
          assert_equal want, List.find(991000 + i).status, "old status #{old}"
        end
      end

      test "does not run auto_simplify_content (preserves legacy formatted_text)" do
        run_migrator([legacy_row("id" => 992001, "raw_html" => "<div><script>x</script>Hello</div>", "formatted_text" => "LEGACY")])

        assert_equal "LEGACY", List.find(992001).simplified_content
      end

      test "fails loud on an unmapped status" do
        result = run_migrator([legacy_row("id" => 993001, "status" => 9)])

        refute result[:success]
        assert_match(/993001/, result[:error])
      end

      test "is idempotent on id" do
        run_migrator([legacy_row("id" => 994001)])

        assert_no_difference -> { List.count } do
          run_migrator([legacy_row("id" => 994001, "name" => "Renamed")])
        end
        assert_equal "Renamed", List.find(994001).name
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/services/books_migration/list_migrator_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::BooksMigration::ListMigrator`.

- [ ] **Step 4: Implement the migrator**

Create `web-app/app/lib/services/books_migration/list_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `lists` -> STI Books::List, preserving id. Bulk upsert_all bypasses the List
    # callbacks — crucially before_save :auto_simplify_content, which would re-run the HTML
    # simplifier over raw_content and overwrite the legacy formatted_text we preserve as
    # simplified_content — and the validations. status is symbol-remapped (old/new enums
    # differ: active/rejected swap ints, inactive/pending collapse to unapproved).
    # raw_content <- raw_html, simplified_content <- formatted_text, items_json skipped
    # (nil; real items live in list_items). Legacy created_at/updated_at preserved.
    # Idempotent on id.
    class ListMigrator < BulkUpsertMigrator
      # old {unapproved:0, approved:1, active:2, rejected:3, inactive:4, pending:5}
      # new {unapproved:0, approved:1, rejected:2, active:3}
      STATUS_MAP = {0 => 0, 1 => 1, 2 => 3, 3 => 2, 4 => 0, 5 => 0}.freeze

      private

      def legacy_model
        LegacyBooks::List
      end

      def model_key
        "Books::List"
      end

      def target_model
        List
      end

      def unique_by
        :id
      end

      def record_timestamps?
        false
      end

      def build_rows(attrs)
        [{
          id: attrs["id"],
          type: "Books::List",
          name: attrs["name"],
          description: attrs["description"],
          source: attrs["source"],
          url: attrs["url"],
          status: remap_status(attrs["status"]),
          year_published: attrs["year_published"],
          number_of_voters: attrs["number_of_voters"],
          estimated_quality: attrs["estimated_quality"],
          submitted_by_id: attrs["submitted_by_id"],
          high_quality_source: attrs["high_quality_source"],
          category_specific: attrs["category_specific"],
          location_specific: attrs["location_specific"],
          yearly_award: attrs["yearly_award"],
          voter_count_unknown: attrs["voter_count_unknown"],
          voter_names_unknown: attrs["voter_names_unknown"],
          raw_content: attrs["raw_html"],
          simplified_content: attrs["formatted_text"],
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end

      def remap_status(old)
        STATUS_MAP.fetch(old) { raise "unmapped legacy lists.status=#{old.inspect}" }
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/services/books_migration/list_migrator_test.rb`
Expected: PASS — 5 runs, 0 failures, 0 errors.

- [ ] **Step 6: Lint**

Run: `cd web-app && bundle exec standardrb app/models/legacy_books/list.rb app/lib/services/books_migration/list_migrator.rb test/lib/services/books_migration/list_migrator_test.rb`
Expected: no offenses (autocorrect with `--fix` if needed, then re-run).

- [ ] **Step 7: Commit**

```bash
cd web-app && git add app/models/legacy_books/list.rb app/lib/services/books_migration/list_migrator.rb test/lib/services/books_migration/list_migrator_test.rb
git commit -m "Add ListMigrator (legacy lists -> Books::List)"
```

---

## Task 2: `LegacyBooks::ListItem` + `ListItemMigrator`

**Files:**
- Create: `web-app/app/models/legacy_books/list_item.rb`
- Create: `web-app/app/lib/services/books_migration/list_item_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/list_item_migrator_test.rb`

**Interfaces:**
- Consumes: `BulkUpsertMigrator` base (+ `preload_context` hook); `ListItem` (target; unique index `index_list_items_on_list_and_listable_unique` on `[list_id, listable_type, listable_id]`); `Books::Book`, `Books::List`.
- Produces: `Services::BooksMigration::ListItemMigrator.call`; `LegacyBooks::ListItem` (`table_name = "list_items"`).

- [ ] **Step 1: Create the read-only legacy model**

Create `web-app/app/models/legacy_books/list_item.rb`:

```ruby
module LegacyBooks
  class ListItem < Record
    self.table_name = "list_items"
  end
end
```

- [ ] **Step 2: Write the failing test file**

Create `web-app/test/lib/services/books_migration/list_item_migrator_test.rb`:

```ruby
require "test_helper"

module Services
  module BooksMigration
    class ListItemMigratorTest < ActiveSupport::TestCase
      setup do
        @list = Books::List.create!(name: "Item Parent List")
        @book = Books::Book.create!(title: "Item Book")
      end

      def run_migrator(rows)
        migrator = ListItemMigrator.new
        migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
        migrator.call
      end

      def legacy_row(overrides = {})
        {
          "id" => 8000001,
          "list_id" => @list.id,
          "book_id" => @book.id,
          "position" => 3,
          "pending_book_data" => nil,
          "created_at" => Time.utc(2018, 5, 6, 7, 8, 9),
          "updated_at" => Time.utc(2019, 6, 7, 8, 9, 10)
        }.merge(overrides)
      end

      test "maps a legacy list_item to a Books::Book listable" do
        result = run_migrator([legacy_row])

        assert result[:success], result[:error]
        assert_equal 1, result[:data][:count]
        assert_equal "ListItem", result[:data][:model]

        item = ListItem.find_by(list_id: @list.id, listable_type: "Books::Book", listable_id: @book.id)
        assert_not_nil item
        assert_equal @book, item.listable
        assert_equal 3, item.position
        assert_equal false, item.verified
        assert_nil item.metadata
        assert_equal Time.utc(2018, 5, 6, 7, 8, 9), item.created_at
        assert_equal Time.utc(2019, 6, 7, 8, 9, 10), item.updated_at
      end

      test "parses pending_book_data into metadata" do
        run_migrator([legacy_row("pending_book_data" => '{"title":"T","authors":"A"}')])

        item = ListItem.find_by(list_id: @list.id, listable_id: @book.id)
        assert_equal({"title" => "T", "authors" => "A"}, item.metadata)
      end

      test "null position and blank pending_book_data become nil" do
        run_migrator([legacy_row("position" => nil, "pending_book_data" => "")])

        item = ListItem.find_by(list_id: @list.id, listable_id: @book.id)
        assert_nil item.position
        assert_nil item.metadata
      end

      test "fails loud when the book is not migrated" do
        missing = Books::Book.maximum(:id).to_i + 999_999
        result = run_migrator([legacy_row("id" => 8000042, "book_id" => missing)])

        refute result[:success]
        assert_match(/8000042/, result[:error])
      end

      test "is idempotent on [list, listable]" do
        run_migrator([legacy_row])

        assert_no_difference -> { ListItem.count } do
          run_migrator([legacy_row("position" => 99)])
        end
        assert_equal 99, ListItem.find_by(list_id: @list.id, listable_id: @book.id).position
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/services/books_migration/list_item_migrator_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::BooksMigration::ListItemMigrator`.

- [ ] **Step 4: Implement the migrator**

Create `web-app/app/lib/services/books_migration/list_item_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `list_items` -> polymorphic list_items (listable = Books::Book), fresh id.
    # Bulk upsert on the natural-key unique index [list_id, listable_type, listable_id].
    # Every legacy row has a non-null book_id (no pending items), so there are no
    # NULL-in-unique-index rows and (since [list_id, book_id] is unique in the source) no
    # intra-batch ON CONFLICT double-touch. listable has no DB FK (polymorphic), so a
    # book_id with no migrated Books::Book is a fail-loud raise naming the legacy
    # list_item id (preloaded id set). metadata <- parsed pending_book_data (plain jsonb;
    # a raw string would store as a jsonb string scalar). verified defaults false. Legacy
    # created_at/updated_at preserved.
    class ListItemMigrator < BulkUpsertMigrator
      private

      def legacy_model
        LegacyBooks::ListItem
      end

      def model_key
        "ListItem"
      end

      def target_model
        ListItem
      end

      def unique_by
        :index_list_items_on_list_and_listable_unique
      end

      def record_timestamps?
        false
      end

      def preload_context
        @book_ids = Books::Book.pluck(:id).to_set
      end

      def build_rows(attrs)
        book_id = attrs["book_id"]
        unless @book_ids.include?(book_id)
          raise "no migrated Books::Book for legacy list_items.book_id=#{book_id.inspect} (list_item id=#{attrs["id"]})"
        end

        [{
          list_id: attrs["list_id"],
          listable_type: "Books::Book",
          listable_id: book_id,
          position: attrs["position"],
          metadata: parse_metadata(attrs["pending_book_data"]),
          verified: false,
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end

      def parse_metadata(value)
        return nil if value.blank?
        JSON.parse(value)
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/services/books_migration/list_item_migrator_test.rb`
Expected: PASS — 5 runs, 0 failures, 0 errors.

- [ ] **Step 6: Lint**

Run: `cd web-app && bundle exec standardrb app/models/legacy_books/list_item.rb app/lib/services/books_migration/list_item_migrator.rb test/lib/services/books_migration/list_item_migrator_test.rb`
Expected: no offenses (autocorrect with `--fix` if needed, then re-run).

- [ ] **Step 7: Commit**

```bash
cd web-app && git add app/models/legacy_books/list_item.rb app/lib/services/books_migration/list_item_migrator.rb test/lib/services/books_migration/list_item_migrator_test.rb
git commit -m "Add ListItemMigrator (legacy list_items -> list_items)"
```

---

## Task 3: Orchestration

**Files:**
- Modify: `web-app/lib/tasks/data_migration.rake`

**Interfaces:**
- Consumes: `ListMigrator` (Task 1), `ListItemMigrator` (Task 2).
- Produces: rake tasks `data_migration:lists`, `data_migration:list_items`; both appended to `data_migration:all`.

- [ ] **Step 1: Add the rake tasks**

In `web-app/lib/tasks/data_migration.rake`, add these two tasks after the `external_links` task (before the `all` task):

```ruby
  desc "Migrate legacy lists into Books::List (preserve id; status symbol-remap)"
  task lists: :environment do
    pp Services::BooksMigration::ListMigrator.call
  end

  desc "Migrate legacy list_items into list_items (listable = Books::Book; fresh id)"
  task list_items: :environment do
    pp Services::BooksMigration::ListItemMigrator.call
  end
```

- [ ] **Step 2: Append to the `:all` task**

Update the `:all` task list to end with `:lists, :list_items` (lists before list_items):

```ruby
  desc "Run all Phase-1 migrators in dependency order"
  task all: [:languages, :users, :authors, :books, :book_authors, :editions, :identifiers, :categories, :category_items, :external_links, :lists, :list_items]
```

- [ ] **Step 3: Verify the tasks are registered**

Run: `cd web-app && bin/rails -T data_migration`
Expected: the output lists `data_migration:lists` and `data_migration:list_items` with their descriptions.

- [ ] **Step 4: Lint**

Run: `cd web-app && bundle exec standardrb lib/tasks/data_migration.rake`
Expected: no offenses.

- [ ] **Step 5: Commit**

```bash
cd web-app && git add lib/tasks/data_migration.rake
git commit -m "Wire lists + list_items into the data_migration rake orchestrator"
```

---

## Final verification (controller-run against the real legacy DB, after all tasks)

Run by the controlling session (not a subagent). Reset dev DB to the migrated baseline first if needed.

- [ ] Run `cd web-app && bin/rails data_migration:lists` → `{success: true, data: {model: "Books::List", count: 1030}}`, then `data_migration:list_items` → `{success: true, data: {model: "ListItem", count: 65252}}`.
- [ ] `List.where(type: "Books::List").count == 1030`; ids 1–1,175 present; no collision with the reserved ≥10,001 app lists.
- [ ] `List.where(type: "Books::List").group(:status).count` → `{"unapproved" => 252, "approved" => 14, "rejected" => 5, "active" => 759}`.
- [ ] `simplified_content` present on 627 Books::Lists; `raw_content` present on 157; `items_json` null on all 1,030; legacy timestamps preserved.
- [ ] `ListItem.where(listable_type: "Books::Book").count == 65252`; 0 rows with a null/dangling `listable_id`; `metadata` present on 948; distinct `list_id` = 761.
- [ ] Idempotent: a second run of each task leaves both counts unchanged.
- [ ] Full suite green (`bin/rails test`); `bundle exec standardrb` and `bin/brakeman --no-pager` clean (0 new).

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-07-09-books-lists-migration-design.md`):
- D-write-lists (bulk, keyed on :id, bypass callbacks, preserve timestamps) → Task 1 Step 4 (`BulkUpsertMigrator`, `unique_by :id`, `record_timestamps? false`); idempotency + auto_simplify-bypass tests. ✓
- D-status (symbol-remap, raise on unmapped) → `STATUS_MAP` + `remap_status` (Task 1 Step 4); remap + fail-loud tests. ✓
- D-simplified (formatted_text) → `simplified_content ← formatted_text` (Step 4); auto_simplify-bypass test asserts "LEGACY". ✓
- D-items-json (nil) → items_json omitted from build_rows; mapping test asserts `assert_nil list.items_json`. ✓
- D-write-list-items (bulk on natural-key index) → Task 2 Step 4 (`unique_by :index_list_items_on_list_and_listable_unique`); idempotency test. ✓
- D-li-failloud (preload Books::Book ids, raise) → `preload_context` + guard (Task 2 Step 4); missing-book test asserts `/8000042/`. ✓
- D-metadata (parse pending_book_data) → `parse_metadata` (Step 4); metadata + blank tests. ✓
- D-no-finalize / no schema change → no `finalize`, no migration file. ✓
- Orchestration (`:lists` before `:list_items`, appended to `:all`) → Task 3. ✓

**Placeholder scan:** No TBD/TODO; every code step has complete code; every run step has an exact command + expected output. ✓

**Type consistency:** Both migrators return `{success:, data:{model:, count:}}` (inherited from `BulkUpsertMigrator#call`; tests assert `model` = `"Books::List"` / `"ListItem"`). `build_rows` returns an array of one row hash (matches `BulkUpsertMigrator#call` doing `build_rows(attrs).each`). `STATUS_MAP.fetch(old) { raise … }` — the raise is caught by the base per-row rescue, which re-raises naming `attrs["id"]`, then the outer rescue returns `{success: false}` (matches the fail-loud tests). `preload_context`/`unique_by`/`record_timestamps?`/`build_rows`/`legacy_model`/`model_key`/`target_model` are the exact hooks `BulkUpsertMigrator` calls. ✓
