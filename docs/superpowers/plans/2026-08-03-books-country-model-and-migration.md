# Books Country Model & Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the `Books::Country` model and its join to `Books::Book`, and migrate the 253 legacy countries plus 126,007 `book_countries` links that the original books migration dropped.

**Architecture:** Two new books-namespaced tables (`books_countries`, `books_book_countries`) written by two new migrators in the established `Services::BooksMigration` style. `CountryMigrator` preserves legacy ids and pins slugs (the `/written-by/:slug/authors` URLs are indexed); `BookCountryMigrator` bulk-upserts the join with no id remapping at all, since both sides already preserve their ids, then recomputes `book_count` in raw SQL because `upsert_all` bypasses the counter_cache.

**Tech Stack:** Rails 8.1, PostgreSQL (array column + GIN index), FriendlyId, Minitest + Mocha + fixtures. Design spec: `docs/superpowers/specs/2026-08-03-books-filters-design.md` (this plan implements **increment 1 only**; increments 2–5 get their own plans).

## Global Constraints

- Run **all** commands from `web-app/`. Docs live in `docs/` at the **project root**, not `web-app/docs/`.
- Work on the current feature branch **`worktree-books-filters`** (never commit to `main`).
- Namespace all media code (`Books::`); tests mirror the namespace and directory (`module Books; class CountryTest`).
- **`Books.table_name_prefix` is `"books_"`**, so `bin/rails generate model Books::Country` produces the table `books_countries` automatically. Do **not** pass an explicit table name.
- **Generators:** use `bin/rails generate model` for `Books::Country` and `Books::BookCountry` — they need a real migration, test, and fixture. **Hand-create** everything under `app/models/legacy_books/` and `app/lib/services/books_migration/`; every existing file in those two directories is hand-written, and `rails g model` would wrongly add a primary-DB migration and fixture for a read-only replica.
- **Skinny models, fat services.** Migration services live in `app/lib/services/books_migration/` and subclass `Services::BooksMigration::Migrator` (or `BulkUpsertMigrator`), returning `{success: true, data: {model:, count:}}` or `{success: false, error:, data:}`.
- **Comments:** the project rule is no code comments — *except* that every file in `app/lib/services/books_migration/` carries a class-level header comment recording remaps and landmines. Match that established local pattern for the two new migrators; write no inline comments elsewhere.
- **Testing:** Minitest + Mocha + fixtures. 100% coverage of public methods; never test private methods. **No test legacy database exists or is required** — `LegacyBooks::Record` skips `connects_to` in test, so every migrator test stubs `legacy_each` with Mocha and never opens a legacy connection.
- **The development database is not disposable.** Books data exists only in dev and takes hours to rebuild. A `PreToolUse` hook hard-blocks destructive commands. Never run `ActiveRecord::FixtureSet.create_fixtures` (it TRUNCATES every table it names) — read fixture YAML directly instead.
- **Exact legacy volumes** (verified against the legacy DB on 2026-08-03): **253** countries, **126,007** `book_countries` rows, 126,003 books with exactly one country and 4 with two. Largest countries: American 42,289, Unknown 34,124, British 17,190, Japanese 3,960, French 3,620.
- `unknown` is migrated (fidelity — `/written-by/unknown/authors` may be indexed) but must be excluded from any filter UI via the `filterable` scope.
- **Gate before "done":** `bundle exec standardrb` and `bin/rails test` must both pass. The owner does **not** use brakeman — never run it. No new user-facing page in this increment → **no** Playwright E2E.
- Every git commit message ends with the trailer: `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

---

## File Structure

- `db/migrate/<ts>_create_books_countries.rb` — **new (generated, then rewritten).** The `books_countries` table: name, slug, description, `labels` string array, `book_count`.
- `app/models/books/country.rb` — **new (generated).** FriendlyId slugs, name validation, label scopes, the `filterable` scope. One responsibility: a country record and how you select sets of them.
- `test/fixtures/books/countries.yml` — **new (generated).**
- `test/models/books/country_test.rb` — **new (generated).**
- `db/migrate/<ts>_create_books_book_countries.rb` — **new (generated, then rewritten).** The join table with its unique index and both foreign keys.
- `app/models/books/book_country.rb` — **new (generated).** Two `belongs_to`s and the counter_cache. Nothing else.
- `test/fixtures/books/book_countries.yml` — **new (generated).**
- `test/models/books/book_country_test.rb` — **new (generated).**
- `app/models/books/book.rb` — **modify.** Add two association lines.
- `app/models/legacy_books/country.rb` — **new.** Read-only replica mapping for legacy `countries`.
- `app/models/legacy_books/book_country.rb` — **new.** Read-only replica mapping for legacy `book_countries`.
- `app/lib/services/books_migration/country_migrator.rb` — **new.** Preserved-id entity migrator. One responsibility: legacy country row → `Books::Country`.
- `test/lib/services/books_migration/country_migrator_test.rb` — **new.**
- `app/lib/services/books_migration/book_country_migrator.rb` — **new.** Bulk join migrator + `book_count` recompute.
- `test/lib/services/books_migration/book_country_migrator_test.rb` — **new.**
- `lib/tasks/data_migration.rake` — **modify.** Two new tasks, both added to `:all`.

No transformer classes. Every mapping here is a straight field copy with one `Array()` coercion; the existing `*Transformer` classes exist only where a migrator has real remapping to do (`ListMigrator`, `ExternalLinkMigrator`, and `PenaltyMigrator` likewise have none).

**Task order (dependencies):** Task 1 (`Books::Country`) → Task 2 (`Books::BookCountry`, consumes Task 1) → Task 3 (`CountryMigrator`, consumes Task 1) → Task 4 (`BookCountryMigrator`, consumes Tasks 2 and 3) → Task 5 (rake wiring + real data run, consumes Tasks 3 and 4).

---

### Task 1: `Books::Country` model and table

**Files:**
- Create: `db/migrate/<ts>_create_books_countries.rb`
- Create: `app/models/books/country.rb`
- Create: `test/fixtures/books/countries.yml`
- Test: `test/models/books/country_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Books::Country` with `name:string`, `slug:string`, `description:text`, `labels:string[]`, `book_count:integer`. Scopes `with_label(label)`, `without_label(label)`, `sorted_by_name`, `filterable`. FriendlyId `:slugged, :finders`, so `Books::Country.find("french")` resolves by slug. **No book associations yet** — Task 2 adds them.

- [ ] **Step 1: Generate the model**

```bash
bin/rails generate model Books::Country
```

This creates the migration, `app/models/books/country.rb`, `test/models/books/country_test.rb`, and `test/fixtures/books/countries.yml`. The generated migration is empty of columns; Step 2 rewrites it.

- [ ] **Step 2: Rewrite the generated migration**

Replace the generated file's contents (keep its timestamped filename):

```ruby
class CreateBooksCountries < ActiveRecord::Migration[8.1]
  def change
    create_table :books_countries do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      t.string :labels, array: true, null: false, default: []
      t.integer :book_count, null: false, default: 0

      t.timestamps
    end

    add_index :books_countries, :slug, unique: true
    add_index :books_countries, :labels, using: :gin
    add_index :books_countries, :book_count
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `bin/rails db:migrate`
Expected: creates `books_countries` and updates `db/schema.rb`. This is additive — it creates a new table and touches nothing existing.

