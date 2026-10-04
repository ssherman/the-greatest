# Goodreads Import Increment 3: Resolver Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a Goodreads export CSV into resolved editions: parse and normalize every row, store
imports/rows/editions/provenance, resolve each edition once through the books finder, and create a
provisional book (under an advisory lock) when nothing matches. Ship a dry-run rake that prints the
decisions for a local CSV and saves nothing.

**Architecture:** Plain parsers in `app/lib/books/` (`Books::Isbn`, `Books::GoodreadsId`,
`Books::Goodreads::ExportFile`/`ExportRow`) feed four new tables. Five services under
`app/lib/services/books/goodreads_imports/` do the work: `ParseRows` writes rows and editions;
`ResolveImport` loops over the editions; `ResolveEdition` runs the finder; `CreateBook` takes the
lock and creates through the existing book importer; `DryRun` runs all of it in a savepoint and
rolls it back. The book importer gains four options: `match:`, `provisional:`,
`stamp_identifiers:`, `enrich:`.

**Tech Stack:** Rails 8.1, Postgres (partial unique indexes, `pg_advisory_xact_lock`), Ruby `csv`,
Minitest 6 + fixtures + Mocha + WebMock.

**Spec:** `docs/superpowers/specs/2026-10-03-goodreads-import-design.md` (§3 data model, §4 parsing,
§5 resolution, §13 failure handling, §14 testing; increment 3 in §15).

## Global Constraints

- Run every Rails, test and lint command from `web-app/`. Docs live in the root `docs/`.
- Lint is `bundle exec standardrb`, never `bin/rubocop`. Do not run brakeman.
- Models are made with `bin/rails generate model …` (pass `--skip` so the existing
  `app/models/books.rb` is never touched), then edited.
- Inside `module Books`, `module DataImporters` or `module Services`, reference other namespaces
  root-anchored: `::Books::Book`, `::Services::Text::NameNormalizer`, `::Identifier`.
- Minitest 6: `assert_nil`, never `assert_equal nil, …`.
- A clean `bin/rails test` emits no new warnings.
- The development database is shared and not disposable. Migrate with
  `ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate`, then `git diff db/schema.rb` must show only
  this plan's four tables plus the version line.
- Spec rules that every task honors:
  - Columns are read **by header name, never by position**.
  - Encoding: strip a BOM; if not valid UTF-8 try Windows-1252, then scrub. **Never
    `force_encoding` alone.**
  - **`Private Notes` is never stored.**
  - Title is kept whole, subtitle included; only a trailing `(Series Name, #N)` is split off.
    **Nothing after a colon is ever dropped.**
  - Only the primary `Author` is trusted as an author. `Additional Authors` is AI context only.
  - An invalid ISBN is dropped, not stored.
  - An AI "none of these" ends in create-and-flag. **It never falls back to the top search hit.**
  - Matching AI is **not capped**; `ai_calls_count` counts it.
  - The finder never reads through `catalog`: provisional books must stay findable so a second
    import links to the first one's book instead of creating another.
  - One bad row never stops an import; Postgres errors re-raise.
- No new jobs, no production caller. Nothing outside the dry-run rake calls these services yet.

## Decisions this plan makes (carried as rulings)

1. **`binding` is stored as `book_format`.** An Active Record attribute named `binding` collides
   with `Kernel#binding` and raises `DangerousAttributeError`. Cost if wrong: a column rename.
2. **Import rows get a `notes` string array** for "a bad date is dropped and noted on the row"
   (§4); `outcome_detail` belongs to the write step (increment 6). Cost: one column.
3. **The signature is built from the series-stripped title** plus the primary author, and the
   advisory-lock key is the signature. So "Dune (Dune, #1)" and "Dune" by the same author share
   a key, and two editions of one book racing to create it serialize. Cost: none for honest
   exports; a hostile row still gets its own edition because its title differs.
4. **The importer gains a fourth option, `match:`**, alongside the spec's three. Without it,
   `CreateBook` would run the finder a third time and could ask the AI again, which doubles the
   cost and might flip the answer. `Providers::OpenLibrary` already expects to reuse the finder's
   resolution through the match. Cost: one keyword on `ImporterBase#call`.
5. **The `private_imports` storage service and `has_one_attached` are deferred** to increment 4
   (HTML) and increment 6 (the uploaded file). Increment 3 reads local files only.
6. **With no fetcher yet, unmatched editions are created with `verification: unverified`.** That
   is the spec's "fetcher unavailable" branch. Increment 4 adds the fetch and the sweep that
   verifies these later.
7. **These services do not move `import.status`.** The job that owns the phases is increment 6.
8. **The re-check under the lock looks only at editions resolved `created` with the same
   signature, minus the books the finder already considered.** A book the finder saw and turned
   down (including an AI "none") stays turned down.
9. **Counters are recomputed from state at the end of `ResolveImport`, except `ai_calls_count`,
   which is incremented per call.** A retry then neither double-counts nor loses AI calls.
10. **The dry run uses `transaction(requires_new: true)`** so its rollback works inside a test's
    transaction too. The rake takes an optional `user_id` (default: the first user), because an
    import needs an owner even when it never commits.

## Review Focus

1. **Legacy exports that failed with `CSV::MalformedCSVError`.** 23 legacy imports died on a parse
   error. The likely cause is a stray quote inside a field. The file must parse with liberal
   parsing; one odd row must not refuse the whole file. Test: Task 2, "keeps a row with a stray
   quote".
2. **Reviews that span several lines.** A quoted `My Review` with newlines must stay one row, and
   row numbers count records, not lines. Test: Task 2, "numbers rows by record".
3. **A real Goodreads id under a different title** (a hostile or AI-invented row) must get its own
   edition and leave the honest edition untouched. Test: Task 6.
4. **Retrying after a crash mid-resolution** must not duplicate rows, editions, books or
   decisions, and must not double-count. Tests: Task 6 "running it twice" and Task 8 "running it
   again".
5. **An edition whose book was deleted later** must be resolved again, never left pointing at
   nothing. Test: Task 8.

## File Structure

| File | Responsibility |
|---|---|
| `app/lib/books/isbn.rb` | ISBN checksum + 10↔13 (mirrors `data-sources/src/common/normalize.py`) |
| `app/lib/books/goodreads_id.rb` | Goodreads id from bare / slug / URL forms |
| `app/lib/books/goodreads/export_file.rb` | bytes → decoded text → `ExportRow`s; refuses non-exports |
| `app/lib/books/goodreads/export_row.rb` | one row: edition fields, user fields, notes, signature |
| `db/migrate/*_create_books_goodreads_{imports,editions,import_rows,import_records}.rb` | the four tables |
| `app/models/books/goodreads_{import,edition,import_row,import_record}.rb` | associations, enums, validations |
| `app/models/user.rb`, `app/models/books/book.rb`, `app/lib/books/book/merger.rb` | `has_many` + the merger moves editions |
| `app/lib/data_importers/books/book/import_query.rb`, `finder.rb` | series + additional authors as AI context |
| `app/lib/data_importers/importer_base.rb`, `import_result.rb` | `match:` option, `created_author_ids` |
| `app/lib/data_importers/books/book/importer.rb`, `providers/{authors,open_library,query_identifiers}.rb` | `provisional:`, `stamp_identifiers:`, `enrich:` |
| `app/lib/data_importers/books/author/importer.rb` | `provisional:` |
| `app/lib/services/books/goodreads_imports/parse_rows.rb` | rows + editions, idempotent |
| `app/lib/services/books/goodreads_imports/create_book.rb` | lock, re-check, create, provenance |
| `app/lib/services/books/goodreads_imports/resolve_edition.rb` | cache → finder → link or create |
| `app/lib/services/books/goodreads_imports/resolve_import.rb` | every edition once; counters |
| `app/lib/services/books/goodreads_imports/dry_run.rb` | parse + resolve in a savepoint, report, roll back |
| `lib/tasks/books/goodreads.rake` | `books:goodreads:resolve_file[path,user_id]` |
| `test/support/goodreads_import_helper.rb` | shared stubs and builders |
| `docs/features/goodreads-import.md` | feature doc |

---

### Task 1: ISBN and Goodreads id normalizers

**Files:**
- Create: `web-app/app/lib/books/isbn.rb`, `web-app/app/lib/books/goodreads_id.rb`
- Test: `web-app/test/lib/books/isbn_test.rb`, `web-app/test/lib/books/goodreads_id_test.rb`

**Interfaces:**
- Produces: `Books::Isbn.normalize(raw) → Books::Isbn::Normalized(isbn13:, isbn10:) | nil`
  (`isbn10` is nil for a 979 ISBN-13). `Books::GoodreadsId.normalize(raw) → String | nil` (digits,
  no leading zeros, at most 18 digits so it fits a bigint).

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/books/isbn_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  class IsbnTest < ActiveSupport::TestCase
    test "an ISBN-10 also yields its ISBN-13" do
      assert_equal ["9780441013593", "0441013597"], pair(Isbn.normalize("0441013597"))
    end

    test "a 978 ISBN-13 also yields its ISBN-10" do
      assert_equal ["9780140447934", "0140447938"], pair(Isbn.normalize("9780140447934"))
    end

    test "a 979 ISBN-13 has no ISBN-10" do
      assert_equal ["9791032305690", nil], pair(Isbn.normalize("9791032305690"))
    end

    test "the Goodreads spreadsheet wrapper, hyphens and spaces are ignored" do
      assert_equal "9780441013593", Isbn.normalize('="9780441013593"').isbn13
      assert_equal "9780441013593", Isbn.normalize("978-0-441 01359-3").isbn13
    end

    test "an ISBN-10 check digit of X is accepted in either case" do
      assert_equal "080442957X", Isbn.normalize("080442957x").isbn10
    end

    test "a failed checksum is dropped" do
      assert_nil Isbn.normalize("0441013598")
      assert_nil Isbn.normalize("9780441013594")
    end

    test "blank, wrapped-blank and non-ISBN values are dropped" do
      [nil, "", '=""', "B00ABC1234", "12345", "ISBN 0441013597"].each do |raw|
        assert_nil Isbn.normalize(raw), raw.inspect
      end
    end

    private

    def pair(normalized)
      [normalized.isbn13, normalized.isbn10]
    end
  end
end
```

`web-app/test/lib/books/goodreads_id_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  class GoodreadsIdTest < ActiveSupport::TestCase
    test "a bare id is kept" do
      assert_equal "4671", GoodreadsId.normalize("4671")
      assert_equal "4671", GoodreadsId.normalize(" 4671 ")
    end

    test "slug forms keep only the leading digits" do
      assert_equal "32076670", GoodreadsId.normalize("32076670-ball-lightning")
      assert_equal "49122921", GoodreadsId.normalize("49122921-konosuba?from_search=true&from_srp=true")
      assert_equal "4671", GoodreadsId.normalize("4671.The_Great_Gatsby")
    end

    test "a book page URL yields its id" do
      assert_equal "4671", GoodreadsId.normalize("https://www.goodreads.com/book/show/4671.The_Great_Gatsby")
    end

    test "leading zeros are dropped" do
      assert_equal "7", GoodreadsId.normalize("007")
    end

    test "values with no usable id are nil" do
      [nil, "", "abc", "0", "1" * 19].each do |raw|
        assert_nil GoodreadsId.normalize(raw), raw.inspect
      end
    end
  end
end
```

Checksums used above, verified by hand: `0441013597` (weighted sum 125 ≡ 4 mod 11 → 7),
`9780140447934` (106 → 4), `9791032305690` (110 → 0), `080442957X` (199 ≡ 1 mod 11 → X).

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/books/isbn_test.rb test/lib/books/goodreads_id_test.rb`
Expected: errors, `uninitialized constant Books::Isbn` / `Books::GoodreadsId`.

- [ ] **Step 3: Implement**

`web-app/app/lib/books/isbn.rb`:

```ruby
# frozen_string_literal: true

module Books
  # The Rails twin of normalize_isbn in data-sources/src/common/normalize.py:
  # drop every non-alphanumeric character, check the checksum, derive the
  # other form. Unlike the Python twin it returns nil for a failed checksum
  # instead of flagging it, because an import never stores an invalid ISBN
  # (Goodreads import spec §4).
  module Isbn
    Normalized = Data.define(:isbn13, :isbn10)

    def self.normalize(raw)
      cleaned = raw.to_s.gsub(/[^0-9A-Za-z]/, "").upcase

      if cleaned.match?(/\A\d{9}[\dX]\z/)
        return nil unless isbn10_check_digit(cleaned[0, 9]) == cleaned[9]

        body13 = "978#{cleaned[0, 9]}"
        Normalized.new(isbn13: body13 + isbn13_check_digit(body13), isbn10: cleaned)
      elsif cleaned.match?(/\A\d{13}\z/)
        return nil unless isbn13_check_digit(cleaned[0, 12]) == cleaned[12]

        body10 = cleaned[3, 9]
        Normalized.new(isbn13: cleaned, isbn10: cleaned.start_with?("978") ? body10 + isbn10_check_digit(body10) : nil)
      end
    end

    def self.isbn10_check_digit(body)
      total = body.chars.each_with_index.sum { |digit, index| (10 - index) * digit.to_i }
      remainder = (11 - (total % 11)) % 11
      (remainder == 10) ? "X" : remainder.to_s
    end

    def self.isbn13_check_digit(body)
      total = body.chars.each_with_index.sum { |digit, index| digit.to_i * (index.even? ? 1 : 3) }
      ((10 - (total % 10)) % 10).to_s
    end

    private_class_method :isbn10_check_digit, :isbn13_check_digit
  end
end
```

`web-app/app/lib/books/goodreads_id.rb`:

```ruby
# frozen_string_literal: true

module Books
  # A Goodreads book id from any of the forms it arrives in: bare ("4671"),
  # slugged ("4671.The_Great_Gatsby", "32076670-ball-lightning", with or
  # without a query string) or a book page URL. 543 slug forms were carried
  # into books_work_goodreads_id from the legacy app. Only the leading
  # integer identifies the book (normalize_goodreads in
  # data-sources/src/common/normalize.py). Longer than 18 digits cannot be a
  # Goodreads id and would overflow the bigint column.
  module GoodreadsId
    SHOW_PATH = %r{/book/show/(\d+)}
    LEADING_DIGITS = /\A(\d+)/
    MAX_DIGITS = 18

    def self.normalize(raw)
      text = raw.to_s.strip
      digits = text[SHOW_PATH, 1] || text[LEADING_DIGITS, 1]
      return nil if digits.nil? || digits.length > MAX_DIGITS

      id = digits.to_i
      id.positive? ? id.to_s : nil
    end
  end
end
```

- [ ] **Step 4: Run them to verify they pass**

Run: `bin/rails test test/lib/books/isbn_test.rb test/lib/books/goodreads_id_test.rb`
Expected: 12 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/lib/books/isbn.rb app/lib/books/goodreads_id.rb test/lib/books/isbn_test.rb test/lib/books/goodreads_id_test.rb
git commit -m "Books: ISBN and Goodreads id normalizers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Export file and row parsing

**Files:**
- Create: `web-app/app/lib/books/goodreads/export_file.rb`, `web-app/app/lib/books/goodreads/export_row.rb`
- Test: `web-app/test/lib/books/goodreads/export_file_test.rb`, `web-app/test/lib/books/goodreads/export_row_test.rb`

**Interfaces:**
- Consumes: `Books::Isbn.normalize`, `Books::GoodreadsId.normalize` (Task 1).
- Produces:
  - `Books::Goodreads::ExportFile.parse(bytes) → Result(success?:, data: {rows: [ExportRow]}, errors: [String])`.
  - `ExportRow.new(row_number:, fields:)` with readers `row_number raw notes goodreads_book_id
    (Integer|nil) title series_name series_number primary_author additional_authors isbn13 isbn10
    original_publication_year year_published publisher book_format pages exclusive_shelf shelves
    shelf_positions rating review_body date_read date_added read_count`, plus `errors`, `valid?`,
    `signature`, `edition_attributes`, `row_attributes`.
  - `ExportRow.signature(title, primary_author) → String` (SHA-256 hex).

