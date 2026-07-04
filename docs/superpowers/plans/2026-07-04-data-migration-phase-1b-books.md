# Data Migration Phase 1b — books + book_authors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate legacy `books` → `books_books` (preserved id, with the first real use of `legacy_id_maps` to remap the language FK) and legacy `book_authors` → `books_book_authors`, on top of the Phase 1a ETL framework.

**Architecture:** Two more `Services::BooksMigration::Migrator` subclasses reusing the Phase 1a base (batched read → pure `Transformer` → idempotent upsert through the real model, search suppressed). `books` preserves its legacy id and resolves `original_language_id` through `LegacyIdMap.lookup` (the impure FK remap lives in the migrator, keeping the transformer pure). `book_authors` upserts on its natural key `[book_id, author_id]`. Two Phase-1a deferrals come due here: per-row error context in the base `Migrator`, and guarding `Books::BookAuthor`'s direct-`SearchIndexRequest` reindex path.

**Tech Stack:** Rails 8.1, PostgreSQL 17, Minitest + Mocha + fixtures, `Services::` objects returning `{success:, data:/error:}`.

## Global Constraints

- Run all commands from `/home/shane/dev/the-greatest/web-app`.
- Lint with `bundle exec standardrb` (NOT rubocop). Tests: `bin/rails test`.
- Legacy dev DB `the_greatest_books_legacy` on `localhost:6543`. Volumes: `books` 126,204 (max id 141,785); `book_authors` 126,869.
- Preserved-id: `books` insert with the legacy `id` (books-only table, empty at real import via the planned DB reset) + `reset_pk_sequence!` after. `book_authors` gets fresh auto ids (not URL-facing); dedupe on `[book_id, author_id]`.
- Transformers are PURE (plain String-keyed hash in → symbol-keyed attrs hash out, no DB). FK remaps (language) happen in the migrator, not the transformer.
- Migrator tests are connection-free: stub `legacy_each` (Mocha `multiple_yields`); never open the legacy connection.
- Write through the real models (`Books::Book`, `Books::BookAuthor`) so FriendlyId slugs, `normalize_title`, and enum defaults apply. `Books::Book` requires `title` (presence); `alternate_titles` is `default: [], null: false` (never nil). `book_kind` defaults `:standalone` (omit from the transformer). `Books::BookAuthor.role` defaults `:author` (omit).
- SKIP this pass (later plans): editions/`default_edition_id`, identifiers (`goodreads_id`; `ol_work_id` is unused per owner), `book_type` (categories), series.
- Framework already on this branch: `Services::BooksMigration::Migrator`, `LegacyBooks::{Record,Language,Author}`, `LegacyIdMap.record/lookup`, `without_search_indexing`, the language/author migrators.

## File Structure

- `app/lib/services/books_migration/migrator.rb` — add per-row error context.
- `app/models/books/book_author.rb` — guard the reindex callback.
- `app/models/legacy_books/{book,book_author}.rb` — two thin legacy models.
- `app/lib/services/books_migration/{book,book_author}_transformer.rb` — pure transformers.
- `app/lib/services/books_migration/{book,book_author}_migrator.rb` — the two migrators.
- `lib/tasks/data_migration.rake` — add the two tasks + wire `:all`.

---

### Task 1: Per-row error context in the base Migrator

**Files:**
- Modify: `web-app/app/lib/services/books_migration/migrator.rb`
- Test: `web-app/test/lib/services/books_migration/migrator_test.rb`

**Interfaces:**
- Produces: on a per-row failure, `Migrator#call` returns `{success: false, error: "<model> migration failed at legacy id=<id> (<n> rows succeeded): <msg>", data: {model:, count:}}`. Success shape unchanged (`{success: true, data: {model:, count:}}`).

- [ ] **Step 1: Write the failing test**

