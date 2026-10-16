# Identifier Provenance (Increment 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every books-domain identifier records who attached it (`identifiers.source`), every books writer sets it from now on, and a one-time task marks everything that already exists `legacy`.

**Architecture:** A nullable integer enum on the shared `identifiers` table, set by each writer at the point it builds the row. `Identifier.verified` (`open_library`, `worldcat`) is the trust scope later code reads. Mergers keep the more trusted of two duplicate rows. A batched rake task marks existing books-domain rows, then relabels the keys the old OL key backfill wrote. Music and games are not touched.

**Tech Stack:** Rails 8.1, PostgreSQL, Minitest + Mocha + fixtures, Sidekiq (unchanged), Standard Ruby.

**Spec:** `docs/superpowers/specs/2026-10-16-book-verification-design.md` (section 1 is this increment; sections 2-4 are increment 2).

## Global Constraints

- Run every Rails command from `web-app/`. Docs live in `docs/` at the project root.
- `identifiers.source`: nullable integer, no default. Enum values and integers, exactly: `legacy: 0, open_library: 1, worldcat: 2, goodreads_import: 3, amazon: 4, wikidata: 5, viaf: 6`, declared `enum :source, {...}, prefix: true`.
- `Identifier.verified` = `source: [:open_library, :worldcat]`. Never includes `null`.
- Books-domain identifiable types: `Books::Book`, `Books::Edition`, `Books::Author`, `Books::Series`. Music, games and movies rows stay `null`; their writers are not modified.
- The one-time marking is a rake task (`identifiers:mark_legacy`), never part of a deploy migration. Batches of 10,000.
- Rails 8 enum syntax only (`enum :source, {...}`).
- Services return `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Minitest 6: use `assert_nil`, never `assert_equal nil, x`.
- Lint with `bundle exec standardrb` (never `bin/rubocop`). Do not run brakeman.
- Never run a destructive command against the development database. `bin/rails test` uses the per-worktree test DB and is safe.
- Do not add an `admin` source value (spec: no admin writer exists).

## Review Focus

1. **A writer missed.** A books identifier written with no source would read as untrusted forever but also never get marked `legacy` once the marking has run. Expected: every books write site in `app/` and `lib/tasks/` names a source. Pinned by the lint test in Task 7.
2. **A legacy re-run downgrading a verified row.** The weekly sync re-runs `find_or_create_by!` over existing rows. Expected: a row already `open_library` stays `open_library`. Pinned in Task 2.
3. **A merge losing trust.** Source book holds `9780140447934` as `open_library`, target holds it as `legacy`. Expected: the surviving row is `open_library`. Pinned in Task 6 for books and authors.
4. **The marking re-run or interrupted.** Expected: re-running marks nothing new, never touches a non-null row, never touches music/games rows. Pinned in Task 7.
5. **The OL backfill revert after this ships.** A `confirmed` row's key was upgraded to `open_library`; revert must not leave it trusted. Expected: revert sets that key back to `legacy`, and restored old keys come back `legacy`. Pinned in Task 5.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `web-app/db/migrate/<ts>_add_source_to_identifiers.rb` | create (generator) | the column |
| `web-app/app/models/identifier.rb` | modify | enum, `verified` scope, `trust_rank` |
| `web-app/app/lib/services/books_migration/identifier_migrator.rb` | modify | legacy migrators + weekly sync write `legacy` |
| `web-app/app/lib/services/books/edition_identifier_backfill.rb` | modify | `legacy` |
| `web-app/app/lib/data_importers/books/book/importer.rb` | modify | `query_identifier_source:` option |
| `web-app/app/lib/data_importers/books/book/providers/open_library.rb` | modify | OL key `open_library`, query identifiers by option |
| `web-app/app/lib/data_importers/books/book/providers/query_identifiers.rb` | modify | query identifiers by option |
| `web-app/app/lib/data_importers/books/author/providers/open_library.rb` | modify | `open_library` |
| `web-app/app/lib/services/books/goodreads_replay/apply/strip_identifier.rb` | modify | `goodreads_import` |
| `web-app/app/lib/services/books/amazon_edition_upserter.rb` | modify | `amazon` |
| `web-app/app/lib/services/books/authors/fact_sheet.rb` | modify | source passed in |
| `web-app/app/lib/services/books/authors/apply_wikidata.rb`, `apply_viaf.rb` | modify | pass `:wikidata` / `:viaf` |
| `web-app/app/lib/services/books/authors/restore_identifier.rb` | modify | source per finder |
| `web-app/lib/tasks/e2e.rake` | modify | seed QID `wikidata` |
| `web-app/app/lib/services/books/ol_backfill/apply_book.rb`, `author_keys.rb`, `revert.rb` | modify | `open_library`; revert back to `legacy` |
| `web-app/app/lib/books/book/merger.rb`, `web-app/app/lib/books/author/merger.rb` | modify | keep the more trusted duplicate |
| `web-app/app/lib/services/identifiers/mark_legacy.rb` | create | the one-time marking |
| `web-app/lib/tasks/identifiers.rake` | create | `identifiers:mark_legacy` |
| `web-app/test/lint/identifier_source_test.rb` | create | every books write site names a source |
| `docs/features/identifier-provenance.md` | create | what `source` means, who writes what, the marking |
| `docs/launch-todo.md` | modify | run the marking once after deploy |

---

### Task 1: The column, the enum, `verified`, `trust_rank`

**Files:**
- Create: `web-app/db/migrate/<timestamp>_add_source_to_identifiers.rb` (via generator)
- Modify: `web-app/app/models/identifier.rb`
- Test: `web-app/test/models/identifier_test.rb`

**Interfaces:**
- Produces: `Identifier.sources` (enum hash), `identifier.source`, `identifier.source_legacy?` etc., `Identifier.verified` (scope), `Identifier::BOOKS_TYPES` (array of strings), `Identifier.trust_rank(source) -> Integer` (accepts a symbol, string or nil).

- [ ] **Step 1: Generate the migration**

```bash
cd web-app
ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails generate migration AddSourceToIdentifiers source:integer
```

Edit the generated file so it reads exactly (nullable, no default, no index):

```ruby
class AddSourceToIdentifiers < ActiveRecord::Migration[8.1]
  def change
    add_column :identifiers, :source, :integer
  end