- [ ] **Step 1: Write the failing row tests**

`web-app/test/lib/books/goodreads/export_row_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  module Goodreads
    class ExportRowTest < ActiveSupport::TestCase
      def row(fields)
        ExportRow.new(row_number: 1, fields: {"Book Id" => "4671", "Title" => "The Great Gatsby", "Author" => "F. Scott Fitzgerald"}.merge(fields))
      end

      test "the Goodreads id is read from a slug form" do
        assert_equal 32076670, row("Book Id" => "32076670-ball-lightning").goodreads_book_id
      end

      test "a trailing series suffix is split off and kept" do
        parsed = row("Title" => "The Final Empire (Mistborn, #1)")

        assert_equal ["The Final Empire", "Mistborn", "1"], [parsed.title, parsed.series_name, parsed.series_number]
      end

      test "a series suffix without a comma or with a range still splits" do
        assert_equal ["Dune", "Dune", "1"], row("Title" => "Dune (Dune #1)").then { |r| [r.title, r.series_name, r.series_number] }
        assert_equal "1-3", row("Title" => "The Trilogy (Saga, #1-3)").series_number
      end

      test "nothing after a colon is dropped, and a parenthetical without a number stays in the title" do
        assert_equal "Mistborn: The Final Empire", row("Title" => "Mistborn: The Final Empire").title
        assert_equal "Poems (Selected)", row("Title" => "Poems (Selected)").title
        assert_nil row("Title" => "Poems (Selected)").series_name
      end

      test "an earlier parenthetical survives when the series suffix is split" do
        assert_equal "Title (A Note)", row("Title" => "Title (A Note) (Series, #2)").title
      end

      test "only the primary author is an author; additional authors are a list beside it" do
        parsed = row("Author" => "Cixin  Liu", "Additional Authors" => "Ken Liu, Joel Martinsen")

        assert_equal "Cixin Liu", parsed.primary_author
        assert_equal ["Ken Liu", "Joel Martinsen"], parsed.additional_authors
      end

      test "ISBNs are unwrapped and each derives the other" do
        parsed = row("ISBN" => '="0441013597"', "ISBN13" => '=""')

        assert_equal ["9780441013593", "0441013597"], [parsed.isbn13, parsed.isbn10]
      end

      test "an invalid ISBN is dropped and noted" do
        parsed = row("ISBN13" => '="9780441013594"')

        assert_nil parsed.isbn13
        assert_includes parsed.notes, 'invalid ISBN13 dropped: ="9780441013594"'
      end

      test "both years are read, including a year before the common era" do
        parsed = row("Original Publication Year" => "-750", "Year Published" => "1999")

        assert_equal [-750, 1999], [parsed.original_publication_year, parsed.year_published]
      end

      test "user fields are read" do
        parsed = row(
          "Exclusive Shelf" => "Read", "Bookshelves" => "favorites, sci-fi, favorites",
          "Bookshelves with positions" => "favorites (#4), sci-fi (#12)", "My Rating" => "4",
          "My Review" => "Loved it.<br/>Twice.", "Date Read" => "2024/05/03", "Date Added" => "2023/1/9",
          "Read Count" => "2"
        )

        assert_equal "read", parsed.exclusive_shelf
        assert_equal ["favorites", "sci-fi"], parsed.shelves
        assert_equal({"favorites" => 4, "sci-fi" => 12}, parsed.shelf_positions)
        assert_equal [4, "Loved it.<br/>Twice.", 2], [parsed.rating, parsed.review_body, parsed.read_count]
        assert_equal [Date.new(2024, 5, 3), Date.new(2023, 1, 9)], [parsed.date_read, parsed.date_added]
        assert_equal [], parsed.notes
      end

      test "a rating of zero is kept; one out of range is dropped and noted" do
        assert_equal 0, row("My Rating" => "0").rating
        parsed = row("My Rating" => "7")

        assert_nil parsed.rating
        assert_includes parsed.notes, "unreadable My Rating dropped: 7"
      end

      test "a bad date is dropped and noted" do
        parsed = row("Date Read" => "2024/13/45")

        assert_nil parsed.date_read
        assert_includes parsed.notes, "unreadable Date Read dropped: 2024/13/45"
      end

      test "Private Notes never reaches raw" do
        parsed = row("Private Notes" => "my secret", "My Review" => "public")

        assert_not parsed.raw.key?("Private Notes")
        assert_equal "public", parsed.raw["My Review"]
      end

      test "a row with no id, title or author is invalid and says why" do
        parsed = ExportRow.new(row_number: 3, fields: {"Book Id" => "", "Title" => " ", "Author" => nil})

        assert_not parsed.valid?
        assert_equal ["no Goodreads book id", "no title", "no author"], parsed.errors
      end

      test "honest variants of one title and author share a signature; another title does not" do
        plain = row("Title" => "Dune", "Author" => "Frank Herbert").signature

        assert_equal plain, row("Title" => "Dune (Dune, #1)", "Author" => "Frank  Herbert").signature
        assert_equal plain, row("Title" => "DUNE", "Author" => "frank herbert").signature
        assert_not_equal plain, row("Title" => "Dune Messiah", "Author" => "Frank Herbert").signature
      end
    end
  end
end
```

- [ ] **Step 2: Write the failing file tests**

`web-app/test/lib/books/goodreads/export_file_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  module Goodreads
    class ExportFileTest < ActiveSupport::TestCase
      HEADER = "Book Id,Title,Author,Exclusive Shelf\n"

      test "columns are read by header name in any order" do
        result = ExportFile.parse("Exclusive Shelf,Author,Title,Book Id\nread,Leo Tolstoy,War and Peace,656\n")

        row = result.data[:rows].sole
        assert_equal [656, "War and Peace", "Leo Tolstoy", "read"], [row.goodreads_book_id, row.title, row.primary_author, row.exclusive_shelf]
      end

      test "a UTF-8 byte order mark is stripped" do
        result = ExportFile.parse("\xEF\xBB\xBF".b + "#{HEADER}656,War and Peace,Leo Tolstoy,read\n".b)

        assert result.success?, result.errors.inspect
        assert_equal 656, result.data[:rows].sole.goodreads_book_id
      end

      test "a Windows-1252 file is read as Windows-1252" do
        result = ExportFile.parse("#{HEADER}1,Caf\xE9 Stories,Jos\xE9 Saramago,read\n".b)

        assert_equal ["Café Stories", "José Saramago"], result.data[:rows].sole.then { |row| [row.title, row.primary_author] }
      end

      test "bytes that are neither UTF-8 nor Windows-1252 are scrubbed" do
        result = ExportFile.parse("#{HEADER}1,Bad\x81Title,Ann Author,read\n".b)

        assert_equal "BadTitle", result.data[:rows].sole.title
      end

      test "a file without the export headers is refused" do
        result = ExportFile.parse("Book Id,Title,Author\n1,War and Peace,Leo Tolstoy\n")

        assert_not result.success?
        assert_equal ["missing Goodreads export headers: Exclusive Shelf"], result.errors
      end

      test "a spreadsheet renamed to .csv is refused" do
        result = ExportFile.parse("PK\x03\x04\x14\x00\x06\x00\x08\x00\x00\x00!\x00\xA4\x9B\"\x8F\x01\x00".b)

        assert_not result.success?
      end

      test "an empty file is refused" do
        assert_not ExportFile.parse("").success?
      end

      test "a header-only file has no rows" do
        result = ExportFile.parse(HEADER)

        assert result.success?
        assert_equal [], result.data[:rows]
      end

      test "keeps a row with a stray quote" do
        result = ExportFile.parse(%(#{HEADER}1,The "Best" Book,Ann Author,read\n2,Second,Ann Author,read\n))

        assert result.success?, result.errors.inspect
        assert_equal ['The "Best" Book', "Second"], result.data[:rows].map(&:title)
      end

      test "numbers rows by record, so a review spanning lines is one row" do
        csv = "Book Id,Title,Author,Exclusive Shelf,My Review\n" \
          "1,First,Ann Author,read,\"line one\nline two, with a comma\"\n" \
          "2,Second,Ann Author,read,\n"

        rows = ExportFile.parse(csv).data[:rows]

        assert_equal [[1, "First"], [2, "Second"]], rows.map { |row| [row.row_number, row.title] }
        assert_equal "line one\nline two, with a comma", rows.first.review_body
      end
    end
  end
end
```

- [ ] **Step 3: Run them to verify they fail**

Run: `bin/rails test test/lib/books/goodreads/`
Expected: errors, `uninitialized constant Books::Goodreads`.

- [ ] **Step 4: Implement the row**

`web-app/app/lib/books/goodreads/export_row.rb`:

```ruby
# frozen_string_literal: true

module Books
  module Goodreads
    # One row of a Goodreads library export, read by header name (Goodreads
    # import spec §4). Edition fields describe the edition the row names;
    # user fields are the member's shelves, rating, review and dates. A value
    # that does not parse is dropped and noted, never guessed; the notes end
    # up on the import row. Touches no database.
    class ExportRow
      PRIVATE_NOTES = "Private Notes"
      # Goodreads appends "(Series Name, #N)" to the title of every book in a
      # series. It is evidence, so it is kept, but it is not the title.
      SERIES_SUFFIX = /\A(?<title>.+?)\s*\((?<series>[^()#]+?),?\s*#(?<number>[^()]+)\)\s*\z/
      SHELF_POSITION = /\A(?<shelf>.+?)\s*\(#(?<position>\d+)\)\z/
      YEAR = /\A-?\d{1,4}\z/
      DATE_FORMAT = "%Y/%m/%d"

      attr_reader :row_number, :raw, :notes,
        :goodreads_book_id, :title, :series_name, :series_number, :primary_author, :additional_authors,
        :isbn13, :isbn10, :original_publication_year, :year_published, :publisher, :book_format, :pages,
        :exclusive_shelf, :shelves, :shelf_positions, :rating, :review_body, :date_read, :date_added, :read_count

      # The second half of an edition's key, and the advisory-lock key for
      # creating its book: the normalized title (series suffix removed) and
      # primary author. Honest exports give one title and author per Goodreads
      # id, so they share a signature; a row claiming a real id under another
      # title gets its own edition and cannot overwrite the honest one.
      def self.signature(title, primary_author)
        Digest::SHA256.hexdigest("#{normalize(title)}\u0000#{normalize(primary_author)}")
      end

      def self.normalize(text)
        ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).downcase
      end

      def initialize(row_number:, fields:)
        @row_number = row_number
        @fields = fields.to_h.reject { |header, _value| header.blank? }
        @raw = @fields.except(PRIVATE_NOTES)
        @notes = []
        parse
      end

      def errors
        [
          ("no Goodreads book id" if goodreads_book_id.nil?),
          ("no title" if title.blank?),
          ("no author" if primary_author.blank?)
        ].compact
      end

      def valid?
        errors.empty?
      end

      def signature
        self.class.signature(title, primary_author)
      end

      def edition_attributes
        {
          goodreads_book_id: goodreads_book_id, signature: signature, title: title,
          series_name: series_name, series_number: series_number, primary_author: primary_author,
          additional_authors: additional_authors, isbn13: isbn13, isbn10: isbn10,
          original_publication_year: original_publication_year, year_published: year_published,
          publisher: publisher, book_format: book_format, pages: pages
        }
      end

      def row_attributes
        {
          row_number: row_number, raw: raw, exclusive_shelf: exclusive_shelf, shelves: shelves,
          shelf_positions: shelf_positions, rating: rating, review_body: review_body,
          date_read: date_read, date_added: date_added, read_count: read_count, notes: notes
        }
      end

      private

      def parse
        @goodreads_book_id = ::Books::GoodreadsId.normalize(field("Book Id"))&.to_i
        split_title(clean(field("Title")))
        @primary_author = clean(field("Author"))
        @additional_authors = list(field("Additional Authors"))
        parse_isbns
        @original_publication_year = year("Original Publication Year")
        @year_published = year("Year Published")
        @publisher = clean(field("Publisher"))
        @book_format = clean(field("Binding"))
        @pages = integer("Number of Pages", minimum: 1)
        @exclusive_shelf = clean(field("Exclusive Shelf"))&.downcase
        @shelves = list(field("Bookshelves")).map(&:downcase).uniq
        @shelf_positions = shelf_positions_from(field("Bookshelves with positions"))
        @rating = integer("My Rating", minimum: 0, maximum: 5)
        @review_body = field("My Review").presence
        @date_read = date("Date Read")
        @date_added = date("Date Added")
        @read_count = integer("Read Count", minimum: 0)
      end

      def field(header)
        @fields[header].to_s
      end

      def clean(text)
        ::Services::Text::NameNormalizer.call(text.to_s).presence
      end

      def list(text)
        text.to_s.split(",").filter_map { |item| clean(item) }
      end

      def split_title(whole)
        match = whole && SERIES_SUFFIX.match(whole)
        if match && match[:title].strip.present?
          @title = match[:title].strip
          @series_name = match[:series].strip
          @series_number = match[:number].strip
        else
          @title = whole
        end
      end

      def parse_isbns
        from13 = isbn("ISBN13")
        from10 = isbn("ISBN")
        @isbn13 = from13&.isbn13 || from10&.isbn13
        @isbn10 = from10&.isbn10 || from13&.isbn10
      end

      def isbn(header)
        value = field(header)
        normalized = ::Books::Isbn.normalize(value)
        @notes << "invalid #{header} dropped: #{value}" if normalized.nil? && value.match?(/\d/)
        normalized
      end

      def year(header)
        value = field(header).strip
        return nil if value.empty?
        return value.to_i if value.match?(YEAR) && value.to_i != 0

        @notes << "unreadable #{header} dropped: #{value}"
        nil
      end

      def integer(header, minimum:, maximum: nil)
        value = field(header).strip
        return nil if value.empty?

        number = Integer(value, 10, exception: false)
        return number if number && number >= minimum && (maximum.nil? || number <= maximum)

        @notes << "unreadable #{header} dropped: #{value}"
        nil
      end

      def date(header)
        value = field(header).strip
        return nil if value.empty?

        Date.strptime(value, DATE_FORMAT)
      rescue Date::Error
        @notes << "unreadable #{header} dropped: #{value}"
        nil
      end

      def shelf_positions_from(text)
        list(text).each_with_object({}) do |entry, positions|
          match = SHELF_POSITION.match(entry)
          positions[match[:shelf].downcase] = match[:position].to_i if match
        end
      end
    end
  end
end
```

- [ ] **Step 5: Implement the file**

`web-app/app/lib/books/goodreads/export_file.rb`:

