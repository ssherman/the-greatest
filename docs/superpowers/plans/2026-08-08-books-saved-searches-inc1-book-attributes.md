# Books Saved Searches — Increment 1: Book Attributes & Category Backfill

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `Books::Book` the `book_length`, `page_range`, and `word_count` data that 1,069 legacy saved searches filter on, and backfill the four `book_type` categories so 909 more can be served without a `book_type` column.

**Architecture:** Three nullable columns are added to `books_books` and populated verbatim from the legacy database by a migrator that `UPDATE`s existing rows (every book already exists — this is the first migrator in the suite that updates rather than inserts). A pure `Books::BookLength` PORO ports legacy's derivation rules so new books get a length on write. A second migrator inserts 6,726 `category_items` rows linking every legacy-typed book to its equivalent category.

**Tech Stack:** Rails 8.1, PostgreSQL, Minitest + fixtures + Mocha, `Services::BooksMigration` migrator framework, `standardrb`.

**Spec:** `docs/superpowers/specs/2026-08-08-books-saved-searches-design.md` §4.

## Global Constraints

- Run **all** commands from `web-app/`.
- Use Rails generators for models/migrations — never hand-create them.
- Rails 8 enum syntax: `enum :name, {key: 0}` (colon prefix).
- **No code comments unless they explain a non-obvious *why*.** The migrator classes in this codebase carry a header comment explaining their decisions; follow that convention for the two new migrators, and add no inline comments elsewhere.
- Business logic lives in `app/lib/`, never `app/services/`.
- Lint with `bundle exec standardrb`, **never** `bin/rubocop`.
- Do **not** run `bin/brakeman`.
- Tests mirror the namespace: `Services::BooksMigration::FooTest`, `Books::FooTest`.
- **Never run a destructive DB command against development.** `ActiveRecord::FixtureSet.create_fixtures` truncates every table it names — read fixture YAML with `sed` instead.
- Inside `Services::BooksMigration`, a bare `Music::` resolves to `Services::Music`. Root-anchor constants (`::Books::Book`) in migrator code.
- Before any commit that finishes a task: `bin/rails test` and `bundle exec standardrb` must both pass.

## File Structure

| File | Responsibility |
|---|---|
| `db/migrate/<ts>_add_length_fields_to_books_books.rb` | Create the three columns |
| `app/lib/books/book_length.rb` | Pure derivation: page range / word count → length symbol |
| `test/lib/books/book_length_test.rb` | Table-driven tests for every rule and boundary |
| `app/models/books/book.rb` | `book_length` enum + write-time derivation |
| `test/models/books/book_test.rb` | Enum + derivation-on-write tests (existing file) |
| `app/lib/services/books_migration/book_attributes_migrator.rb` | Copy the three columns from legacy |
| `test/lib/services/books_migration/book_attributes_migrator_test.rb` | Migrator tests |
| `app/lib/services/books_migration/book_type_category_migrator.rb` | Backfill 6,726 category_items |
| `test/lib/services/books_migration/book_type_category_migrator_test.rb` | Migrator tests |
| `lib/tasks/data_migration.rake` | Two new rake tasks, plus the `:all` chain |

---

### Task 1: `Books::BookLength` derivation PORO

Pure function, no database. This is where legacy's two derivation rules are ported, and it is the highest-risk piece in the increment because the legacy method name is actively misleading.

**Files:**
- Create: `app/lib/books/book_length.rb`
- Test: `test/lib/books/book_length_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Books::BookLength.call(page_range:, word_count:) => Symbol | nil`, where the symbol is one of `:very_short, :short, :medium, :moderate, :long, :very_long`. Task 2 calls this from `Books::Book`.

**The rules, ported verbatim from legacy `app/models/book.rb`:**

Page range is tried first. If it yields a page count, word count is never consulted.

1. `nil` if the string contains **any** letter (`/[a-zA-Z]/`).
2. No `-` in the string: `to_i`; return it if `> 0`, else `nil`.
3. Otherwise split on `-`, `map(&:to_i)`; `nil` if **any** part is zero; else `((min + max) / 2.0).round`.

**⚠ Legacy names this `extract_max_pages` but it returns the MIDPOINT, not the max.** 66,783 of 85,211 legacy values are ranges, so treating it as a max mis-classifies most of the corpus.

Falling back to word count: `(word_count / 275.0).round` pages.

Thresholds (applied to whichever page count was produced):