`test/lib/services/books_migration/migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::MigratorTest < ActiveSupport::TestCase
  # Minimal test subclass: fails on the row whose legacy id is 2.
  class BoomMigrator < Services::BooksMigration::Migrator
    def model_key
      "Boom"
    end

    def upsert_row(attrs)
      raise "kaboom" if attrs["id"] == 2
    end
  end

  test "a per-row failure names the legacy id and how many succeeded" do
    migrator = BoomMigrator.new
    migrator.stubs(:legacy_each).multiple_yields([{"id" => 1}], [{"id" => 2}], [{"id" => 3}])

    result = migrator.call

    refute result[:success]
    assert_includes result[:error], "legacy id=2"
    assert_equal 1, result[:data][:count]
    assert_equal "Boom", result[:data][:model]
  end

  test "success still returns the processed count" do
    migrator = BoomMigrator.new
    migrator.stubs(:legacy_each).multiple_yields([{"id" => 1}], [{"id" => 3}])

    result = migrator.call

    assert result[:success]
    assert_equal 2, result[:data][:count]
  end
end
```

- [ ] **Step 2: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/migrator_test.rb`
Expected: FAIL — the error message lacks `legacy id=2` and the error result has no `data`.

- [ ] **Step 3: Add per-row rescue to `Migrator#call`**

Replace the `call` method in `app/lib/services/books_migration/migrator.rb` with:

```ruby
      def call
        @count = 0
        Services::BooksMigration.without_search_indexing do
          legacy_each do |attrs|
            upsert_row(attrs)
            @count += 1
          rescue => e
            raise "#{model_key} migration failed at legacy id=#{attrs["id"]} (#{@count} rows succeeded): #{e.message}"
          end
        end
        finalize
        {success: true, data: {model: model_key, count: @count}}
      rescue => e
        {success: false, error: e.message, data: {model: model_key, count: @count}}
      end
```

- [ ] **Step 4: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/migrator_test.rb`
Expected: PASS (2 runs). Also run the existing migrator suite to confirm no regression:
`bin/rails test test/lib/services/books_migration/`
Expected: all pass.

- [ ] **Step 5: Lint + commit**

```bash
bundle exec standardrb --fix app/lib/services/books_migration/migrator.rb test/lib/services/books_migration/migrator_test.rb
git add app/lib/services/books_migration/migrator.rb test/lib/services/books_migration/migrator_test.rb
git commit -m "Add per-row error context to migration Migrator base"
```

---

### Task 2: books migrator (preserved id + language FK remap)

**Files:**
- Create: `web-app/app/models/legacy_books/book.rb`
- Create: `web-app/app/lib/services/books_migration/book_transformer.rb`
- Create: `web-app/app/lib/services/books_migration/book_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/book_transformer_test.rb`
- Test: `web-app/test/lib/services/books_migration/book_migrator_test.rb`

**Interfaces:**
- Consumes: `LegacyIdMap.lookup(model:, legacy_id:)`, `Migrator` base, `Books::Book`.
- Produces: `BookTransformer.call(attrs) -> {title:, subtitle:, description:, first_published_year:, sort_title:, alternate_titles:}` (pure, no language). `BookMigrator` (preserves legacy id; sets `original_language_id` via `LegacyIdMap.lookup(model: "Language", ...)`; `finalize` resets the `books_books` sequence).

- [ ] **Step 1: Create the legacy model**

`app/models/legacy_books/book.rb`:

```ruby
module LegacyBooks
  class Book < Record
    self.table_name = "books"
  end
end
```

- [ ] **Step 2: Write the failing transformer test**

`test/lib/services/books_migration/book_transformer_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::BookTransformerTest < ActiveSupport::TestCase
  test "maps core fields and merges alternate titles" do
    attrs = Services::BooksMigration::BookTransformer.call(
      {"id" => 5, "title" => "The Hobbit", "sub_title" => "There and Back Again",
       "description" => "A tale", "first_year_published" => 1937, "sort_title" => "Hobbit, The",
       "alternate_titles" => ["Hobbit", ""], "alternate_title_1" => "The Hobbit or There and Back Again"}
    )
    assert_equal "The Hobbit", attrs[:title]
    assert_equal "There and Back Again", attrs[:subtitle]
    assert_equal "A tale", attrs[:description]
    assert_equal 1937, attrs[:first_published_year]
    assert_equal "Hobbit, The", attrs[:sort_title]
    assert_equal ["Hobbit", "The Hobbit or There and Back Again"], attrs[:alternate_titles]
  end

  test "alternate_titles is [] when legacy has none, and never includes original_language" do
    attrs = Services::BooksMigration::BookTransformer.call(
      {"id" => 6, "title" => "Beowulf", "alternate_titles" => nil, "alternate_title_1" => nil, "original_language_id" => 3}
    )
    assert_equal [], attrs[:alternate_titles]
    refute attrs.key?(:original_language_id)
  end
