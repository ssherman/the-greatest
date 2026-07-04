# Books Editions Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate legacy `editions` → `books_editions` (fresh id + `LegacyIdMap`, `book_binding` re-encoded by symbol) and set `default_edition_id` on the already-migrated books, on top of the Phase 1a/1b ETL framework.

**Architecture:** One more `Services::BooksMigration::Migrator` subclass reusing the base (batched read → pure `EditionTransformer` → idempotent upsert through the real `Books::Edition`, search suppressed). Editions take fresh auto ids; the `LegacyIdMap("Books::Edition")` is the dedup key (needed later by identifiers). `default_edition_id` is set in `finalize` by one set-based `UPDATE` (most-popular edition per book; editionless books stay NULL — no synthesis).

**Tech Stack:** Rails 8.1, PostgreSQL 17, Minitest + Mocha + fixtures, `Services::` migrators.

**Spec:** `docs/superpowers/specs/2026-07-04-books-editions-migration-design.md`.

## Global Constraints

- Run all commands from `/home/shane/dev/the-greatest/web-app`.
- Lint with `bundle exec standardrb` (NOT rubocop). Tests: `bin/rails test`.
- Legacy dev DB `the_greatest_books_legacy` on `localhost:6543`. Volume: `editions` 148,296; 38,668 of 126,204 books have ≥1 edition.
- **Fresh ids** (editions aren't URL-facing) — no `reset_pk_sequence!`. Idempotency via `LegacyIdMap("Books::Edition")`: `save!` + `LegacyIdMap.record` in a **per-row transaction**.
- Transformer is **PURE** (String-keyed hash in → symbol-keyed attrs out, no DB). `book_id` (direct passthrough — books preserve id) is set by the migrator; `language_id` has no legacy source (left nil).
- `book_binding`: re-encode **by symbol, never copy ints**. Unknown non-nil legacy value → **raise**; `nil` → `nil`.
- Write through the real `Books::Edition`: `edition_type` omitted (model default `:standard`); `metadata` is `jsonb NOT NULL`, so `nil` → `{}`.
- `default_edition_id`: set in `finalize` by one set-based SQL `UPDATE` — most-popular edition (`popularity DESC NULLS LAST, id ASC`), books-with-editions only; editionless books stay `NULL` (**no synthesis**). Raw SQL bypasses AR callbacks (no `SearchIndexRequest` flood; `finalize` runs outside `without_search_indexing`).
- Migrator tests are **connection-free**: stub `legacy_each` (Mocha `multiple_yields`); never open the legacy connection.
- SKIP (deferred/out of scope): identifiers (`ol_edition_id`, `identifiers`/`flat_identifiers` jsonb), `book_versions`, `language_id`, `description`, `last_refreshed`.
- Framework already on the branch base (`main`): `Services::BooksMigration::Migrator`, `LegacyBooks::Record`, `LegacyIdMap.record/lookup`, `without_search_indexing`, the language/author/book/book_author migrators, `data_migration:*` rake.

---

### Task 1: EditionTransformer (pure) + book_binding re-encoding

**Files:**
- Create: `web-app/app/lib/services/books_migration/edition_transformer.rb`
- Test: `web-app/test/lib/services/books_migration/edition_transformer_test.rb`

**Interfaces:**
- Produces: `EditionTransformer.call(attrs) -> {title:, publication_year:, popularity:, book_binding:, metadata:}` (pure, String-keyed hash in). `book_binding` is a NEW `Books::Edition` enum **symbol** (or nil). No `book_id`/`language_id`/`edition_type` keys emitted.

- [ ] **Step 1: Write the failing test**

`test/lib/services/books_migration/edition_transformer_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::EditionTransformerTest < ActiveSupport::TestCase
  def transform(overrides = {})
    Services::BooksMigration::EditionTransformer.call({
      "title" => "First Edition", "publication_year" => 1937,
      "popularity" => 42, "book_binding" => 1, "metadata" => {"src" => "x"}
    }.merge(overrides))
  end

  test "maps core fields directly" do
    attrs = transform
    assert_equal "First Edition", attrs[:title]
    assert_equal 1937, attrs[:publication_year]
    assert_equal 42, attrs[:popularity]
    assert_equal({"src" => "x"}, attrs[:metadata])
  end

  test "does not emit edition_type, book_id, or language_id" do
    attrs = transform
    refute attrs.key?(:edition_type)
    refute attrs.key?(:book_id)
    refute attrs.key?(:language_id)
  end

  test "re-encodes each legacy book_binding to the new symbol by name" do
    {0 => :paperback, 1 => :hardcover, 2 => :ebook, 3 => :audiobook,
     4 => :mass_market, 5 => :audiobook, 6 => :library_binding,
     7 => :other, 8 => :leather_bound, 9 => :other}.each do |legacy_int, new_sym|
      assert_equal new_sym, transform("book_binding" => legacy_int)[:book_binding],
        "legacy binding #{legacy_int} should map to #{new_sym}"
    end
  end

  test "nil book_binding stays nil" do
    assert_nil transform("book_binding" => nil)[:book_binding]
  end

  test "unknown book_binding raises" do
    assert_raises(RuntimeError) { transform("book_binding" => 99) }
  end

  test "nil metadata becomes an empty hash (column is NOT NULL)" do
    assert_equal({}, transform("metadata" => nil)[:metadata])
  end
end
```

- [ ] **Step 2: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/edition_transformer_test.rb`
Expected: FAIL — `uninitialized constant ...EditionTransformer`.

- [ ] **Step 3: Write the transformer**

`app/lib/services/books_migration/edition_transformer.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `editions` row -> new Books::Edition attributes. PURE (String-keyed
    # hash in -> symbol-keyed attrs out, no DB). `book_id` (direct passthrough)
    # and `language_id` (no legacy source) are handled by the migrator. `edition_type`
    # is omitted so the model default (:standard) applies. The legacy `book_binding`
    # integer is re-encoded to the NEW enum BY SYMBOL (never by int) — the old and
    # new enums assign different integers to the same names.
    class EditionTransformer
      # legacy book_binding int -> legacy symbol
      LEGACY_BINDING = {
        0 => :paperback, 1 => :hardcover, 2 => :ebook, 3 => :audible,
        4 => :mass_market_paperback, 5 => :audio, 6 => :library_binding,
        7 => :collectable, 8 => :leather_bound, 9 => :other
      }.freeze

      # legacy symbol -> new Books::Edition book_binding symbol
      BINDING_TO_NEW = {
        paperback: :paperback, hardcover: :hardcover, ebook: :ebook,
        audible: :audiobook, mass_market_paperback: :mass_market, audio: :audiobook,
        library_binding: :library_binding, collectable: :other,
        leather_bound: :leather_bound, other: :other
      }.freeze

      def self.call(attrs)
        {
          title: attrs["title"],
          publication_year: attrs["publication_year"],
          popularity: attrs["popularity"],
          book_binding: book_binding(attrs["book_binding"]),
          metadata: attrs["metadata"] || {}
        }
      end

      def self.book_binding(legacy_int)
        return nil if legacy_int.nil?
        legacy_sym = LEGACY_BINDING.fetch(legacy_int) do
          raise "unknown legacy book_binding: #{legacy_int.inspect}"
        end
        BINDING_TO_NEW.fetch(legacy_sym)
      end
      private_class_method :book_binding
    end
  end
end
```

- [ ] **Step 4: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/edition_transformer_test.rb`
Expected: PASS (6 runs).

- [ ] **Step 5: Lint + commit**

```bash
bundle exec standardrb --fix app/lib/services/books_migration/edition_transformer.rb test/lib/services/books_migration/edition_transformer_test.rb
git add app/lib/services/books_migration/edition_transformer.rb test/lib/services/books_migration/edition_transformer_test.rb
git commit -m "Add EditionTransformer (pure book_binding re-encoding)"
```

---

### Task 2: LegacyBooks::Edition + EditionMigrator (fresh id + map + default_edition_id)

**Files:**
- Create: `web-app/app/models/legacy_books/edition.rb`
- Create: `web-app/app/lib/services/books_migration/edition_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/edition_migrator_test.rb`

**Interfaces:**
- Consumes: `EditionTransformer.call`, `Migrator` base, `LegacyIdMap.record/lookup`, `Books::Edition`, `Books::Book`.
- Produces: `EditionMigrator` (fresh id; records `LegacyIdMap(model: "Books::Edition")`; `book_id` direct; `finalize` sets `default_edition_id`). Result shape `{success:, data: {model: "Books::Edition", count:}}`.

- [ ] **Step 1: Create the legacy model**

`app/models/legacy_books/edition.rb`:

```ruby
module LegacyBooks
  class Edition < Record
    self.table_name = "editions"
  end
end
```

- [ ] **Step 2: Write the failing migrator test**

`test/lib/services/books_migration/edition_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::EditionMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    migrator = Services::BooksMigration::EditionMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
    migrator.call
  end

  test "creates editions with fresh ids, records the id map, and sets book_id directly" do
    book = Books::Book.create!(title: "Edition Parent")

    result = run_migrator([
      {"id" => 5001, "book_id" => book.id, "title" => "HC", "publication_year" => 1990,
       "popularity" => 10, "book_binding" => 1, "metadata" => {"a" => 1}}
    ])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]
    assert_equal "Books::Edition", result[:data][:model]

    new_id = LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 5001)
    assert_not_nil new_id
    edition = Books::Edition.find(new_id)
    assert_equal book.id, edition.book_id
    assert_equal "HC", edition.title
    assert_equal 1990, edition.publication_year
    assert_equal "hardcover", edition.book_binding
    assert_equal "standard", edition.edition_type
    assert_equal({"a" => 1}, edition.metadata)
  end

  test "is idempotent: re-running updates in place without duplicating or remapping" do
    book = Books::Book.create!(title: "Idem Edition Parent")
    run_migrator([{"id" => 5002, "book_id" => book.id, "title" => "V1", "book_binding" => 0}])
    first_id = LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 5002)

    assert_no_difference -> { Books::Edition.count } do
      run_migrator([{"id" => 5002, "book_id" => book.id, "title" => "V2", "book_binding" => 0}])
    end
    assert_equal first_id, LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 5002)
    assert_equal "V2", Books::Edition.find(first_id).title
  end

  test "suppresses search indexing during the load" do
    book = Books::Book.create!(title: "Quiet Edition Parent")
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([{"id" => 5003, "book_id" => book.id, "title" => "Q", "book_binding" => nil}])
    end
  end

  test "finalize sets default_edition_id to the most-popular edition" do
    book = Books::Book.create!(title: "Popularity Parent")
    run_migrator([
      {"id" => 5004, "book_id" => book.id, "title" => "Low", "popularity" => 1, "book_binding" => 0},
      {"id" => 5005, "book_id" => book.id, "title" => "High", "popularity" => 99, "book_binding" => 0}
    ])
    high_id = LegacyIdMap.lookup(model: "Books::Edition", legacy_id: 5005)
    assert_equal high_id, book.reload.default_edition_id
  end

  test "a book with no editions keeps default_edition_id nil" do
    editionless = Books::Book.create!(title: "Editionless Parent")
    other = Books::Book.create!(title: "Has Edition")
    run_migrator([{"id" => 5006, "book_id" => other.id, "title" => "E", "book_binding" => 0}])
    assert_nil editionless.reload.default_edition_id
  end
end
```

- [ ] **Step 3: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/edition_migrator_test.rb`
Expected: FAIL — `uninitialized constant ...EditionMigrator`.

- [ ] **Step 4: Write the migrator**

`app/lib/services/books_migration/edition_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Fresh-id migrator: legacy editions -> books_editions. Editions aren't
    # URL-facing, so they take new auto ids; the LegacyIdMap ("Books::Edition")
    # is the dedup key (editions have no natural business key) and is needed by
    # the later identifiers pass. book_id is a direct passthrough (books preserve
    # their id). finalize back-references default_edition_id onto books_books.
    class EditionMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Edition
      end

      def model_key
        "Books::Edition"
      end

      def upsert_row(attrs)
        Books::Edition.transaction do
          new_id = LegacyIdMap.lookup(model: model_key, legacy_id: attrs["id"])
          edition = new_id ? Books::Edition.find(new_id) : Books::Edition.new
          edition.assign_attributes(EditionTransformer.call(attrs))
          edition.book_id = attrs["book_id"]
          edition.save!
          LegacyIdMap.record(model: model_key, legacy_id: attrs["id"], new_id: edition.id)
        end
      end

      # Set each book's default_edition_id to its most-popular edition (popularity
      # desc, nulls last, id asc), for books that have editions only. Set-based SQL
      # bypasses AR callbacks (no SearchIndexRequest flood — finalize runs OUTSIDE
      # the without_search_indexing block) and is idempotent. Editionless books
      # keep default_edition_id NULL (no synthesis).
      def finalize
        Books::Book.connection.execute(<<~SQL)
          UPDATE books_books b
          SET default_edition_id = e.id
          FROM (
            SELECT DISTINCT ON (book_id) id, book_id
            FROM books_editions
            ORDER BY book_id, popularity DESC NULLS LAST, id ASC
          ) e
          WHERE e.book_id = b.id
        SQL
      end
    end
  end
end
```

- [ ] **Step 5: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/edition_migrator_test.rb`
Expected: PASS (5 runs). Also run the whole migration suite to confirm no regression:
`bin/rails test test/lib/services/books_migration/`
Expected: all pass.

- [ ] **Step 6: Lint + commit**

```bash
bundle exec standardrb --fix app/models/legacy_books/edition.rb app/lib/services/books_migration/edition_migrator.rb test/lib/services/books_migration/edition_migrator_test.rb
git add app/models/legacy_books/edition.rb app/lib/services/books_migration/edition_migrator.rb test/lib/services/books_migration/edition_migrator_test.rb
git commit -m "Add editions migrator (fresh id + map + default_edition_id back-reference)"
```

---

### Task 3: Orchestrator wiring + end-to-end dev run

**Files:**
- Modify: `web-app/lib/tasks/data_migration.rake`

**Interfaces:**
- Consumes: `EditionMigrator`.
- Produces: `data_migration:editions`; `:all` runs `[:languages, :authors, :books, :book_authors, :editions]`.

- [ ] **Step 1: Add the task + update `:all`**

In `lib/tasks/data_migration.rake`, add after the `book_authors` task:

```ruby
  desc "Migrate legacy editions into books_editions (fresh ids + map; sets default_edition_id)"
  task editions: :environment do
    pp Services::BooksMigration::EditionMigrator.call
  end
```

and change the `:all` line to:

```ruby
  task all: [:languages, :authors, :books, :book_authors, :editions]
```

- [ ] **Step 2: Verify the tasks register**

Run: `bin/rails -T data_migration`
Expected: lists `languages`, `authors`, `books`, `book_authors`, `editions`, `all`.

- [ ] **Step 3: Commit**

```bash
git add lib/tasks/data_migration.rake
git commit -m "Wire editions into data_migration orchestrator"
```

- [ ] **Step 4: End-to-end dev run against the real legacy DB**

> `editions` (148k) writes via AR `save!`, so the run takes roughly 8–12 minutes. Books/authors/languages are already migrated in dev; run editions directly.

First, proactively scan for orphaned edition `book_id`s (a legacy edition whose book wasn't migrated would raise an FK error, named by the per-row error context):

```bash
bin/rails runner '
klass = Class.new(LegacyBooks::Record) { self.table_name = "editions" }
orphans = klass.where.not(book_id: nil).where.not(book_id: Books::Book.select(:id)).count
puts "orphan_edition_book_ids=#{orphans}"'
```
Expected: `orphan_edition_book_ids=0`. If non-zero, report the ids — the run will name the first offending edition, and it is idempotent/resumable.

Then run:
```bash
bin/rails data_migration:editions
bin/rails runner 'puts "editions=#{Books::Edition.count} edition_maps=#{LegacyIdMap.where(model: "Books::Edition").count} books_with_default=#{Books::Book.where.not(default_edition_id: nil).count} pending_book_index=#{SearchIndexRequest.where(parent_type: "Books::Book").count}"'
```
Expected: `editions` result `{success: true, ...}` `count: 148296`; then `editions=148296 edition_maps=148296 books_with_default=38668 pending_book_index=0`.

> If a run returns `{success: false, ...}`, the error names the offending legacy edition id and the count that succeeded — report it; the run is idempotent, so it resumes after the row is understood.

---

## Self-Review

**1. Spec coverage:**
- editions → books_editions, fresh id + `LegacyIdMap`, per-row transaction idempotency → Task 2. ✓
- `book_binding` re-encode by symbol, unknown→raise, nil→nil → Task 1. ✓
- field mapping (title/publication_year/popularity/metadata nil→{}, edition_type default, book_id direct, language_id nil) → Tasks 1+2. ✓
- `default_edition_id` set-based SQL, most-popular, editionless→NULL, no synthesis → Task 2 `finalize`. ✓
- search suppression (load suppressed; finalize bypasses callbacks) → Task 2. ✓
- orchestrator + e2e (+ orphan scan) → Task 3. ✓
- Skipped-by-design (identifiers, book_versions, language_id, description) — stated in Global Constraints. ✓

**2. Placeholder scan:** No TBD/TODO; complete code in every code step.

**3. Type consistency:** `EditionTransformer.call(attrs)` (String-keyed) → symbol-keyed hash, consistent Task 1↔2. `LegacyIdMap.record/lookup(model:, legacy_id:[, new_id:])` keyword signatures match Phase 1a. Subclass hooks (`legacy_model`, `model_key`, `upsert_row`, `finalize`) match the base contract. `model_key` == `"Books::Edition"` used consistently for both the result shape and the `LegacyIdMap` model key.