| Pages | Length |
|---|---|
| 0–149 | `:very_short` |
| 150–250 | `:short` |
| 251–350 | `:medium` |
| 351–500 | `:moderate` |
| 501–1000 | `:long` |
| > 1000 | `:very_long` |

- [ ] **Step 1: Write the failing test**

Create `test/lib/books/book_length_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Books::BookLengthTest < ActiveSupport::TestCase
  # Legacy calls this "extract_max_pages" but it returns the MIDPOINT of the
  # range. Most legacy values are ranges, so this is the case that matters most.
  test "a hyphenated range resolves to the rounded midpoint, not the max" do
    # (200 + 400) / 2 = 300 -> medium. The max, 400, would be moderate.
    assert_equal :medium, Books::BookLength.call(page_range: "200-400", word_count: nil)
  end

  test "midpoint rounds half up" do
    # (100 + 201) / 2.0 = 150.5 -> 151 -> short
    assert_equal :short, Books::BookLength.call(page_range: "100-201", word_count: nil)
  end

  test "a bare positive number is used as-is" do
    assert_equal :medium, Books::BookLength.call(page_range: "300", word_count: nil)
  end

  test "any letter in the page range rejects it entirely" do
    assert_nil Books::BookLength.call(page_range: "300 pages", word_count: nil)
  end

  test "a letter in the page range does not fall through to word_count" do
    # Legacy's two callbacks are independent; page_range containing letters
    # leaves book_length blank rather than deferring to word_count.
    assert_nil Books::BookLength.call(page_range: "xii-300", word_count: 100_000)
  end

  test "a zero part in the range rejects it" do
    assert_nil Books::BookLength.call(page_range: "0-300", word_count: nil)
  end

  test "a non-numeric-but-letterless range rejects it" do
    assert_nil Books::BookLength.call(page_range: "--", word_count: nil)
  end

  test "a bare zero rejects it" do
    assert_nil Books::BookLength.call(page_range: "0", word_count: nil)
  end

  test "word_count is used when page_range is blank" do
    # 82_500 / 275.0 = 300 -> medium
    assert_equal :medium, Books::BookLength.call(page_range: nil, word_count: 82_500)
  end

  test "word_count is used when page_range is an empty string" do
    assert_equal :medium, Books::BookLength.call(page_range: "", word_count: 82_500)
  end

  test "returns nil when neither source is present" do
    assert_nil Books::BookLength.call(page_range: nil, word_count: nil)
  end

  test "maps every threshold band" do
    {
      100 => :very_short,
      149 => :very_short,
      150 => :short,
      250 => :short,
      251 => :medium,
      350 => :medium,
      351 => :moderate,
      500 => :moderate,
      501 => :long,
      1000 => :long,
      1001 => :very_long
    }.each do |pages, expected|
      assert_equal expected, Books::BookLength.call(page_range: pages.to_s, word_count: nil),
        "#{pages} pages should be #{expected}"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/books/book_length_test.rb`
Expected: FAIL with `NameError: uninitialized constant Books::BookLength`

- [ ] **Step 3: Write the implementation**

Create `app/lib/books/book_length.rb`:

```ruby
# frozen_string_literal: true

module Books
  # Ports the legacy site's two book_length derivation rules so books created
  # after the migration still get a length. page_range wins outright: legacy
  # runs the two rules in independent before_save callbacks, each guarded on
  # book_length being blank, so a page_range that fails to parse leaves the
  # length unset rather than falling through to word_count.
  class BookLength
    WORDS_PER_PAGE = 275.0

    def self.call(page_range:, word_count:)
      pages = pages_from_range(page_range)
      pages ||= (word_count / WORDS_PER_PAGE).round if page_range.blank? && word_count.present?
      return nil if pages.nil?

      band(pages)
    end

    # Legacy names this extract_max_pages, but a hyphenated range resolves to the
    # rounded MIDPOINT of its bounds, not the maximum.
    def self.pages_from_range(page_range)
      return nil if page_range.blank?
      return nil if page_range.match?(/[a-zA-Z]/)

      unless page_range.include?("-")
        number = page_range.to_i
        return number.positive? ? number : nil
      end

      numbers = page_range.split("-").map(&:to_i)
      return nil if numbers.empty? || numbers.any?(&:zero?)

      ((numbers.min + numbers.max) / 2.0).round
    end
    private_class_method :pages_from_range

    def self.band(pages)
      case pages
      when 0..149 then :very_short
      when 150..250 then :short
      when 251..350 then :medium
      when 351..500 then :moderate
      when 501..1000 then :long
      else :very_long
      end
    end
    private_class_method :band
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/books/book_length_test.rb`
Expected: PASS, 12 runs, 0 failures