end
```

- [ ] **Step 3: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/book_transformer_test.rb`
Expected: FAIL (uninitialized constant `BookTransformer`).

- [ ] **Step 4: Write the transformer**

`app/lib/services/books_migration/book_transformer.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `books` row -> new Books::Book attributes. PURE: the language FK is
    # remapped by BookMigrator (needs a DB lookup), not here. `book_kind` is
    # omitted so the model default (:standalone) applies; `slug` is generated by
    # FriendlyId on save. `alternate_titles` is NOT NULL default [] in the new
    # schema, so it always resolves to an array (legacy `alternate_titles` array
    # plus the single `alternate_title_1`, blanks dropped, de-duplicated).
    class BookTransformer
      def self.call(attrs)
        {
          title: attrs["title"],
          subtitle: attrs["sub_title"],
          description: attrs["description"],
          first_published_year: attrs["first_year_published"],
          sort_title: attrs["sort_title"],
          alternate_titles: alternate_titles(attrs)
        }
      end

      def self.alternate_titles(attrs)
        (Array(attrs["alternate_titles"]) + [attrs["alternate_title_1"]]).compact_blank.uniq
      end
      private_class_method :alternate_titles
    end
  end
end
```

- [ ] **Step 5: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/book_transformer_test.rb`
Expected: PASS (2 runs).

- [ ] **Step 6: Write the failing migrator test**

`test/lib/services/books_migration/book_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::BookMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    migrator = Services::BooksMigration::BookMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
    migrator.call
  end

  test "creates books preserving id and remapping original_language_id via the id map" do
    language = Language.create!(name: "Old English")
    LegacyIdMap.record(model: "Language", legacy_id: 700, new_id: language.id)

    result = run_migrator([
      {"id" => 90001, "title" => "Legacy Book One", "sub_title" => "Sub", "first_year_published" => 1954,
       "original_language_id" => 700, "alternate_titles" => ["Alt One"], "alternate_title_1" => "Alt Two"},
      {"id" => 90002, "title" => "Legacy Book Two", "original_language_id" => nil,
       "alternate_titles" => nil, "alternate_title_1" => nil}
    ])

    assert result[:success], result[:error]
    assert_equal 2, result[:data][:count]

    b1 = Books::Book.find(90001)
    assert_equal "Legacy Book One", b1.title
    assert_equal "Sub", b1.subtitle
    assert_equal 1954, b1.first_published_year
    assert_equal language.id, b1.original_language_id
    assert_equal ["Alt One", "Alt Two"], b1.alternate_titles
    assert b1.slug.present?

    b2 = Books::Book.find(90002)
    assert_nil b2.original_language_id
    assert_equal [], b2.alternate_titles
  end

  test "suppresses search indexing during the load" do
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([{"id" => 90003, "title" => "Quiet Book", "original_language_id" => nil}])
    end
  end

  test "is idempotent: re-running does not duplicate or error" do
    rows = [{"id" => 90004, "title" => "Repeat Book", "original_language_id" => nil}]
    run_migrator(rows)
    assert_no_difference -> { Books::Book.count } do
      run_migrator(rows)
    end
  end

  test "resets the books_books sequence above the max migrated id" do
    run_migrator([{"id" => 90005, "title" => "Seq Probe Book", "original_language_id" => nil}])
    fresh = Books::Book.create!(title: "Post Migration Book")
    assert_operator fresh.id, :>, 90005
  end
end
```

- [ ] **Step 7: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/book_migrator_test.rb`
Expected: FAIL (uninitialized constant `BookMigrator`).

- [ ] **Step 8: Write the migrator**

