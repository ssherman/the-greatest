# Books Identifiers Migration (work + author level) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Populate the polymorphic `identifiers` table with work-level and author-level external ids (goodreads + openlibrary) from four legacy sources, on top of the merged Phase 1a/1b + editions framework.

**Architecture:** A shared `IdentifierMigrator < Migrator` base holds two helpers — a pure `strip_openlibrary_key` and a private `upsert_identifier` (natural-key `find_or_create_by!`, skips blanks). Four thin concrete migrators (one per legacy source table) emit identifiers through it. Idempotency comes from the `Identifier` unique key — no `LegacyIdMap` for the identifiers themselves; only the 18 edition ids remap through `LegacyIdMap`.

**Tech Stack:** Rails 8.1, PostgreSQL 17, Minitest + Mocha + fixtures, `Services::` migrators.

**Spec:** `docs/superpowers/specs/2026-07-04-books-identifiers-migration-design.md`.

## Global Constraints

- Run all commands from `/home/shane/dev/the-greatest/web-app`. Lint `bundle exec standardrb` (NOT rubocop). Tests `bin/rails test`.
- Legacy volumes: `book_identifiers` 421,698 (type-5 goodreads 154,524); `books.ol_work_id` 31,602 + `books.goodreads_id` 3,406; `authors.ol_author_id` 16,542; `editions.ol_edition_id` 18.
- **Idempotency via the natural key:** `Identifier` is unique on `(identifiable_type, identifier_type, value, identifiable_id)`; every row is a `find_or_create_by!` on that key. **No `LegacyIdMap` for identifiers.** Only editions remap their id through `LegacyIdMap.lookup(model: "Books::Edition", legacy_id:)` (editions have fresh ids; books/authors are preserved so their `identifiable_id` is the legacy id directly).
- **OpenLibrary values** stored as the bare key: `strip_openlibrary_key(v)` = basename after the last `/` (`/works/OL20600W` → `OL20600W`), blank→nil. **Goodreads** stored verbatim (bare numeric). Nil/blank source values are skipped.
- `book_identifiers`: migrate **only** `identifier_type == 5` (goodreads) this pass; types 1-4 (ISBN/ASIN/EAN) are deferred.
- Write through the real `Identifier`. It has no callbacks and no `touch:` on its polymorphic `belongs_to`, so creating identifiers has **no** search impact; the base still wraps the load in `without_search_indexing`.
- Migrator tests are **connection-free**: stub `legacy_each` (Mocha `multiple_yields`); never open the legacy connection.
- SKIP (deferred follow-up): `book_identifiers` types 1-4 + `editions.flat_identifiers` (edition-level ISBN placement).
- Framework on the branch base (`main`): `Services::BooksMigration::Migrator`, `LegacyBooks::{Record,Book,Author,Edition}`, `LegacyIdMap`, `without_search_indexing`, `data_migration:*` rake. The `Identifier` enum values used here: `books_work_openlibrary_id: 2`, `books_work_goodreads_id: 3`, `books_edition_openlibrary_id: 16`, `books_author_openlibrary_id: 33`.

---

### Task 1: Shared `IdentifierMigrator` base + `strip_openlibrary_key`

**Files:**
- Create: `web-app/app/lib/services/books_migration/identifier_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/identifier_migrator_test.rb`

**Interfaces:**
- Produces: `IdentifierMigrator < Migrator`. Public class method `IdentifierMigrator.strip_openlibrary_key(value) -> String|nil` (pure). Private instance helper `upsert_identifier(identifiable_type:, identifiable_id:, identifier_type:, value:)` (skips nil/blank `value` or nil `identifiable_id`; `find_or_create_by!` on the natural key). Concrete migrators subclass this.

- [ ] **Step 1: Write the failing test**

`test/lib/services/books_migration/identifier_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::IdentifierMigratorTest < ActiveSupport::TestCase
  M = Services::BooksMigration::IdentifierMigrator

  test "strip_openlibrary_key reduces an OL path to the bare key" do
    assert_equal "OL20600W", M.strip_openlibrary_key("/works/OL20600W")
    assert_equal "OL9100206A", M.strip_openlibrary_key("/authors/OL9100206A")
    assert_equal "OL25955852M", M.strip_openlibrary_key("/books/OL25955852M")
  end

  test "strip_openlibrary_key passes through a bare key and maps blank/nil to nil" do
    assert_equal "OL20600W", M.strip_openlibrary_key("OL20600W")
    assert_nil M.strip_openlibrary_key(nil)
    assert_nil M.strip_openlibrary_key("")
  end
end
```