```ruby
# frozen_string_literal: true

require "csv"

module Books
  module Goodreads
    # The bytes of a Goodreads library export, turned into ExportRows
    # (Goodreads import spec §4). Refuses a file that is not CSV or lacks the
    # export's headers; never refuses a row (a bad row is the row's problem).
    #
    # Encoding: a BOM is stripped; bytes that are not valid UTF-8 are read as
    # Windows-1252; bytes that are neither are scrubbed. Liberal parsing
    # keeps a field with a stray quote, the likely cause of the 23 legacy
    # imports that died on CSV::MalformedCSVError.
    class ExportFile
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      REQUIRED_HEADERS = ["Book Id", "Title", "Author", "Exclusive Shelf"].freeze
      BOM = "\xEF\xBB\xBF".b

      def self.parse(bytes)
        new(bytes).parse
      end

      def initialize(bytes)
        @bytes = bytes.to_s.b
      end

      def parse
        table = CSV.parse(decode, headers: true, liberal_parsing: true, skip_blanks: true,
          header_converters: ->(header) { header.to_s.strip })
        missing = REQUIRED_HEADERS - table.headers.compact
        return failure("missing Goodreads export headers: #{missing.join(", ")}") if missing.any?

        rows = table.each_with_index.map { |row, index| ExportRow.new(row_number: index + 1, fields: row.to_h) }
        Result.new(success?: true, data: {rows: rows}, errors: [])
      rescue CSV::MalformedCSVError => e
        failure("not a readable CSV file: #{e.message}")
      end

      private

      def decode
        bytes = @bytes.start_with?(BOM) ? @bytes.byteslice(BOM.bytesize..) : @bytes
        utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
        return utf8 if utf8.valid_encoding?

        begin
          bytes.encode(Encoding::UTF_8, Encoding::Windows_1252)
        rescue EncodingError
          utf8.scrub("")
        end
      end

      def failure(message)
        Result.new(success?: false, data: {rows: []}, errors: [message])
      end
    end
  end
end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/lib/books/goodreads/`
Expected: 25 runs, 0 failures. If "a spreadsheet renamed to .csv" passes for the wrong reason, that's
fine: either a missing-headers refusal or a `MalformedCSVError` refusal satisfies the spec. If it
**succeeds**, the decoded garbage happened to contain all four headers, which is not possible with
those bytes. Investigate before changing the test.

- [ ] **Step 7: Check Zeitwerk sees the new directory, then commit**

Run: `CI=1 bin/rails zeitwerk:check`
Expected: `All is good!`

```bash
git add app/lib/books/goodreads test/lib/books/goodreads
git commit -m "Books: parse Goodreads export files and rows

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Import, edition, row and provenance tables

**Files:**
- Create (generator, then replace contents): 4 migrations, `web-app/app/models/books/goodreads_import.rb`,
  `goodreads_edition.rb`, `goodreads_import_row.rb`, `goodreads_import_record.rb`, fixtures
  `web-app/test/fixtures/books/goodreads_imports.yml`, `goodreads_editions.yml`,
  `goodreads_import_rows.yml`, model tests under `web-app/test/models/books/`.
- Modify: `web-app/app/models/user.rb` (after `has_many :api_tokens`), `web-app/app/models/books/book.rb`
  (after `has_many :match_decisions`), `web-app/app/lib/books/book/merger.rb` (`merge_all_associations`),
  `web-app/test/lib/books/book/merger_test.rb`, `web-app/test/controllers/admin/users_controller_test.rb`.

**Interfaces:**
- Consumes: `Books::Goodreads::ExportRow.signature` (Task 2), in fixtures and tests.
- Produces:
  - `Books::GoodreadsImport`: `user`, `reviewed_by`, `rows`, `records`, `editions` (distinct
    through rows). Enums: `source` `member|legacy_replay`; `status`
    `queued|parsing|resolving|verifying|writing|complete|failed`; `review_status`
    `pending|approved|rejected` (prefix `review`). Integer counters.
  - `Books::GoodreadsEdition`: `book`, `match_decision`, `import_rows`. Enums: `resolution`
    `matched|created|parked`; `verification`
    `not_needed|pending|verified|not_found|mismatch|unverified` (prefix `verification`). Column
    `book_format`, not `binding`.
  - `Books::GoodreadsImportRow`: `import`, `goodreads_edition`; `outcome`
    `pending|applied|parked|skipped|failed`; `notes` string array.
  - `Books::GoodreadsImportRecord`: `import`, polymorphic `record`; `action` `created|stamped`.
  - `Books::Book#goodreads_editions`; `User#goodreads_imports`, `User#reviewed_goodreads_imports`.

- [ ] **Step 1: Generate the four models, in this order**

```bash
bin/rails generate model books/goodreads_import --skip
bin/rails generate model books/goodreads_edition --skip
bin/rails generate model books/goodreads_import_row --skip
bin/rails generate model books/goodreads_import_record --skip --no-fixture
```

Expected: four migrations, four models, four model tests and three fixture files are created, and
`app/models/books.rb` is skipped. Run `git status` and confirm `app/models/books.rb` is not
modified.

- [ ] **Step 2: Replace the four migrations' bodies**

`*_create_books_goodreads_imports.rb`:

```ruby
class CreateBooksGoodreadsImports < ActiveRecord::Migration[8.1]
  def change
    create_table :books_goodreads_imports do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :source, null: false, default: 0
      t.integer :legacy_import_id
      t.integer :status, null: false, default: 0
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at
      t.integer :review_status, null: false, default: 0
      t.references :reviewed_by, foreign_key: {to_table: :users}
      t.datetime :reviewed_at
      t.integer :rows_count, null: false, default: 0
      t.integer :editions_count, null: false, default: 0
      t.integer :matched_count, null: false, default: 0
      t.integer :created_count, null: false, default: 0
      t.integer :flagged_count, null: false, default: 0
      t.integer :parked_count, null: false, default: 0
      t.integer :skipped_count, null: false, default: 0
      t.integer :ai_calls_count, null: false, default: 0
      t.timestamps
    end

    add_index :books_goodreads_imports, :legacy_import_id, unique: true, where: "legacy_import_id IS NOT NULL"
    # One import in progress per user (spec §3): queued, parsing, resolving,
    # verifying or writing.
    add_index :books_goodreads_imports, :user_id, unique: true, where: "status IN (0, 1, 2, 3, 4)",
      name: "index_books_goodreads_imports_one_in_progress_per_user"
  end
end
```

`*_create_books_goodreads_editions.rb`:

```ruby
class CreateBooksGoodreadsEditions < ActiveRecord::Migration[8.1]
  def change
    create_table :books_goodreads_editions do |t|
      t.bigint :goodreads_book_id, null: false
      t.string :signature, null: false
      t.string :title, null: false
      t.string :series_name
      t.string :series_number
      t.string :primary_author, null: false
      t.string :additional_authors, array: true, null: false, default: []
      t.string :isbn13
      t.string :isbn10
      t.integer :original_publication_year
      t.integer :year_published
      t.string :publisher
      # Goodreads' "Binding". Not `binding`: that name collides with Kernel#binding.
      t.string :book_format
      t.integer :pages
      t.references :book, foreign_key: {to_table: :books_books, on_delete: :nullify}
      t.references :match_decision, foreign_key: {on_delete: :nullify}
      t.datetime :resolved_at
      t.integer :resolution
      t.integer :verification, null: false, default: 0
      t.timestamps
    end

    add_index :books_goodreads_editions, [:goodreads_book_id, :signature], unique: true
    add_index :books_goodreads_editions, :signature
  end
end
```

`*_create_books_goodreads_import_rows.rb`:

```ruby
class CreateBooksGoodreadsImportRows < ActiveRecord::Migration[8.1]
  def change
    create_table :books_goodreads_import_rows do |t|
      t.references :import, null: false, index: false,
        foreign_key: {to_table: :books_goodreads_imports, on_delete: :cascade}
      t.integer :row_number, null: false
      t.references :goodreads_edition, foreign_key: {to_table: :books_goodreads_editions}
      t.jsonb :raw, null: false, default: {}
      t.string :exclusive_shelf
      t.string :shelves, array: true, null: false, default: []
      t.jsonb :shelf_positions, null: false, default: {}
      t.integer :rating
      t.text :review_body
      t.date :date_read
      t.date :date_added
      t.integer :read_count
      t.string :notes, array: true, null: false, default: []
      t.integer :outcome, null: false, default: 0
      t.string :outcome_detail
      t.text :error
      t.jsonb :applied, null: false, default: {}
      t.timestamps
    end

    add_index :books_goodreads_import_rows, [:import_id, :row_number], unique: true
  end
end
```

`*_create_books_goodreads_import_records.rb`:

```ruby
class CreateBooksGoodreadsImportRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :books_goodreads_import_records do |t|
      t.references :import, null: false, index: false,
        foreign_key: {to_table: :books_goodreads_imports, on_delete: :cascade}
      t.references :record, polymorphic: true, null: false
      t.integer :action, null: false
      t.timestamps
    end

    add_index :books_goodreads_import_records, [:import_id, :record_type, :record_id], unique: true,
      name: "index_books_goodreads_import_records_uniqueness"
  end
end
```

- [ ] **Step 3: Migrate and check the schema diff**

```bash
ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate
git diff --stat db/schema.rb
git diff db/schema.rb | grep '^[-+]' | grep -v '^[-+][-+]' | grep -v 'books_goodreads' | head -20
```