end
```

Run it against development and test:

```bash
ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate
```

Expected: `db/schema.rb` gains `t.integer "source"` in `create_table "identifiers"`. Adding a nullable column with no default is a metadata-only change in PostgreSQL, safe on the shared dev DB and in production.

- [ ] **Step 2: Write the failing tests**

Append to `web-app/test/models/identifier_test.rb`, inside the class:

```ruby
  test "source is nullable and defaults to nil" do
    identifier = Identifier.create!(identifiable: books_books(:war_and_peace), identifier_type: :books_work_isbn10, value: "0140447938")

    assert_nil identifier.source
  end

  test "source takes the provenance values" do
    assert_equal(
      {"legacy" => 0, "open_library" => 1, "worldcat" => 2, "goodreads_import" => 3, "amazon" => 4, "wikidata" => 5, "viaf" => 6},
      Identifier.sources
    )
    identifier = Identifier.create!(identifiable: books_books(:war_and_peace), identifier_type: :books_work_isbn10,
      value: "0140447938", source: :open_library)

    assert identifier.source_open_library?
  end

  test "verified is open_library and worldcat only" do
    book = books_books(:war_and_peace)
    open_library = Identifier.create!(identifiable: book, identifier_type: :books_work_isbn10, value: "0140447938", source: :open_library)
    worldcat = Identifier.create!(identifiable: book, identifier_type: :books_work_oclc_id, value: "12345", source: :worldcat)
    legacy = Identifier.create!(identifiable: book, identifier_type: :books_work_goodreads_id, value: "656", source: :legacy)
    imported = Identifier.create!(identifiable: book, identifier_type: :books_work_asin, value: "B0TEST0001", source: :goodreads_import)
    unmarked = identifiers(:war_and_peace_isbn13)

    verified = Identifier.verified.where(identifiable: book)

    assert_includes verified, open_library
    assert_includes verified, worldcat
    refute_includes verified, legacy
    refute_includes verified, imported
    refute_includes verified, unmarked
  end

  test "trust_rank orders verified over other sources over legacy over nil" do
    assert_equal 3, Identifier.trust_rank(:open_library)
    assert_equal 3, Identifier.trust_rank("worldcat")
    assert_equal 2, Identifier.trust_rank(:goodreads_import)
    assert_equal 2, Identifier.trust_rank(:wikidata)
    assert_equal 1, Identifier.trust_rank(:legacy)
    assert_equal 0, Identifier.trust_rank(nil)
  end

  test "BOOKS_TYPES lists every books identifiable" do
    assert_equal %w[Books::Book Books::Edition Books::Author Books::Series], Identifier::BOOKS_TYPES
  end
```

- [ ] **Step 3: Run them to verify they fail**

Run: `bin/rails test test/models/identifier_test.rb`
Expected: FAIL (`undefined method 'sources'`, `undefined method 'verified'`, `uninitialized constant Identifier::BOOKS_TYPES`).

- [ ] **Step 4: Implement**

In `web-app/app/models/identifier.rb`, after the `identifier_type` enum block, add:

```ruby
  # Who attached the identifier (identifier provenance spec, section 1).
  # Books rows only; music and games stay nil. Everything that existed
  # before provenance is legacy (identifiers:mark_legacy).
  enum :source, {
    legacy: 0,
    open_library: 1,
    worldcat: 2,
    goodreads_import: 3,
    amazon: 4,
    wikidata: 5,
    viaf: 6
  }, prefix: true

  BOOKS_TYPES = %w[Books::Book Books::Edition Books::Author Books::Series].freeze
  VERIFIED_SOURCES = %w[open_library worldcat].freeze

  # A source an independent catalogue tied to the record by title, author
  # and year. What the Goodreads rebuild's matcher reads.
  scope :verified, -> { where(source: VERIFIED_SOURCES) }

  # For keeping the better of two rows holding the same value (mergers):
  # verified 3, any other source 2, legacy 1, nil 0.
  def self.trust_rank(source)
    source = source&.to_s
    return 0 if source.nil?
    return 3 if VERIFIED_SOURCES.include?(source)
    return 1 if source == "legacy"

    2
  end
```

Also add `#  source            :integer` to the schema comment header at the top of the model (between `value` and `created_at`), by hand; do not run annotaterb.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/models/identifier_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add db/migrate/*_add_source_to_identifiers.rb db/schema.rb app/models/identifier.rb test/models/identifier_test.rb
git commit -m "Identifiers: source column, verified scope and trust rank

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Legacy writers write `legacy`

**Files:**
- Modify: `web-app/app/lib/services/books_migration/identifier_migrator.rb:34-43`
- Modify: `web-app/app/lib/services/books/edition_identifier_backfill.rb` (`row`)
- Test: `web-app/test/lib/services/books_migration/book_identifier_migrator_test.rb`, `web-app/test/lib/services/books/edition_identifier_backfill_test.rb`

**Interfaces:**
- Consumes: `Identifier.sources` (Task 1).
- Produces: every row these write carries `source: legacy`; an existing row is never re-labelled.

`upsert_identifier` is shared by `BookIdentifierMigrator`, `BookWorkIdentifierMigrator`, `AuthorIdentifierMigrator`, `EditionIdentifierMigrator` and `EditionIsbnIdentifierMigrator`, and by the weekly `data_migration:sync`. Using `create_with` means a new row is `legacy` and an existing row (which may already be `open_library`) is left alone.

- [ ] **Step 1: Write the failing tests**

Read the top of `test/lib/services/books_migration/book_identifier_migrator_test.rb` to see how it builds a legacy row and runs the migrator (it stubs the legacy source), then add two tests in the same style. The assertions:

```ruby
  test "a migrated identifier is marked legacy" do
    # Arrange one legacy book_identifiers row (isbn13 "9780140449136" on war_and_peace's id)
    # using this file's existing helper, then run the migrator as the other tests do.
    identifier = Identifier.find_by!(identifiable: books_books(:war_and_peace), identifier_type: :books_work_isbn13, value: "9780140449136")

    assert identifier.source_legacy?
  end

  test "re-migrating never downgrades a row a verified source already confirmed" do
    existing = Identifier.create!(identifiable: books_books(:war_and_peace), identifier_type: :books_work_isbn13,
      value: "9780140449136", source: :open_library)
    # Arrange the same legacy row and run the migrator again.

    assert existing.reload.source_open_library?
  end
```