- [ ] **Step 2: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/identifier_migrator_test.rb`
Expected: FAIL — `uninitialized constant ...IdentifierMigrator`.

- [ ] **Step 3: Write the base**

`app/lib/services/books_migration/identifier_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Shared base for the identifier migrators. Identifiers dedupe on their natural
    # unique key (identifiable_type, identifier_type, value, identifiable_id), so
    # there is NO LegacyIdMap for identifiers themselves — upsert_identifier is a
    # find_or_create_by! on that key that skips blank values.
    class IdentifierMigrator < Migrator
      # Pure: reduce a legacy OpenLibrary path ("/works/OL20600W") to its bare
      # canonical key ("OL20600W"). The identifier_type already encodes the level,
      # so the "/works/" etc. prefix is redundant.
      def self.strip_openlibrary_key(value)
        value.to_s.rpartition("/").last.presence
      end

      private

      def upsert_identifier(identifiable_type:, identifiable_id:, identifier_type:, value:)
        return if value.blank? || identifiable_id.nil?
        Identifier.find_or_create_by!(
          identifiable_type: identifiable_type,
          identifiable_id: identifiable_id,
          identifier_type: identifier_type,
          value: value
        )
      end
    end
  end
end
```

- [ ] **Step 4: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/identifier_migrator_test.rb`
Expected: PASS (2 runs). (`upsert_identifier` is a private helper exercised by the concrete-migrator tests in later tasks.)

- [ ] **Step 5: Lint + commit**

```bash
bundle exec standardrb --fix app/lib/services/books_migration/identifier_migrator.rb test/lib/services/books_migration/identifier_migrator_test.rb
git add app/lib/services/books_migration/identifier_migrator.rb test/lib/services/books_migration/identifier_migrator_test.rb
git commit -m "Add IdentifierMigrator base (strip_openlibrary_key + upsert_identifier)"
```

---

### Task 2: LegacyBooks::BookIdentifier + BookIdentifierMigrator (goodreads type-5)

**Files:**
- Create: `web-app/app/models/legacy_books/book_identifier.rb`
- Create: `web-app/app/lib/services/books_migration/book_identifier_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/book_identifier_migrator_test.rb`

**Interfaces:**
- Consumes: `IdentifierMigrator` base, `Identifier`, `Books::Book`.
- Produces: `BookIdentifierMigrator` — reads legacy `book_identifiers`, creates `books_work_goodreads_id` on `Books::Book` (id = `book_id`) for `identifier_type == 5` rows only.

- [ ] **Step 1: Create the legacy model**

`app/models/legacy_books/book_identifier.rb`:

```ruby
module LegacyBooks
  class BookIdentifier < Record
    self.table_name = "book_identifiers"
  end
end
```

- [ ] **Step 2: Write the failing migrator test**

`test/lib/services/books_migration/book_identifier_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::BookIdentifierMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::BookIdentifierMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "migrates goodreads (type 5) as a work-level goodreads id on the book" do
    book = Books::Book.create!(title: "GR Book")
    result = run_migrator([{"id" => 1, "book_id" => book.id, "identifier_type" => 5, "identifier" => "1079398"}])
    assert result[:success], result[:error]
    idf = Identifier.find_by(identifiable: book)
    assert_equal "books_work_goodreads_id", idf.identifier_type
    assert_equal "1079398", idf.value
  end

  test "ignores non-goodreads types (isbn/asin/ean deferred)" do
    book = Books::Book.create!(title: "ISBN Book")
    assert_no_difference -> { Identifier.count } do
      run_migrator([
        {"id" => 2, "book_id" => book.id, "identifier_type" => 1, "identifier" => "0375755349"},
        {"id" => 3, "book_id" => book.id, "identifier_type" => 2, "identifier" => "9780375755347"},
        {"id" => 4, "book_id" => book.id, "identifier_type" => 3, "identifier" => "B01K0T9772"}
      ])
    end
  end

  test "is idempotent on the natural key" do
    book = Books::Book.create!(title: "Idem GR Book")
    rows = [{"id" => 5, "book_id" => book.id, "identifier_type" => 5, "identifier" => "5527"}]
    run_migrator(rows)
    assert_no_difference -> { Identifier.count } do
      run_migrator(rows)
    end
  end

  test "suppresses search indexing during the load" do
    book = Books::Book.create!(title: "Quiet GR Book")
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([{"id" => 6, "book_id" => book.id, "identifier_type" => 5, "identifier" => "42"}])
    end
  end
end
```