`app/lib/services/books_migration/book_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Preserved-id migrator: books_books is a books-only table, so legacy book ids
    # are kept verbatim (book URLs). Writes through Books::Book (FriendlyId slug,
    # title normalization, book_kind default). Remaps original_language_id through
    # LegacyIdMap (languages migrate first) — the first real consumer of the map.
    # Resets the PK sequence after load.
    class BookMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Book
      end

      def model_key
        "Books::Book"
      end

      def upsert_row(attrs)
        book = Books::Book.find_or_initialize_by(id: attrs["id"])
        book.assign_attributes(BookTransformer.call(attrs))
        book.original_language_id = remap_language(attrs["original_language_id"])
        book.save!
      end

      def remap_language(legacy_language_id)
        return nil if legacy_language_id.nil?
        LegacyIdMap.lookup(model: "Language", legacy_id: legacy_language_id)
      end

      def finalize
        Books::Book.connection.reset_pk_sequence!("books_books")
      end
    end
  end
end
```

- [ ] **Step 9: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/book_migrator_test.rb`
Expected: PASS (4 runs).

- [ ] **Step 10: Lint + commit**

```bash
bundle exec standardrb --fix app/models/legacy_books/book.rb app/lib/services/books_migration/book_transformer.rb app/lib/services/books_migration/book_migrator.rb test/lib/services/books_migration/book_transformer_test.rb test/lib/services/books_migration/book_migrator_test.rb
git add app/models/legacy_books/book.rb app/lib/services/books_migration/book_transformer.rb app/lib/services/books_migration/book_migrator.rb test/lib/services/books_migration/book_transformer_test.rb test/lib/services/books_migration/book_migrator_test.rb
git commit -m "Add books migrator (preserved id + language FK remap)"
```

---

### Task 3: BookAuthor reindex guard + book_authors migrator

**Files:**
- Modify: `web-app/app/models/books/book_author.rb`
- Create: `web-app/app/models/legacy_books/book_author.rb`
- Create: `web-app/app/lib/services/books_migration/book_author_transformer.rb`
- Create: `web-app/app/lib/services/books_migration/book_author_migrator.rb`
- Test: `web-app/test/models/books/book_author_test.rb` (add cases)
- Test: `web-app/test/lib/services/books_migration/book_author_migrator_test.rb`

**Interfaces:**
- Consumes: `Migrator` base, `Books::BookAuthor`, `without_search_indexing`.
- Produces: `Books::BookAuthor#queue_book_for_reindexing` honors suppression. `BookAuthorTransformer.call(attrs) -> {position:}`. `BookAuthorMigrator` (natural key `[book_id, author_id]`, idempotent, no sequence reset).

- [ ] **Step 1: Guard the reindex callback**

In `app/models/books/book_author.rb`, add the suppression early-return to `queue_book_for_reindexing`:

```ruby
  def queue_book_for_reindexing
    return if Services::BooksMigration.search_indexing_suppressed?
    queue_reindex(book_id)
    queue_reindex(book_id_before_last_save) if saved_change_to_book_id?
  end
```

(Leave `queue_reindex` unchanged.)

- [ ] **Step 2: Write the failing guard tests**

Add to `test/models/books/book_author_test.rb` (inside the existing `class Books::BookAuthorTest`):

```ruby
  test "reindex is suppressed inside without_search_indexing" do
    author = Books::Author.create!(name: "Guard Author")
    book = Books::Book.create!(title: "Guard Book")
    assert_no_difference -> { SearchIndexRequest.count } do
      Services::BooksMigration.without_search_indexing do
        Books::BookAuthor.create!(book: book, author: author)
      end
    end
  end

  test "reindex still fires outside suppression" do
    author = Books::Author.create!(name: "Unguarded Author")
    book = Books::Book.create!(title: "Unguarded Book")
    assert_difference -> { SearchIndexRequest.where(parent_type: "Books::Book").count }, 1 do
      Books::BookAuthor.create!(book: book, author: author)
    end
  end
```

> If `test/models/books/book_author_test.rb` does not exist, create it with `require "test_helper"` and `class Books::BookAuthorTest < ActiveSupport::TestCase ... end` wrapping these two tests.

- [ ] **Step 3: Run them — verify the suppression test fails**