- [ ] **Step 5: Lint**

Run: `bundle exec standardrb app/lib/books/book_length.rb test/lib/books/book_length_test.rb`
Expected: no offenses. If it reports any, run `bundle exec standardrb --fix` on those two paths and re-run the test.

- [ ] **Step 6: Commit**

```bash
git add app/lib/books/book_length.rb test/lib/books/book_length_test.rb
git commit -m "Port the legacy book_length derivation rules"
```

---

### Task 2: Columns and enum on `Books::Book`

**Files:**
- Create: `db/migrate/<timestamp>_add_length_fields_to_books_books.rb` (generated)
- Modify: `app/models/books/book.rb`
- Modify: `db/schema.rb` (generated by running the migration)
- Test: `test/models/books/book_test.rb` (existing file — append)

**Interfaces:**
- Consumes: `Books::BookLength.call(page_range:, word_count:)` from Task 1.
- Produces: `books_books.book_length` (integer, nullable), `books_books.page_range` (string, nullable), `books_books.word_count` (integer, nullable); `Books::Book` enum `book_length` with keys `very_short, short, medium, moderate, long, very_long` mapping to `0..5`. Tasks 3 and 5 write these columns; increment 2 indexes `book_length`.

All three columns are **nullable with no default**. Legacy's `book_type` used `default: 0`, which silently asserts a value for books nobody classified; these do not repeat that.

- [ ] **Step 1: Generate the migration**

Run:

```bash
bin/rails generate migration AddLengthFieldsToBooksBooks
```

- [ ] **Step 2: Write the migration body**

Replace the generated file's contents (keep the generated class name and timestamp):

```ruby
class AddLengthFieldsToBooksBooks < ActiveRecord::Migration[8.1]
  def change
    add_column :books_books, :book_length, :integer
    add_column :books_books, :page_range, :string
    add_column :books_books, :word_count, :integer
  end
end
```

No indexes: all filtering on these happens in OpenSearch (spec §4.3).

- [ ] **Step 3: Run the migration**

Run: `bin/rails db:migrate`
Expected: succeeds, and `db/schema.rb` gains the three columns on `books_books`.

Then prepare the test database: `bin/rails db:test:prepare`

- [ ] **Step 4: Write the failing model test**

Append to `test/models/books/book_test.rb`, inside the existing `Books::BookTest` class:

```ruby
  test "book_length enum maps the six legacy bands to 0..5" do
    assert_equal({
      "very_short" => 0, "short" => 1, "medium" => 2,
      "moderate" => 3, "long" => 4, "very_long" => 5
    }, Books::Book.book_lengths)
  end

  test "derives book_length from page_range on create" do
    book = Books::Book.create!(title: "Derived From Pages", page_range: "200-400")

    assert_equal "medium", book.book_length
  end

  test "derives book_length from word_count when page_range is absent" do
    book = Books::Book.create!(title: "Derived From Words", word_count: 82_500)

    assert_equal "medium", book.book_length
  end

  test "does not overwrite an explicitly set book_length" do
    book = Books::Book.create!(title: "Explicit Length", page_range: "200-400", book_length: :very_long)

    assert_equal "very_long", book.book_length
  end

  test "leaves book_length nil when neither source is present" do
    book = Books::Book.create!(title: "No Length Source")

    assert_nil book.book_length
  end

  test "re-derives book_length when page_range changes and length is blank" do
    book = Books::Book.create!(title: "Late Page Range")
    assert_nil book.book_length

    book.update!(page_range: "600-700")

    assert_equal "long", book.book_length
  end
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `bin/rails test test/models/books/book_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'book_lengths'`

- [ ] **Step 6: Add the enum and derivation to the model**

In `app/models/books/book.rb`, add the enum immediately below the existing `enum :book_kind, ...` line:

```ruby
  enum :book_length, {very_short: 0, short: 1, medium: 2, moderate: 3, long: 4, very_long: 5}
```

Add the callback alongside the existing `before_validation :normalize_title`:

```ruby
  before_validation :derive_book_length, if: -> { book_length.blank? }