- [ ] **Step 3: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/book_identifier_migrator_test.rb`
Expected: FAIL — `uninitialized constant ...BookIdentifierMigrator`.

- [ ] **Step 4: Write the migrator**

`app/lib/services/books_migration/book_identifier_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy book_identifiers -> Identifier on Books::Book. This pass migrates only
    # the goodreads type (legacy identifier_type == 5) as books_work_goodreads_id;
    # the edition-level ISBN/ASIN/EAN types (1..4) are deferred to a later pass.
    # book_id is preserved, so it is the new Books::Book id directly.
    class BookIdentifierMigrator < IdentifierMigrator
      GOODREADS_TYPE = 5

      private

      def legacy_model
        LegacyBooks::BookIdentifier
      end

      def model_key
        "Identifier (book goodreads)"
      end

      def upsert_row(attrs)
        return unless attrs["identifier_type"] == GOODREADS_TYPE
        upsert_identifier(
          identifiable_type: "Books::Book",
          identifiable_id: attrs["book_id"],
          identifier_type: :books_work_goodreads_id,
          value: attrs["identifier"]
        )
      end
    end
  end
end
```

- [ ] **Step 5: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/book_identifier_migrator_test.rb`
Expected: PASS (4 runs).

- [ ] **Step 6: Lint + commit**

```bash
bundle exec standardrb --fix app/models/legacy_books/book_identifier.rb app/lib/services/books_migration/book_identifier_migrator.rb test/lib/services/books_migration/book_identifier_migrator_test.rb
git add app/models/legacy_books/book_identifier.rb app/lib/services/books_migration/book_identifier_migrator.rb test/lib/services/books_migration/book_identifier_migrator_test.rb
git commit -m "Add BookIdentifierMigrator (book_identifiers goodreads type-5)"
```

---

### Task 3: BookWorkIdentifierMigrator + AuthorIdentifierMigrator

**Files:**
- Create: `web-app/app/lib/services/books_migration/book_work_identifier_migrator.rb`
- Create: `web-app/app/lib/services/books_migration/author_identifier_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/book_work_identifier_migrator_test.rb`
- Test: `web-app/test/lib/services/books_migration/author_identifier_migrator_test.rb`

**Interfaces:**
- Consumes: `IdentifierMigrator` base, `LegacyBooks::{Book,Author}`, `Identifier`, `Books::{Book,Author}`.
- Produces: `BookWorkIdentifierMigrator` (legacy `books`: `ol_work_id` → `books_work_openlibrary_id`, `goodreads_id` → `books_work_goodreads_id`, on `Books::Book` id = `book.id`); `AuthorIdentifierMigrator` (legacy `authors`: `ol_author_id` → `books_author_openlibrary_id` on `Books::Author` id = `author.id`).

- [ ] **Step 1: Write the failing tests**

`test/lib/services/books_migration/book_work_identifier_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::BookWorkIdentifierMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::BookWorkIdentifierMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "creates stripped openlibrary and verbatim goodreads ids on the book" do
    book = Books::Book.create!(title: "Work Book")
    run_migrator([{"id" => book.id, "ol_work_id" => "/works/OL20600W", "goodreads_id" => "555"}])
    ol = Identifier.find_by(identifiable: book, identifier_type: :books_work_openlibrary_id)
    gr = Identifier.find_by(identifiable: book, identifier_type: :books_work_goodreads_id)
    assert_equal "OL20600W", ol.value
    assert_equal "555", gr.value
  end

  test "creates only the present identifier when a column is nil" do
    book = Books::Book.create!(title: "Partial Book")
    run_migrator([{"id" => book.id, "ol_work_id" => "/works/OL99W", "goodreads_id" => nil}])
    assert_equal ["books_work_openlibrary_id"], Identifier.where(identifiable: book).map(&:identifier_type)
  end

  test "is idempotent" do
    book = Books::Book.create!(title: "Idem Work Book")
    rows = [{"id" => book.id, "ol_work_id" => "/works/OL1W", "goodreads_id" => "1"}]
    run_migrator(rows)
    assert_no_difference -> { Identifier.count } do
      run_migrator(rows)
    end
  end
end
```