In `test/lib/services/books/edition_identifier_backfill_test.rb`, add (following the file's existing edition setup):

```ruby
  test "rows it writes are marked legacy" do
    # Run the backfill over an edition with an Amazon blob, as the existing tests do.
    assert Identifier.where(identifiable_type: "Books::Edition").where.not(source: :legacy).none?
  end
```

Fill the `# Arrange` comments with the file's own helpers; do not invent a new stubbing style.

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books_migration/book_identifier_migrator_test.rb test/lib/services/books/edition_identifier_backfill_test.rb`
Expected: the two "legacy" tests FAIL (`source` is nil); the "never downgrades" test passes already (find_or_create finds the row) and keeps passing.

- [ ] **Step 3: Implement**

In `identifier_migrator.rb`, replace the body of `upsert_identifier` after the guard:

```ruby
        Identifier.create_with(source: :legacy).find_or_create_by!(
          identifiable_type: identifiable_type,
          identifiable_id: identifiable_id,
          identifier_type: identifier_type,
          value: value
        )
```

Add one sentence to the method's comment: "New rows are legacy; an existing row keeps its source, so a re-run never downgrades one a verified source confirmed."

In `edition_identifier_backfill.rb`, add `source: Identifier.sources[:legacy],` to the hash built in `row` (after `value: value,`). `insert_all` skips rows that already exist, so existing sources are untouched.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books_migration/ test/lib/services/books/edition_identifier_backfill_test.rb`
Expected: PASS, including every existing migrator test.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books_migration/identifier_migrator.rb app/lib/services/books/edition_identifier_backfill.rb test/lib/services/books_migration/book_identifier_migrator_test.rb test/lib/services/books/edition_identifier_backfill_test.rb
git commit -m "Identifiers: legacy migrators, the sync and the edition backfill write legacy

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The book and author importers

**Files:**
- Modify: `web-app/app/lib/data_importers/books/book/importer.rb`
- Modify: `web-app/app/lib/data_importers/books/book/providers/open_library.rb` (`initialize`, `apply_trusted`, `apply_candidate`, `persist_query_identifiers`)
- Modify: `web-app/app/lib/data_importers/books/book/providers/query_identifiers.rb`
- Modify: `web-app/app/lib/data_importers/books/author/providers/open_library.rb:~112`
- Test: `web-app/test/lib/data_importers/books/book/providers/open_library_test.rb`, `.../query_identifiers_test.rb`, `.../importer_test.rb`, `web-app/test/lib/data_importers/books/author/providers/open_library_test.rb`

**Interfaces:**
- Consumes: `Identifier.sources` (Task 1).
- Produces: `DataImporters::Books::Book::Importer.call(..., query_identifier_source: :goodreads_import)` (new keyword, default `:goodreads_import`); `Providers::OpenLibrary.new(..., query_identifier_source:)`; `Providers::QueryIdentifiers.new(source:)`.

The query's own identifiers (ISBNs, ASINs, Goodreads ids the caller passed) are the caller's claim, not Open Library's. Today only the Goodreads import paths pass any (the list wizard passes none), so the default is `:goodreads_import`; a future caller with its own identifiers passes its own source. Sources are set on new rows only (`identifier.source = x if identifier.new_record?`): an importer never re-labels an existing row.

- [ ] **Step 1: Write the failing tests**

In `test/lib/data_importers/books/book/providers/open_library_test.rb`, following the file's existing accept setup (stubbed client returning an accepting `Resolution`), add:

```ruby
  test "an accepted work key is written as open_library and query identifiers as goodreads_import" do
    # Arrange an accept for a book whose query carries isbn13 ["9780140449136"] and goodreads_id ["656"],
    # the way this file's existing accept tests build their stubbed client and query, then call populate.
    key = book.identifiers.find { |i| i.identifier_type == "books_work_openlibrary_id" }
    isbn = book.identifiers.find { |i| i.identifier_type == "books_work_isbn13" }

    assert key.source_open_library?
    assert isbn.source_goodreads_import?
  end

  test "a provider built with another query_identifier_source uses it" do
    # Same arrangement, provider built with query_identifier_source: :amazon.
    isbn = book.identifiers.find { |i| i.identifier_type == "books_work_isbn13" }

    assert isbn.source_amazon?
  end

  test "an identifier the book already holds keeps its source" do
    # Arrange the book already holding the accepted work key with source: :legacy, then accept.
    key = book.identifiers.find { |i| i.identifier_type == "books_work_openlibrary_id" }

    assert key.source_legacy?
  end
```

In `query_identifiers_test.rb`:

```ruby
  test "stamped identifiers carry the source it was built with" do
    book = Books::Book.new(title: "Stamped")
    query = DataImporters::Books::Book::ImportQuery.new(title: "Stamped", isbn13: ["9780140449136"], goodreads_id: ["656"])

    DataImporters::Books::Book::Providers::QueryIdentifiers.new(source: :goodreads_import).populate(book, query: query)

    assert book.identifiers.all?(&:source_goodreads_import?)
  end
```

In `importer_test.rb`, add a test that `Importer.call` with `stamp_identifiers: true` passes `query_identifier_source` through: stub the providers as the file does, then assert the `QueryIdentifiers` provider was built with `source: :goodreads_import` by default (`Providers::QueryIdentifiers.expects(:new).with(source: :goodreads_import).returns(...)`), and with `source: :amazon` when `query_identifier_source: :amazon` is given.

In the author provider test (`test/lib/data_importers/books/author/providers/open_library_test.rb`), built like this file's existing tests that stamp an author key:

```ruby
  test "the author key is written as open_library" do
    # Same arrangement as the existing key-stamping test.
    key = author.identifiers.find { |i| i.identifier_type == "books_author_openlibrary_id" }

    assert key.source_open_library?
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/data_importers/books/`
Expected: the new tests FAIL (`source` nil, `unknown keyword: :source`).

- [ ] **Step 3: Implement**

`importer.rb`: add `query_identifier_source: :goodreads_import` to the `self.call` keyword list and to `initialize`, store it as `@query_identifier_source`, pass it through `new(...)`, and in the provider list:

```ruby
              Providers::OpenLibrary.new(new_author_ids: new_author_ids, provisional: @provisional, trust_work_key: @trust_work_key,
                query_identifier_source: @query_identifier_source),
```

```ruby
            list << Providers::QueryIdentifiers.new(source: @query_identifier_source) if @stamp_identifiers
```

Extend the `initialize` comment: "query_identifier_source: the source given to the query's own identifiers (the caller's claim, not Open Library's). Only the Goodreads import passes identifiers today."

`providers/open_library.rb`: `initialize` takes `query_identifier_source: :goodreads_import` and stores it. Add a private helper and use it at the three write sites:

```ruby
          # A new row takes `source`; a row the book already holds keeps its own.
          def stamp(book, identifier_type, value, source)
            identifier = book.identifiers.find_or_initialize_by(identifier_type: identifier_type, value: value)
            identifier.source = source if identifier.new_record?
            identifier
          end
```

- `apply_trusted`: `stamp(book, :books_work_openlibrary_id, key, :open_library)`
- `apply_candidate`: `stamp(book, :books_work_openlibrary_id, candidate.work_key, :open_library)`
- `persist_query_identifiers`: `stamp(book, identifier_type, value, @query_identifier_source)`

`providers/query_identifiers.rb`:

```ruby
          def initialize(source: :goodreads_import)
            super()
            @source = source
          end
```

(Check `DataImporters::ProviderBase#initialize`'s signature first; if it takes no arguments keep `super()`.) In `populate`:

```ruby
                identifier = book.identifiers.find_or_initialize_by(identifier_type: identifier_type, value: value)
                identifier.source = @source if identifier.new_record?
                stamped << identifier_type.to_s if identifier.new_record?
```

`author/providers/open_library.rb`, the key line becomes:

```ruby
            key = author.identifiers.find_or_initialize_by(identifier_type: :books_author_openlibrary_id, value: record.key)
            key.source = :open_library if key.new_record?
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/data_importers/ test/lib/services/books/goodreads_imports/ test/lib/services/lists/wizard/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/data_importers/books/ test/lib/data_importers/books/
git commit -m "Identifiers: importers write open_library keys and the caller's source for query identifiers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Goodreads replay, Amazon and author enrichment writers

**Files:**
- Modify: `web-app/app/lib/services/books/goodreads_replay/apply/strip_identifier.rb:44`
- Modify: `web-app/app/lib/services/books/amazon_edition_upserter.rb` (`upsert_identifier`)
- Modify: `web-app/app/lib/services/books/authors/fact_sheet.rb` (`initialize`, `stamp`)
- Modify: `web-app/app/lib/services/books/authors/apply_wikidata.rb:45`, `apply_viaf.rb:33`
- Modify: `web-app/app/lib/services/books/authors/restore_identifier.rb`
- Modify: `web-app/lib/tasks/e2e.rake:153`
- Test: `web-app/test/lib/services/books/goodreads_replay/apply/strip_identifier_test.rb`, `.../amazon_edition_upserter_test.rb`, `.../authors/fact_sheet_test.rb`, `.../authors/restore_identifier_test.rb`

**Interfaces:**
- Consumes: `Identifier.sources` (Task 1).
- Produces: `Services::Books::Authors::FactSheet.new(author, source:)` (required keyword); `RestoreIdentifier::SOURCES` (finder name → source symbol).

- [ ] **Step 1: Write the failing tests**

`strip_identifier_test.rb`, built like this file's existing tests that add identifiers:

```ruby
  test "identifiers it adds are goodreads_import" do
    # Arrange a verdict with add: [["books_work_goodreads_id", "656"]] for a book that lacks it, then call.
    added = book.identifiers.find_by!(identifier_type: :books_work_goodreads_id, value: "656")

    assert added.source_goodreads_import?
  end
```

`amazon_edition_upserter_test.rb`, following its existing identifier test:

```ruby
  test "edition identifiers it writes are amazon" do
    # Arrange like this file's existing tests that write edition identifiers.
    assert edition.identifiers.reload.all?(&:source_amazon?)
  end
```

`fact_sheet_test.rb`:

```ruby
  test "a stamped identifier carries the sheet's source" do
    author = books_authors(:tolstoy)
    sheet = Services::Books::Authors::FactSheet.new(author, source: :viaf)

    sheet.stamp("books_author_viaf", "123456789")

    stamped = author.identifiers.find { |i| i.value == "123456789" }
    assert stamped.source_viaf?
  end
```

(Update every existing `FactSheet.new(author)` in that test file to `FactSheet.new(author, source: :wikidata)`.)

`restore_identifier_test.rb`, following its existing restore test:

```ruby
  test "a restored Wikidata id is wikidata and a restored VIAF id is viaf" do
    # Same arrangement as the existing restore test, once per finder.
    assert author.identifiers.find_by!(identifier_type: :books_author_wikidata_qid).source_wikidata?
    # and for ResolveViaf:
    assert author.identifiers.find_by!(identifier_type: :books_author_viaf).source_viaf?
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/goodreads_replay/apply/strip_identifier_test.rb test/lib/services/books/amazon_edition_upserter_test.rb test/lib/services/books/authors/`
Expected: FAIL (`source` nil; `missing keyword: :source`).

- [ ] **Step 3: Implement**

`strip_identifier.rb:44`:

```ruby
                ::Identifier.create!(identifiable: book, identifier_type: type, value: value, source: :goodreads_import)
```

Add to the class comment: "Added identifiers come from a Goodreads export row, attached by the replay's own matcher: goodreads_import."

`amazon_edition_upserter.rb`:

```ruby
      def upsert_identifier(edition, identifier_type, value)
        return if value.blank?

        identifier = edition.identifiers.find_or_initialize_by(identifier_type: identifier_type, value: value)
        identifier.source = :amazon if identifier.new_record?
        identifier.save!
      end
```

`fact_sheet.rb`: `def initialize(author, source:)`, store `@source = source`, and in `stamp`:

```ruby
          identifier = author.identifiers.find_or_initialize_by(identifier_type: type, value: value)
          identifier.source = @source if identifier.new_record?
          "filled"
```

Update the class comment: "source: who the stamped ids come from (:wikidata or :viaf)."

`apply_wikidata.rb:45`: `@sheet = FactSheet.new(author, source: :wikidata)`. `apply_viaf.rb:33`: `@sheet = FactSheet.new(author, source: :viaf)`.

`restore_identifier.rb`: add next to `TYPES`

```ruby
        SOURCES = {
          "Services::Books::Authors::ResolveWikidata" => :wikidata,
          "Services::Books::Authors::ResolveViaf" => :viaf
        }.freeze
```

and in `call`: `@author.identifiers.create!(identifier_type: @type, value: value, source: SOURCES.fetch(@finder))`.

`lib/tasks/e2e.rake:153`: `author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: REJECT_LINK_QID, source: :wikidata)`.

Search for any other `FactSheet.new(` caller: `grep -rn "FactSheet.new" app lib test` and pass a source to each.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/ test/lib/tasks/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/goodreads_replay/apply/strip_identifier.rb app/lib/services/books/amazon_edition_upserter.rb app/lib/services/books/authors/ lib/tasks/e2e.rake test/lib/services/books/
git commit -m "Identifiers: replay, Amazon and author enrichment writers record their source

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: The OL key backfill writes `open_library`; revert goes back to `legacy`

**Files:**
- Modify: `web-app/app/lib/services/books/ol_backfill/apply_book.rb` (`decide`, `set_work_key`, `save_duplicates`)
- Modify: `web-app/app/lib/services/books/ol_backfill/author_keys.rb:~40`
- Modify: `web-app/app/lib/services/books/ol_backfill/revert.rb` (`restore_work_keys`)
- Test: `web-app/test/lib/services/books/ol_backfill/apply_book_test.rb`, `author_keys_test.rb`, `revert_test.rb`

**Interfaces:**
- Consumes: `Identifier.sources` (Task 1).
- Produces: after a `confirmed`, `updated`, `replaced` or `keyed` outcome the book's work key row is `open_library`; new duplicate keys and author keys are `open_library`; `Revert` leaves no key the backfill touched as `open_library`.

Increment 2 replaces this code's home (it becomes stage 1 of the verification pass); this task keeps the existing tool honest until then.

- [ ] **Step 1: Write the failing tests**

`apply_book_test.rb`, following its existing per-outcome tests:

```ruby
  test "a keyed book's new key is open_library" do
    # Arrange a keyed outcome (book with no key, an accept) the way this file's keyed tests do.
    assert book.identifiers.find_by!(identifier_type: :books_work_openlibrary_id).source_open_library?
  end

  test "a confirmed book's legacy key becomes open_library" do
    # Arrange a confirmed outcome the way this file's confirmed tests do, with the stored key created source: :legacy.
    assert book.identifiers.find_by!(identifier_type: :books_work_openlibrary_id).source_open_library?
  end

  test "a confirmed_on_abstain book's key becomes open_library and nothing else changes" do
    # Arrange a confirm-on-abstain outcome the way this file's confirm-on-abstain tests do,
    # with the stored key created source: :legacy, and keep that file's assertions that no key,
    # duplicate, author or pair changed.
    assert book.identifiers.find_by!(identifier_type: :books_work_openlibrary_id).source_open_library?
  end

  test "saved duplicate keys are open_library" do
    # Arrange a /resolve accept carrying duplicates the way this file's duplicate-key tests do.
    assert book.identifiers.where(identifier_type: :books_work_openlibrary_duplicate_id).all?(&:source_open_library?)
  end

  test "an unsure book's keys keep their source" do
    # Arrange the existing unsure scenario with a stored legacy key.
    assert book.identifiers.find_by!(identifier_type: :books_work_openlibrary_id).source_legacy?
  end
```

`author_keys_test.rb`:

```ruby
  test "an added author key is open_library" do
    # Arrange an author with no key the way this file's add-key tests do.
    assert author.identifiers.find_by!(identifier_type: :books_author_openlibrary_id).source_open_library?
  end
```

`revert_test.rb`:

```ruby
  test "reverting a confirmed book puts its key back to legacy" do
    # Arrange a confirmed row whose book holds new_key (also in old_keys) as open_library.
    Services::Books::OlBackfill::Revert.call(book: book)

    assert book.identifiers.find_by!(identifier_type: :books_work_openlibrary_id, value: row.new_key).source_legacy?
  end

  test "restored old keys come back legacy" do
    # Arrange a replaced row the way this file's revert tests do.
    Services::Books::OlBackfill::Revert.call(book: book)

    assert book.identifiers.where(identifier_type: :books_work_openlibrary_id).all?(&:source_legacy?)
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/ol_backfill/`
Expected: the new tests FAIL; existing ones pass.

- [ ] **Step 3: Implement**

`apply_book.rb`:

```ruby
        def set_work_key(stored, key)
          @book.identifiers.where(identifier_type: WORK_KEY).where.not(value: key).destroy_all
          @book.identifiers.where(identifier_type: DUPLICATE_KEY, value: key).destroy_all
          if stored.include?(key)
            @book.identifiers.where(identifier_type: WORK_KEY, value: key).update_all(source: ::Identifier.sources[:open_library], updated_at: Time.current)
          else
            @book.identifiers.create!(identifier_type: WORK_KEY, value: key, source: :open_library)
          end
        end
```

(`update_all` here touches one book's one row, by key; it is not a bulk write.)

The confirm-on-abstain branch in `decide` passed the same title-and-author check, and the spec counts it as settled (stage 2 runs for it), so its key is trusted too. Change only its source; it still changes no key, duplicate, author or pair:

```ruby
          if answer.confirm_only
            @book.identifiers.where(identifier_type: WORK_KEY, value: work.key)
              .update_all(source: ::Identifier.sources[:open_library], updated_at: Time.current)
            return unchanged(:confirmed, stored, work.key)
          end
```

This replaces the one-line `return unchanged(:confirmed, stored, work.key) if answer.confirm_only`. `Identifiers::MarkLegacy` (Task 7) relabels the same keys, because `KEYED_OUTCOMES` includes confirmed-on-abstain rows.

In `save_duplicates`: `@book.identifiers.create!(identifier_type: DUPLICATE_KEY, value: duplicate, source: :open_library)`.

`author_keys.rb`: `author.identifiers.create!(identifier_type: AUTHOR_KEY, value: key, source: :open_library)`.

`revert.rb`, `restore_work_keys`:

```ruby
        def restore_work_keys(row)
          held = @book.identifiers.where(identifier_type: ApplyBook::WORK_KEY)
          held.where(value: row.new_key).destroy_all if row.new_key.present? && !row.old_keys.include?(row.new_key)
          # A key the backfill confirmed was upgraded in place; it was legacy before.
          held.where(value: row.old_keys).update_all(source: ::Identifier.sources[:legacy], updated_at: Time.current)
          (row.old_keys - held.reload.pluck(:value)).each do |key|
            @book.identifiers.create!(identifier_type: ApplyBook::WORK_KEY, value: key, source: :legacy)
          end
        end
```

Update the comment above it: "Old keys were legacy (the backfill only ever checked stored keys); they come back legacy."

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/ol_backfill/ test/lib/tasks/books_ol_backfill_rake_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/ol_backfill/ test/lib/services/books/ol_backfill/
git commit -m "Identifiers: the OL key backfill writes open_library; revert restores legacy

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Mergers keep the more trusted duplicate

**Files:**
- Modify: `web-app/app/lib/books/book/merger.rb:203-218` (`merge_identifiers`)
- Modify: `web-app/app/lib/books/author/merger.rb:140-155` (`merge_identifiers`)
- Test: `web-app/test/lib/books/book/merger_test.rb`, `web-app/test/lib/books/author/merger_test.rb`

**Interfaces:**
- Consumes: `Identifier.trust_rank` (Task 1).

- [ ] **Step 1: Write the failing tests**

`test/lib/books/book/merger_test.rb`, following the file's existing merge setup (`source_book` merged into `target_book`):

```ruby
  test "a duplicate identifier keeps the more trusted source" do
    Identifier.create!(identifiable: source_book, identifier_type: :books_work_isbn13, value: "9780000000017", source: :open_library)
    Identifier.create!(identifiable: target_book, identifier_type: :books_work_isbn13, value: "9780000000017", source: :legacy)

    # run the merger as the file's other tests do

    kept = Identifier.where(identifiable: target_book, identifier_type: :books_work_isbn13, value: "9780000000017")
    assert_equal 1, kept.count
    assert kept.first.source_open_library?
  end

  test "a less trusted duplicate never downgrades the target's row" do
    Identifier.create!(identifiable: source_book, identifier_type: :books_work_isbn13, value: "9780000000017", source: :legacy)
    Identifier.create!(identifiable: target_book, identifier_type: :books_work_isbn13, value: "9780000000017", source: :worldcat)

    # run the merger

    assert Identifier.find_by!(identifiable: target_book, identifier_type: :books_work_isbn13, value: "9780000000017").source_worldcat?
  end

  test "a moved identifier keeps its source" do
    Identifier.create!(identifiable: source_book, identifier_type: :books_work_oclc_id, value: "424242", source: :worldcat)

    # run the merger

    assert Identifier.find_by!(identifiable: target_book, identifier_type: :books_work_oclc_id, value: "424242").source_worldcat?
  end
```

Add the same first two tests to `test/lib/books/author/merger_test.rb` with `books_author_viaf` values and author records.

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/books/book/merger_test.rb test/lib/books/author/merger_test.rb`
Expected: "keeps the more trusted source" FAILS (the target's legacy row survives); the other two pass.

- [ ] **Step 3: Implement**

In both mergers, the `if existing` branch becomes:

```ruby
          if existing
            if ::Identifier.trust_rank(identifier.source) > ::Identifier.trust_rank(existing.source)
              existing.update!(source: identifier.source)
            end
            identifier.destroy!
```

Add a one-line comment above it: "Two rows for one value: the survivor takes the more trusted source (identifier provenance spec, section 1)."

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/books/ test/lib/actions/admin/books/ test/lib/services/books/goodreads_replay/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/books/book/merger.rb app/lib/books/author/merger.rb test/lib/books/book/merger_test.rb test/lib/books/author/merger_test.rb
git commit -m "Identifiers: a merge keeps the more trusted of two duplicate rows

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The one-time marking, the writer lint, docs

**Files:**
- Create: `web-app/app/lib/services/identifiers/mark_legacy.rb`
- Create: `web-app/lib/tasks/identifiers.rake`
- Create: `web-app/test/lib/services/identifiers/mark_legacy_test.rb`
- Create: `web-app/test/lib/tasks/identifiers_rake_test.rb`
- Create: `web-app/test/lint/identifier_source_test.rb`
- Create: `docs/features/identifier-provenance.md`
- Modify: `docs/launch-todo.md` (section 5)

**Interfaces:**
- Consumes: `Identifier::BOOKS_TYPES`, `Identifier.sources` (Task 1); `Books::OpenLibraryBackfill` and its `KEYED_OUTCOMES` (existing).
- Produces: `Services::Identifiers::MarkLegacy.call(batch_size: 10_000) -> Result` with `data: {legacy: Integer, open_library: Integer}`.

Because `zeitwerk` eager-loading is off in tests, run `CI=1 bin/rails zeitwerk:check` after creating `app/lib/services/identifiers/` (a new directory).

- [ ] **Step 1: Write the failing service tests**

`web-app/test/lib/services/identifiers/mark_legacy_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Identifiers
    class MarkLegacyTest < ActiveSupport::TestCase
      test "marks every unmarked books-domain row legacy and leaves music alone" do
        book_row = identifiers(:war_and_peace_isbn13)
        music_row = identifiers(:david_bowie_musicbrainz)

        result = MarkLegacy.call

        assert result.success?
        assert book_row.reload.source_legacy?
        assert_nil music_row.reload.source
        assert_operator result.data[:legacy], :>=, 1
      end

      test "never touches a row that already has a source" do
        row = Identifier.create!(identifiable: books_books(:war_and_peace), identifier_type: :books_work_oclc_id,
          value: "99", source: :worldcat)

        MarkLegacy.call

        assert row.reload.source_worldcat?
      end

      test "is safe to re-run" do
        MarkLegacy.call
        second = MarkLegacy.call

        assert_equal 0, second.data[:legacy]
      end

      test "relabels the keys the OL key backfill wrote or confirmed as open_library" do
        book = books_books(:crime_and_punishment)
        author = books_authors(:tolstoy)
        Identifier.create!(identifiable: book, identifier_type: :books_work_openlibrary_duplicate_id, value: "OL9W")
        Identifier.create!(identifiable: author, identifier_type: :books_author_openlibrary_id, value: "OL1A")
        Books::OpenLibraryBackfill.create!(book: book, outcome: :confirmed, new_key: "OL262758W", old_keys: ["OL262758W"],
          duplicate_keys: ["OL9W"], author_changes: {"added" => [[author.id, "OL1A"]]}, run_id: "test")

        result = MarkLegacy.call

        assert Identifier.find_by!(identifiable: book, identifier_type: :books_work_openlibrary_id, value: "OL262758W").source_open_library?
        assert Identifier.find_by!(identifiable: book, identifier_type: :books_work_openlibrary_duplicate_id, value: "OL9W").source_open_library?
        assert Identifier.find_by!(identifiable: author, identifier_type: :books_author_openlibrary_id, value: "OL1A").source_open_library?
        assert_equal 3, result.data[:open_library]
      end

      test "a reverted or unsure backfill row relabels nothing" do
        book = books_books(:crime_and_punishment)
        Books::OpenLibraryBackfill.create!(book: book, outcome: :reverted, new_key: "OL262758W", old_keys: [], run_id: "test")

        MarkLegacy.call

        assert identifiers(:crime_and_punishment_openlibrary).reload.source_legacy?
      end
    end
  end
end
```

(`crime_and_punishment_openlibrary` is the fixture holding `OL262758W`. Check `Books::OpenLibraryBackfill`'s required columns before running; add any it validates.)

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/identifiers/mark_legacy_test.rb`
Expected: FAIL (`uninitialized constant Services::Identifiers::MarkLegacy`).

- [ ] **Step 3: Implement the service**

`web-app/app/lib/services/identifiers/mark_legacy.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Identifiers
    # Identifier provenance spec, section 1: once, after the source column
    # ships. Every books-domain identifier with no source came from legacy
    # (or from code acting on legacy's choices), so it becomes legacy. Then
    # the keys the OL key backfill wrote or confirmed, if it ran first,
    # become open_library. Batched by id; only null rows are touched, so a
    # re-run marks nothing new. Music and games rows are never touched.
    class MarkLegacy
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(batch_size: 10_000)
        new(batch_size).call
      end

      def initialize(batch_size)
        @batch_size = batch_size
      end

      def call
        legacy = mark_legacy
        open_library = relabel_backfill_keys
        Result.new(success?: true, data: {legacy: legacy, open_library: open_library}, errors: [])
      end

      private

      def mark_legacy
        marked = 0
        ::Identifier.where(identifiable_type: ::Identifier::BOOKS_TYPES, source: nil).in_batches(of: @batch_size) do |batch|
          marked += batch.update_all(source: ::Identifier.sources[:legacy], updated_at: Time.current)
        end
        marked
      end

      def relabel_backfill_keys
        relabelled = 0
        ::Books::OpenLibraryBackfill.where(outcome: ::Books::OpenLibraryBackfill::KEYED_OUTCOMES).find_each do |row|
          relabelled += relabel("Books::Book", row.book_id, "books_work_openlibrary_id", [row.new_key])
          relabelled += relabel("Books::Book", row.book_id, "books_work_openlibrary_duplicate_id", row.duplicate_keys)
          Array(row.author_changes["added"]).each do |author_id, key|
            relabelled += relabel("Books::Author", author_id, "books_author_openlibrary_id", [key])
          end
        end
        relabelled
      end

      def relabel(type, id, identifier_type, values)
        values = Array(values).compact
        return 0 if values.empty?

        ::Identifier.where(identifiable_type: type, identifiable_id: id, identifier_type: identifier_type, value: values)
          .where.not(source: ::Identifier.sources[:open_library])
          .update_all(source: ::Identifier.sources[:open_library], updated_at: Time.current)
      end
    end
  end
end
```

Check `Books::OpenLibraryBackfill::KEYED_OUTCOMES` holds `confirmed updated replaced keyed` (`grep -n KEYED_OUTCOMES app/models/books/open_library_backfill.rb`); if it differs, use those four names explicitly.

- [ ] **Step 4: Run the service tests to verify they pass**

Run: `bin/rails test test/lib/services/identifiers/mark_legacy_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: PASS; "All is good!"

- [ ] **Step 5: The rake task, test first**

`web-app/test/lib/tasks/identifiers_rake_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "rake"

class IdentifiersRakeTest < ActiveSupport::TestCase
  setup do
    unless Rake::Task.task_defined?("identifiers:mark_legacy")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/identifiers.rake").to_s }
    end
    Rake::Task["identifiers:mark_legacy"].reenable
  end

  test "mark_legacy prints the counts" do
    Services::Identifiers::MarkLegacy.expects(:call).returns(
      Services::Identifiers::MarkLegacy::Result.new(success?: true, data: {legacy: 12, open_library: 3}, errors: [])
    )

    assert_output(/12 identifiers marked legacy, 3 relabelled open_library/) { Rake::Task["identifiers:mark_legacy"].invoke }
  end
end
```

Run: `bin/rails test test/lib/tasks/identifiers_rake_test.rb` → FAIL (no task).

`web-app/lib/tasks/identifiers.rake`:

```ruby
# frozen_string_literal: true

namespace :identifiers do
  desc "Once, after identifiers.source ships: mark every unmarked books identifier legacy (safe to re-run)"
  task mark_legacy: :environment do
    result = Services::Identifiers::MarkLegacy.call
    puts "#{result.data[:legacy]} identifiers marked legacy, #{result.data[:open_library]} relabelled open_library"
  end
end
```

Run: `bin/rails test test/lib/tasks/identifiers_rake_test.rb` → PASS.

- [ ] **Step 6: The writer lint, test first**

`web-app/test/lint/identifier_source_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

# Identifier provenance spec, section 1: every books writer sets a source.
# A model validation would break 135 test call sites that build books
# identifiers by hand, so the rule is enforced on the app's write sites
# instead. A write is the statement starting at a matching line and
# running to its closing parenthesis (at most WINDOW lines); it must
# mention `source`. Music and games code is not scanned.
class IdentifierSourceTest < ActiveSupport::TestCase
  ROOTS = %w[
    app/lib/books
    app/lib/data_importers/books
    app/lib/services/books
    app/lib/services/books_migration
    app/lib/services/identifiers
    lib/tasks
  ].freeze
  WRITE = /identifiers\.(create!?|find_or_create_by!?|find_or_initialize_by|build|new)\(|Identifier\.(create!?|find_or_create_by!?|insert_all|upsert_all|new)\(/
  WINDOW = 6

  test "every books identifier write names a source" do
    offenders = []
    ROOTS.each do |root|
      Dir[Rails.root.join(root, "**/*.{rb,rake}")].each do |path|
        lines = File.readlines(path)
        lines.each_with_index do |line, index|
          next unless line.match?(WRITE)
          next if music_or_games?(path, line)

          statement = lines[index, WINDOW].join
          next if statement.include?("source")
          next if followed_by_source_assignment?(lines, index)

          offenders << "#{path.delete_prefix("#{Rails.root}/")}:#{index + 1}: #{line.strip}"
        end
      end
    end

    assert_empty offenders, "books identifier writes with no source:\n#{offenders.join("\n")}"
  end

  private

  # `identifier = ...find_or_initialize_by(...)` followed by `identifier.source = ...`
  def followed_by_source_assignment?(lines, index)
    variable = lines[index][/\A\s*(\w+)\s*=/, 1]
    variable && lines[index + 1, WINDOW].to_a.any? { |line| line.include?("#{variable}.source") }
  end

  def music_or_games?(path, line)
    path.include?("/tasks/music") || path.include?("/tasks/games") || line.match?(/music_|games_/)
  end
end
```

Run: `bin/rails test test/lint/identifier_source_test.rb`
Expected after Tasks 2-6: PASS. If it lists an offender, it is a writer this plan missed: fix the writer (set its source per the spec's table), never weaken the lint. Two known shapes to check by eye if they appear: `EditionIdentifierBackfill` (its `source` is in `row`, not on the `insert_all` line: if the lint flags `Identifier.insert_all(rows, ...)`, add the comment `# rows carry source: legacy (see #row)` on that line, which names `source`), and `lib/tasks/e2e.rake` (fixed in Task 4).

- [ ] **Step 7: Docs**

Create `docs/features/identifier-provenance.md`:

```markdown
# Identifier provenance

Every books-domain identifier (`Books::Book`, `Books::Edition`, `Books::Author`, `Books::Series`)
records who attached it in `identifiers.source`. Music and games rows are `null`.
Spec: `docs/superpowers/specs/2026-10-16-book-verification-design.md`, section 1.

| Source | Meaning | Written by |
|---|---|---|
| `legacy` | came from the legacy app, or was there before provenance | legacy migrators, `data_migration:sync`, `EditionIdentifierBackfill`, `identifiers:mark_legacy` |
| `open_library` | Open Library tied it to the book | the book and author importers' Open Library providers, the OL key backfill, the verification pass |
| `worldcat` | a WorldCat record agreeing on title, author and year | the verification pass |
| `goodreads_import` | copied from a Goodreads export row or page by our own matcher | member Goodreads imports, the replay's identifier fixes |
| `amazon` | the live Amazon product API | `AmazonEditionUpserter` |
| `wikidata`, `viaf` | author enrichment | `FactSheet` via `ApplyWikidata` / `ApplyViaf`, `RestoreIdentifier` |

**Trust.** `Identifier.verified` is `open_library` and `worldcat`. Nothing else is trusted, `null`
included. The existing finders still read every identifier; only new code reads `verified`.

**Writers set it on new rows only.** An importer or enrichment that finds the row already there
leaves its source alone, so a re-run never downgrades a verified row. A new books writer must set a
source: `test/lint/identifier_source_test.rb` fails otherwise.

**Merges** keep one row per value, with the more trusted source (`Identifier.trust_rank`).

**The one-time marking.** `bin/rails identifiers:mark_legacy` marks every books-domain row with no
source `legacy` (batches of 10,000), then relabels `open_library` the keys the OL key backfill wrote
or confirmed. Safe to re-run. Until it runs, a books-domain `null` means `legacy`.
```

In `docs/launch-todo.md` section 5 ("Cleanup, after the switch-over"), insert a new item before "Open Library key backfill" and renumber the items after it in that section only:

```markdown
2. **Identifier provenance, once.** After the deploy that adds `identifiers.source`, run
   `bin/rails identifiers:mark_legacy`. It prints how many rows it marked; a second run prints 0.
   Details: `docs/features/identifier-provenance.md`.
```

- [ ] **Step 8: Full verification**

Run:

```bash
bin/rails test
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
```

Expected: all green, no new warning lines (AGENTS.md: a clean run emits none beyond the two known sources).

- [ ] **Step 9: Commit**

```bash
git add app/lib/services/identifiers/ lib/tasks/identifiers.rake test/lib/services/identifiers/ test/lib/tasks/identifiers_rake_test.rb test/lint/identifier_source_test.rb ../docs/features/identifier-provenance.md ../docs/launch-todo.md
git commit -m "Identifiers: one-time legacy marking, writer lint and provenance doc

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## After the plan

- Dev: run `bin/rails identifiers:mark_legacy` against the shared dev DB only with Shane's go-ahead (it updates ~1.1M rows; reversible only by restoring a snapshot, so take `bin/snapshot-dev-db.sh --label pre-mark-legacy` first).
- Increment 2 (the verification pass) gets its own plan once this merges.