```

And add the private method next to the existing `normalize_title`:

```ruby
  def derive_book_length
    self.book_length = Books::BookLength.call(page_range: page_range, word_count: word_count)
  end
```

The `book_length.blank?` guard mirrors legacy, where both derivation callbacks bail unless the length is unset — an explicitly chosen length is never overwritten.

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/books/book_test.rb`
Expected: PASS, 0 failures

- [ ] **Step 8: Run the full suite and lint**

Run: `bin/rails test && bundle exec standardrb`
Expected: both pass. The full suite matters here — `Books::Book` is widely used and a new always-on `before_validation` can surface elsewhere.

- [ ] **Step 9: Commit**

```bash
git add db/migrate db/schema.rb app/models/books/book.rb test/models/books/book_test.rb
git commit -m "Add book_length, page_range, and word_count to Books::Book"
```

---

### Task 3: `BookAttributesMigrator`

**Files:**
- Create: `app/lib/services/books_migration/book_attributes_migrator.rb`
- Test: `test/lib/services/books_migration/book_attributes_migrator_test.rb`

**Interfaces:**
- Consumes: the three columns from Task 2; `LegacyBooks::Book` (already exists, exposes `book_length`, `page_range`, `word_count`).
- Produces: `Services::BooksMigration::BookAttributesMigrator.call => {success:, data: {model:, count:}}`, matching every other migrator's return shape. Task 5 wires it into rake.

**Why this one is different from every other migrator in the suite:** every other migrator *inserts*; this one *updates* rows that already exist. It therefore cannot use `BulkUpsertMigrator` — `upsert_all` builds an `INSERT … ON CONFLICT` whose INSERT arm must satisfy `books_books`' `NOT NULL` `title` and `slug`, which a three-column attribute row does not carry. Instead it batches a single `UPDATE … FROM (VALUES …)` keyed on the preserved ids.

It extends `Migrator` (for `legacy_each`, the return shape, and search-index suppression) but overrides `call` to buffer rows, the same way `BulkUpsertMigrator` does.

- [ ] **Step 1: Write the failing test**

Create `test/lib/services/books_migration/book_attributes_migrator_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Services::BooksMigration::BookAttributesMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::BookAttributesMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def legacy_row(overrides = {})
    {
      "id" => @book.id,
      "book_length" => 2,
      "page_range" => "251-350",
      "word_count" => 90_000
    }.merge(overrides)
  end

  setup do
    @book = books_books(:war_and_peace)
    @book.update_columns(book_length: nil, page_range: nil, word_count: nil)
  end

  test "copies all three attributes onto the existing book" do
    result = run_migrator([legacy_row])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]
    assert_equal "Books::Book", result[:data][:model]

    @book.reload
    assert_equal "medium", @book.book_length
    assert_equal "251-350", @book.page_range
    assert_equal 90_000, @book.word_count
  end

  test "copies the legacy book_length verbatim rather than re-deriving it" do
    # 251-350 would derive to medium(2); legacy says long(4). Legacy wins, because
    # migrated searches must match legacy results exactly.
    run_migrator([legacy_row("book_length" => 4)])

    assert_equal "long", @book.reload.book_length
  end

  test "copies a null book_length even when a page_range is present" do
    # 1,136 legacy books have a source but no stored length. Re-deriving them
    # here would change what their saved searches return.
    run_migrator([legacy_row("book_length" => nil, "page_range" => "xii-300")])

    @book.reload
    assert_nil @book.book_length
    assert_equal "xii-300", @book.page_range
  end

  test "leaves other columns untouched" do
    title = @book.title
    run_migrator([legacy_row])

    assert_equal title, @book.reload.title
  end

  test "ignores a legacy book with no counterpart in the new database" do
    # The UPDATE simply matches no rows. It must not raise, and must not touch
    # any other book -- a WHERE clause bug here would silently rewrite the corpus.
    before = Books::Book.where.not(book_length: nil).count

    result = run_migrator([legacy_row("id" => 999_999_999)])

    assert result[:success], result[:error]
    assert_equal before, Books::Book.where.not(book_length: nil).count
    assert_nil @book.reload.book_length
  end

  test "is idempotent" do
    rows = [legacy_row]
    run_migrator(rows)
    result = run_migrator(rows)

    assert result[:success], result[:error]
    assert_equal "medium", @book.reload.book_length
  end

  test "does not queue search index requests" do
    SearchIndexRequest.delete_all
    run_migrator([legacy_row])

    assert_equal 0, SearchIndexRequest.count
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/book_attributes_migrator_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::BooksMigration::BookAttributesMigrator`