`test/lib/services/books_migration/author_identifier_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::AuthorIdentifierMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::AuthorIdentifierMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "creates a stripped openlibrary id on the author" do
    author = Books::Author.create!(name: "OL Author")
    run_migrator([{"id" => author.id, "ol_author_id" => "/authors/OL9100206A"}])
    idf = Identifier.find_by(identifiable: author)
    assert_equal "books_author_openlibrary_id", idf.identifier_type
    assert_equal "OL9100206A", idf.value
  end

  test "skips authors with no ol_author_id" do
    author = Books::Author.create!(name: "No OL Author")
    assert_no_difference -> { Identifier.count } do
      run_migrator([{"id" => author.id, "ol_author_id" => nil}])
    end
  end
end
```

- [ ] **Step 2: Run them — verify they fail**

Run: `bin/rails test test/lib/services/books_migration/book_work_identifier_migrator_test.rb test/lib/services/books_migration/author_identifier_migrator_test.rb`
Expected: FAIL — `uninitialized constant` for both migrators.

- [ ] **Step 3: Write the migrators**

`app/lib/services/books_migration/book_work_identifier_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy books table -> work-level Identifiers on Books::Book. ol_work_id (OL
    # key stripped) -> books_work_openlibrary_id; goodreads_id (verbatim) ->
    # books_work_goodreads_id. book id is preserved. A book yields 0-2 identifiers;
    # upsert_identifier skips the ones whose source column is blank.
    class BookWorkIdentifierMigrator < IdentifierMigrator
      private

      def legacy_model
        LegacyBooks::Book
      end

      def model_key
        "Identifier (book work-level)"
      end

      def upsert_row(attrs)
        upsert_identifier(
          identifiable_type: "Books::Book", identifiable_id: attrs["id"],
          identifier_type: :books_work_openlibrary_id,
          value: self.class.strip_openlibrary_key(attrs["ol_work_id"])
        )
        upsert_identifier(
          identifiable_type: "Books::Book", identifiable_id: attrs["id"],
          identifier_type: :books_work_goodreads_id,
          value: attrs["goodreads_id"]
        )
      end
    end
  end
end
```

`app/lib/services/books_migration/author_identifier_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy authors table -> Books::Author books_author_openlibrary_id (OL key
    # stripped). author id is preserved.
    class AuthorIdentifierMigrator < IdentifierMigrator
      private

      def legacy_model
        LegacyBooks::Author
      end

      def model_key
        "Identifier (author openlibrary)"
      end

      def upsert_row(attrs)
        upsert_identifier(
          identifiable_type: "Books::Author", identifiable_id: attrs["id"],
          identifier_type: :books_author_openlibrary_id,
          value: self.class.strip_openlibrary_key(attrs["ol_author_id"])
        )
      end
    end
  end
end
```

- [ ] **Step 4: Run them — verify they pass**

Run: `bin/rails test test/lib/services/books_migration/book_work_identifier_migrator_test.rb test/lib/services/books_migration/author_identifier_migrator_test.rb`
Expected: PASS (3 + 2 runs).

- [ ] **Step 5: Lint + commit**

```bash
bundle exec standardrb --fix app/lib/services/books_migration/book_work_identifier_migrator.rb app/lib/services/books_migration/author_identifier_migrator.rb test/lib/services/books_migration/book_work_identifier_migrator_test.rb test/lib/services/books_migration/author_identifier_migrator_test.rb
git add app/lib/services/books_migration/book_work_identifier_migrator.rb app/lib/services/books_migration/author_identifier_migrator.rb test/lib/services/books_migration/book_work_identifier_migrator_test.rb test/lib/services/books_migration/author_identifier_migrator_test.rb
git commit -m "Add book work-level + author identifier migrators (openlibrary + goodreads)"
```

---

### Task 4: EditionIdentifierMigrator (openlibrary via LegacyIdMap)