Run: `bin/rails test test/models/books/book_author_test.rb`
Expected: the "suppressed inside" test FAILS (a SearchIndexRequest is created because the guard isn't in place yet) — unless you already added Step 1; if Step 1 is in place it PASSES. (Write the test first, confirm RED by temporarily removing the guard line if needed, then keep the guard.)

- [ ] **Step 4: Confirm the guard tests pass**

Run: `bin/rails test test/models/books/book_author_test.rb`
Expected: PASS (both new tests, plus any pre-existing ones).

- [ ] **Step 5: Create the legacy model + transformer**

`app/models/legacy_books/book_author.rb`:

```ruby
module LegacyBooks
  class BookAuthor < Record
    self.table_name = "book_authors"
  end
end
```

`app/lib/services/books_migration/book_author_transformer.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `book_authors` row -> new Books::BookAuthor attributes. `role` is
    # omitted (model default :author); `credited_as` is not present in legacy.
    # book_id/author_id are the natural key, resolved by the migrator, not here.
    class BookAuthorTransformer
      def self.call(attrs)
        {position: attrs["position"]}
      end
    end
  end
end
```

- [ ] **Step 6: Write the failing migrator test**

`test/lib/services/books_migration/book_author_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::BookAuthorMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    migrator = Services::BooksMigration::BookAuthorMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
    migrator.call
  end

  test "creates book_authors on the natural key with no search flood" do
    author = Books::Author.create!(name: "Link Author")
    book = Books::Book.create!(title: "Link Book")

    assert_no_difference -> { SearchIndexRequest.count } do
      result = run_migrator([{"book_id" => book.id, "author_id" => author.id, "position" => 1}])
      assert result[:success], result[:error]
      assert_equal 1, result[:data][:count]
    end

    ba = Books::BookAuthor.find_by(book_id: book.id, author_id: author.id)
    assert_equal 1, ba.position
    assert_equal "author", ba.role
  end

  test "is idempotent on the [book_id, author_id] natural key" do
    author = Books::Author.create!(name: "Idem Author")
    book = Books::Book.create!(title: "Idem Book")
    rows = [{"book_id" => book.id, "author_id" => author.id, "position" => 2}]
    run_migrator(rows)
    assert_no_difference -> { Books::BookAuthor.count } do
      run_migrator(rows)
    end
  end
end
```

- [ ] **Step 7: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/book_author_migrator_test.rb`
Expected: FAIL (uninitialized constant `BookAuthorMigrator`).

- [ ] **Step 8: Write the migrator**

`app/lib/services/books_migration/book_author_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Join-table migrator: legacy book_authors -> books_book_authors. Both
    # book_id and author_id are preserved ids (books/authors migrate first), so
    # they map straight through. Idempotent on the [book_id, author_id] natural
    # key. Not URL-facing, so ids are fresh (no sequence reset needed).
    class BookAuthorMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::BookAuthor
      end

      def model_key
        "Books::BookAuthor"
      end

      def upsert_row(attrs)
        book_author = Books::BookAuthor.find_or_initialize_by(
          book_id: attrs["book_id"], author_id: attrs["author_id"]
        )
        book_author.assign_attributes(BookAuthorTransformer.call(attrs))
        book_author.save!
      end
    end
  end
end
```

- [ ] **Step 9: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/book_author_migrator_test.rb`
Expected: PASS (2 runs).

- [ ] **Step 10: Lint + commit**

```bash
bundle exec standardrb --fix app/models/books/book_author.rb app/models/legacy_books/book_author.rb app/lib/services/books_migration/book_author_transformer.rb app/lib/services/books_migration/book_author_migrator.rb test/models/books/book_author_test.rb test/lib/services/books_migration/book_author_migrator_test.rb
git add app/models/books/book_author.rb app/models/legacy_books/book_author.rb app/lib/services/books_migration/book_author_transformer.rb app/lib/services/books_migration/book_author_migrator.rb test/models/books/book_author_test.rb test/lib/services/books_migration/book_author_migrator_test.rb
git commit -m "Guard BookAuthor reindex + add book_authors migrator"
```

---

### Task 4: Orchestrator wiring + end-to-end dev run

**Files:**
- Modify: `web-app/lib/tasks/data_migration.rake`

**Interfaces:**
- Consumes: `BookMigrator`, `BookAuthorMigrator`.
- Produces: `data_migration:books`, `data_migration:book_authors`; `:all` runs `[:languages, :authors, :books, :book_authors]` in dependency order.

- [ ] **Step 1: Add the tasks + update `:all`**

Replace `lib/tasks/data_migration.rake` with:

```ruby
namespace :data_migration do
  desc "Migrate legacy languages (fresh ids + legacy_id_maps)"
  task languages: :environment do
    pp Services::BooksMigration::LanguageMigrator.call
  end

  desc "Migrate legacy authors into books_authors (preserves ids)"
  task authors: :environment do
    pp Services::BooksMigration::AuthorMigrator.call
  end

  desc "Migrate legacy books into books_books (preserves ids; remaps language)"
  task books: :environment do
    pp Services::BooksMigration::BookMigrator.call
  end

  desc "Migrate legacy book_authors into books_book_authors"
  task book_authors: :environment do
    pp Services::BooksMigration::BookAuthorMigrator.call
  end

  desc "Run all Phase-1 migrators in dependency order"
  task all: [:languages, :authors, :books, :book_authors]
end
```

- [ ] **Step 2: Verify the tasks register**

Run: `bin/rails -T data_migration`
Expected: lists `languages`, `authors`, `books`, `book_authors`, `all`.

- [ ] **Step 3: End-to-end dev run against the real legacy DB**

> `books` (126k) and `book_authors` (127k) each write via AR `save!`, so the full run takes roughly 10–15 minutes. Run books + book_authors (languages/authors are idempotent no-ops from Phase 1a; re-running `:all` is fine).

Run:
```bash
bin/rails data_migration:books
bin/rails data_migration:book_authors
bin/rails runner 'puts "books=#{Books::Book.count} book_max=#{Books::Book.maximum(:id)} book_authors=#{Books::BookAuthor.count} pending_book_index=#{SearchIndexRequest.where(parent_type: "Books::Book").count} books_with_lang=#{Books::Book.where.not(original_language_id: nil).count}"'
```
Expected: `books` result `{success: true, ...}` `count: 126204`; `book_authors` result `count: 126869`; then `books=126204 book_max=141785 book_authors=126869 pending_book_index=0 books_with_lang=<non-zero>` (language remap populated some rows, and search stayed suppressed). Then confirm the sequence reset:
```bash
bin/rails runner 'b = Books::Book.create!(title: "Post-migration Probe"); puts b.id > 141785; b.destroy'
```
Expected: prints `true`.

> If a run returns `{success: false, ...}`, the error now names the offending legacy id and the count that succeeded (Task 1) — report it; the run is idempotent, so it resumes after the row is understood.

- [ ] **Step 4: Commit**

```bash
git add lib/tasks/data_migration.rake
git commit -m "Wire books + book_authors into data_migration orchestrator"
```

---

## Self-Review

**1. Spec coverage** (design doc Books mapping + Phase 1b scope):
- books → books_books, preserve id, subtitle/first_published_year/sort_title/alternate_titles, language FK remap via id map, book_kind default, slug, sequence reset → Task 2. ✓
- book_authors → books_book_authors, natural key, position, role/credited_as defaults → Task 3. ✓
- Deferred #1 (guard BookAuthor direct reindex) → Task 3 Step 1. ✓
- Deferred #2 (per-row error context) → Task 1. ✓
- orchestrator dependency order → Task 4. ✓
- Skipped-by-design (editions/identifiers/book_type/series) — stated in Global Constraints. ✓

**2. Placeholder scan:** No TBD/TODO; complete code in every code step. The one conditional instruction (create `book_author_test.rb` if absent) carries the exact scaffold.

**3. Type consistency:** `Migrator#call` result shape (`{success:, data: {model:, count:}}` / error with `data`) consistent across Tasks 1/2/3/4. Transformer `.call(attrs)` (String-keyed) → symbol-keyed hash, pure, consistent (Book/BookAuthor). `LegacyIdMap.lookup(model:, legacy_id:)` keyword signature matches Task 2 usage. Subclass hooks (`legacy_model`, `model_key`, `upsert_row`, `finalize`) match the base contract for both new migrators. `Books::BookAuthor#queue_book_for_reindexing` guard uses the same `Services::BooksMigration.search_indexing_suppressed?` predicate defined in Phase 1a.