- [ ] **Step 3: Write the implementation**

Create `app/lib/services/books_migration/book_attributes_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Backfills book_length, page_range, and word_count onto already-migrated
    # books. Unlike every other migrator in this suite it UPDATEs rather than
    # inserts, so it cannot use BulkUpsertMigrator: upsert_all's INSERT arm would
    # have to satisfy books_books' NOT NULL title and slug, which a three-column
    # attribute row does not carry. A batched UPDATE ... FROM (VALUES ...) keyed
    # on the preserved ids does the same job in one statement per batch.
    #
    # book_length is copied verbatim, never re-derived: legacy's stored value is
    # what its saved searches were built against, including the 1,136 books whose
    # page_range never parsed and the 3 whose length came from neither source.
    class BookAttributesMigrator < Migrator
      UPDATE_BATCH = 1000

      def call
        @count = 0
        buffer = []
        Services::BooksMigration.without_search_indexing do
          legacy_each do |attrs|
            buffer << row_for(attrs)
            if buffer.size >= UPDATE_BATCH
              flush(buffer)
              buffer = []
            end
          rescue => e
            raise "#{model_key} migration failed at legacy id=#{attrs["id"]} (#{@count} rows updated): #{e.message}"
          end
          flush(buffer) if buffer.any?
        end
        {success: true, data: {model: model_key, count: @count}}
      rescue => e
        {success: false, error: e.message, data: {model: model_key, count: @count}}
      end

      private

      def legacy_model
        LegacyBooks::Book
      end

      def model_key
        "Books::Book"
      end

      def row_for(attrs)
        [attrs["id"], attrs["book_length"], attrs["page_range"], attrs["word_count"]]
      end

      def flush(rows)
        connection = ::Books::Book.connection
        values = rows.map do |id, book_length, page_range, word_count|
          "(#{connection.quote(id)}::bigint, " \
            "#{connection.quote(book_length)}::integer, " \
            "#{connection.quote(page_range)}::varchar, " \
            "#{connection.quote(word_count)}::integer)"
        end.join(", ")

        connection.execute(<<~SQL)
          UPDATE books_books
             SET book_length = v.book_length,
                 page_range  = v.page_range,
                 word_count  = v.word_count
            FROM (VALUES #{values}) AS v(id, book_length, page_range, word_count)
           WHERE books_books.id = v.id
        SQL

        @count += rows.size
      end
    end
  end
end
```

The explicit `::bigint` / `::integer` / `::varchar` casts on the first VALUES tuple are load-bearing: without them Postgres infers `text` for a `VALUES` list containing NULLs and the `SET` fails with a type mismatch.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/book_attributes_migrator_test.rb`
Expected: PASS, 7 runs, 0 failures

- [ ] **Step 5: Lint and run the full suite**

Run: `bin/rails test && bundle exec standardrb`
Expected: both pass.

- [ ] **Step 6: Commit**

```bash
git add app/lib/services/books_migration/book_attributes_migrator.rb \
        test/lib/services/books_migration/book_attributes_migrator_test.rb