**Files:**
- Create: `web-app/app/lib/services/books_migration/edition_identifier_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/edition_identifier_migrator_test.rb`

**Interfaces:**
- Consumes: `IdentifierMigrator` base, `LegacyBooks::Edition`, `LegacyIdMap.lookup`, `Identifier`, `Books::Edition`.
- Produces: `EditionIdentifierMigrator` — legacy `editions.ol_edition_id` → `books_edition_openlibrary_id` on the NEW `Books::Edition` (id via `LegacyIdMap.lookup`). Skips rows with no `ol_edition_id` or no map entry.

- [ ] **Step 1: Write the failing test**

`test/lib/services/books_migration/edition_identifier_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::EditionIdentifierMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::EditionIdentifierMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "creates a stripped openlibrary id on the mapped new edition" do
    book = Books::Book.create!(title: "Ed Book")
    edition = Books::Edition.create!(book: book, title: "Ed")
    LegacyIdMap.record(model: "Books::Edition", legacy_id: 900, new_id: edition.id)
    run_migrator([{"id" => 900, "ol_edition_id" => "/books/OL25955852M"}])
    idf = Identifier.find_by(identifiable: edition)
    assert_equal "books_edition_openlibrary_id", idf.identifier_type
    assert_equal "OL25955852M", idf.value
  end

  test "skips a legacy edition with no ol_edition_id" do
    assert_no_difference -> { Identifier.count } do
      run_migrator([{"id" => 901, "ol_edition_id" => nil}])
    end
  end

  test "skips when the edition has no id-map entry" do
    assert_no_difference -> { Identifier.count } do
      run_migrator([{"id" => 902, "ol_edition_id" => "/books/OL5M"}])
    end
  end
end
```

- [ ] **Step 2: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/edition_identifier_migrator_test.rb`
Expected: FAIL — `uninitialized constant ...EditionIdentifierMigrator`.

- [ ] **Step 3: Write the migrator**

`app/lib/services/books_migration/edition_identifier_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy editions.ol_edition_id -> Books::Edition books_edition_openlibrary_id
    # (OL key stripped). Editions have FRESH ids, so the legacy edition id is
    # remapped to the new id through LegacyIdMap (editions migrate first). Rows with
    # no ol_edition_id, or with no map entry, are skipped (upsert_identifier's nil
    # guard handles a nil new id).
    class EditionIdentifierMigrator < IdentifierMigrator
      private

      def legacy_model
        LegacyBooks::Edition
      end

      def model_key
        "Identifier (edition openlibrary)"
      end

      def upsert_row(attrs)
        value = self.class.strip_openlibrary_key(attrs["ol_edition_id"])
        return if value.nil?
        upsert_identifier(
          identifiable_type: "Books::Edition",
          identifiable_id: LegacyIdMap.lookup(model: "Books::Edition", legacy_id: attrs["id"]),
          identifier_type: :books_edition_openlibrary_id,
          value: value
        )
      end
    end
  end
end
```

- [ ] **Step 4: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/edition_identifier_migrator_test.rb`
Expected: PASS (3 runs). Also run the whole migration suite for no regression:
`bin/rails test test/lib/services/books_migration/`
Expected: all pass.

- [ ] **Step 5: Lint + commit**

```bash
bundle exec standardrb --fix app/lib/services/books_migration/edition_identifier_migrator.rb test/lib/services/books_migration/edition_identifier_migrator_test.rb
git add app/lib/services/books_migration/edition_identifier_migrator.rb test/lib/services/books_migration/edition_identifier_migrator_test.rb
git commit -m "Add EditionIdentifierMigrator (openlibrary via LegacyIdMap)"
```

---

### Task 5: Orchestrator wiring + end-to-end dev run

**Files:**
- Modify: `web-app/lib/tasks/data_migration.rake`

**Interfaces:**
- Consumes: the four identifier migrators.
- Produces: `data_migration:identifiers` (runs all four); `:all` runs `[:languages, :authors, :books, :book_authors, :editions, :identifiers]`.

- [ ] **Step 1: Add the task + update `:all`**

In `lib/tasks/data_migration.rake`, add after the `editions` task:

```ruby
  desc "Migrate legacy identifiers (goodreads + openlibrary) into identifiers"
  task identifiers: :environment do
    pp Services::BooksMigration::BookIdentifierMigrator.call
    pp Services::BooksMigration::BookWorkIdentifierMigrator.call
    pp Services::BooksMigration::AuthorIdentifierMigrator.call
    pp Services::BooksMigration::EditionIdentifierMigrator.call
  end
```

and change the `:all` line to:

```ruby
  task all: [:languages, :authors, :books, :book_authors, :editions, :identifiers]
```

- [ ] **Step 2: Verify the tasks register**

Run: `bin/rails -T data_migration`
Expected: lists `languages`, `authors`, `books`, `book_authors`, `editions`, `identifiers`, `all`.

- [ ] **Step 3: Commit**

```bash
git add lib/tasks/data_migration.rake
git commit -m "Wire identifiers into data_migration orchestrator"
```

- [ ] **Step 4: End-to-end dev run against the real legacy DB**

> Each migrator scans its full source table and `find_or_create_by!`s per identifier (~360k total across ~753k source rows), so the run takes roughly 15–25 minutes. Editions must already be migrated in dev (they are, from the editions increment) so the edition id-map exists.

Run:
```bash
bin/rails data_migration:identifiers
bin/rails runner 'puts "goodreads=#{Identifier.where(identifier_type: :books_work_goodreads_id).count} ol_work=#{Identifier.where(identifier_type: :books_work_openlibrary_id).count} ol_author=#{Identifier.where(identifier_type: :books_author_openlibrary_id).count} ol_edition=#{Identifier.where(identifier_type: :books_edition_openlibrary_id).count} pending_book_index=#{SearchIndexRequest.where(parent_type: "Books::Book").count}"'
```
Expected: each migrator result `{success: true, ...}`; then `ol_work=31602 ol_author=16542 ol_edition=18`, `goodreads=` roughly 154,524 plus any net-new from `books.goodreads_id` (natural-key overlap collapses the rest), `pending_book_index` unchanged (no new `Books::Book` requests from this run). Spot-check a stripped OL value:
```bash
bin/rails runner 'puts Identifier.where(identifier_type: :books_work_openlibrary_id).limit(3).pluck(:value).inspect'
```
Expected: bare `OL…W` keys, no `/works/` prefix.

> If a run returns `{success: false, ...}`, the error names the offending legacy source-row id and the count that succeeded — report it; the run is idempotent, so it resumes.

---

## Self-Review

**1. Spec coverage:**
- shared base `IdentifierMigrator` + `strip_openlibrary_key` (pure) + `upsert_identifier` (natural-key, skip blank) → Task 1. ✓
- `book_identifiers` type-5 goodreads → Book (types 1-4 skipped) → Task 2. ✓
- `books.ol_work_id` → Book openlibrary, `books.goodreads_id` → Book goodreads → Task 3. ✓
- `authors.ol_author_id` → Author openlibrary → Task 3. ✓
- `editions.ol_edition_id` → Edition openlibrary via `LegacyIdMap` → Task 4. ✓
- OL key stripping (bare key, blank→nil), goodreads verbatim, skip nil/blank → Tasks 1/2/3/4. ✓
- natural-key idempotency, no LegacyIdMap for identifiers, no search impact → Tasks 1-4. ✓
- orchestrator (all four) + e2e → Task 5. ✓
- Deferred (ISBN types 1-4, flat_identifiers) — stated in Global Constraints + Task 2 filters to type-5. ✓

**2. Placeholder scan:** No TBD/TODO; complete code in every code step. E2e goodreads count intentionally approximate (natural-key overlap between the two goodreads sources) — stated.

**3. Type consistency:** `IdentifierMigrator.strip_openlibrary_key` (public class method) called as `self.class.strip_openlibrary_key(...)` in Tasks 3/4. `upsert_identifier(identifiable_type:, identifiable_id:, identifier_type:, value:)` keyword signature identical across Tasks 2/3/4. `identifier_type` symbols (`:books_work_goodreads_id`, `:books_work_openlibrary_id`, `:books_author_openlibrary_id`, `:books_edition_openlibrary_id`) match the `Identifier` enum. Subclass hooks (`legacy_model`, `model_key`, `upsert_row`) match the base contract. `LegacyIdMap.lookup(model: "Books::Edition", legacy_id:)` matches the editions increment's map key.
