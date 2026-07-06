# Books ISBN Identifiers Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the deferred legacy ISBN family (`book_identifiers` types 1-4 + `editions.identifiers` jsonb) into work-level `Identifier` rows on `Books::Book`, deduped on the identifier natural key.

**Architecture:** Add four `books_work_*` ISBN-family enum values to `Identifier` (code-only, no DB migration). Extend the existing `BookIdentifierMigrator` to map `book_identifiers` types 1-4, and add a new `EditionIsbnIdentifierMigrator` that folds each legacy edition's `identifiers` jsonb up to its parent `Books::Book`. Both reuse the per-row `IdentifierMigrator` base (`find_or_create_by!` on the natural key → automatic cross-source/cross-run dedup + fail-loud on a missing book). A shared pure `asin_identifier_type` helper reclassifies ISBN-10-shaped ASINs to isbn10.

**Tech Stack:** Rails 8, Minitest + Mocha, PostgreSQL. Legacy read-only replica via `LegacyBooks::Record`.

**Design doc:** `docs/superpowers/specs/2026-07-06-books-isbn-identifiers-migration-design.md`

## Global Constraints

- Run **all** Rails commands from `web-app/` (`cd web-app` first).
- Lint with `bundle exec standardrb` (NOT rubocop); security scan `bin/brakeman --no-pager`. CI runs `bin/rails db:test:prepare test test:system`.
- **No DB migration** — `identifier_type` is already an `integer` column; enum values are a pure model edit.
- Namespace all migration code under `Services::BooksMigration`; mirror the namespace in tests (`class Services::BooksMigration::...Test`).
- **Fail loud on a missing prerequisite/FK** — a `book_id` with no migrated `Books::Book` must abort the run naming the offending legacy id (inherited free from `IdentifierMigrator`'s `find_or_create_by!` + `Identifier`'s `belongs_to :identifiable` presence validation + the `Migrator` base's per-row rescue). Never silently drop.
- **Faithful values** — strip surrounding whitespace, skip blanks (both handled by `upsert_identifier`); no ISBN checksum validation, no reformatting.
- Dedup is on the `Identifier` natural key `(identifiable_type, identifier_type, value, identifiable_id)` via `find_or_create_by!`.
- Enum slot assignment (final): `books_work_isbn13: 5`, `books_work_isbn10: 6`, `books_work_asin: 7`, `books_work_ean13: 8`.

---

## File Structure

- **Modify** `web-app/app/models/identifier.rb` — add 4 enum values (Task 1).
- **Modify** `web-app/app/lib/services/books_migration/identifier_migrator.rb` — add `ISBN10_SHAPE` + pure `asin_identifier_type` class method (Task 1).
- **Modify** `web-app/test/models/identifier_test.rb` — assert the new enum values (Task 1).
- **Modify** `web-app/test/lib/services/books_migration/identifier_migrator_test.rb` — unit-test `asin_identifier_type` (Task 1).
- **Modify** `web-app/app/lib/services/books_migration/book_identifier_migrator.rb` — map types 1-4 (Task 2).
- **Modify** `web-app/test/lib/services/books_migration/book_identifier_migrator_test.rb` — flip the "deferred" test; add type/asin/fail-loud tests (Task 2).
- **Create** `web-app/app/lib/services/books_migration/edition_isbn_identifier_migrator.rb` — jsonb → work-level (Task 3).
- **Create** `web-app/test/lib/services/books_migration/edition_isbn_identifier_migrator_test.rb` (Task 3).
- **Modify** `web-app/lib/tasks/data_migration.rake` — append the new migrator to `:identifiers` (Task 3).

---

## Task 1: Enum values + shared ASIN-shape helper

**Files:**
- Modify: `web-app/app/models/identifier.rb`
- Modify: `web-app/app/lib/services/books_migration/identifier_migrator.rb`
- Test: `web-app/test/models/identifier_test.rb`
- Test: `web-app/test/lib/services/books_migration/identifier_migrator_test.rb`

**Interfaces:**
- Produces (used by Tasks 2 & 3):
  - `Identifier#identifier_type` accepts `:books_work_isbn13` (5), `:books_work_isbn10` (6), `:books_work_asin` (7), `:books_work_ean13` (8).
  - `Services::BooksMigration::IdentifierMigrator.asin_identifier_type(value) -> Symbol` — returns `:books_work_isbn10` if `value` (stripped) matches `/\A\d{9}[\dX]\z/i`, else `:books_work_asin`.

- [ ] **Step 1: Write the failing enum test**

Add to `web-app/test/models/identifier_test.rb` (inside the existing `class IdentifierTest`):

```ruby
  test "defines work-level ISBN-family identifier types at slots 5-8" do
    assert_equal 5, Identifier.identifier_types["books_work_isbn13"]
    assert_equal 6, Identifier.identifier_types["books_work_isbn10"]
    assert_equal 7, Identifier.identifier_types["books_work_asin"]
    assert_equal 8, Identifier.identifier_types["books_work_ean13"]
  end
```

- [ ] **Step 2: Write the failing helper test**

Add to `web-app/test/lib/services/books_migration/identifier_migrator_test.rb` (inside the existing class, after the `strip_openlibrary_key` tests):

```ruby
  test "asin_identifier_type maps an ISBN-10-shaped value to isbn10" do
    assert_equal :books_work_isbn10, M.asin_identifier_type("0375755349")
    assert_equal :books_work_isbn10, M.asin_identifier_type("037575534X")
    assert_equal :books_work_isbn10, M.asin_identifier_type("037575534x")
    assert_equal :books_work_isbn10, M.asin_identifier_type("  0375755349  ")
  end

  test "asin_identifier_type keeps a real Amazon (Kindle) ASIN as asin" do
    assert_equal :books_work_asin, M.asin_identifier_type("B01K0T9772")
    assert_equal :books_work_asin, M.asin_identifier_type("B09LVX2Y9V")
  end

  test "asin_identifier_type defaults blank/short/long values to asin" do
    assert_equal :books_work_asin, M.asin_identifier_type(nil)
    assert_equal :books_work_asin, M.asin_identifier_type("")
    assert_equal :books_work_asin, M.asin_identifier_type("12345")
    assert_equal :books_work_asin, M.asin_identifier_type("9780375755347")
  end
```

- [ ] **Step 3: Run both tests to verify they fail**

Run: `bin/rails test test/models/identifier_test.rb test/lib/services/books_migration/identifier_migrator_test.rb`
Expected: FAIL — enum keys return `nil`; `NoMethodError: undefined method 'asin_identifier_type'`.

- [ ] **Step 4: Add the enum values**

In `web-app/app/models/identifier.rb`, insert the four values immediately after `books_work_librarything_id: 4,` (keep the blank line before the `# Books - Edition level` comment):

```ruby
    books_work_librarything_id: 4,
    books_work_isbn13: 5,
    books_work_isbn10: 6,
    books_work_asin: 7,
    books_work_ean13: 8,

    # Books - Edition level (Books::Edition)
```

- [ ] **Step 5: Add the shared helper**

In `web-app/app/lib/services/books_migration/identifier_migrator.rb`, add the constant and class method inside `class IdentifierMigrator`, right after the existing `strip_openlibrary_key` method:

```ruby
      # ISBN-10 shape: 10 chars, first 9 digits, last a digit or X (check digit).
      # Legacy Amazon "asin" values are ISBN-10 for print books but "B0..." codes
      # for Kindle; the check keys on shape (not "starts with B") so Kindle ASINs,
      # which have letters in the first 9 positions, are preserved as ASINs.
      ISBN10_SHAPE = /\A\d{9}[\dX]\z/i

      # Pure: given a legacy "asin" value, return the work-level identifier_type
      # symbol. ISBN-10-shaped -> :books_work_isbn10, else -> :books_work_asin.
      def self.asin_identifier_type(value)
        ISBN10_SHAPE.match?(value.to_s.strip) ? :books_work_isbn10 : :books_work_asin
      end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/models/identifier_test.rb test/lib/services/books_migration/identifier_migrator_test.rb`
Expected: PASS (all tests, including the pre-existing ones).

- [ ] **Step 7: Lint**

Run: `bundle exec standardrb app/models/identifier.rb app/lib/services/books_migration/identifier_migrator.rb`
Expected: no offenses.

- [ ] **Step 8: Commit**

```bash
git add app/models/identifier.rb app/lib/services/books_migration/identifier_migrator.rb test/models/identifier_test.rb test/lib/services/books_migration/identifier_migrator_test.rb
git commit -m "Add work-level ISBN-family enum types + ASIN-shape helper"
```

---

## Task 2: Migrate `book_identifiers` types 1-4

**Files:**
- Modify: `web-app/app/lib/services/books_migration/book_identifier_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/book_identifier_migrator_test.rb`

**Interfaces:**
- Consumes: enum values + `IdentifierMigrator.asin_identifier_type` from Task 1; `upsert_identifier(identifiable_type:, identifiable_id:, identifier_type:, value:)` from the `IdentifierMigrator` base.
- Produces: `BookIdentifierMigrator` now emits work-level identifiers for legacy `book_identifiers` types 1 (isbn10), 2 (isbn13), 3 (asin→isbn10-or-asin), 4 (ean13), and 5 (goodreads, unchanged).

- [ ] **Step 1: Update the "deferred" test to assert types 1-4 now migrate**

In `web-app/test/lib/services/books_migration/book_identifier_migrator_test.rb`, **delete** the existing test named `"ignores non-goodreads types (isbn/asin/ean deferred)"` (lines ~19-28) and add these tests in its place:

```ruby
  test "migrates isbn10 (type 1), isbn13 (type 2), ean13 (type 4) as work-level ids" do
    book = Books::Book.create!(title: "ISBN Book")
    result = run_migrator([
      {"id" => 2, "book_id" => book.id, "identifier_type" => 1, "identifier" => "0375755349"},
      {"id" => 3, "book_id" => book.id, "identifier_type" => 2, "identifier" => "9780375755347"},
      {"id" => 4, "book_id" => book.id, "identifier_type" => 4, "identifier" => "9780375755347"}
    ])
    assert result[:success], result[:error]
    types = Identifier.where(identifiable: book).pluck(:identifier_type).sort
    assert_equal ["books_work_ean13", "books_work_isbn10", "books_work_isbn13"], types
  end

  test "reclassifies an ISBN-10-shaped asin (type 3) as isbn10 but keeps a Kindle asin" do
    book = Books::Book.create!(title: "ASIN Book")
    run_migrator([
      {"id" => 7, "book_id" => book.id, "identifier_type" => 3, "identifier" => "0375755349"},
      {"id" => 8, "book_id" => book.id, "identifier_type" => 3, "identifier" => "B01K0T9772"}
    ])
    pairs = Identifier.where(identifiable: book).pluck(:identifier_type, :value).sort
    assert_equal [["books_work_asin", "B01K0T9772"], ["books_work_isbn10", "0375755349"]], pairs
  end

  test "skips an unknown identifier_type" do
    book = Books::Book.create!(title: "Unknown Type Book")
    assert_no_difference -> { Identifier.count } do
      run_migrator([{"id" => 20, "book_id" => book.id, "identifier_type" => 99, "identifier" => "x"}])
    end
  end

  test "fails loud when book_id has no migrated Books::Book" do
    result = run_migrator([{"id" => 9, "book_id" => 999_999, "identifier_type" => 1, "identifier" => "0375755349"}])
    refute result[:success]
    assert_match(/legacy id=9/, result[:error])
  end
```

- [ ] **Step 2: Run the test file to verify the new tests fail**

Run: `bin/rails test test/lib/services/books_migration/book_identifier_migrator_test.rb`
Expected: FAIL — types 1-4 currently produce no identifiers (the migrator only handles type 5), so the type-mapping assertions fail.

- [ ] **Step 3: Rewrite the migrator to map all handled types**

Replace the entire body of `web-app/app/lib/services/books_migration/book_identifier_migrator.rb` with:

```ruby
module Services
  module BooksMigration
    # Legacy book_identifiers -> work-level Identifiers on Books::Book. book_id is
    # preserved, so it is the new Books::Book id directly. Handles the whole legacy
    # ISBN family plus goodreads:
    #   1 isbn10, 2 isbn13, 4 ean13, 5 goodreads -> fixed types;
    #   3 asin    -> isbn10 if ISBN-10-shaped, else asin (see asin_identifier_type).
    # Values dedupe on the identifier natural key (find_or_create_by!), so a value
    # also present in editions.identifiers collapses to one row.
    class BookIdentifierMigrator < IdentifierMigrator
      TYPE_MAP = {
        1 => :books_work_isbn10,
        2 => :books_work_isbn13,
        4 => :books_work_ean13,
        5 => :books_work_goodreads_id
      }.freeze
      ASIN_TYPE = 3

      private

      def legacy_model
        LegacyBooks::BookIdentifier
      end

      def model_key
        "Identifier (book_identifiers)"
      end

      def upsert_row(attrs)
        value = attrs["identifier"]
        legacy_type = attrs["identifier_type"]
        identifier_type =
          (legacy_type == ASIN_TYPE) ? self.class.asin_identifier_type(value) : TYPE_MAP[legacy_type]
        return if identifier_type.nil?
        upsert_identifier(
          identifiable_type: "Books::Book",
          identifiable_id: attrs["book_id"],
          identifier_type: identifier_type,
          value: value
        )
      end
    end
  end
end
```

- [ ] **Step 4: Run the test file to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/book_identifier_migrator_test.rb`
Expected: PASS (new tests + the retained goodreads, idempotency, and search-suppression tests).

- [ ] **Step 5: Lint**

Run: `bundle exec standardrb app/lib/services/books_migration/book_identifier_migrator.rb test/lib/services/books_migration/book_identifier_migrator_test.rb`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add app/lib/services/books_migration/book_identifier_migrator.rb test/lib/services/books_migration/book_identifier_migrator_test.rb
git commit -m "Migrate book_identifiers ISBN/ASIN/EAN types to work-level identifiers"
```

---

## Task 3: `EditionIsbnIdentifierMigrator` (edition jsonb → work-level) + orchestration

**Files:**
- Create: `web-app/app/lib/services/books_migration/edition_isbn_identifier_migrator.rb`
- Create: `web-app/test/lib/services/books_migration/edition_isbn_identifier_migrator_test.rb`
- Modify: `web-app/lib/tasks/data_migration.rake`

**Interfaces:**
- Consumes: enum values + `IdentifierMigrator.asin_identifier_type` from Task 1; `upsert_identifier(...)` from the base; `LegacyBooks::Edition`.
- Produces: `Services::BooksMigration::EditionIsbnIdentifierMigrator.call` — reads legacy `editions`, folds each edition's `identifiers` jsonb up to its parent `Books::Book` (via preserved `book_id`) as work-level identifiers.

- [ ] **Step 1: Write the failing test file**

Create `web-app/test/lib/services/books_migration/edition_isbn_identifier_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::EditionIsbnIdentifierMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::EditionIsbnIdentifierMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  test "migrates edition jsonb isbn/ean arrays as work-level identifiers on the book" do
    book = Books::Book.create!(title: "Ed ISBN Book")
    result = run_migrator([{"id" => 100, "book_id" => book.id,
      "identifiers" => {"isbn_10" => ["0375755349"], "isbn_13" => ["9780375755347"], "ean" => ["9780375755347"], "asin" => ""}}])
    assert result[:success], result[:error]
    types = Identifier.where(identifiable: book).pluck(:identifier_type).sort
    assert_equal ["books_work_ean13", "books_work_isbn10", "books_work_isbn13"], types
  end

  test "fans out a multi-valued array into one identifier per value" do
    book = Books::Book.create!(title: "Multi EAN Book")
    run_migrator([{"id" => 101, "book_id" => book.id,
      "identifiers" => {"ean" => ["9780375755347", "9781234567897"]}}])
    assert_equal 2, Identifier.where(identifiable: book, identifier_type: :books_work_ean13).count
  end

  test "reclassifies an ISBN-10-shaped asin and keeps a Kindle asin" do
    b1 = Books::Book.create!(title: "Phys Ed")
    b2 = Books::Book.create!(title: "Kindle Ed")
    run_migrator([
      {"id" => 102, "book_id" => b1.id, "identifiers" => {"asin" => "0375755349"}},
      {"id" => 103, "book_id" => b2.id, "identifiers" => {"asin" => "B09LVX2Y9V"}}
    ])
    assert_equal "books_work_isbn10", Identifier.find_by(identifiable: b1).identifier_type
    assert_equal "books_work_asin", Identifier.find_by(identifiable: b2).identifier_type
  end

  test "handles empty, nil, and non-hash identifiers without error" do
    book = Books::Book.create!(title: "Empty Ed Book")
    assert_no_difference -> { Identifier.count } do
      result = run_migrator([
        {"id" => 104, "book_id" => book.id, "identifiers" => {}},
        {"id" => 105, "book_id" => book.id, "identifiers" => nil},
        {"id" => 106, "book_id" => book.id, "identifiers" => {"isbn_10" => [], "asin" => ""}}
      ])
      assert result[:success], result[:error]
    end
  end

  test "dedupes against an identifier already created by another source" do
    book = Books::Book.create!(title: "Dedup Ed Book")
    Identifier.create!(identifiable: book, identifier_type: :books_work_isbn13, value: "9780375755347")
    assert_no_difference -> { Identifier.count } do
      run_migrator([{"id" => 107, "book_id" => book.id, "identifiers" => {"isbn_13" => ["9780375755347"]}}])
    end
  end

  test "is idempotent on rerun" do
    book = Books::Book.create!(title: "Idem Ed Book")
    rows = [{"id" => 108, "book_id" => book.id, "identifiers" => {"isbn_10" => ["0375755349"]}}]
    run_migrator(rows)
    assert_no_difference -> { Identifier.count } do
      run_migrator(rows)
    end
  end

  test "suppresses search indexing during the load" do
    book = Books::Book.create!(title: "Quiet Ed Book")
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([{"id" => 109, "book_id" => book.id, "identifiers" => {"isbn_10" => ["0375755349"]}}])
    end
  end

  test "fails loud when book_id has no migrated Books::Book" do
    result = run_migrator([{"id" => 110, "book_id" => 999_999, "identifiers" => {"isbn_10" => ["0375755349"]}}])
    refute result[:success]
    assert_match(/legacy id=110/, result[:error])
  end
end
```

- [ ] **Step 2: Run the test file to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/edition_isbn_identifier_migrator_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::BooksMigration::EditionIsbnIdentifierMigrator`.

- [ ] **Step 3: Create the migrator**

Create `web-app/app/lib/services/books_migration/edition_isbn_identifier_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy editions.identifiers (jsonb) -> work-level ISBN-family Identifiers on
    # the parent Books::Book. Editions are only READ here; each edition's ISBNs are
    # folded up to its book (edition.book_id is preserved = the Books::Book id).
    # jsonb keys isbn_10/isbn_13/ean are arrays (one identifier per element); asin
    # is a single string reclassified by shape. Values dedupe on the identifier
    # natural key, so overlap with book_identifiers collapses to one row.
    class EditionIsbnIdentifierMigrator < IdentifierMigrator
      ARRAY_KEYS = {
        "isbn_10" => :books_work_isbn10,
        "isbn_13" => :books_work_isbn13,
        "ean" => :books_work_ean13
      }.freeze

      private

      def legacy_model
        LegacyBooks::Edition
      end

      def model_key
        "Identifier (edition ISBN)"
      end

      def upsert_row(attrs)
        ids = attrs["identifiers"]
        return unless ids.is_a?(Hash)
        book_id = attrs["book_id"]

        ARRAY_KEYS.each do |key, identifier_type|
          Array(ids[key]).each do |value|
            upsert_identifier(
              identifiable_type: "Books::Book",
              identifiable_id: book_id,
              identifier_type: identifier_type,
              value: value.to_s.strip
            )
          end
        end

        Array(ids["asin"]).each do |value|
          stripped = value.to_s.strip
          upsert_identifier(
            identifiable_type: "Books::Book",
            identifiable_id: book_id,
            identifier_type: self.class.asin_identifier_type(stripped),
            value: stripped
          )
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the test file to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/edition_isbn_identifier_migrator_test.rb`
Expected: PASS (all 8 tests).

- [ ] **Step 5: Wire the migrator into the rake orchestrator**

In `web-app/lib/tasks/data_migration.rake`, update the `:identifiers` task — change the `desc` and append the new migrator call after `EditionIdentifierMigrator`:

```ruby
  desc "Migrate legacy identifiers (goodreads + openlibrary + ISBN family) into identifiers"
  task identifiers: :environment do
    pp Services::BooksMigration::BookIdentifierMigrator.call
    pp Services::BooksMigration::BookWorkIdentifierMigrator.call
    pp Services::BooksMigration::AuthorIdentifierMigrator.call
    pp Services::BooksMigration::EditionIdentifierMigrator.call
    pp Services::BooksMigration::EditionIsbnIdentifierMigrator.call
  end
```

(The `:all` task already depends on `:identifiers`; no change there.)

- [ ] **Step 6: Lint**

Run: `bundle exec standardrb app/lib/services/books_migration/edition_isbn_identifier_migrator.rb test/lib/services/books_migration/edition_isbn_identifier_migrator_test.rb lib/tasks/data_migration.rake`
Expected: no offenses.

- [ ] **Step 7: Run the whole migration test directory + brakeman**

Run: `bin/rails test test/lib/services/books_migration/ test/models/identifier_test.rb`
Expected: PASS (all migration + identifier tests).

Run: `bin/brakeman --no-pager -q`
Expected: no new warnings.

- [ ] **Step 8: Commit**

```bash
git add app/lib/services/books_migration/edition_isbn_identifier_migrator.rb test/lib/services/books_migration/edition_isbn_identifier_migrator_test.rb lib/tasks/data_migration.rake
git commit -m "Add EditionIsbnIdentifierMigrator + wire into identifiers orchestrator"
```

---

## Final verification (controller-run, after all tasks)

Not a subagent task — the controller runs these against the real legacy DB (`the_greatest_books_legacy` on `localhost:6543`) on a dev DB reset to the migrated baseline.

- [ ] Full suite green: `bin/rails test` (from `web-app/`).
- [ ] `bundle exec standardrb` and `bin/brakeman --no-pager` clean.
- [ ] Run `bin/rails data_migration:identifiers`; confirm each migrator returns `{success: true}`.
- [ ] Counts by type non-zero and **stable across a second run** (idempotency): `Identifier.where(identifier_type: [:books_work_isbn10, :books_work_isbn13, :books_work_asin, :books_work_ean13]).group(:identifier_type).count`; `Identifier.count` unchanged on rerun.
- [ ] Spot-check a known physical book (ISBN-10/13 present as `books_work_isbn10/13`) and a Kindle-only edition (`books_work_asin` present, not misfiled as isbn10).
- [ ] 0 ISBN-family identifiers point at a nonexistent `Books::Book` (fail-loud held).
- [ ] `SearchIndexRequest` count unchanged by the run (search suppression held).

---

## Self-Review

**Spec coverage:**
- D1 (work-level only) → both migrators write `identifiable_type: "Books::Book"` (Tasks 2, 3). ✓
- D2 (both sources, deduped) → Task 2 (book_identifiers) + Task 3 (editions jsonb); dedup via `find_or_create_by!` (dedup test in Task 3 Step 1). ✓
- D3 (ASIN reclassification by shape, no checksum) → `asin_identifier_type` helper (Task 1) used by both migrators; tests for ISBN-10 / X-check-digit / Kindle / blank. ✓
- D4 (EAN faithful → ean13) → `TYPE_MAP[4]` and `ARRAY_KEYS["ean"]` both `:books_work_ean13`. ✓
- D5 (strip, skip blank, no validation) → `value.to_s.strip` + `upsert_identifier` blank guard; no ISBN validation added. ✓
- D6 (typed jsonb, not flat_identifiers) → Task 3 reads `attrs["identifiers"]`. ✓
- Enum slots 5-8 (code-only) → Task 1 Step 4, no migration. ✓
- Orchestration → Task 3 Step 5. ✓
- Fail-loud → tests in Tasks 2 & 3. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every command has expected output. ✓

**Type consistency:** `asin_identifier_type` (Task 1) returns the same symbols consumed in Tasks 2 & 3; `upsert_identifier` signature matches the base; enum symbols `:books_work_isbn10/isbn13/asin/ean13` consistent throughout. ✓