git commit -m "Add BookAttributesMigrator for legacy book length fields"
```

---

### Task 4: `BookTypeCategoryMigrator`

**Files:**
- Create: `app/lib/services/books_migration/book_type_category_migrator.rb`
- Test: `test/lib/services/books_migration/book_type_category_migrator_test.rb`

**Interfaces:**
- Consumes: `LegacyBooks::Book` (exposes `book_type`); `LegacyIdMap` rows with `model: "Books::Category"`; `CategoryItem`.
- Produces: `Services::BooksMigration::BookTypeCategoryMigrator.call => {success:, data: {model:, count:}}`. Also `Services::BooksMigration::BookTypeCategoryMigrator::LEGACY_CATEGORY_IDS` — a frozen `{0 => 40348, 1 => 41013, 2 => 47008, 3 => 40876}` hash mapping legacy `book_type` to **legacy** category id. Increment 4's `BookAdvanced` needs the same mapping in *new* ids; it will resolve them through `LegacyIdMap` rather than hard-coding, so it does not consume this constant.

Legacy `book_type` values and their category targets:

| `book_type` | Legacy category id | Category | New id (dev) |
|---|---|---|---|
| 0 fiction | 40348 | Fiction | 2683 |
| 1 nonfiction | 41013 | Nonfiction | 3348 |
| 2 religious | 47008 | **Religion & Spirituality** | 9343 |
| 3 poetry | 40876 | Poetry | 3211 |

`religious` maps to the **Religion & Spirituality genre**, not the near-empty `Religious` subject category (9 items), which would retain 1 of 142 ranked books. See spec §4.2.

Legacy ids are used as the source of truth and remapped through `LegacyIdMap` at run time, because category ids were **not** preserved by the migration (73,913 map rows, zero identity mappings). Hard-coding new ids would break on any environment whose categories were migrated separately.

Expected production of ~6,726 new rows (3,260 Fiction + 3,218 Nonfiction + 139 Religion & Spirituality + 109 Poetry); the rest of the 126,204 typed books already carry their category, and the unique index makes those no-ops.

- [ ] **Step 1: Write the failing test**

Create `test/lib/services/books_migration/book_type_category_migrator_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Services::BooksMigration::BookTypeCategoryMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::BookTypeCategoryMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  # preload_context resolves ALL FOUR target categories up front and raises if any
  # is unmapped, so every test needs all four mapped -- not just the one it exercises.
  setup do
    @book = books_books(:war_and_peace)
    @categories = Services::BooksMigration::BookTypeCategoryMigrator::LEGACY_CATEGORY_IDS
      .each_with_object({}) do |(book_type, legacy_id), map|
        category = ::Books::Category.create!(name: "Type Target #{book_type}", category_type: :genre)
        LegacyIdMap.record(model: "Books::Category", legacy_id: legacy_id, new_id: category.id)
        map[book_type] = category
      end
    @fiction = @categories[0]
  end

  test "links a fiction book to the Fiction category" do
    result = run_migrator([{"id" => @book.id, "book_type" => 0}])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]
    assert_equal "CategoryItem", result[:data][:model]
    assert CategoryItem.exists?(
      category_id: @fiction.id, item_type: "Books::Book", item_id: @book.id
    )
  end

  test "skips a book whose book_type is null" do
    result = run_migrator([{"id" => @book.id, "book_type" => nil}])

    assert result[:success], result[:error]
    assert_equal 0, result[:data][:count]
  end

  test "is idempotent against an existing link" do
    CategoryItem.create!(category: @fiction, item: @book)
    result = run_migrator([{"id" => @book.id, "book_type" => 0}])

    assert result[:success], result[:error]
    assert_equal 1, CategoryItem.where(
      category_id: @fiction.id, item_type: "Books::Book", item_id: @book.id
    ).count
  end

  test "raises when any target category has no LegacyIdMap entry" do
    # Missing prerequisite: the categories migrator has not run. Failing loud
    # beats silently producing a success-looking low count. It raises before any
    # write, even for a book_type whose own category IS mapped.
    LegacyIdMap.where(model: "Books::Category", legacy_id: 40876).delete_all

    result = run_migrator([{"id" => @book.id, "book_type" => 0}])

    refute result[:success]
    assert_match(/LegacyIdMap for Books::Category legacy_id=40876/, result[:error])
    refute CategoryItem.exists?(category_id: @fiction.id, item_type: "Books::Book", item_id: @book.id)
  end

  test "recomputes item_count for the affected categories" do
    run_migrator([{"id" => @book.id, "book_type" => 0}])

    assert_equal 1, @fiction.reload.item_count
  end

  test "does not queue search index requests" do
    SearchIndexRequest.delete_all
    run_migrator([{"id" => @book.id, "book_type" => 0}])

    assert_equal 0, SearchIndexRequest.count
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/book_type_category_migrator_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::BooksMigration::BookTypeCategoryMigrator`

- [ ] **Step 3: Write the implementation**

Create `app/lib/services/books_migration/book_type_category_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy's book_type column (fiction/nonfiction/religious/poetry) has no new
    # column: the values are already category data, and saved searches resolve
    # book_type to a category at query time. This backfills the ~6,726 links that
    # are missing so that resolution retains ~100% of each type's books.
    #
    # religious maps to the "Religion & Spirituality" GENRE (legacy 47008), not the
    # near-empty "Religious" subject category, which holds 9 items against 1,899
    # typed books and would have retained 1 of 142 ranked ones.
    #
    # Legacy category ids are remapped through LegacyIdMap because the categories
    # table is shared across domains and its ids were NOT preserved.
    class BookTypeCategoryMigrator < BulkUpsertMigrator
      LEGACY_CATEGORY_IDS = {
        0 => 40348,  # Fiction
        1 => 41013,  # Nonfiction
        2 => 47008,  # Religion & Spirituality
        3 => 40876   # Poetry
      }.freeze

      private

      def legacy_model
        LegacyBooks::Book
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
        @category_ids = LEGACY_CATEGORY_IDS.transform_values do |legacy_id|
          LegacyIdMap.lookup(model: "Books::Category", legacy_id: legacy_id) ||
            raise("no LegacyIdMap for Books::Category legacy_id=#{legacy_id} (run the categories migrator first)")
        end
      end

      def build_rows(attrs)
        book_type = attrs["book_type"]
        return [] if book_type.nil?

        category_id = @category_ids[book_type]
        return [] if category_id.nil?

        [{category_id: category_id, item_type: "Books::Book", item_id: attrs["id"]}]
      end

      def finalize
        CategoryItem.connection.execute(<<~SQL)
          UPDATE categories c
          SET item_count = (SELECT COUNT(*) FROM category_items ci WHERE ci.category_id = c.id)
          WHERE c.id IN (#{@category_ids.values.join(", ")})
        SQL
      end
    end
  end
end
```

`preload_context` raises eagerly rather than per row, so a missing prerequisite fails before any write. `finalize` recomputes `item_count` in raw SQL because `upsert_all` bypasses the counter cache — the same reason `CategoryItemMigrator` does it, and it must stay callback-free because `finalize` runs outside `without_search_indexing`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/book_type_category_migrator_test.rb`
Expected: PASS, 6 runs, 0 failures

- [ ] **Step 5: Lint and run the full suite**

Run: `bin/rails test && bundle exec standardrb`
Expected: both pass.

- [ ] **Step 6: Commit**

```bash
git add app/lib/services/books_migration/book_type_category_migrator.rb \
        test/lib/services/books_migration/book_type_category_migrator_test.rb
git commit -m "Add BookTypeCategoryMigrator to backfill legacy book_type categories"
```

---

### Task 5: Rake wiring, dev data run, and schema annotations

**Files:**
- Modify: `lib/tasks/data_migration.rake`
- Modify: `app/models/books/book.rb` (annotaterb header only — regenerated, not hand-edited)

**Interfaces:**
- Consumes: both migrators from Tasks 3 and 4.
- Produces: `rake data_migration:book_attributes` and `rake data_migration:book_type_categories`. Nothing downstream consumes these.

- [ ] **Step 1: Add the rake tasks**

Append to the `namespace :data_migration` block in `lib/tasks/data_migration.rake`, immediately after the existing `book_countries` task:

```ruby
  desc "Backfill book_length, page_range, and word_count onto migrated books"
  task book_attributes: :environment do
    pp Services::BooksMigration::BookAttributesMigrator.call
  end

  desc "Backfill category links for legacy book_type (recomputes item_count)"
  task book_type_categories: :environment do
    pp Services::BooksMigration::BookTypeCategoryMigrator.call
  end
```

Then add both to the `:all` chain at the bottom of the same file (currently line 144). The two new names go **after `:category_items`**, because `BookTypeCategoryMigrator` depends on `LegacyIdMap` entries that the categories migrator creates and will raise without them:

```ruby
  task all: [:languages, :users, :authors, :books, :book_authors, :editions, :identifiers,
    :categories, :category_items, :book_attributes, :book_type_categories, :countries,
    :book_countries, :external_links, :lists, :list_items, :ranking_configurations,
    :ranked_lists, :penalties, :list_penalties, :user_lists, :user_list_items]
```

Preserve the existing single-line formatting if `standardrb` prefers it — run the linter after editing and accept its shape.

- [ ] **Step 2: Snapshot the development database**

The books data exists **only** in development and takes hours to rebuild. Snapshot before any bulk write.

Run: `bin/snapshot-dev-db.sh --label pre-book-attributes`
Expected: reports a snapshot written. If the script reports failure, **stop** and surface it — do not run the migrators.

- [ ] **Step 3: Capture the before-state**

Run:

```bash
bin/rails runner 'puts({book_length: Books::Book.where.not(book_length: nil).count, page_range: Books::Book.where.not(page_range: nil).count, word_count: Books::Book.where.not(word_count: nil).count, category_items: CategoryItem.where(item_type: "Books::Book").count}.inspect)'
```

Record the output. `category_items` is the figure the next step's delta is measured against.

- [ ] **Step 4: Run both migrators against development**

Run:

```bash
bin/rails data_migration:book_attributes
bin/rails data_migration:book_type_categories
```

Expected: both print `{success: true, ...}`. `book_attributes` reports a count of ~126,204 (every legacy book streamed, whether or not it had values). `book_type_categories` reports ~126,204 rows upserted — the count is rows *sent*, not rows *created*, because `upsert_all` no-ops on the unique index.

- [ ] **Step 5: Verify the exact counts**

Run:

```bash
bin/rails runner 'puts({book_length: Books::Book.where.not(book_length: nil).count, page_range: Books::Book.where.not(page_range: nil).count, word_count: Books::Book.where.not(word_count: nil).count}.inspect)'
```

Expected, matching the legacy source exactly:

| Column | Expected |
|---|---|
| `book_length` | 84,108 |
| `page_range` | 85,211 |
| `word_count` | 17,370 |

Then verify the category backfill delta:

```bash
bin/rails runner 'ids = Services::BooksMigration::BookTypeCategoryMigrator::LEGACY_CATEGORY_IDS.values.map { |l| LegacyIdMap.lookup(model: "Books::Category", legacy_id: l) }; puts Books::Category.where(id: ids).pluck(:id, :name, :item_count).inspect'
```

Expected: four rows, whose `item_count` values exceed their pre-run values by 3,260 (Fiction), 3,218 (Nonfiction), 139 (Religion & Spirituality), and 109 (Poetry) — **6,726 total**. Compare against the Step 3 `category_items` figure: it should have risen by 6,726.

**If any number is off, stop and report it rather than proceeding.** Restore with `bin/snapshot-dev-db.sh --restore` if the data needs resetting.

- [ ] **Step 6: Verify idempotency**

Run both tasks a second time:

```bash
bin/rails data_migration:book_attributes
bin/rails data_migration:book_type_categories
```

Then re-run the Step 5 verification. Expected: **identical** counts. Any change means a migrator is not idempotent.

- [ ] **Step 7: Refresh the schema annotations**

Books models are documented by their annotaterb schema header, not by a per-model file under `docs/` — the `Books::Country` increment set this precedent, and a missing header was a review finding there.

Run: `bundle exec rake annotate_rb:models`
Expected: the `# == Schema Information` header at the top of `app/models/books/book.rb` gains `book_length`, `page_range`, and `word_count`.

Then add a `why` comment directly above the enum in `app/models/books/book.rb`, since the transitional status of two of these columns is not visible from the schema:

```ruby
  # page_range and word_count are transitional. Page data belongs on the edition
  # (books_editions.page_count), but that column is empty for every book: legacy's
  # editions table carries no page or word counts, so the only source is these
  # work-level values. They exist to keep book_length derivable until a real
  # per-edition source arrives, and should go away when one does.
  enum :book_length, {very_short: 0, short: 1, medium: 2, moderate: 3, long: 4, very_long: 5}
```

Review the diff before staging — `annotate_rb:models` rewrites headers across **all** models, so if it touches files unrelated to this change, that is pre-existing drift. Commit those separately or discard them; do not bundle them into this task's commit.

- [ ] **Step 8: Run the full suite and lint**

Run: `bin/rails test && bundle exec standardrb`
Expected: both pass.

- [ ] **Step 9: Commit**

```bash
git add lib/tasks/data_migration.rake app/models/books/book.rb
git commit -m "Wire the book attribute migrators into the data_migration namespace"
```

---

## Done When

- [ ] `bin/rails test` passes with zero failures.
- [ ] `bundle exec standardrb` reports no offenses.
- [ ] Development data verified: 84,108 `book_length`, 85,211 `page_range`, 17,370 `word_count`, +6,726 `category_items`.
- [ ] Both migrators verified idempotent by a second run producing identical counts.
- [ ] `app/models/books/book.rb`'s annotaterb header lists the three columns, and a comment records why two of them are transitional.

**Not in this increment** (spec §12): the OpenSearch index fields (increment 2), the `SavedSearch` model and its migration (increment 3), the query layer (increment 4), and everything user-facing (increments 5–7). Nothing in this increment is visible to users.