- [ ] **Step 4: Write the fixtures**

Replace `test/fixtures/books/countries.yml` with:

```yaml
french:
  name: French
  slug: french
  labels: [western]
  book_count: 0

japanese:
  name: Japanese
  slug: japanese
  labels: [asian]
  book_count: 0

unknown:
  name: Unknown
  slug: unknown
  labels: []
  book_count: 0
```

- [ ] **Step 5: Write the failing test**

Replace `test/models/books/country_test.rb` with:

```ruby
require "test_helper"

module Books
  class CountryTest < ActiveSupport::TestCase
    test "requires a name" do
      country = Books::Country.new(name: nil)

      assert_not country.valid?
      assert_includes country.errors[:name], "can't be blank"
    end

    test "generates a slug from the name" do
      country = Books::Country.create!(name: "Sri Lankan")

      assert_equal "sri-lankan", country.slug
    end

    test "finds by slug" do
      assert_equal books_countries(:french), Books::Country.find("french")
    end

    test "with_label selects only countries carrying that label" do
      assert_equal [books_countries(:french)], Books::Country.with_label("western").to_a
    end

    test "without_label excludes countries carrying that label but keeps label-less ones" do
      results = Books::Country.without_label("western")

      assert_not_includes results, books_countries(:french)
      assert_includes results, books_countries(:japanese)
      assert_includes results, books_countries(:unknown)
    end

    test "filterable excludes the unknown bucket" do
      results = Books::Country.filterable

      assert_not_includes results, books_countries(:unknown)
      assert_includes results, books_countries(:french)
    end

    test "sorted_by_name orders alphabetically" do
      names = Books::Country.sorted_by_name.pluck(:name)

      assert_equal names.sort, names
    end
  end
end
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `bin/rails test test/models/books/country_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'with_label'` (the generated model is empty).

- [ ] **Step 7: Write the model**

Replace `app/models/books/country.rb` with:

```ruby
module Books
  class Country < ApplicationRecord
    extend FriendlyId
    friendly_id :name, use: [:slugged, :finders]

    validates :name, presence: true

    scope :with_label, ->(label) { where("labels @> ARRAY[?]::varchar[]", label) }
    scope :without_label, ->(label) {
      where.not("labels @> ARRAY[?]::varchar[]", label).or(where(labels: []))
    }
    scope :sorted_by_name, -> { order(:name) }
    scope :filterable, -> { where.not(slug: "unknown") }
  end