Expected: the first `grep` shows only the version line, the four `create_table` blocks, their
indexes and the `add_foreign_key` lines. If anything else changed (a column from another
worktree's migration on the shared dev DB), revert those hunks from `db/schema.rb` by hand and note
it in the ledger.

Then: `RAILS_ENV=test bin/rails db:test:prepare`. Expected: exit 0.

- [ ] **Step 4: Write the models**

`web-app/app/models/books/goodreads_import.rb` (keep the schema annotation block the generator or
annotaterb produced above the class, if any):

```ruby
module Books
  class GoodreadsImport < ApplicationRecord
    belongs_to :user
    belongs_to :reviewed_by, class_name: "User", optional: true
    has_many :rows, class_name: "Books::GoodreadsImportRow", foreign_key: :import_id, inverse_of: :import,
      dependent: :delete_all
    has_many :records, class_name: "Books::GoodreadsImportRecord", foreign_key: :import_id, inverse_of: :import,
      dependent: :delete_all
    has_many :editions, -> { distinct }, through: :rows, source: :goodreads_edition

    enum :source, {member: 0, legacy_replay: 1}
    enum :status, {queued: 0, parsing: 1, resolving: 2, verifying: 3, writing: 4, complete: 5, failed: 6}
    enum :review_status, {pending: 0, approved: 1, rejected: 2}, prefix: :review

    validates :legacy_import_id, uniqueness: true, allow_nil: true
  end
end
```

`web-app/app/models/books/goodreads_edition.rb`:

```ruby
module Books
  # The unit an import resolves: one Goodreads id under one signature
  # (normalized title plus primary author), shared by every import and user
  # that names it. Resolved once; a later import reuses the answer while its
  # book exists (Goodreads import spec §3, §5).
  class GoodreadsEdition < ApplicationRecord
    belongs_to :book, class_name: "Books::Book", optional: true
    belongs_to :match_decision, optional: true
    has_many :import_rows, class_name: "Books::GoodreadsImportRow", inverse_of: :goodreads_edition,
      dependent: :restrict_with_exception

    enum :resolution, {matched: 0, created: 1, parked: 2}
    enum :verification, {not_needed: 0, pending: 1, verified: 2, not_found: 3, mismatch: 4, unverified: 5},
      prefix: true

    validates :goodreads_book_id, :signature, :title, :primary_author, presence: true
    validates :signature, uniqueness: {scope: :goodreads_book_id}
  end
end
```

`web-app/app/models/books/goodreads_import_row.rb`:

```ruby
module Books
  class GoodreadsImportRow < ApplicationRecord
    belongs_to :import, class_name: "Books::GoodreadsImport", inverse_of: :rows
    belongs_to :goodreads_edition, class_name: "Books::GoodreadsEdition", optional: true, inverse_of: :import_rows

    enum :outcome, {pending: 0, applied: 1, parked: 2, skipped: 3, failed: 4}

    validates :row_number, presence: true, uniqueness: {scope: :import_id}
    validates :rating, inclusion: {in: 0..5}, allow_nil: true
  end
end
```

`web-app/app/models/books/goodreads_import_record.rb`:

```ruby
module Books
  # Provenance: every book, author, book_author and identifier an import
  # created or stamped. Approval reads it to know what to promote, rejection
  # to know what to remove (Goodreads import spec §3, §10).
  class GoodreadsImportRecord < ApplicationRecord
    belongs_to :import, class_name: "Books::GoodreadsImport", inverse_of: :records
    belongs_to :record, polymorphic: true

    enum :action, {created: 0, stamped: 1}

    validates :record_id, uniqueness: {scope: [:import_id, :record_type]}
  end
end
```

`web-app/app/models/user.rb`, after `has_many :api_tokens, dependent: :destroy`:

```ruby
  has_many :goodreads_imports, class_name: "Books::GoodreadsImport", dependent: :destroy
  has_many :reviewed_goodreads_imports, class_name: "Books::GoodreadsImport", foreign_key: :reviewed_by_id,
    dependent: :nullify
```

`web-app/app/models/books/book.rb`, after `has_many :match_decisions, as: :record, dependent: :nullify`:

```ruby
  has_many :goodreads_editions, class_name: "Books::GoodreadsEdition", dependent: :nullify
```

Then run `bundle exec annotaterb models` to refresh schema annotations. If it errors trying to
reach the legacy database, skip it and copy the column list from `db/schema.rb` into each new
model's annotation block by hand, matching `app/models/books/book.rb`'s format.

- [ ] **Step 5: Write the fixtures**

`web-app/test/fixtures/books/goodreads_imports.yml`:

```yaml
regular_user_import:
  user: regular_user
  source: member
  status: complete
  review_status: pending
```

`web-app/test/fixtures/books/goodreads_editions.yml` (the signatures are
`Books::Goodreads::ExportRow.signature(title, primary_author)`):

```yaml
war_and_peace_edition:
  goodreads_book_id: 656
  signature: ae5a8901c1ecb81ed9fe71c4bf64d33b958275d868816dbae66b3b92e45a35aa
  title: War and Peace
  primary_author: Leo Tolstoy
  isbn13: "9780140447934"
  original_publication_year: 1869
  book: war_and_peace
  resolution: matched
  verification: not_needed
  resolved_at: 2026-10-01 12:00:00

unresolved_edition:
  goodreads_book_id: 99000001
  signature: 2a874f3fe57c971e6a4b30558e404c516c58e66a585216586a988126f88de558
  title: The Quiet Year
  primary_author: Anna Brenner
```

`web-app/test/fixtures/books/goodreads_import_rows.yml`:

```yaml
war_and_peace_row:
  import: regular_user_import
  row_number: 1
  goodreads_edition: war_and_peace_edition
  raw: {"Book Id": "656", "Title": "War and Peace", "Author": "Leo Tolstoy"}
  exclusive_shelf: read
  rating: 5
  outcome: pending
```

- [ ] **Step 6: Write the model tests (replace the generated placeholders)**

`web-app/test/models/books/goodreads_import_test.rb` (keep the schema annotation comment the
generator added, if any):

```ruby
require "test_helper"

module Books
  class GoodreadsImportTest < ActiveSupport::TestCase
    test "a user has at most one import in progress" do
      user = users(:editor_user)
      GoodreadsImport.create!(user: user, status: :queued)

      assert_raises(ActiveRecord::RecordNotUnique) { GoodreadsImport.create!(user: user, status: :resolving) }
    end

    test "a finished import does not block a new one" do
      assert books_goodreads_imports(:regular_user_import).complete?

      assert GoodreadsImport.create!(user: users(:regular_user), status: :queued).persisted?
    end

    test "a legacy import id is replayed into one import only" do
      GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, legacy_import_id: 42)

      assert_not GoodreadsImport.new(user: users(:editor_user), source: :legacy_replay, legacy_import_id: 42).valid?
    end

    test "editions lists an edition once however many rows name it" do
      import = books_goodreads_imports(:regular_user_import)
      import.rows.create!(row_number: 2, goodreads_edition: books_goodreads_editions(:war_and_peace_edition))

      assert_equal [books_goodreads_editions(:war_and_peace_edition)], import.editions.to_a
    end

    test "destroying the user takes the import, its rows and its provenance" do
      user = User.create!(email: "importer@example.com", role: :user, email_verified: false)
      import = GoodreadsImport.create!(user: user, status: :complete)
      import.rows.create!(row_number: 1)
      import.records.create!(record: books_books(:war_and_peace), action: :created)

      user.destroy!

      assert_equal [0, 0, 0], [GoodreadsImport.where(id: import.id).count,
        GoodreadsImportRow.where(import_id: import.id).count, GoodreadsImportRecord.where(import_id: import.id).count]
    end
  end
end
```

`web-app/test/models/books/goodreads_edition_test.rb`:

```ruby
require "test_helper"

module Books
  class GoodreadsEditionTest < ActiveSupport::TestCase
    test "a Goodreads id may carry a second signature but never the same one twice" do
      honest = books_goodreads_editions(:war_and_peace_edition)
      hostile = GoodreadsEdition.new(goodreads_book_id: honest.goodreads_book_id,
        signature: Goodreads::ExportRow.signature("Invented Book", "Nobody"), title: "Invented Book", primary_author: "Nobody")
      duplicate = GoodreadsEdition.new(goodreads_book_id: honest.goodreads_book_id, signature: honest.signature,
        title: honest.title, primary_author: honest.primary_author)

      assert hostile.valid?
      assert_not duplicate.valid?
    end

    test "the fixture signatures are what ExportRow computes" do
      edition = books_goodreads_editions(:unresolved_edition)

      assert_equal Goodreads::ExportRow.signature(edition.title, edition.primary_author), edition.signature
    end

    test "deleting its book unlinks the edition" do
      book = Book.create!(title: "Ephemeral")
      edition = books_goodreads_editions(:unresolved_edition)
      edition.update!(book: book, resolution: :created, resolved_at: Time.current)

      book.destroy!

      assert_nil edition.reload.book_id
    end
  end
end
```

`web-app/test/models/books/goodreads_import_row_test.rb`:

```ruby
require "test_helper"

module Books
  class GoodreadsImportRowTest < ActiveSupport::TestCase
    test "a rating is 0 to 5 or absent" do
      row = books_goodreads_import_rows(:war_and_peace_row)

      assert row.tap { |r| r.rating = 0 }.valid?
      assert row.tap { |r| r.rating = nil }.valid?
      assert_not row.tap { |r| r.rating = 6 }.valid?
    end

    test "a row number is used once per import" do
      existing = books_goodreads_import_rows(:war_and_peace_row)

      assert_not GoodreadsImportRow.new(import: existing.import, row_number: existing.row_number).valid?
    end
  end
end
```

`web-app/test/models/books/goodreads_import_record_test.rb`:

```ruby
require "test_helper"

module Books
  class GoodreadsImportRecordTest < ActiveSupport::TestCase
    test "a record is recorded once per import" do
      import = books_goodreads_imports(:regular_user_import)
      import.records.create!(record: books_books(:war_and_peace), action: :created)

      assert_not import.records.new(record: books_books(:war_and_peace), action: :stamped).valid?
    end
  end
end
```

`web-app/test/lib/books/book/merger_test.rb`, after "moves editions to the target":

```ruby
      test "moves Goodreads editions to the target" do
        edition = ::Books::GoodreadsEdition.create!(goodreads_book_id: 123, title: "Crime and Punishment",
          primary_author: "Fyodor Dostoevsky", signature: "crime", book: @source, resolution: :matched,
          resolved_at: Time.current)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, edition.reload.book_id
      end
```

`web-app/test/controllers/admin/users_controller_test.rb`, after "should destroy user with a saved
search" (copy that test's request and assertions):

```ruby
  test "should destroy user with a goodreads import" do
    user_to_delete = User.create!(email: "goodreadsowner@example.com", role: :user, email_verified: false)
    import = Books::GoodreadsImport.create!(user: user_to_delete, status: :complete)

    assert_difference("User.count", -1) do
      delete admin_user_url(user_to_delete)
    end
    assert_redirected_to admin_users_url
    assert_not Books::GoodreadsImport.exists?(import.id)
  end
```

- [ ] **Step 7: Run the new tests and watch the merger one fail**

Run: `bin/rails test test/models/books/goodreads_import_test.rb test/models/books/goodreads_edition_test.rb test/models/books/goodreads_import_row_test.rb test/models/books/goodreads_import_record_test.rb test/lib/books/book/merger_test.rb test/controllers/admin/users_controller_test.rb`
Expected: one failure, "moves Goodreads editions to the target" (the merger does not move them yet,
so `destroy!` nullifies `book_id`). Everything else passes.

- [ ] **Step 8: Teach the merger**

`web-app/app/lib/books/book/merger.rb`: in `merge_all_associations`, add `merge_goodreads_editions`
right after `merge_editions`, and define it after `merge_editions`:

```ruby
      # Goodreads editions carry no book-scoped uniqueness (their key is the
      # Goodreads id and signature), so they simply follow the book. Without
      # this, dependent: :nullify would unlink them on destroy and every
      # import that names them would re-resolve.
      def merge_goodreads_editions
        @stats[:goodreads_editions] = source_book.goodreads_editions.update_all(book_id: target_book.id)
      end
```

- [ ] **Step 9: Run the same tests again**

Run: the Step 7 command.
Expected: 0 failures.

- [ ] **Step 10: Commit**

```bash
git add db/migrate db/schema.rb app/models/books/goodreads_*.rb app/models/user.rb app/models/books/book.rb app/lib/books/book/merger.rb test/fixtures/books/goodreads_*.yml test/models/books/goodreads_*_test.rb test/lib/books/book/merger_test.rb test/controllers/admin/users_controller_test.rb
git commit -m "Books: Goodreads import, edition, row and provenance tables

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Series and additional authors as AI context

**Files:**
- Modify: `web-app/app/lib/data_importers/books/book/import_query.rb`, `web-app/app/lib/data_importers/books/book/finder.rb`
- Test: `web-app/test/lib/data_importers/books/book/finder_test.rb`, `web-app/test/lib/data_importers/books/book/import_query_test.rb` (create it if it does not exist)

**Interfaces:**
- Produces: `ImportQuery.new(..., series_name: nil, series_number: nil, context_author_names: [])`
  with readers of the same names, all three in `SNAPSHOT_KEYS`. `Finder#describe_query(query)`
  appends `| series: <name> #<number>` and `| also credited, role unknown: <names>`.

- [ ] **Step 1: Write the failing tests**

Add to `finder_test.rb` (inside the class, after the helpers):

```ruby
        # ---- AI context (Goodreads import spec §4) ----------------------------

        test "the AI is shown the query's series and its other credited names" do
          query = ImportQuery.new(title: "The Final Empire", author_names: ["Brandon Sanderson"],
            series_name: "Mistborn", series_number: "1", context_author_names: ["Ken Liu"])

          assert_equal "The Final Empire | by Brandon Sanderson | series: Mistborn #1 | also credited, role unknown: Ken Liu",
            @finder.describe_query(query)
        end

        test "the AI prompt carries that context" do
          SEARCH.stubs(:call).returns([hit(@war_and_peace)])
          ::Services::Ai::Tasks::Matching::SelectCandidateTask.expects(:new)
            .with(has_entry(:query_line, regexp_matches(/series: Epics #2/))).returns(@task)
          @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, ai_chat: ai_chats(:general_chat),
            data: {selected_index: 0, confidence: "high", reasoning: "no", same_entity_groups: []}))

          @finder.call(query: ImportQuery.new(title: "War and Peace Retold", author_names: ["Leo Tolstoy"],
            series_name: "Epics", series_number: "2"))
        end

        test "an other credited name never counts as a creator" do
          SEARCH.stubs(:call).returns([hit(@war_and_peace)])
          stub_ai(selected_index: 0, confidence: "high", reasoning: "different author", same_entity_groups: [])
          query = ImportQuery.new(title: "War and Peace", author_names: ["Somebody Else"], year: 1869,
            context_author_names: ["Leo Tolstoy"])

          # Were Leo Tolstoy counted as a creator, rule 4 (exact title, creator
          # and year) would match War and Peace before the AI was asked.
          assert @finder.call(query: query).unmatched?
        end
```

Create or extend `web-app/test/lib/data_importers/books/book/import_query_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      class ImportQueryTest < ActiveSupport::TestCase
        test "series and context names survive a snapshot round trip" do
          query = ImportQuery.new(title: "The Final Empire", series_name: "Mistborn", series_number: "1",
            context_author_names: ["Ken Liu", "", "Ken Liu"])
          snapshot = query.instance_variables.to_h { |ivar| [ivar.to_s.delete("@"), query.instance_variable_get(ivar)] }

          rebuilt = ImportQuery.from_snapshot(snapshot)

          assert_equal ["Mistborn", "1", ["Ken Liu"]], [rebuilt.series_name, rebuilt.series_number, rebuilt.context_author_names]
        end
      end
    end
  end
end
```

If `import_query_test.rb` already exists, add only the test method and keep the file's existing
structure.

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/data_importers/books/book/finder_test.rb test/lib/data_importers/books/book/import_query_test.rb`
Expected: `ArgumentError: unknown keyword: :series_name` errors in the new tests. "an other credited
name never counts as a creator" also errors on the unknown keyword. It must **pass** once the
keyword exists, and must keep passing after Step 3.

- [ ] **Step 3: Implement**

`import_query.rb`: add the readers, keys and keywords:

```ruby
        attr_reader :title, :author_names, :year, :isbn13, :isbn10, :asin, :goodreads_id, :open_library_work_key,
          :series_name, :series_number, :context_author_names

        SNAPSHOT_KEYS = %i[title author_names year isbn13 isbn10 asin goodreads_id open_library_work_key
          series_name series_number context_author_names].freeze
```

```ruby
        # series_name, series_number and context_author_names are AI context
        # only (Goodreads import spec §4): Goodreads' Additional Authors mixes
        # co-authors with translators and illustrators, so no rule treats
        # those names as creators.
        def initialize(title:, author_names: [], year: nil, isbn13: [], isbn10: [], asin: [], goodreads_id: [],
          open_library_work_key: nil, series_name: nil, series_number: nil, context_author_names: [])
```

and at the end of `initialize`:

```ruby
          @series_name = series_name.presence
          @series_number = series_number.presence
          @context_author_names = Array(context_author_names).compact_blank.uniq
```

`finder.rb`: add after `describe_candidate`:

```ruby
        def describe_query(query)
          line = super
          if query.series_name.present?
            line = "#{line} | series: #{[query.series_name, query.series_number && "##{query.series_number}"].compact.join(" ")}"
          end
          line = "#{line} | also credited, role unknown: #{query.context_author_names.join(", ")}" if query.context_author_names.any?
          line
        end
```

- [ ] **Step 4: Run the tests to verify they pass, plus the finder's neighbours**

Run: `bin/rails test test/lib/data_importers/books/ test/lib/services/books/find_duplicates_test.rb`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/lib/data_importers/books/book/import_query.rb app/lib/data_importers/books/book/finder.rb test/lib/data_importers/books/book/finder_test.rb test/lib/data_importers/books/book/import_query_test.rb
git commit -m "Books finder: series and other credited names as AI context

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Importer options — match, provisional, stamp identifiers, enrich

**Files:**
- Create: `web-app/app/lib/data_importers/books/book/providers/query_identifiers.rb`
- Modify: `web-app/app/lib/data_importers/importer_base.rb`, `web-app/app/lib/data_importers/import_result.rb`,
  `web-app/app/lib/data_importers/books/book/importer.rb`, `providers/authors.rb`, `providers/open_library.rb`,
  `web-app/app/lib/data_importers/books/author/importer.rb`
- Test: `web-app/test/lib/data_importers/books/book/importer_test.rb`, `web-app/test/lib/data_importers/books/author/importer_test.rb`,
  `web-app/test/lib/data_importers/books/book/providers/query_identifiers_test.rb`

**Interfaces:**
- Consumes: `DataImporters::Match` (existing).
- Produces:
  - `ImporterBase.call/#call(..., match: nil)`: when given, used instead of running the finder.
  - `ImportResult#created_author_ids` (Array, default `[]`).
  - `DataImporters::Books::Book::Importer.call(..., match: nil, provisional: false, stamp_identifiers: false, enrich: true)`.
  - `DataImporters::Books::Author::Importer.call(..., provisional: false)`.
  - `Providers::QueryIdentifiers#populate(book, query:, match: nil)`.

- [ ] **Step 1: Write the failing tests**

Add to `book/importer_test.rb` (after "a title-and-author re-import is idempotent"):

```ruby
        test "provisional saves the new book and the author it creates as provisional" do
          stub_resolve_down

          result = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"], provisional: true)

          book = result.item.reload
          assert book.provisional?
          assert book.authors.sole.provisional?
          assert_equal [book.authors.sole.id], result.created_author_ids
        end

        test "provisional never touches an existing author it links" do
          stub_resolve_down

          result = Importer.call(title: "Hadji Murat", author_names: ["Leo Tolstoy"], provisional: true)

          assert_not books_authors(:tolstoy).reload.provisional?
          assert_equal [], result.created_author_ids
        end

        test "without provisional, nothing is provisional" do
          stub_resolve_down

          book = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"]).item.reload

          assert_equal [false, false], [book.provisional?, book.authors.sole.provisional?]
        end

        test "stamp_identifiers stamps the query's identifiers when Open Library is down" do
          stub_resolve_down

          book = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"], isbn13: ["9780441013593"],
            goodreads_id: ["234225"], stamp_identifiers: true).item.reload

          assert_equal [["books_work_goodreads_id", "234225"], ["books_work_isbn13", "9780441013593"]],
            book.identifiers.map { |identifier| [identifier.identifier_type, identifier.value] }.sort
        end

        test "without stamp_identifiers, an Open Library outage stamps nothing" do
          stub_resolve_down

          book = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"], isbn13: ["9780441013593"]).item.reload

          assert_equal 0, book.identifiers.count
        end

        test "enrich: false runs neither enrichment provider" do
          stub_resolve_down
          ::Books::EnrichBookJob.expects(:perform_async).never
          ::Books::Authors::WikidataJob.expects(:perform_async).never

          result = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"], enrich: false)

          assert_equal ["DataImporters::Books::Book::Providers::OpenLibrary", "DataImporters::Books::Book::Providers::Authors"],
            result.provider_results.map(&:provider)
        end

        test "a supplied match is used instead of running the finder, and its decision points at the new book" do
          stub_resolve_down
          Finder.any_instance.expects(:call).never
          decision = ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", outcome: :unmatched,
            confidence: :high, decided_by: :rule)
          match = ::DataImporters::Match.new(outcome: :unmatched, confidence: :high, decided_by: :rule, decision: decision)

          result = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"], match: match)

          assert result.created?
          assert_equal result.item, decision.reload.record
        end
```

Add to `author/importer_test.rb`:

```ruby
        test "provisional saves a new author as provisional" do
          assert Importer.call(name: "Anna Brenner", provisional: true).item.reload.provisional?
        end

        test "provisional leaves a matched author alone" do
          assert_not Importer.call(name: "Leo Tolstoy", provisional: true).item.reload.provisional?
        end
```

Create `web-app/test/lib/data_importers/books/book/providers/query_identifiers_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      module Providers
        class QueryIdentifiersTest < ActiveSupport::TestCase
          test "stamps each query identifier once, even when the book already holds one" do
            book = books_books(:war_and_peace)
            query = ImportQuery.new(title: "War and Peace", isbn13: [identifiers(:war_and_peace_isbn13).value],
              goodreads_id: ["656"])

            result = QueryIdentifiers.new.populate(book, query: query)
            book.save!

            assert result.success?
            assert_equal ["books_work_goodreads_id"], result.data_populated
            assert_equal 1, book.identifiers.where(identifier_type: :books_work_isbn13).count
            assert book.identifiers.exists?(identifier_type: :books_work_goodreads_id, value: "656")
          end

          test "no query, nothing stamped" do
            assert_equal [], QueryIdentifiers.new.populate(books_books(:war_and_peace), query: nil).data_populated
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/data_importers/books/book/importer_test.rb test/lib/data_importers/books/author/importer_test.rb test/lib/data_importers/books/book/providers/query_identifiers_test.rb`
Expected: `unknown keyword` errors (`provisional`, `stamp_identifiers`, `enrich`, `match`) and
`uninitialized constant ...QueryIdentifiers`. "without provisional, nothing is provisional" and
"without stamp_identifiers, an Open Library outage stamps nothing" already pass. They pin today's
behavior.

- [ ] **Step 3: Implement the base and result**

`import_result.rb`: add below `attr_reader`:

```ruby
    # The authors this import created (the book importer fills it), so a
    # caller can record what it made without guessing from timestamps.
    attr_accessor :created_author_ids
```

and in `initialize`, `@created_author_ids = []`.

`importer_base.rb`:

```ruby
    def self.call(query: nil, item: nil, force_providers: false, providers: nil, subject: nil, verify: false, match: nil)
      new.call(query: query, item: item, force_providers: force_providers, providers: providers, subject: subject,
        verify: verify, match: match)
    end

    # match: a Match the caller already got from this importer's finder. It is
    # used instead of asking again, so a decision is made (and an AI call paid
    # for) once.
    def call(query: nil, item: nil, force_providers: false, providers: nil, subject: nil, verify: false, match: nil)
```

In the single-item branch, delete the `match = nil` line and replace

```ruby
          match = finder.call(query: query, verify: verify, subject: subject)
```

with

```ruby
          match ||= finder.call(query: query, verify: verify, subject: subject)
```

and at the top of the `if item.present?` arm add `match = nil`, so an item-based import never
carries a match.

- [ ] **Step 4: Implement the book and author importers and providers**

`book/importer.rb`:

```ruby
        def self.call(title: nil, author_names: [], year: nil, isbn13: [], isbn10: [], asin: [], goodreads_id: [],
          open_library_work_key: nil, item: nil, force_providers: false, providers: nil, subject: nil, verify: false,
          match: nil, provisional: false, stamp_identifiers: false, enrich: true)
          importer = new(provisional: provisional, stamp_identifiers: stamp_identifiers, enrich: enrich)
          if item.present?
            importer.call(item: item, force_providers: force_providers, providers: providers)
          else
            query = ImportQuery.new(
              title: title,
              author_names: author_names,
              year: year,
              isbn13: isbn13,
              isbn10: isbn10,
              asin: asin,
              goodreads_id: goodreads_id,
              open_library_work_key: open_library_work_key
            )
            importer.call(query: query, force_providers: force_providers, providers: providers, subject: subject,
              verify: verify, match: match)
          end
        end

        # provisional: the book, and any author this import creates, are saved
        # provisional (Goodreads import spec §5, §9). stamp_identifiers: the
        # query's identifiers are stamped whatever Open Library says, so a
        # book made while the service is down can be found again by them.
        # enrich: false skips AiEnrichment and AuthorEnrichment; an import's
        # enrichment runs on admin approval instead.
        def initialize(provisional: false, stamp_identifiers: false, enrich: true)
          @provisional = provisional
          @stamp_identifiers = stamp_identifiers
          @enrich = enrich
        end

        def call(**)
          result = super
          result.created_author_ids = new_author_ids.dup
          result
        end
```

Replace `providers` (keep its comment, and add one line saying QueryIdentifiers runs after Authors
when asked for):

```ruby
        def providers
          @providers ||= begin
            list = [
              Providers::OpenLibrary.new(new_author_ids: new_author_ids, provisional: @provisional),
              Providers::Authors.new(new_author_ids: new_author_ids, provisional: @provisional)
            ]
            list << Providers::QueryIdentifiers.new if @stamp_identifiers
            if @enrich
              list << Providers::AiEnrichment.new(new_author_ids: new_author_ids)
              list << Providers::AuthorEnrichment.new(new_author_ids: new_author_ids)
            end
            list
          end
        end
```

and in `initialize_item` add `provisional: @provisional` to `::Books::Book.new(...)`.

`providers/authors.rb`: `def initialize(new_author_ids: [], provisional: false)` storing
`@provisional`, and pass `provisional: @provisional` to `::DataImporters::Books::Author::Importer.call`.

`providers/open_library.rb`: `def initialize(client: nil, new_author_ids: [], provisional: false)` storing
`@provisional`, and pass `provisional: @provisional` in `link_open_library_authors`'s
`::DataImporters::Books::Author::Importer.call`.

`providers/query_identifiers.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      module Providers
        # Stamps the query's own identifiers on the book whatever Open Library
        # said (Goodreads import spec §5). Providers::OpenLibrary stamps them
        # only on an accept, so a book created while the service is down or
        # abstaining could never be found again by the identifier it came in
        # with. Runs only when the importer is asked to (stamp_identifiers).
        class QueryIdentifiers < DataImporters::ProviderBase
          def populate(book, query:, match: nil)
            return success_result(data_populated: []) if query.nil?

            stamped = []
            Providers::OpenLibrary::IDENTIFIER_TYPE_BY_QUERY_FIELD.each do |field, identifier_type|
              Array(query.public_send(field)).each do |value|
                identifier = book.identifiers.find_or_initialize_by(identifier_type: identifier_type, value: value)
                stamped << identifier_type.to_s if identifier.new_record?
              end
            end
            success_result(data_populated: stamped.uniq)
          end
        end
      end
    end
  end
end
```

`author/importer.rb`:

```ruby
        def self.call(name: nil, open_library_author_key: nil, birth_year: nil, death_year: nil, alternate_names: [], work_titles: [],
          item: nil, force_providers: false, providers: nil, subject: nil, verify: false, provisional: false)
          importer = new(provisional: provisional)
          if item.present?
            importer.call(item: item, force_providers: force_providers, providers: providers)
          else
            query = ImportQuery.new(
              name: name,
              open_library_author_key: open_library_author_key,
              birth_year: birth_year,
              death_year: death_year,
              alternate_names: alternate_names,
              work_titles: work_titles
            )
            importer.call(query: query, force_providers: force_providers, providers: providers, subject: subject, verify: verify)
          end
        end

        # provisional: an author this import creates is saved provisional; an
        # author it matches is returned untouched (Goodreads import spec §9).
        def initialize(provisional: false)
          @provisional = provisional
        end
```

and add `provisional: @provisional` to `::Books::Author.new(...)` in `initialize_item`.

- [ ] **Step 5: Run the tests, then every importer test**

Run: `bin/rails test test/lib/data_importers/`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/lib/data_importers test/lib/data_importers
git commit -m "Books importer: match, provisional, stamp_identifiers and enrich options

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: ParseRows, and the shared test helper

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_imports/parse_rows.rb`, `web-app/test/support/goodreads_import_helper.rb`
- Modify: `web-app/test/test_helper.rb` (add the `require_relative` after the other support files)
- Test: `web-app/test/lib/services/books/goodreads_imports/parse_rows_test.rb`

**Interfaces:**
- Consumes: `Books::Goodreads::ExportFile`, `ExportRow#edition_attributes/#row_attributes/#valid?/#errors` (Task 2);
  the models (Task 3).
- Produces:
  - `Services::Books::GoodreadsImports::ParseRows.call(import:, rows:) → Result(data: {import:})`.
  - `GoodreadsImportHelper` with `stub_resolution_services(search_hits: [])`, `search_hit(book)`,
    `stub_matching_ai(selected_index:, confidence: "high")`, `goodreads_csv(*rows)`,
    `goodreads_rows(*rows)`, `goodreads_edition(**attributes)`,
    `unmatched_match(subject:, candidates: [], decided_by: :rule)`.

- [ ] **Step 1: Write the helper**

`web-app/test/support/goodreads_import_helper.rb`:

```ruby
# frozen_string_literal: true

require "csv"

# Shared setup for the Goodreads import resolver tests: the finder's and the
# importer's outside services stubbed to "nothing found" (OpenSearch empty,
# Open Library abstaining), plus builders for export CSVs, editions and
# unmatched finder answers.
module GoodreadsImportHelper
  OPEN_LIBRARY_URL = "http://open-library.test:8080"
  EXPORT_HEADERS = ["Book Id", "Title", "Author", "Additional Authors", "ISBN", "ISBN13", "My Rating",
    "Year Published", "Original Publication Year", "Date Read", "Date Added", "Bookshelves",
    "Bookshelves with positions", "Exclusive Shelf", "My Review", "Private Notes", "Read Count"].freeze

  def stub_resolution_services(search_hits: [])
    client = ::Books::OpenLibrary::Client.new(
      config: ::Books::OpenLibrary::Configuration.new(base_url: OPEN_LIBRARY_URL),
      breaker: ::Books::OpenLibrary::CircuitBreaker.new(key: "test:goodreads:open_library", failure_threshold: 5,
        cooldown: 60, redis: ::Books::OpenLibrary::FakeRedis.new)
    )
    ::Books::OpenLibrary::Client.stubs(:new).returns(client)
    stub_request(:post, "#{OPEN_LIBRARY_URL}/resolve").to_return(status: 200, body: open_library_abstain.to_json)
    ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns(search_hits)
    ::Search::Books::Search::AuthorByName.stubs(:call).returns([])
    ::Books::EnrichBookJob.stubs(:perform_async)
    ::Books::Authors::WikidataJob.stubs(:perform_async)
  end

  def open_library_abstain
    {
      "source_version" => {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1,
                           "pipeline_version" => 1, "matcher_version" => 2},
      "data" => {
        "decision" => {"verdict" => "abstain", "key" => nil, "score" => 0.0, "margin" => 0.0, "reason" => "test"},
        "guards_tripped" => [], "volume_guards_tripped" => [], "candidates" => []
      }
    }
  end

  def search_hit(book, score = 9.0)
    {id: book.id.to_s, score: score, source: {}}
  end

  def stub_matching_ai(selected_index:, confidence: "high")
    task = stub("select_candidate_task")
    task.stubs(:call).returns(::Services::Ai::Result.new(success: true, ai_chat: ai_chats(:general_chat),
      data: {selected_index: selected_index, confidence: confidence, reasoning: "test", same_entity_groups: []}))
    ::Services::Ai::Tasks::Matching::SelectCandidateTask.stubs(:new).returns(task)
  end

  # Each row is a hash keyed by export header; headers it omits are blank.
  def goodreads_csv(*rows)
    CSV.generate do |csv|
      csv << EXPORT_HEADERS
      rows.each { |row| csv << EXPORT_HEADERS.map { |header| row[header] } }
    end
  end

  def goodreads_rows(*rows)
    ::Books::Goodreads::ExportFile.parse(goodreads_csv(*rows)).data[:rows]
  end

  def goodreads_edition(**attributes)
    title = attributes.fetch(:title, "The Quiet Year")
    author = attributes.fetch(:primary_author, "Anna Brenner")
    ::Books::GoodreadsEdition.create!({
      goodreads_book_id: 90_000_000 + ::Books::GoodreadsEdition.count,
      signature: ::Books::Goodreads::ExportRow.signature(title, author),
      title: title, primary_author: author
    }.merge(attributes))
  end

  def unmatched_match(subject:, candidates: [], decided_by: :rule)
    decision = ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: subject,
      outcome: :unmatched, confidence: :high, decided_by: decided_by)
    ::DataImporters::Match.new(outcome: :unmatched, record: nil, confidence: :high, decided_by: decided_by,
      reason: "test", candidates: candidates, decision: decision)
  end
end
```

In `web-app/test/test_helper.rb`, after `require_relative "support/books/open_library/fake_redis"`:

```ruby
require_relative "support/goodreads_import_helper"
```

- [ ] **Step 2: Write the failing tests**

`web-app/test/lib/services/books/goodreads_imports/parse_rows_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class ParseRowsTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        DUNE = {"Book Id" => "234225", "Title" => "Dune (Dune, #1)", "Author" => "Frank Herbert",
                "ISBN" => '="0441013597"', "Original Publication Year" => "1965", "Exclusive Shelf" => "read",
                "Private Notes" => "secret"}.freeze

        setup do
          @import = ::Books::GoodreadsImport.create!(user: users(:editor_user), status: :parsing)
        end

        test "writes a row per CSV row and an edition per Goodreads id and signature" do
          ParseRows.call(import: @import, rows: goodreads_rows(DUNE, DUNE.merge("Exclusive Shelf" => "to-read")))

          edition = ::Books::GoodreadsEdition.find_by!(goodreads_book_id: 234225)
          assert_equal [2, 1], [@import.reload.rows_count, @import.editions_count]
          assert_equal [edition.id, edition.id], @import.rows.order(:row_number).pluck(:goodreads_edition_id)
          assert_equal ["Dune", "Dune", "1", "Frank Herbert", "9780441013593", "0441013597", 1965],
            [edition.title, edition.series_name, edition.series_number, edition.primary_author, edition.isbn13,
              edition.isbn10, edition.original_publication_year]
        end

        test "a real Goodreads id under another title gets its own edition and leaves the honest one alone" do
          ParseRows.call(import: @import, rows: goodreads_rows(DUNE, DUNE.merge("Title" => "An Invented Book", "Author" => "Nobody")))

          editions = ::Books::GoodreadsEdition.where(goodreads_book_id: 234225).order(:id)
          assert_equal [["Dune", "Frank Herbert"], ["An Invented Book", "Nobody"]], editions.map { |e| [e.title, e.primary_author] }
        end

        test "a row that cannot be parsed is kept as failed, with why, and no edition" do
          ParseRows.call(import: @import, rows: goodreads_rows(DUNE.merge("Book Id" => "")))

          row = @import.rows.sole
          assert row.failed?
          assert_nil row.goodreads_edition_id
          assert_equal "no Goodreads book id", row.error
        end

        test "running it twice changes nothing" do
          rows = goodreads_rows(DUNE, DUNE.merge("Book Id" => "1", "Title" => "Other"))
          ParseRows.call(import: @import, rows: rows)

          assert_no_difference(["::Books::GoodreadsImportRow.count", "::Books::GoodreadsEdition.count"]) do
            ParseRows.call(import: @import, rows: rows)
          end
          assert_equal [2, 2], [@import.reload.rows_count, @import.editions_count]
        end

        test "an edition another import already parsed is reused, not rewritten" do
          other = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :complete)
          ParseRows.call(import: other, rows: goodreads_rows(DUNE))

          ParseRows.call(import: @import, rows: goodreads_rows(DUNE.merge("Original Publication Year" => "1999")))

          assert_equal 1, ::Books::GoodreadsEdition.where(goodreads_book_id: 234225).count
          assert_equal 1965, ::Books::GoodreadsEdition.find_by!(goodreads_book_id: 234225).original_publication_year
        end

        test "Private Notes is never stored; the parse notes are" do
          ParseRows.call(import: @import, rows: goodreads_rows(DUNE.merge("Date Read" => "someday")))

          row = @import.rows.sole
          assert_not row.raw.key?("Private Notes")
          assert_equal ["unreadable Date Read dropped: someday"], row.notes
        end
      end
    end
  end
end
```

- [ ] **Step 3: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/goodreads_imports/parse_rows_test.rb`
Expected: errors, `uninitialized constant Services::Books::GoodreadsImports`.

- [ ] **Step 4: Implement**

`web-app/app/lib/services/books/goodreads_imports/parse_rows.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Writes one import row per export row and links each parseable row to
      # its edition, creating the edition the first time any import names
      # that Goodreads id under that signature (Goodreads import spec §3, §5).
      # An edition another import created is reused as it is; its fields are
      # never rewritten. A row that cannot be parsed is kept, failed, with the
      # reason. Safe to run again: rows already written are skipped.
      class ParseRows
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(import:, rows:)
          new(import: import, rows: rows).call
        end

        def initialize(import:, rows:)
          @import = import
          @rows = rows
        end

        def call
          written = @import.rows.pluck(:row_number).to_set
          @rows.each do |row|
            next if written.include?(row.row_number)

            write(row)
          end
          @import.update!(
            rows_count: @import.rows.count,
            editions_count: @import.rows.where.not(goodreads_edition_id: nil).distinct.count(:goodreads_edition_id)
          )
          Result.new(success?: true, data: {import: @import}, errors: [])
        end

        private

        def write(row)
          if row.valid?
            @import.rows.create!(row.row_attributes.merge(goodreads_edition: edition_for(row)))
          else
            @import.rows.create!(row.row_attributes.merge(outcome: :failed, error: row.errors.join("; ")))
          end
        end

        def edition_for(row)
          key = {goodreads_book_id: row.goodreads_book_id, signature: row.signature}
          ::Books::GoodreadsEdition.find_by(key) ||
            ::Books::GoodreadsEdition.create_or_find_by!(key) { |edition| edition.assign_attributes(row.edition_attributes) }
        end
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass, and check Zeitwerk**

Run: `bin/rails test test/lib/services/books/goodreads_imports/parse_rows_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: 6 runs, 0 failures; `All is good!`

- [ ] **Step 6: Commit**

```bash
git add app/lib/services/books/goodreads_imports/parse_rows.rb test/support/goodreads_import_helper.rb test/test_helper.rb test/lib/services/books/goodreads_imports/parse_rows_test.rb
git commit -m "Goodreads import: parse rows into import rows and shared editions

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: CreateBook — lock, re-check, create, provenance

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_imports/create_book.rb`
- Test: `web-app/test/lib/services/books/goodreads_imports/create_book_test.rb`,
  `web-app/test/lib/services/books/goodreads_imports/create_book_concurrency_test.rb`

**Interfaces:**
- Consumes: the importer options (Task 5), `ImportResult#created_author_ids`, the models (Task 3),
  `GoodreadsImportHelper` (Task 6).
- Produces: `Services::Books::GoodreadsImports::CreateBook.call(edition:, import:, match:, importer: DataImporters::Books::Book::Importer)`
  `→ Result(data: {edition:, outcome: :created | :matched | :cached})`. Raises
  `CreateBook::CreateFailed` when the importer makes no book. Callers pass a `match` that is
  unmatched.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/books/goodreads_imports/create_book_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class CreateBookTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          stub_resolution_services
          @import = ::Books::GoodreadsImport.create!(user: users(:editor_user), status: :resolving)
        end

        test "creates a provisional, unverified book from the edition and records everything it made" do
          edition = goodreads_edition(goodreads_book_id: 90_000_001, isbn13: "9780441013593", original_publication_year: 1977)
          match = unmatched_match(subject: edition)

          result = CreateBook.call(edition: edition, import: @import, match: match)

          edition.reload
          book = edition.book
          author = book.authors.sole
          assert_equal :created, result.data[:outcome]
          assert_equal ["The Quiet Year", 1977, true], [book.title, book.first_published_year, book.provisional?]
          assert_equal ["Anna Brenner", true], [author.name, author.provisional?]
          assert_equal [["books_work_goodreads_id", "90000001"], ["books_work_isbn13", "9780441013593"]],
            book.identifiers.map { |identifier| [identifier.identifier_type, identifier.value] }.sort
          assert_equal [true, true], [edition.created?, edition.verification_unverified?]
          assert_equal match.decision, edition.match_decision
          assert_equal book, match.decision.reload.record
          expected = [["Books::Book", book.id], ["Books::Author", author.id]] +
            book.book_authors.map { |link| ["Books::BookAuthor", link.id] } +
            book.identifiers.map { |identifier| ["Identifier", identifier.id] }
          assert_equal expected.sort, @import.records.map { |record| [record.record_type, record.record_id] }.sort
          assert @import.records.all?(&:created?)
        end

        test "an existing author is linked, never made provisional, never recorded as created" do
          edition = goodreads_edition(title: "Hadji Murat", primary_author: "Leo Tolstoy")

          CreateBook.call(edition: edition, import: @import, match: unmatched_match(subject: edition))

          tolstoy = books_authors(:tolstoy)
          assert_equal [tolstoy], edition.reload.book.authors.to_a
          assert_not tolstoy.reload.provisional?
          assert_not @import.records.exists?(record_type: "Books::Author", record_id: tolstoy.id)
        end

        test "an edition another import resolved while this one waited is left as it is" do
          edition = goodreads_edition
          match = unmatched_match(subject: edition)
          ::Books::GoodreadsEdition.where(id: edition.id)
            .update_all(book_id: books_books(:war_and_peace).id, resolution: 0, resolved_at: Time.current)
          importer = mock("importer")
          importer.expects(:call).never

          result = CreateBook.call(edition: edition, import: @import, match: match, importer: importer)

          assert_equal [:cached, books_books(:war_and_peace)], [result.data[:outcome], edition.reload.book]
        end

        test "a book created for the same signature since the finder looked is adopted" do
          book = ::Books::Book.create!(title: "The Quiet Year", provisional: true)
          goodreads_edition(goodreads_book_id: 90_000_010, book: book, resolution: :created, resolved_at: Time.current)
          edition = goodreads_edition(goodreads_book_id: 90_000_011)
          importer = mock("importer")
          importer.expects(:call).never

          result = CreateBook.call(edition: edition, import: @import, match: unmatched_match(subject: edition), importer: importer)

          edition.reload
          assert_equal [:matched, book, true], [result.data[:outcome], edition.book, edition.matched?]
        end

        test "a book the finder already considered and turned down is not adopted" do
          book = ::Books::Book.create!(title: "The Quiet Year", provisional: true)
          goodreads_edition(goodreads_book_id: 90_000_010, book: book, resolution: :created, resolved_at: Time.current)
          edition = goodreads_edition(goodreads_book_id: 90_000_011)
          considered = ::DataImporters::Candidate.new(record: book, sources: [:exact])

          result = CreateBook.call(edition: edition, import: @import, match: unmatched_match(subject: edition, candidates: [considered]))

          assert_equal :created, result.data[:outcome]
          assert_not_equal book, edition.reload.book
        end

        test "a same-signature edition that was matched, not created, is not adopted" do
          goodreads_edition(goodreads_book_id: 90_000_010, book: books_books(:war_and_peace), resolution: :matched,
            resolved_at: Time.current)
          edition = goodreads_edition(goodreads_book_id: 90_000_011)

          result = CreateBook.call(edition: edition, import: @import, match: unmatched_match(subject: edition))

          assert_equal :created, result.data[:outcome]
          assert_not_equal books_books(:war_and_peace), edition.reload.book
        end

        test "an importer that makes no book raises and leaves nothing behind" do
          edition = goodreads_edition
          failing = Object.new
          def failing.call(**)
            ::DataImporters::ImportResult.new(item: ::Books::Book.new, provider_results: [], success: false)
          end

          assert_raises(CreateBook::CreateFailed) do
            CreateBook.call(edition: edition, import: @import, match: unmatched_match(subject: edition), importer: failing)
          end
          assert_nil edition.reload.resolved_at
          assert_equal 0, @import.records.count
        end
      end
    end
  end
end
```

`web-app/test/lib/services/books/goodreads_imports/create_book_concurrency_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsImports
      # Two imports racing to create the same new book end with one book
      # (Goodreads import spec §5 "Locking", §14). Transactional tests are off:
      # each thread has its own connection, and one connection cannot see
      # another's rows inside a shared test transaction. Nothing rolls back,
      # so teardown deletes every row the test wrote.
      class CreateBookConcurrencyTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        self.use_transactional_tests = false

        TITLE = "The Concurrency Novel"
        AUTHOR = "Rae Racer"

        # Creates the book as the importer would. On its first call it reports
        # that, then waits to be released, holding its transaction (and so the
        # advisory lock) open.
        class PausingImporter
          def initialize(created:, release:)
            @created = created
            @release = release
            @calls = 0
            @mutex = Mutex.new
          end

          def call(title:, goodreads_id:, **)
            first = @mutex.synchronize { (@calls += 1) == 1 }
            book = ::Books::Book.create!(title: title, provisional: true)
            book.identifiers.create!(identifier_type: :books_work_goodreads_id, value: goodreads_id.first)
            if first
              @created << true
              @release.pop(timeout: 10)
            end
            ::DataImporters::ImportResult.new(item: book, provider_results: [], success: true, created: true)
          end
        end

        # Loaded with the class, before any thread starts: autoloading inside a
        # thread while this one holds the load interlock would deadlock.
        PRELOADED = [CreateBook, ::DataImporters::ImportResult, ::Books::GoodreadsImportRecord, ::Books::BookAuthor,
          ::Identifier, ::MatchDecision, ::SearchIndexRequest].freeze

        setup do
          @import = ::Books::GoodreadsImport.create!(user: users(:editor_user), status: :resolving)
          signature = ::Books::Goodreads::ExportRow.signature(TITLE, AUTHOR)
          @first = ::Books::GoodreadsEdition.create!(goodreads_book_id: 91_000_001, signature: signature, title: TITLE, primary_author: AUTHOR)
          @second = ::Books::GoodreadsEdition.create!(goodreads_book_id: 91_000_002, signature: signature, title: TITLE, primary_author: AUTHOR)
        end

        teardown do
          book_ids = ::Books::Book.where(title: TITLE).pluck(:id)
          ::Books::GoodreadsImportRecord.where(import_id: @import.id).delete_all
          ::Books::GoodreadsEdition.where(id: [@first.id, @second.id]).delete_all
          ::MatchDecision.where(subject_type: "Books::GoodreadsEdition", subject_id: [@first.id, @second.id]).delete_all
          ::Identifier.where(identifiable_type: "Books::Book", identifiable_id: book_ids).delete_all
          ::SearchIndexRequest.where(parent_type: "Books::Book", parent_id: book_ids).delete_all
          ::Books::Book.where(id: book_ids).delete_all
          ::Books::GoodreadsImport.where(id: @import.id).delete_all
        end

        test "two imports racing to create the same new book end with one book" do
          created = Thread::Queue.new
          release = Thread::Queue.new
          importer = PausingImporter.new(created: created, release: release)
          first_match = unmatched_match(subject: @first)
          second_match = unmatched_match(subject: @second)

          first = Thread.new { in_connection { CreateBook.call(edition: @first, import: @import, match: first_match, importer: importer) } }
          assert waiting { created.pop(timeout: 10) }, "the first import never reached its create"
          second = Thread.new { in_connection { CreateBook.call(edition: @second, import: @import, match: second_match, importer: importer) } }
          waiting { sleep 0.5 }
          assert second.alive?, "the second import did not wait for the first one's lock"

          release << true
          results = waiting { [first.value, second.value] }

          assert_equal [:created, :matched], results.map { |result| result.data[:outcome] }
          assert_equal 1, ::Books::Book.where(title: TITLE).count
          assert_equal @first.reload.book_id, @second.reload.book_id
        end

        private

        def in_connection(&block)
          ActiveRecord::Base.connection_pool.with_connection(&block)
        end

        def waiting(&block)
          ActiveSupport::Dependencies.interlock.permit_concurrent_loads(&block)
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/goodreads_imports/create_book_test.rb test/lib/services/books/goodreads_imports/create_book_concurrency_test.rb`
Expected: errors, `uninitialized constant Services::Books::GoodreadsImports::CreateBook`.

- [ ] **Step 3: Implement**

`web-app/app/lib/services/books/goodreads_imports/create_book.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Creates the provisional book for an edition the finder could not
      # match, and records what it made (Goodreads import spec §5, "Creating a
      # book" and "Locking").
      #
      # The advisory lock is keyed by the edition's signature (normalized
      # title plus primary author), so two imports racing to create one book,
      # through the same Goodreads id or two editions of the same title and
      # author, take turns here. Under the lock the edition is re-read (the
      # other import may have resolved it), then editions with the same
      # signature are checked for a book created since the finder looked.
      # Only then is a book created. Books the finder already considered are
      # left out of that check: a book it saw and turned down, an AI "none"
      # included, stays turned down.
      #
      # The book goes through the book importer with the finder's match (no
      # second finder run), provisional, with the edition's identifiers
      # stamped and no enrichment; enrichment runs on admin approval. With no
      # Goodreads fetcher yet (increment 4), every creation is unverified.
      class CreateBook
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        CreateFailed = Class.new(StandardError)

        # The subquery gives the result a type the adapter knows:
        # pg_advisory_xact_lock returns void (see Services::Billing::ReconcileCustomer).
        LOCK_SQL = "SELECT 1 AS locked FROM (SELECT pg_advisory_xact_lock(hashtext($1)::bigint)) AS lock_taken"

        def self.call(edition:, import:, match:, importer: ::DataImporters::Books::Book::Importer)
          new(edition: edition, import: import, match: match, importer: importer).call
        end

        def initialize(edition:, import:, match:, importer:)
          @edition = edition
          @import = import
          @match = match
          @importer = importer
        end

        def call
          ActiveRecord::Base.transaction do
            acquire_lock
            @edition.reload
            next done(:cached) if settled?

            racer = book_created_since_the_finder_looked
            next adopt(racer) if racer

            create
          end
        end

        private

        def acquire_lock
          ActiveRecord::Base.connection.exec_query(LOCK_SQL, "goodreads-create-lock", ["goodreads-edition:#{@edition.signature}"])
        end

        def settled?
          @edition.resolved_at.present? && (@edition.book_id.present? || @edition.parked?)
        end

        def book_created_since_the_finder_looked
          considered = @match.candidates.select(&:local?).map { |candidate| candidate.record.id }
          ::Books::GoodreadsEdition.created
            .where(signature: @edition.signature)
            .where.not(id: @edition.id)
            .where.not(book_id: [nil, *considered])
            .order(:resolved_at, :id)
            .first&.book
        end

        def adopt(book)
          @match.decision&.update!(record: book)
          resolve!(book, :matched, :not_needed)
          done(:matched)
        end

        def create
          result = @importer.call(
            title: @edition.title,
            author_names: [@edition.primary_author],
            year: @edition.original_publication_year || @edition.year_published,
            isbn13: [@edition.isbn13].compact,
            isbn10: [@edition.isbn10].compact,
            goodreads_id: [@edition.goodreads_book_id.to_s],
            subject: @edition,
            match: @match,
            provisional: true,
            stamp_identifiers: true,
            enrich: false
          )
          book = result.item
          unless result.created? && book&.persisted?
            raise CreateFailed, "no book created for Goodreads edition #{@edition.id}: #{result.all_errors.join("; ")}"
          end

          record_provenance(book, result.created_author_ids)
          resolve!(book, :created, :unverified)
          done(:created)
        end

        def record_provenance(book, created_author_ids)
          records = [book] +
            ::Books::BookAuthor.where(book: book).to_a +
            ::Identifier.where(identifiable: book).to_a +
            ::Books::Author.where(id: created_author_ids).to_a
          records.each { |record| @import.records.create!(record: record, action: :created) }
        end

        def resolve!(book, resolution, verification)
          @edition.update!(book: book, resolution: resolution, verification: verification,
            match_decision: @match.decision, resolved_at: Time.current)
        end

        def done(outcome)
          Result.new(success?: true, data: {edition: @edition, outcome: outcome}, errors: [])
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: the Step 2 command.
Expected: 8 runs, 0 failures.

- [ ] **Step 5: Get mutation evidence for the lock and the re-check**

Each change below must make "two imports racing…" fail. Revert each one before making the next.
1. Comment out `acquire_lock` in `call`. Expected: `the second import did not wait` (or two books).
2. Restore it and replace `racer = book_created_since_the_finder_looked` with `racer = nil`.
   Expected: `Expected: 1  Actual: 2` books.

Record both in the ledger as `Task 7: mutation <change> → <failure seen>`.

Then run the concurrency test 5 times to check it is stable:
`for i in 1 2 3 4 5; do bin/rails test test/lib/services/books/goodreads_imports/create_book_concurrency_test.rb | tail -1; done`
Expected: `0 failures, 0 errors` on all five runs.

- [ ] **Step 6: Commit**

```bash
git add app/lib/services/books/goodreads_imports/create_book.rb test/lib/services/books/goodreads_imports/create_book_test.rb test/lib/services/books/goodreads_imports/create_book_concurrency_test.rb
git commit -m "Goodreads import: create provisional books under an advisory lock

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: ResolveEdition and ResolveImport

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_imports/resolve_edition.rb`, `resolve_import.rb`
- Test: `web-app/test/lib/services/books/goodreads_imports/resolve_edition_test.rb`, `resolve_import_test.rb`

**Interfaces:**
- Consumes: `CreateBook` (Task 7), `ParseRows` (Task 6), the finder's AI context (Task 4).
- Produces:
  - `ResolveEdition.call(edition:, import:, finder: nil, importer: ...) → Result(data: {edition:, outcome: :cached | :matched | :created})`.
    Increments `import.ai_calls_count` per AI call.
  - `ResolveImport.call(import:, finder: nil, importer: ...) → Result(data: {import:, outcomes: Hash})`.
    Sets `matched_count`, `created_count`, `flagged_count` and `parked_count`.

- [ ] **Step 1: Write the failing ResolveEdition tests**

`web-app/test/lib/services/books/goodreads_imports/resolve_edition_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class ResolveEditionTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          stub_resolution_services
          @import = ::Books::GoodreadsImport.create!(user: users(:editor_user), status: :resolving)
          @war_and_peace = books_books(:war_and_peace)
        end

        test "an exact title and author match links the existing book, unflagged" do
          edition = goodreads_edition(title: "War and Peace", primary_author: "Leo Tolstoy", original_publication_year: 1869)

          result = ResolveEdition.call(edition: edition, import: @import)

          edition.reload
          decision = edition.match_decision
          assert_equal [:matched, @war_and_peace], [result.data[:outcome], edition.book]
          assert_equal [true, true], [edition.matched?, edition.verification_not_needed?]
          assert_equal ["high", false, edition], [decision.confidence, decision.needs_review, decision.subject]
        end

        test "an ISBN the catalog holds links its book with certainty" do
          edition = goodreads_edition(title: "War and Peace", primary_author: "Leo Tolstoy", isbn13: "9780140447934")

          ResolveEdition.call(edition: edition, import: @import)

          assert_equal [@war_and_peace, "certain"], [edition.reload.book, edition.match_decision.confidence]
        end

        test "nothing found creates a provisional book, unflagged" do
          edition = goodreads_edition

          result = ResolveEdition.call(edition: edition, import: @import)

          edition.reload
          assert_equal :created, result.data[:outcome]
          assert edition.book.provisional?
          assert_equal false, edition.match_decision.needs_review
        end

        test "an AI 'none of these' creates a book and flags it; it never takes the top search hit" do
          ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([search_hit(@war_and_peace)])
          stub_matching_ai(selected_index: 0)
          edition = goodreads_edition(title: "War and Peace in the Garden", primary_author: "Leo Tolstoy")

          result = ResolveEdition.call(edition: edition, import: @import)

          edition.reload
          assert_equal :created, result.data[:outcome]
          assert_not_equal @war_and_peace, edition.book
          assert edition.book.provisional?
          assert edition.match_decision.needs_review
        end

        test "a medium-confidence AI match links the book and flags it" do
          ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([search_hit(@war_and_peace)])
          stub_matching_ai(selected_index: 1, confidence: "medium")
          edition = goodreads_edition(title: "War and Peace in the Garden", primary_author: "Leo Tolstoy")

          assert_no_difference("::Books::Book.count") { ResolveEdition.call(edition: edition, import: @import) }

          assert_equal [@war_and_peace, true], [edition.reload.book, edition.match_decision.needs_review]
        end

        test "AI calls are counted on the import; rule decisions are not" do
          ResolveEdition.call(edition: goodreads_edition(title: "War and Peace", primary_author: "Leo Tolstoy",
            original_publication_year: 1869), import: @import)
          assert_equal 0, @import.reload.ai_calls_count

          ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([search_hit(@war_and_peace)])
          stub_matching_ai(selected_index: 1, confidence: "medium")
          ResolveEdition.call(edition: goodreads_edition(title: "War and Peace in the Garden", primary_author: "Leo Tolstoy"),
            import: @import)

          assert_equal 1, @import.reload.ai_calls_count
        end

        test "an edition already resolved is reused without asking the finder" do
          edition = goodreads_edition(book: @war_and_peace, resolution: :matched, resolved_at: Time.current)
          finder = mock("finder")
          finder.expects(:call).never

          result = ResolveEdition.call(edition: edition, import: @import, finder: finder)

          assert_equal :cached, result.data[:outcome]
        end

        test "an edition whose book was deleted is resolved again" do
          gone = ::Books::Book.create!(title: "The Quiet Year")
          edition = goodreads_edition(book: gone, resolution: :matched, resolved_at: 1.day.ago)
          gone.destroy!

          result = ResolveEdition.call(edition: edition.reload, import: @import)

          assert_equal :created, result.data[:outcome]
          assert edition.reload.book.present?
        end

        test "a later import finds the provisional book an earlier one created instead of making another" do
          first = goodreads_edition(goodreads_book_id: 90_000_001)
          ResolveEdition.call(edition: first, import: @import)
          later_import = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :resolving)
          second = goodreads_edition(goodreads_book_id: 90_000_002)

          assert_no_difference("::Books::Book.count") { ResolveEdition.call(edition: second, import: later_import) }

          assert_equal first.reload.book, second.reload.book
          assert_equal "matched", second.match_decision.outcome
        end
      end
    end
  end
end
```

- [ ] **Step 2: Write the failing ResolveImport tests**

`web-app/test/lib/services/books/goodreads_imports/resolve_import_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class ResolveImportTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        # Not 656: the war_and_peace_edition fixture holds 656 under this
        # signature, already resolved, and would be reused without a finder run.
        WAR_AND_PEACE = {"Book Id" => "12345678", "Title" => "War and Peace", "Author" => "Leo Tolstoy",
                         "Original Publication Year" => "1869"}.freeze
        QUIET_YEAR = {"Book Id" => "90000001", "Title" => "The Quiet Year", "Author" => "Anna Brenner"}.freeze

        setup do
          stub_resolution_services
          @import = ::Books::GoodreadsImport.create!(user: users(:editor_user), status: :resolving)
        end

        def parse(*rows)
          ParseRows.call(import: @import, rows: goodreads_rows(*rows))
        end

        def counters
          @import.reload.slice(:matched_count, :created_count, :flagged_count, :parked_count, :ai_calls_count).values
        end

        test "resolves each edition once and sets the counters" do
          parse(WAR_AND_PEACE, WAR_AND_PEACE, QUIET_YEAR, {"Title" => "No Id", "Author" => "Anna Brenner"})

          ResolveImport.call(import: @import)

          assert_equal [1, 1, 0, 0, 0], counters
          assert_equal 2, ::MatchDecision.where(subject_type: "Books::GoodreadsEdition", subject_id: @import.editions.select(:id)).count
        end

        test "a flagged decision is counted" do
          ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([search_hit(books_books(:war_and_peace))])
          stub_matching_ai(selected_index: 1, confidence: "medium")
          parse(WAR_AND_PEACE.merge("Title" => "War and Peace in the Garden"))

          ResolveImport.call(import: @import)

          assert_equal [1, 0, 1, 0, 1], counters
        end

        test "a failing edition records its error on its rows, the rest resolve, and a retry clears it" do
          parse(WAR_AND_PEACE, QUIET_YEAR)
          real = ::DataImporters::Books::Book::Finder.new
          flaky = Object.new
          flaky.define_singleton_method(:call) do |query:, **options|
            raise "AI timeout" if query.title == "The Quiet Year"

            real.call(query: query, **options)
          end

          ResolveImport.call(import: @import, finder: flaky)

          quiet = @import.rows.joins(:goodreads_edition).find_by!(books_goodreads_editions: {title: "The Quiet Year"})
          assert_equal "resolution failed: RuntimeError: AI timeout", quiet.error
          assert_equal [1, 0], counters.first(2)

          ResolveImport.call(import: @import)

          assert_nil quiet.reload.error
          assert_equal [1, 1], counters.first(2)
        end

        test "a Postgres error stops the import" do
          parse(QUIET_YEAR)
          broken = Object.new
          broken.define_singleton_method(:call) { |**| raise ActiveRecord::StatementInvalid, "connection lost" }

          assert_raises(ActiveRecord::StatementInvalid) { ResolveImport.call(import: @import, finder: broken) }
        end

        test "running it again asks the finder nothing and leaves the counters alone" do
          parse(WAR_AND_PEACE, QUIET_YEAR)
          ResolveImport.call(import: @import)
          before = counters
          finder = mock("finder")
          finder.expects(:call).never

          assert_no_difference(["::Books::Book.count", "::MatchDecision.count"]) { ResolveImport.call(import: @import, finder: finder) }

          assert_equal before, counters
        end
      end
    end
  end
end
```

- [ ] **Step 3: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/goodreads_imports/resolve_edition_test.rb test/lib/services/books/goodreads_imports/resolve_import_test.rb`
Expected: errors, `uninitialized constant ...ResolveEdition` / `...ResolveImport`.

- [ ] **Step 4: Implement ResolveEdition**

`web-app/app/lib/services/books/goodreads_imports/resolve_edition.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Resolves one Goodreads edition (Goodreads import spec §5):
      #
      # 1. Cache: an edition already resolved to a book that still exists (or
      #    parked) is reused. The merger moves editions, so merges are
      #    followed; a deleted book nullifies book_id and the edition is
      #    resolved again.
      # 2. Finder: the full books finder, with the edition as its subject and
      #    the series and other credited names as AI context.
      # 3. Outcome: a match links (the finder flags medium, low and fallback
      #    decisions). No match creates a provisional book through CreateBook.
      #    An AI "none of these" creates too, and is flagged here; nothing
      #    ever falls back to the top search hit.
      #
      # Every AI call is counted on the import. Nothing caps them.
      class ResolveEdition
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(edition:, import:, finder: nil, importer: ::DataImporters::Books::Book::Importer)
          new(edition: edition, import: import, finder: finder, importer: importer).call
        end

        def initialize(edition:, import:, finder:, importer:)
          @edition = edition
          @import = import
          @finder = finder || ::DataImporters::Books::Book::Finder.new
          @importer = importer
        end

        def call
          return done(:cached) if settled?

          match = @finder.call(query: query, subject: @edition)
          @import.increment!(:ai_calls_count) if ai_call?(match.decision)

          if match.matched?
            @edition.update!(book: match.record, resolution: :matched, verification: :not_needed,
              match_decision: match.decision, resolved_at: Time.current)
            return done(:matched)
          end

          match.decision&.update!(needs_review: true) if match.decided_by == :ai
          done(CreateBook.call(edition: @edition, import: @import, match: match, importer: @importer).data[:outcome])
        end

        private

        def settled?
          @edition.resolved_at.present? && (@edition.book_id.present? || @edition.parked?)
        end

        def query
          ::DataImporters::Books::Book::ImportQuery.new(
            title: @edition.title,
            author_names: [@edition.primary_author],
            year: @edition.original_publication_year || @edition.year_published,
            isbn13: [@edition.isbn13],
            isbn10: [@edition.isbn10],
            goodreads_id: [@edition.goodreads_book_id.to_s],
            series_name: @edition.series_name,
            series_number: @edition.series_number,
            context_author_names: @edition.additional_authors
          )
        end

        # A fallback decision only comes from an AI call that failed, which
        # was still a call.
        def ai_call?(decision)
          decision.present? && (decision.ai_chat_id.present? || decision.decided_by_ai? || decision.decided_by_fallback?)
        end

        def done(outcome)
          Result.new(success?: true, data: {edition: @edition, outcome: outcome}, errors: [])
        end
      end
    end
  end
end
```

- [ ] **Step 5: Implement ResolveImport**

`web-app/app/lib/services/books/goodreads_imports/resolve_import.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Resolves every edition an import's rows name, once each, then sets
      # the import's counters from what is now true (Goodreads import spec §5,
      # §13). Safe to run again: resolved editions are reused, and the
      # counters are recomputed rather than incremented, so a retry neither
      # double-counts nor loses anything. ai_calls_count is the exception: it
      # counts calls as they happen (ResolveEdition).
      #
      # One failing edition never stops the import: its rows carry the error
      # and the edition stays unresolved for the next run, which clears the
      # error on success. Postgres errors re-raise.
      class ResolveImport
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        POSTGRES_ERRORS = [ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished].freeze

        def self.call(import:, finder: nil, importer: ::DataImporters::Books::Book::Importer)
          new(import: import, finder: finder, importer: importer).call
        end

        def initialize(import:, finder:, importer:)
          @import = import
          @finder = finder || ::DataImporters::Books::Book::Finder.new
          @importer = importer
        end

        def call
          outcomes = Hash.new(0)
          ::Books::GoodreadsEdition.where(id: edition_ids).order(:id).each do |edition|
            outcomes[resolve(edition)] += 1
          end
          recount
          Result.new(success?: true, data: {import: @import, outcomes: outcomes}, errors: [])
        end

        private

        def edition_ids
          @edition_ids ||= @import.rows.where.not(goodreads_edition_id: nil).distinct.pluck(:goodreads_edition_id)
        end

        def resolve(edition)
          result = ResolveEdition.call(edition: edition, import: @import, finder: @finder, importer: @importer)
          rows_for(edition).where.not(error: nil).update_all(error: nil)
          result.data[:outcome]
        rescue *POSTGRES_ERRORS
          raise
        rescue => e
          Rails.logger.error("#{self.class.name}: Goodreads edition #{edition.id} failed: #{e.class}: #{e.message}")
          rows_for(edition).update_all(error: "resolution failed: #{e.class}: #{e.message}")
          :failed
        end

        def rows_for(edition)
          @import.rows.where(goodreads_edition_id: edition.id)
        end

        # created: books this import's provenance says it made. matched: every
        # other linked edition, including books another import created.
        # flagged: linked decisions still waiting for review.
        def recount
          editions = ::Books::GoodreadsEdition.where(id: edition_ids)
          created_book_ids = @import.records.created.where(record_type: "Books::Book").pluck(:record_id)
          @import.update!(
            created_count: created_book_ids.size,
            matched_count: editions.where.not(book_id: nil).where.not(book_id: created_book_ids).count,
            parked_count: editions.parked.count,
            flagged_count: editions.joins(:match_decision).merge(::MatchDecision.needing_review).count
          )
        end
      end
    end
  end
end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: the Step 3 command.
Expected: 14 runs, 0 failures.

- [ ] **Step 7: Get mutation evidence for the flag and create-vs-link rules**

Each change must make the named test fail. Revert each one before the next.
1. Delete `match.decision&.update!(needs_review: true) if match.decided_by == :ai`. Expected:
   "an AI 'none of these' creates a book and flags it…" fails on `needs_review`.
2. Change `if match.matched?` to `if match.matched? || match.candidates.any?(&:local?)` and
   `match.record` to `match.record || match.candidates.find(&:local?).record` (legacy root cause
   1: take the top hit). Expected: the same AI-none test fails on `assert_not_equal @war_and_peace`.
3. Change `settled?` to `@edition.resolved_at.present?`. Expected: "an edition whose book was
   deleted is resolved again" fails.

Ledger each as `Task 8: mutation <change> → <failure seen>`.

- [ ] **Step 8: Commit**

```bash
git add app/lib/services/books/goodreads_imports/resolve_edition.rb app/lib/services/books/goodreads_imports/resolve_import.rb test/lib/services/books/goodreads_imports/resolve_edition_test.rb test/lib/services/books/goodreads_imports/resolve_import_test.rb
git commit -m "Goodreads import: resolve editions through the finder, once each

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Dry run, rake task and feature doc

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_imports/dry_run.rb`, `web-app/lib/tasks/books/goodreads.rake`,
  `web-app/test/fixtures/files/goodreads/small_export.csv`, `docs/features/goodreads-import.md`
- Test: `web-app/test/lib/services/books/goodreads_imports/dry_run_test.rb`, `web-app/test/lib/tasks/books_goodreads_rake_test.rb`

**Interfaces:**
- Consumes: `ExportFile` (Task 2), `ParseRows` (Task 6), `ResolveImport` (Task 8).
- Produces: `DryRun.call(bytes:, user:, finder: nil, importer: ...) → Result(success?:, data: {report: String}, errors:)`;
  rake `books:goodreads:resolve_file[path,user_id]`.

- [ ] **Step 1: Write the fixture CSV**

`web-app/test/fixtures/files/goodreads/small_export.csv` (a real export's full header row):

```csv
Book Id,Title,Author,Author l-f,Additional Authors,ISBN,ISBN13,My Rating,Average Rating,Publisher,Binding,Number of Pages,Year Published,Original Publication Year,Date Read,Date Added,Bookshelves,Bookshelves with positions,Exclusive Shelf,My Review,Spoiler,Private Notes,Read Count,Owned Copies
12345678,War and Peace,Leo Tolstoy,"Tolstoy, Leo","Richard Pevear, Larissa Volokhonsky","=""0140447938""","=""9780140447934""",5,4.16,Penguin,Paperback,1392,2006,1869,2024/05/03,2024/01/09,classics,classics (#1),read,"A long one.<br/>Worth it.",,keep this private,1,0
90000001,The Quiet Year (Brenner Saga #1),Anna Brenner,"Brenner, Anna",,"=""""","=""""",0,3.90,Small Press,Hardcover,212,2020,2019,,2024/02/10,,,to-read,,,,0,0
,A Row With No Id,Anna Brenner,"Brenner, Anna",,"=""""","=""""",0,0.00,,,,,,,2024/02/11,,,to-read,,,,0,0
```

- [ ] **Step 2: Write the failing tests**

`web-app/test/lib/services/books/goodreads_imports/dry_run_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class DryRunTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          stub_resolution_services
          @bytes = file_fixture("goodreads/small_export.csv").binread
        end

        test "reports each decision" do
          report = DryRun.call(bytes: @bytes, user: users(:regular_user)).data[:report]

          assert_match "Goodreads dry run: 3 rows, 2 editions. Nothing was saved.", report
          assert_match "matched 1 | created 1 | flagged 0 | failed rows 1 | AI calls 0", report
          assert_match %(row 1: gr 12345678 "War and Peace" by Leo Tolstoy -> matched Books::Book##{books_books(:war_and_peace).id}), report
          assert_match %r{row 2: gr 90000001 "The Quiet Year" by Anna Brenner -> created provisional Books::Book#\d+ "The Quiet Year" \(unverified\)}, report
          assert_match "row 3: failed: no Goodreads book id", report
        end

        test "saves nothing" do
          counted = ["::Books::Book.count", "::Books::Author.count", "::Books::GoodreadsImport.count",
            "::Books::GoodreadsEdition.count", "::Books::GoodreadsImportRow.count", "::MatchDecision.count", "::Identifier.count"]

          assert_no_difference(counted) { DryRun.call(bytes: @bytes, user: users(:regular_user)) }
        end

        test "a file that is not an export is refused with the reason" do
          result = DryRun.call(bytes: "Title,Author\nX,Y\n", user: users(:regular_user))

          assert_not result.success?
          assert_match "missing Goodreads export headers", result.errors.sole
        end

        test "a user with an import in progress can still dry-run" do
          ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :resolving)

          assert DryRun.call(bytes: @bytes, user: users(:regular_user)).success?
        end
      end
    end
  end
end
```

`web-app/test/lib/tasks/books_goodreads_rake_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksGoodreadsRakeTest < ActiveSupport::TestCase
  DRY_RUN = Services::Books::GoodreadsImports::DryRun

  setup do
    # Load only this one rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("books:goodreads:resolve_file")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/goodreads.rake").to_s }
    end
    @task = Rake::Task["books:goodreads:resolve_file"]
    @task.reenable
    @path = file_fixture("goodreads/small_export.csv").to_s
  end

  test "aborts with usage when no path is given" do
    DRY_RUN.expects(:call).never

    assert_output(nil, /usage: books:goodreads:resolve_file/) { assert_raises(SystemExit) { @task.invoke } }
  end

  test "aborts on a file that does not exist" do
    DRY_RUN.expects(:call).never

    assert_output(nil, /no such file/) { assert_raises(SystemExit) { @task.invoke("/nonexistent/export.csv") } }
  end

  test "prints the dry run's report for the given user" do
    user = users(:editor_user)
    DRY_RUN.expects(:call).with(bytes: File.binread(@path), user: user)
      .returns(DRY_RUN::Result.new(success?: true, data: {report: "the report"}, errors: []))

    assert_output(/the report/) { @task.invoke(@path, user.id.to_s) }
  end

  test "aborts with the reason when the file is refused" do
    DRY_RUN.stubs(:call).returns(DRY_RUN::Result.new(success?: false, data: {}, errors: ["missing Goodreads export headers: Title"]))

    assert_output(nil, /missing Goodreads export headers/) { assert_raises(SystemExit) { @task.invoke(@path) } }
  end
end
```

- [ ] **Step 3: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/goodreads_imports/dry_run_test.rb test/lib/tasks/books_goodreads_rake_test.rb`
Expected: errors, `uninitialized constant ...DryRun`, and the rake file is missing.

- [ ] **Step 4: Implement the dry run**

`web-app/app/lib/services/books/goodreads_imports/dry_run.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Resolves a Goodreads export exactly as an import would (parse, find,
      # create) and reports every decision, then rolls all of it back. For
      # measuring the resolver on a real file before anything ships:
      #   bin/rails "books:goodreads:resolve_file[/path/to/export.csv]"
      #
      # The rollback covers rows, editions, decisions, books and authors. It
      # cannot take back outside calls: Open Library requests and matching AI
      # calls are made, and paid for, for real. Runs in a savepoint so the
      # rollback also works inside a caller's transaction (a test). The import
      # is created complete, never in progress, so it never collides with the
      # owner's real in-progress import.
      class DryRun
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(bytes:, user:, finder: nil, importer: ::DataImporters::Books::Book::Importer)
          new(bytes: bytes, user: user, finder: finder, importer: importer).call
        end

        def initialize(bytes:, user:, finder:, importer:)
          @bytes = bytes
          @user = user
          @finder = finder
          @importer = importer
        end

        def call
          parsed = ::Books::Goodreads::ExportFile.parse(@bytes)
          return Result.new(success?: false, data: {}, errors: parsed.errors) unless parsed.success?

          report = nil
          ActiveRecord::Base.transaction(requires_new: true) do
            import = ::Books::GoodreadsImport.create!(user: @user, source: :member, status: :complete)
            ParseRows.call(import: import, rows: parsed.data[:rows])
            ResolveImport.call(import: import, finder: @finder, importer: @importer)
            report = build_report(import.reload)
            raise ActiveRecord::Rollback
          end
          Result.new(success?: true, data: {report: report}, errors: [])
        end

        private

        def build_report(import)
          rows = import.rows.order(:row_number).to_a
          created_ids = import.records.created.where(record_type: "Books::Book").pluck(:record_id).to_set
          editions = ::Books::GoodreadsEdition.where(id: rows.filter_map(&:goodreads_edition_id))
            .includes(:match_decision, book: :authors).index_by(&:id)

          lines = [
            "Goodreads dry run: #{import.rows_count} rows, #{import.editions_count} editions. Nothing was saved.",
            "matched #{import.matched_count} | created #{import.created_count} | flagged #{import.flagged_count} | " \
              "failed rows #{rows.count(&:failed?)} | AI calls #{import.ai_calls_count}",
            ""
          ]
          rows.group_by(&:goodreads_edition_id).each do |edition_id, group|
            if edition_id.nil?
              group.each { |row| lines << "row #{row.row_number}: failed: #{row.error}" }
            else
              lines << "row #{group.map(&:row_number).join(",")}: #{describe(editions.fetch(edition_id), created_ids, group)}"
            end
          end
          lines.join("\n")
        end

        def describe(edition, created_ids, group)
          source = %(gr #{edition.goodreads_book_id} "#{edition.title}" by #{edition.primary_author})
          return "#{source} -> failed: #{group.filter_map(&:error).first}" if edition.resolved_at.nil?
          return "#{source} -> parked" if edition.book.nil?

          book = edition.book
          outcome = if created_ids.include?(book.id)
            %(created provisional Books::Book##{book.id} "#{book.title}" (#{edition.verification}))
          else
            %(matched Books::Book##{book.id} "#{book.title}" by #{book.authors.map(&:name).join(", ")})
          end
          "#{source} -> #{outcome}#{decision_note(edition.match_decision)}"
        end

        def decision_note(decision)
          return "" if decision.nil?

          note = " (#{decision.confidence}, #{decision.decided_by})"
          note += " [flagged: #{decision.reason}]" if decision.needs_review?
          note += " [sources failed: #{decision.sources_failed.join(", ")}]" if decision.sources_failed.any?
          note
        end
      end
    end
  end
end
```

- [ ] **Step 5: Implement the rake task**

`web-app/lib/tasks/books/goodreads.rake`:

```ruby
namespace :books do
  namespace :goodreads do
    desc "Dry run: resolve a Goodreads export CSV and print every decision; saves nothing " \
      "(Open Library and matching AI calls are still made). Usage: books:goodreads:resolve_file[path,user_id]"
    task :resolve_file, [:path, :user_id] => :environment do |_task, args|
      path = args[:path]
      abort "usage: books:goodreads:resolve_file[path,user_id]" if path.blank?
      abort "no such file: #{path}" unless File.file?(path)

      user = args[:user_id].present? ? User.find(args[:user_id]) : User.order(:id).first!
      result = Services::Books::GoodreadsImports::DryRun.call(bytes: File.binread(path), user: user)
      abort result.errors.join("; ") unless result.success?

      puts result.data[:report]
    end
  end
end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: the Step 3 command.
Expected: 8 runs, 0 failures. If "saves nothing" fails, check that the transaction has
`requires_new: true`. Without a savepoint, a nested `ActiveRecord::Rollback` is swallowed by the
test's transaction.

- [ ] **Step 7: Write the feature doc**

`docs/features/goodreads-import.md`:

```markdown
# Goodreads import

Members will upload their Goodreads library export and get their shelves, dates, ratings and
reviews on the books site. The legacy app had this feature and it produced most of the legacy
catalog's bad data; this one is built so that it cannot. Spec:
`docs/superpowers/specs/2026-10-03-goodreads-import-design.md`.

## Status

| Increment | What | State |
|---|---|---|
| 1 | Optional review ratings | shipped |
| 2 | Provisional books and authors (`docs/features/books-provisional-records.md`) | shipped |
| 3 | Resolver core: parsing, tables, edition resolution, dry run | this doc |
| 4 | Goodreads page fetcher and verification | not started |
| 5 | Legacy replay | not started |
| 6 | Member upload, library write, admin approval | not started |
| 7 | Finishing failed legacy imports | not started |

Nothing in production calls the resolver yet. The only entry point is the dry-run rake.

## Parsing

`Books::Goodreads::ExportFile.parse(bytes)` decodes the file (BOM stripped; Windows-1252 when the
bytes are not UTF-8; scrubbed when they are neither), parses it with liberal quoting, and refuses
it unless the `Book Id`, `Title`, `Author` and `Exclusive Shelf` headers are present. It never
refuses a row.

`Books::Goodreads::ExportRow` reads one row by header name:

- The Goodreads id is the leading digits of whatever form it arrives in (`Books::GoodreadsId`).
- ISBNs are checksum-validated and converted both ways (`Books::Isbn`, the Rails twin of
  `data-sources/src/common/normalize.py`). An invalid ISBN is dropped.
- The title is kept whole. Only a trailing `(Series Name, #N)` is split off into
  `series_name`/`series_number`.
- Only the primary `Author` is an author. `Additional Authors` is passed to the matching AI as
  context, because Goodreads mixes translators and illustrators into it.
- A value that does not parse is dropped and recorded in the row's `notes`.
- `Private Notes` is never stored.

## Data model

- `books_goodreads_imports`: one per upload. A partial unique index allows one import in progress
  per user.
- `books_goodreads_editions`: the unit that is resolved, keyed by Goodreads id plus signature
  (digest of the normalized, series-stripped title and primary author). An edition is shared by
  every import that names it. A row claiming a real id under another title gets its own edition.
  `book_id` is nullified if the book is deleted; the book merger moves editions.
- `books_goodreads_import_rows`: one per CSV row, with the user's fields, `notes`, and later the
  ids it wrote.
- `books_goodreads_import_records`: provenance. Every book, author, book_author and identifier an
  import created.

Editions reference `books_books`, so truncating books for a migration pass empties them too. That
is intended: the replay rebuilds them.

## Resolution

`Services::Books::GoodreadsImports::ResolveImport` resolves each distinct edition once, through
`ResolveEdition`:

1. **Cache.** An edition already resolved to a book that exists is reused.
2. **Finder.** The full books finder (identifiers, exact, OpenSearch, Open Library, AI), with the
   edition as the match decision's subject. The finder does not filter provisional books, so a
   later import links to an earlier import's provisional book instead of making another.
3. **Outcome.** A match links. The finder flags medium, low and fallback decisions. No match
   creates a provisional book through `CreateBook`. An AI "none of these" creates too, and is
   flagged. Nothing falls back to the top search hit.

`CreateBook` holds `pg_advisory_xact_lock` on the edition's signature, re-reads the edition, adopts
a book that a same-signature edition created since the finder looked (never one the finder already
considered), and otherwise creates through `DataImporters::Books::Book::Importer` with:

- `match:` the finder's match, so the finder and the AI run once;
- `provisional: true`, for the book and any author it creates;
- `stamp_identifiers: true`, so the edition's Goodreads id and ISBNs are on the book even when Open
  Library is down;
- `enrich: false`, because enrichment runs on admin approval (increment 6).

Every creation is `verification: unverified` until increment 4 adds the Goodreads fetch.

Counters (`matched`, `created`, `flagged`, `parked`) are recomputed from state after each run, so a
retry is safe. `ai_calls_count` counts calls as they happen. Matching AI is not capped. A failing
edition records its error on its rows and stays unresolved for the next run; Postgres errors
re-raise.

## Dry run

    bin/rails "books:goodreads:resolve_file[/path/to/goodreads_library_export.csv]"
    bin/rails "books:goodreads:resolve_file[/path/to/export.csv,USER_ID]"

Parses and resolves the file exactly as an import would, prints one line per edition (matched book,
created book, flagged reason, failed sources) and rolls everything back. Open Library requests and
matching AI calls are real and are paid for.
```

- [ ] **Step 8: Lint, Zeitwerk, full suite**

```bash
bundle exec standardrb --format progress
CI=1 bin/rails zeitwerk:check
bin/rails test > log/inc3-suite.log 2>&1; tail -5 log/inc3-suite.log
grep -i "warn" log/inc3-suite.log | grep -v -i "npm\|yarn" | head
```

Expected: standardrb `no offenses`; `All is good!`; the suite has 0 failures and 0 errors; no new
warning lines beyond the known npm/yarn and `weighted_list_rank` ones. Fix any standardrb offenses
with `bundle exec standardrb --fix` and re-run the touched tests.

No Playwright test: this increment adds no page or flow. The upload page and admin pages are
increment 6, and their E2E tests come with them.

- [ ] **Step 9: Commit**

```bash
git add app/lib/services/books/goodreads_imports/dry_run.rb lib/tasks/books/goodreads.rake test/fixtures/files/goodreads test/lib/services/books/goodreads_imports/dry_run_test.rb test/lib/tasks/books_goodreads_rake_test.rb ../docs/features/goodreads-import.md
git commit -m "Goodreads import: dry-run rake and feature doc

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