end
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `bin/rails test test/models/books/country_test.rb`
Expected: PASS, 7 runs, 0 failures.

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb --fix app/models/books/country.rb test/models/books/country_test.rb db/migrate/*_create_books_countries.rb
bundle exec standardrb
git add app/models/books/country.rb test/models/books/country_test.rb test/fixtures/books/countries.yml db/migrate/*_create_books_countries.rb db/schema.rb
git commit -m "Add Books::Country model and table

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `Books::BookCountry` join and book associations

**Files:**
- Create: `db/migrate/<ts>_create_books_book_countries.rb`
- Create: `app/models/books/book_country.rb`
- Create: `test/fixtures/books/book_countries.yml`
- Modify: `app/models/books/country.rb`
- Modify: `app/models/books/book.rb` (association block, around lines 49–72)
- Modify: `test/fixtures/books/countries.yml`
- Test: `test/models/books/book_country_test.rb`

**Interfaces:**
- Consumes: `Books::Country` from Task 1.
- Produces: `Books::BookCountry` with `book_id`, `country_id`, and `counter_cache: :book_count` on the country. `Books::Book#countries` and `Books::Country#books` both resolve through it. Unique index **`index_books_book_countries_on_book_id_and_country_id`** — Task 4 passes this exact name to `upsert_all`.

- [ ] **Step 1: Generate the model**

```bash
bin/rails generate model Books::BookCountry
```

- [ ] **Step 2: Rewrite the generated migration**

```ruby
class CreateBooksBookCountries < ActiveRecord::Migration[8.1]
  def change
    create_table :books_book_countries do |t|
      t.references :book, null: false, foreign_key: {to_table: :books_books}
      t.references :country, null: false, foreign_key: {to_table: :books_countries}

      t.timestamps
    end

    add_index :books_book_countries, [:book_id, :country_id], unique: true
  end
end
```

`t.references` already indexes `book_id` and `country_id` individually; the composite index above is the upsert key.

- [ ] **Step 3: Run the migration**

Run: `bin/rails db:migrate`
Expected: creates `books_book_countries`. Confirm the composite index is named `index_books_book_countries_on_book_id_and_country_id` in `db/schema.rb` — Task 4 references that literal name.

- [ ] **Step 4: Write the fixtures**

Replace `test/fixtures/books/book_countries.yml` with:

```yaml
war_and_peace_french:
  book: war_and_peace
  country: french

got_french:
  book: got
  country: french

of_mice_and_men_japanese:
  book: of_mice_and_men
  country: japanese
```

These reference existing labels in `test/fixtures/books/books.yml` (`war_and_peace`, `got`, `of_mice_and_men`). `book` and `country` are ordinary `belongs_to`s, **not** polymorphic — do not add a `(Books::Book)` type suffix.

Then update `test/fixtures/books/countries.yml` so `book_count` matches the fixtures above (fixture loading does not run counter_cache callbacks):

```yaml
french:
  name: French
  slug: french
  labels: [western]
  book_count: 2

japanese:
  name: Japanese
  slug: japanese
  labels: [asian]
  book_count: 1

unknown:
  name: Unknown
  slug: unknown
  labels: []
  book_count: 0
```

- [ ] **Step 5: Write the failing test**

Replace `test/models/books/book_country_test.rb` with:

```ruby
require "test_helper"

module Books
  class BookCountryTest < ActiveSupport::TestCase
    test "requires a book and a country" do
      link = Books::BookCountry.new

      assert_not link.valid?
      assert_includes link.errors[:book], "must exist"
      assert_includes link.errors[:country], "must exist"
    end

    test "a book reads its countries through the join" do
      assert_equal [books_countries(:french)], books_books(:war_and_peace).countries.to_a
    end

    test "a country reads its books through the join" do
      titles = books_countries(:french).books.pluck(:title).sort

      assert_equal [books_books(:got).title, books_books(:war_and_peace).title].sort, titles
    end

    test "creating a link increments the country book_count" do
      country = Books::Country.create!(name: "Peruvian")
      book = Books::Book.create!(title: "Counter Cache Probe")

      assert_difference -> { country.reload.book_count }, 1 do
        Books::BookCountry.create!(book: book, country: country)
      end
    end

    test "destroying a link decrements the country book_count" do
      country = Books::Country.create!(name: "Bolivian")
      book = Books::Book.create!(title: "Counter Cache Decrement Probe")
      link = Books::BookCountry.create!(book: book, country: country)

      assert_difference -> { country.reload.book_count }, -1 do
        link.destroy!
      end
    end

    test "the same book and country cannot be linked twice" do
      book = Books::Book.create!(title: "Duplicate Link Probe")
      country = Books::Country.create!(name: "Chilean")
      Books::BookCountry.create!(book: book, country: country)

      assert_raises ActiveRecord::RecordNotUnique do
        Books::BookCountry.create!(book: book, country: country)
      end
    end

    test "destroying a country destroys its links" do
      country = Books::Country.create!(name: "Ecuadorian")
      book = Books::Book.create!(title: "Dependent Destroy Probe")
      Books::BookCountry.create!(book: book, country: country)

      assert_difference -> { Books::BookCountry.count }, -1 do
        country.destroy!
      end
    end
  end
end
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `bin/rails test test/models/books/book_country_test.rb`
Expected: FAIL — the generated `Books::BookCountry` has no associations, so `must exist` errors are absent and `books_books(:war_and_peace).countries` raises `NoMethodError`.

- [ ] **Step 7: Write the join model**

Replace `app/models/books/book_country.rb` with:

```ruby
module Books
  class BookCountry < ApplicationRecord
    belongs_to :book, class_name: "Books::Book"
    belongs_to :country, class_name: "Books::Country", counter_cache: :book_count
  end
end
```

- [ ] **Step 8: Add the associations to `Books::Country`**

In `app/models/books/country.rb`, insert directly above `validates :name, presence: true`:

```ruby
    has_many :book_countries, class_name: "Books::BookCountry", dependent: :destroy
    has_many :books, through: :book_countries, class_name: "Books::Book"
```

- [ ] **Step 9: Add the associations to `Books::Book`**

In `app/models/books/book.rb`, in the association block (near the existing `has_many :category_items` / `has_many :categories` pair, currently around lines 61–62), add:

```ruby
  has_many :book_countries, class_name: "Books::BookCountry", dependent: :destroy
  has_many :countries, through: :book_countries, class_name: "Books::Country"
```

- [ ] **Step 10: Run the test to verify it passes**

Run: `bin/rails test test/models/books/book_country_test.rb`
Expected: PASS, 7 runs, 0 failures.

- [ ] **Step 11: Run the full model suite for regressions**

Run: `bin/rails test test/models/books/`
Expected: PASS. The new `book_count` values in `countries.yml` and the two new `Books::Book` associations must not disturb existing book tests.

- [ ] **Step 12: Lint and commit**

```bash
bundle exec standardrb --fix app/models/books test/models/books db/migrate/*_create_books_book_countries.rb
bundle exec standardrb
git add app/models/books db/migrate/*_create_books_book_countries.rb db/schema.rb test/models/books test/fixtures/books
git commit -m "Add Books::BookCountry join and book country associations

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `CountryMigrator`

**Files:**
- Create: `app/models/legacy_books/country.rb`
- Create: `app/lib/services/books_migration/country_migrator.rb`
- Test: `test/lib/services/books_migration/country_migrator_test.rb`

**Interfaces:**
- Consumes: `Books::Country` from Task 1.
- Produces: `Services::BooksMigration::CountryMigrator.call` → `{success: true, data: {model: "Books::Country", count: <n>}}`. Writes `Books::Country` rows at **legacy ids**, which Task 4 relies on to join without any id map.

- [ ] **Step 1: Write the legacy replica model**

Create `app/models/legacy_books/country.rb`:

```ruby
module LegacyBooks
  class Country < Record
    self.table_name = "countries"
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `test/lib/services/books_migration/country_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::CountryMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::CountryMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def legacy_row(overrides = {})
    {
      "id" => 9001,
      "name" => "Peruvian",
      "slug" => "peruvian",
      "description" => "Books of Peruvian origin.",
      "labels" => ["latin_american"],
      "book_count" => 312
    }.merge(overrides)
  end

  test "creates a country preserving the legacy id" do
    result = run_migrator([legacy_row])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]
    assert_equal "Books::Country", result[:data][:model]

    country = Books::Country.find(9001)
    assert_equal "Peruvian", country.name
    assert_equal "Books of Peruvian origin.", country.description
    assert_equal ["latin_american"], country.labels
  end

  test "preserves the legacy slug verbatim rather than regenerating it from the name" do
    result = run_migrator([legacy_row("name" => "United States", "slug" => "american")])

    assert result[:success], result[:error]
    assert_equal "american", Books::Country.find(9001).slug
  end

  test "maps nil labels to an empty array" do
    result = run_migrator([legacy_row("labels" => nil)])

    assert result[:success], result[:error]
    assert_equal [], Books::Country.find(9001).labels
  end

  test "leaves book_count at zero for BookCountryMigrator to recompute" do
    run_migrator([legacy_row])

    assert_equal 0, Books::Country.find(9001).book_count
  end

  test "is idempotent on id" do
    rows = [legacy_row]
    run_migrator(rows)

    assert_no_difference -> { Books::Country.count } do
      result = run_migrator(rows)
      assert result[:success], result[:error]
    end
  end

  test "updates an existing row on re-run rather than duplicating it" do
    run_migrator([legacy_row])
    run_migrator([legacy_row("name" => "Peruvian (revised)")])

    assert_equal "Peruvian (revised)", Books::Country.find(9001).name
  end

  test "resets the primary key sequence so later inserts do not collide" do
    run_migrator([legacy_row])

    assert_operator Books::Country.create!(name: "Sequence Probe").id, :>, 9001
  end

  test "reports failure with the legacy id when a row cannot be saved" do
    result = run_migrator([legacy_row("name" => nil)])

    assert_not result[:success]
    assert_match "legacy id=9001", result[:error]
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/country_migrator_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::BooksMigration::CountryMigrator`.

- [ ] **Step 4: Write the migrator**

Create `app/lib/services/books_migration/country_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Preserved-id migrator: books_countries is a brand-new books-only table that
    # nothing else writes to, so legacy country ids are kept verbatim and no
    # LegacyIdMap entry is needed — BookCountryMigrator joins on them directly.
    # The slug is pinned per-instance because FriendlyId would otherwise regenerate
    # it from name on insert, and /written-by/:slug/authors is an indexed URL.
    # labels is NOT NULL default [], so a nil legacy labels becomes []. book_count
    # is left at 0 here and recomputed by BookCountryMigrator#finalize, once the
    # links it counts actually exist. Resets the PK sequence after load so later
    # auto-inserts don't collide.
    class CountryMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Country
      end

      def model_key
        "Books::Country"
      end

      def upsert_row(attrs)
        country = Books::Country.find_or_initialize_by(id: attrs["id"])
        country.assign_attributes(
          name: attrs["name"],
          slug: attrs["slug"],
          description: attrs["description"],
          labels: Array(attrs["labels"])
        )
        def country.should_generate_new_friendly_id? = false
        country.save!
      end

      def finalize
        Books::Country.connection.reset_pk_sequence!("books_countries")
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/country_migrator_test.rb`
Expected: PASS, 8 runs, 0 failures.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/models/legacy_books/country.rb app/lib/services/books_migration/country_migrator.rb test/lib/services/books_migration/country_migrator_test.rb
bundle exec standardrb
git add app/models/legacy_books/country.rb app/lib/services/books_migration/country_migrator.rb test/lib/services/books_migration/country_migrator_test.rb
git commit -m "Add CountryMigrator for legacy countries

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `BookCountryMigrator`

**Files:**
- Create: `app/models/legacy_books/book_country.rb`
- Create: `app/lib/services/books_migration/book_country_migrator.rb`
- Test: `test/lib/services/books_migration/book_country_migrator_test.rb`

**Interfaces:**
- Consumes: `Books::BookCountry` and the unique index `index_books_book_countries_on_book_id_and_country_id` from Task 2; `Books::Country` rows at legacy ids from Task 3.
- Produces: `Services::BooksMigration::BookCountryMigrator.call` → `{success: true, data: {model: "Books::BookCountry", count: <n>}}`, with `books_countries.book_count` recomputed for every country.

- [ ] **Step 1: Write the legacy replica model**

Create `app/models/legacy_books/book_country.rb`:

```ruby
module LegacyBooks
  class BookCountry < Record
    self.table_name = "book_countries"
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `test/lib/services/books_migration/book_country_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::BookCountryMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::BookCountryMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  # CountryMigrator preserves legacy ids, so a migrated country simply exists at
  # its legacy id — there is no id map to seed.
  def make_country(legacy_id, name:)
    Books::Country.create!(id: legacy_id, name: name)
  end

  test "creates a join row for a migrated book and country" do
    country = make_country(9101, name: "Peruvian")
    book = Books::Book.create!(title: "Join Row Book")

    result = run_migrator([{"id" => 1, "book_id" => book.id, "country_id" => country.id}])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]
    assert_equal "Books::BookCountry", result[:data][:model]
    assert Books::BookCountry.exists?(book_id: book.id, country_id: country.id)
  end

  test "carries both countries across for a book that has two" do
    first = make_country(9102, name: "Russian")
    second = make_country(9103, name: "American")
    book = Books::Book.create!(title: "Dual Country Book")

    result = run_migrator([
      {"id" => 2, "book_id" => book.id, "country_id" => first.id},
      {"id" => 3, "book_id" => book.id, "country_id" => second.id}
    ])

    assert result[:success], result[:error]
    assert_equal [first, second].map(&:id).sort, book.reload.countries.pluck(:id).sort
  end

  test "is idempotent on the (book, country) key" do
    country = make_country(9104, name: "Chilean")
    book = Books::Book.create!(title: "Idempotent Join Book")
    rows = [{"id" => 4, "book_id" => book.id, "country_id" => country.id}]
    run_migrator(rows)

    assert_no_difference -> { Books::BookCountry.count } do
      result = run_migrator(rows)
      assert result[:success], result[:error]
    end
  end

  test "fails loud on a country id that was never migrated" do
    book = Books::Book.create!(title: "Dangling Country Book")

    result = run_migrator([{"id" => 5, "book_id" => book.id, "country_id" => 424242}])

    assert_not result[:success]
    assert_equal 0, Books::BookCountry.where(book_id: book.id).count
  end

  test "fails loud on a book id that was never migrated" do
    country = make_country(9105, name: "Bolivian")

    result = run_migrator([{"id" => 6, "book_id" => 424242, "country_id" => country.id}])

    assert_not result[:success]
    assert_equal 0, Books::BookCountry.where(country_id: country.id).count
  end

  test "finalize recomputes book_count for a populated country" do
    country = make_country(9106, name: "Ecuadorian")
    first = Books::Book.create!(title: "Count Book 1")
    second = Books::Book.create!(title: "Count Book 2")

    run_migrator([
      {"id" => 7, "book_id" => first.id, "country_id" => country.id},
      {"id" => 8, "book_id" => second.id, "country_id" => country.id}
    ])

    assert_equal 2, country.reload.book_count
  end

  test "finalize zeroes book_count for a country with no links" do
    country = make_country(9107, name: "Paraguayan")
    country.update_column(:book_count, 99)
    other = make_country(9108, name: "Uruguayan")
    book = Books::Book.create!(title: "Unrelated Count Book")

    run_migrator([{"id" => 9, "book_id" => book.id, "country_id" => other.id}])

    assert_equal 0, country.reload.book_count
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/book_country_migrator_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::BooksMigration::BookCountryMigrator`.

- [ ] **Step 4: Write the migrator**

Create `app/lib/services/books_migration/book_country_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Bulk join migrator: legacy book_countries -> books_book_countries. Both sides
    # already preserve their ids (books via BookMigrator, countries via
    # CountryMigrator), so there is no remapping at all and build_rows is a straight
    # field copy — the simplest migrator in the suite. A book_id or country_id with
    # no migrated row fails loud through the DB foreign key rather than dropping
    # silently to a success-looking low count, matching ExternalLinkMigrator.
    # finalize recomputes books_countries.book_count, which upsert_all bypasses
    # (counter_cache is a callback); it runs OUTSIDE without_search_indexing, so it
    # must stay raw SQL.
    class BookCountryMigrator < BulkUpsertMigrator
      private

      def legacy_model
        LegacyBooks::BookCountry
      end

      def model_key
        "Books::BookCountry"
      end

      def target_model
        Books::BookCountry
      end

      def unique_by
        :index_books_book_countries_on_book_id_and_country_id
      end

      def build_rows(attrs)
        [{book_id: attrs["book_id"], country_id: attrs["country_id"]}]
      end

      def finalize
        Books::BookCountry.connection.execute(<<~SQL)
          UPDATE books_countries c
          SET book_count = (
            SELECT COUNT(*) FROM books_book_countries bc WHERE bc.country_id = c.id
          )
        SQL
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/book_country_migrator_test.rb`
Expected: PASS, 7 runs, 0 failures.

- [ ] **Step 6: Run the full suite for regressions**

Run: `bin/rails test`
Expected: PASS, 0 failures. Compare the **runs count** against the pre-task baseline, not just the failure count — a collection-time error reports zero failures with no summary line.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/models/legacy_books/book_country.rb app/lib/services/books_migration/book_country_migrator.rb test/lib/services/books_migration/book_country_migrator_test.rb
bundle exec standardrb
git add app/models/legacy_books/book_country.rb app/lib/services/books_migration/book_country_migrator.rb test/lib/services/books_migration/book_country_migrator_test.rb
git commit -m "Add BookCountryMigrator for legacy book_countries

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Rake wiring and the real dev data run

**Files:**
- Modify: `lib/tasks/data_migration.rake`

**Interfaces:**
- Consumes: both migrators from Tasks 3 and 4.
- Produces: `data_migration:countries` and `data_migration:book_countries` rake tasks, both members of `data_migration:all`. After this task, the dev database holds the real country data every later increment queries.

- [ ] **Step 1: Add the two rake tasks**

In `lib/tasks/data_migration.rake`, directly after the existing `category_items` task:

```ruby
  desc "Migrate legacy countries into books_countries (preserves ids + slugs)"
  task countries: :environment do
    pp Services::BooksMigration::CountryMigrator.call
  end

  desc "Migrate legacy book_countries into books_book_countries (bulk upsert; recomputes book_count)"
  task book_countries: :environment do
    pp Services::BooksMigration::BookCountryMigrator.call
  end
```

- [ ] **Step 2: Add both to the `:all` chain**

In the same file, change the `task all:` line so `:countries, :book_countries` follow `:category_items`. Order matters: countries must run after `:books`, because the join's foreign key requires the books to exist.

```ruby
  desc "Run all Phase-1 migrators in dependency order"
  task all: [:languages, :users, :authors, :books, :book_authors, :editions, :identifiers, :categories, :category_items, :countries, :book_countries, :external_links, :lists, :list_items, :ranking_configurations, :ranked_lists, :penalties, :list_penalties, :user_lists, :user_list_items]
```

- [ ] **Step 3: Verify both tasks are registered**

Run: `bin/rails -T data_migration | grep countr`
Expected: both `data_migration:countries` and `data_migration:book_countries` are listed with their descriptions.

- [ ] **Step 4: Snapshot the development database**

```bash
bin/snapshot-dev-db.sh --label pre-countries
```

The books data exists **only** in dev and takes hours to rebuild. This turns any mistake in Step 5 into a ~1 minute restore (`bin/snapshot-dev-db.sh --restore`). Do not skip it.

- [ ] **Step 5: Run the countries migration**

Run: `bin/rails data_migration:countries`
Expected: `{success: true, data: {model: "Books::Country", count: 253}}`

- [ ] **Step 6: Run the book_countries migration**

Run: `bin/rails data_migration:book_countries`
Expected: `{success: true, data: {model: "Books::BookCountry", count: 126007}}`

- [ ] **Step 7: Verify the migrated data against the known legacy volumes**

```bash
bin/rails runner '
puts "countries:     #{Books::Country.count}          (expect 253)"
puts "links:         #{Books::BookCountry.count}      (expect 126007)"
puts "books linked:  #{Books::BookCountry.distinct.count(:book_id)} (expect 126003)"
puts "multi-country: #{Books::BookCountry.group(:book_id).having("count(*) > 1").count.size} (expect 4)"
puts "top 5: #{Books::Country.order(book_count: :desc).limit(5).pluck(:name, :book_count).inspect}"
puts "french slug:   #{Books::Country.find_by(slug: "french")&.name.inspect} (expect \"French\")"
puts "labels:        #{Books::Country.with_label("western").count} western"
'
```

Expected exactly:
- countries 253, links 126,007, books linked 126,003, multi-country 4
- top 5 = `[["American", 42289], ["Unknown", 34124], ["British", 17190], ["Japanese", 3960], ["French", 3620]]`
- french slug resolves to `"French"`

- [ ] **Step 8: Verify idempotency by re-running both**

```bash
bin/rails data_migration:countries
bin/rails data_migration:book_countries
bin/rails runner 'puts "#{Books::Country.count} / #{Books::BookCountry.count}"'
```

Expected: `253 / 126007` — unchanged. A second run must not duplicate anything.

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb
bin/rails test
git add lib/tasks/data_migration.rake
git commit -m "Wire country migrators into the data_migration rake namespace

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Production note

This increment has a deployment consequence the later ones do not. Production has no books data yet, so **the deploy does not carry these rows** — `data_migration:countries` and `data_migration:book_countries` must be run against production's legacy database at books cutover, like every other books migrator. The schema migrations ship with the deploy; the data does not.
