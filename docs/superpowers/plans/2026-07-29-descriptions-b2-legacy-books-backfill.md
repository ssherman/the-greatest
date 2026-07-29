# Descriptions (b2) — Legacy Books & Authors Backfill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Backfill 186,634 `Description` rows from the legacy books database so `/book/:slug` has real content — today only 39% of ranked books have a description, because the original `BookTransformer` ported the wrong column.

**Architecture:** Two `Services::BooksMigration::BulkUpsertMigrator` subclasses stream the legacy `books` and `authors` tables and map each row's description columns onto polymorphic `Description` rows, writing with `insert_all` (ON CONFLICT DO NOTHING) rather than the base class's `upsert_all`. A shared pure `DescriptionSourceNormalizer` maps the dirty legacy source labels onto `(source, source_name, license)`. A third service, `Services::BooksDescriptionSafetyNet`, runs **after** both migrators and gives a `:manual` row to any in-app-created book or author the legacy columns do not speak for.

**Tech Stack:** Rails 8.1, PostgreSQL 17, Minitest + Mocha + fixtures, `standardrb`.

**Spec:** `docs/superpowers/specs/2026-07-27-descriptions-subsystem-design.md` (increment b2 — Backfill section, decisions D5, D10, D11, D14, D15).

---

## Global Constraints

- Run **every** Rails command from `web-app/`. Docs live at the project root in `docs/`, not `web-app/docs/`.
- Lint with `bundle exec standardrb` (`--fix` autocorrects). **Never** `bin/rubocop`. **Never** run brakeman.
- **The development database is not disposable.** The books data exists only in dev and takes hours to rebuild. Never run a destructive DB command against development. `bin/snapshot-dev-db.sh --label pre-b2` before the data run in Task 7.
- **No test legacy database exists or is needed.** `LegacyBooks::Record` skips `connects_to` in test. Every migrator test stubs `legacy_each` with Mocha: `m.stubs(:legacy_each).multiple_yields(*rows.zip)`. No test may query a `LegacyBooks::*` model for real.
- **No code comments inside method bodies.** Class/module-level header comments explaining *why* are the established pattern for `Services::BooksMigration::*` — write those, following the density of `list_item_migrator.rb`.
- **Skinny models, fat services.** Business logic goes in `app/lib/services/`, never `app/services/`.
- Use `Rails.env`-appropriate generators where a generator exists. These are plain service objects under `app/lib/`, which have no generator — create the files directly, and create the matching test file directly too.
- **`.presence`, never truthiness**, on every legacy column read. Legacy data contains a whitespace-only `ai_generated_description` (verified: 1 row), and `descriptions_content_not_blank` rejects the whole batch if one gets through.
- **`source_name` is stripped, never verbatim.** It sits inside the natural-key unique index, and legacy holds `"Publisher "` (98 rows) alongside `"Publisher"`. Case is preserved; only whitespace is trimmed.
- **Never read the in-app `books_books.description` / `books_authors.description` columns in the two legacy migrators.** Those columns already *are* the legacy raw `description` from the earlier migration, so reading them too double-creates. Only Task 5's safety net reads them.
- **`Descriptions::SourcePriority::ORDER` is contractual — do not reorder it.** `ai_generated` before `goodreads` before the sourced values reproduces the legacy books `default` behaviour; `ai_generated` before `wikipedia` reproduces the legacy author page's `ai_description || description`.
- **Constant shadowing.** Inside `module Services`, `Descriptions` resolves lexically to `Services::Descriptions`, and bare `Games::`/`Music::` hit `Services::Games`/`Services::Music`. There is **no** `Services::Books`, so bare `Books::Book` inside `Services::BooksMigration` is safe (and `list_item_migrator.rb` already relies on that). Task 5 still uses string model names + `constantize`, matching `Services::DescriptionColumnBackfill`.
- **`LegacyBooks::Book#use_description` is a raw integer**, not an enum string: `0` default, `1` use_goodreads, `2` use_description.

### Verified source data (probed against the live legacy DB, 2026-07-29)

These are the numbers the plan's assertions use. They were measured, not taken from the spec — **four differ from the spec** and the spec is corrected in Task 7.

| | Rows | Note |
|---|---|---|
| legacy `books` total | 126,204 | 0 missing a migrated `Books::Book`; 50 in-app books have no legacy row |
| legacy `authors` total | 58,193 | 0 missing a migrated `Books::Author`; 21 in-app authors have no legacy row |
| `books.ai_generated_description` | **111,446** | 111,447 non-blank in SQL, **1 is whitespace-only** and `.presence` skips it |
| `books.goodreads_description` | 8,162 | |
| `books.description` | 20,242 | → wikipedia 10,379 · openlibrary 7,511 · other 2,149 · publisher 203 |
| **books rows total** | **139,850** | spec said 139,851 |
| `authors.ai_description` | 38,114 | |
| `authors.description` | 8,670 | → wikipedia 8,218 · **other/"Unattributed" 452** |
| **authors rows total** | **46,784** | matches spec |
| **grand total** | **186,634** | spec said 186,635 |
| preferred rows | **1,481** | goodreads 1,479 + raw 2; spec said 2,139 |
| safety net | **0** | spec said ~50 + ~21 |

**Four corrections, each verified:**

1. **139,850, not 139,851.** One `ai_generated_description` is whitespace-only — present in SQL (`<> ''`) but `.blank?` in Ruby. `.presence` skips it. This is D15's "known gap" showing up in real data, which is why Task 1 exists.
2. **1,481 preferred rows, not 2,139.** There are 2,137 `use_goodreads` books, but only **1,479** of them have a non-blank `goodreads_description`. The other 658 have no Goodreads text at all, so there is no `:goodreads` row to mark — and legacy `description_to_display` falls through to `ai_generated_description` for them, which `SourcePriority::ORDER` already reproduces. Plus the 2 `use_description` books. `build_rows` gets this right for free by only emitting a row when the column has `.presence`, but the test in Task 3 pins it explicitly.
3. **The safety net writes 0 rows in dev.** All 50 in-app-created books and all 21 in-app-created authors have a **blank** `description`, and every book/author that has a description is covered by a non-blank legacy `description`. 0 is a **pass**, not a failure. Build the service anyway: it is specced, it is cheap, and production is a different dataset. Task 7 re-measures the cardinality after the migrators run, before writing.
4. **452 author descriptions have no stated source.** The spec maps all 8,670 legacy author descriptions to `:wikipedia` + `:cc_by_sa_4`, but only **8,218** state `description_source = wikipedia` (with an `en.wikipedia.org` URL); 451 are NULL and 1 is `""`, and **none of the 452 has a `description_source_url`**. Blanket-asserting CC BY-SA on them would be a licence claim the app cannot honour — a public `AttributionComponent` in increment (d) would render a CC BY-SA credit with nothing to attribute to. D10 forbids the guess. They map to `:other` + `source_name: "Unattributed"`, `license: nil`, which is **the same rule the spec already approved** for the 659 books with a blank `description_source_name` — so this is one shared normaliser, not a special case. Display is unaffected: `ai_generated` precedes both `wikipedia` and `other` in `ORDER`, and 8,589 of the 8,670 also have an `ai_description`.

### Verified implementation facts (probed on PG 17 / Rails 8.1, 2026-07-29)

- `Description.insert_all(rows, unique_by: :index_descriptions_on_describable_and_key)` returns an `ActiveRecord::Result` whose **`.length` is the number of rows Postgres actually inserted** — `1` on first insert, `0` on a conflicting re-run. Use it, so a re-run honestly reports 0 instead of re-counting skipped rows.
- Under `insert_all`, two rows sharing the conflict key **in the same batch do not raise** `PG::CardinalityViolation` (the second is silently skipped). That failure mode belongs to `ON CONFLICT DO UPDATE`. Switching to `insert_all` neutralises it — but the header comment must still say so, because a future switch back to `upsert_all` reintroduces it.
- `unique_by:` addressed by index name infers the arbiter correctly against the `NULLS NOT DISTINCT` index, and enum **symbols** serialise through the model's attribute types, so `build_rows` can emit `{source: :ai_generated, rank: :normal}` with no manual integer mapping.
- `Books::Book` / `Books::Author` do **not** override `polymorphic_name`, so `describable_type` is the literal `"Books::Book"` / `"Books::Author"` (matching `list_item_migrator.rb`).

### Available fixtures (checked — do not guess these)

- `test/fixtures/books/books.yml`: `war_and_peace`, `crime_and_punishment`, `combo_steinbeck`, `got`, `clash`, `of_mice_and_men`, `cannery_row`
- `test/fixtures/books/authors.yml`: `tolstoy`, `king`, `bachman`, `garnett`
- `test/fixtures/descriptions.yml` already attaches rows to `war_and_peace`, `crime_and_punishment`, `combo_steinbeck` (books) and `tolstoy` (author). **Use `of_mice_and_men`, `cannery_row`, `got`, `clash` and `king`, `bachman`, `garnett` in new tests** — they start with zero descriptions.

---

## File Structure

| File | Responsibility |
|---|---|
| Create `web-app/db/migrate/<ts>_widen_description_content_not_blank_constraint.rb` | Close D15's `btrim` gap so the DB guard matches Ruby's `.blank?` |
| Create `web-app/app/lib/services/books_migration/description_source_normalizer.rb` | Pure: dirty legacy source label → `{source:, source_name:, license:}`. Shared by both migrators |
| Create `web-app/app/lib/services/books_migration/insert_only_migrator.rb` | `BulkUpsertMigrator` with `flush` overridden to `insert_all`. Holds the why-not-upsert reasoning once; both description migrators subclass it |
| Create `web-app/app/lib/services/books_migration/book_description_migrator.rb` | Legacy `books`' three description columns → `Description` rows |
| Create `web-app/app/lib/services/books_migration/author_description_migrator.rb` | Legacy `authors`' two description columns → `Description` rows |
| Create `web-app/app/lib/services/books_description_safety_net.rb` | In-app books/authors with a description and no row → `:manual` row. Runs last |
| Modify `web-app/lib/tasks/data_migration.rake` | Four new tasks: three runners + an ordered aggregate |
| Create `web-app/test/lib/services/books_migration/description_source_normalizer_test.rb` | Every normalisation branch |
| Create `web-app/test/lib/services/books_migration/book_description_migrator_test.rb` | Sources, licences, preferred, blanks, idempotency, fail-loud |
| Create `web-app/test/lib/services/books_migration/author_description_migrator_test.rb` | Same, plus the Unattributed mapping |
| Create `web-app/test/lib/services/books_description_safety_net_test.rb` | Fires only where no row exists; skips legacy-sourced rows |
| Modify `web-app/test/models/description_test.rb` | Pin the widened CHECK constraint |
| Modify `docs/superpowers/specs/2026-07-27-descriptions-subsystem-design.md` | Correct the four numbers; record the author-provenance decision |
| Delete `docs/superpowers/specs/HANDOFF-descriptions-b2.md` | Its own instruction: delete once b2's plan exists |

---

### Task 1: Widen the content-not-blank CHECK constraint

D15 flagged that single-argument `btrim()` trims ASCII spaces only, so `"\t\n"` satisfies `length(btrim(content)) > 0` while being `.blank?` in Ruby, and said it was "worth widening if increment (b2) touches this migration anyway". b2 does not touch that migration — but the legacy data b2 reads contains **exactly one** whitespace-only `ai_generated_description`, so the gap is real rather than theoretical. Widening it first means the 186,634-row backfill runs under a guard that matches `.presence`. Runs before the backfill while the table holds only 11,382 rows, so validation is instant.

**Files:**
- Create: `web-app/db/migrate/<timestamp>_widen_description_content_not_blank_constraint.rb`
- Modify: `web-app/test/models/description_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: the CHECK constraint `descriptions_content_not_blank` on `descriptions`, now rejecting any content that is empty after trimming space, tab, newline, carriage return, form feed and vertical tab. No Ruby interface.

- [ ] **Step 1: Write the failing test**

Append to `web-app/test/models/description_test.rb`, inside the existing `DescriptionTest` class:

```ruby
  test "the DB rejects whitespace-only content even when validations are bypassed" do
    assert_raises(ActiveRecord::StatementInvalid) do
      Description.insert_all([{
        describable_type: "Books::Book",
        describable_id: books_books(:of_mice_and_men).id,
        kind: :summary,
        locale: "en",
        source: :manual,
        content: "\t\n",
        rank: :normal
      }])
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/description_test.rb -n "/whitespace-only content/"`

Expected: FAIL — no exception is raised, because the current single-argument `btrim` does not trim tabs or newlines, so the row inserts successfully.

- [ ] **Step 3: Generate and write the migration**

Run: `bin/rails generate migration WidenDescriptionContentNotBlankConstraint`

Then replace the generated file's body with:

```ruby
class WidenDescriptionContentNotBlankConstraint < ActiveRecord::Migration[8.1]
  # Single-argument btrim() trims ASCII spaces only, so "\t\n" satisfied the original
  # constraint while being .blank? in Ruby -- D15's known gap. The legacy books data that
  # increment b2 reads contains one whitespace-only ai_generated_description, so the gap is
  # real, not theoretical: a build_rows that tested truthiness instead of .presence would
  # land it and still pass the row-count verification. Widened here, before the 186,634-row
  # backfill, while the table holds only 11,382 rows and validation is instant.
  def up
    remove_check_constraint :descriptions, name: "descriptions_content_not_blank"
    add_check_constraint :descriptions,
      "length(btrim(content, E' \\t\\n\\r\\f\\v')) > 0",
      name: "descriptions_content_not_blank"
  end

  def down
    remove_check_constraint :descriptions, name: "descriptions_content_not_blank"
    add_check_constraint :descriptions,
      "length(btrim(content)) > 0",
      name: "descriptions_content_not_blank"
  end
end
```

The Ruby double-quoted string `"...E' \\t\\n\\r\\f\\v'..."` emits the SQL literal `E' \t\n\r\f\v'`, which Postgres' `E''` escape-string syntax expands to the six whitespace characters.

- [ ] **Step 4: Migrate and run the test to verify it passes**

Run: `bin/rails db:migrate && bin/rails db:test:prepare && bin/rails test test/models/description_test.rb`

Expected: PASS, all tests in the file green.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix db/migrate test/models/description_test.rb
git add web-app/db/migrate web-app/db/schema.rb web-app/test/models/description_test.rb
git commit -m "Widen descriptions_content_not_blank to all whitespace

Single-argument btrim() trims ASCII spaces only, so \"\\t\\n\" passed the DB
check while being .blank? in Ruby (D15's known gap). The legacy books data b2
reads contains one such ai_generated_description, so the gap is reachable."
```

---

### Task 2: `DescriptionSourceNormalizer`

The one piece of real logic in b2: mapping the dirty legacy source labels onto a `Description` source. Pure, no DB, shared by both migrators. Extracted rather than inlined because both migrators need it and because the 452-author correction depends on books and authors using **the same** rule.

**Files:**
- Create: `web-app/app/lib/services/books_migration/description_source_normalizer.rb`
- Test: `web-app/test/lib/services/books_migration/description_source_normalizer_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Services::BooksMigration::DescriptionSourceNormalizer.call(raw_label) → Hash`, where `raw_label` is a `String` or `nil` and the return is exactly `{source: Symbol, source_name: String | nil, license: Symbol | nil}`. `source` is one of `:wikipedia`, `:openlibrary`, `:publisher`, `:other`. `source_name` is non-nil **iff** `source == :other` (required by the `descriptions_source_name_matches_source` biconditional CHECK). Both Task 3 and Task 4 call it.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/books_migration/description_source_normalizer_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::DescriptionSourceNormalizerTest < ActiveSupport::TestCase
  def normalize(label)
    Services::BooksMigration::DescriptionSourceNormalizer.call(label)
  end

  test "maps wikipedia to :wikipedia with a CC BY-SA licence, however it is cased or padded" do
    ["wikipedia", "Wikipedia", "WIkipedia", "Wikipedia ", " wikipedia"].each do |label|
      assert_equal({source: :wikipedia, source_name: nil, license: :cc_by_sa_4}, normalize(label),
        "expected #{label.inspect} to normalise to :wikipedia")
    end
  end

  test "maps openlibrary to :openlibrary with CC0" do
    assert_equal({source: :openlibrary, source_name: nil, license: :cc0}, normalize("OpenLibrary"))
  end

  test "maps publisher to :publisher with no licence, trailing space and all" do
    ["Publisher", "Publisher "].each do |label|
      assert_equal({source: :publisher, source_name: nil, license: nil}, normalize(label))
    end
  end

  test "collapses both Google spellings onto one :other label" do
    ["Google", "google", "Google Books"].each do |label|
      assert_equal({source: :other, source_name: "Google Books", license: nil}, normalize(label))
    end
  end

  test "maps a blank label to :other Unattributed rather than guessing a source" do
    [nil, "", "   "].each do |label|
      assert_equal({source: :other, source_name: "Unattributed", license: nil}, normalize(label),
        "expected #{label.inspect} to normalise to Unattributed")
    end
  end

  test "keeps an unrecognised label as :other with its case preserved and whitespace stripped" do
    assert_equal({source: :other, source_name: "Amazon.com", license: nil}, normalize("Amazon.com"))
    assert_equal({source: :other, source_name: "Publisher's Weekly", license: nil}, normalize("  Publisher's Weekly  "))
    assert_equal({source: :other, source_name: "WIkpedia", license: nil}, normalize("WIkpedia"))
  end

  test "never returns :ai_generated or :goodreads, so a normalised row cannot collide with a column row" do
    ["Goodreads", "good reads", "AI", "wikipedia", ""].each do |label|
      assert_not_includes [:ai_generated, :goodreads], normalize(label)[:source],
        "#{label.inspect} must not normalise onto a source another column already claims"
    end
  end

  test "returns a source_name if and only if the source is :other" do
    ["wikipedia", "OpenLibrary", "Publisher"].each do |label|
      assert_nil normalize(label)[:source_name]
    end
    ["Google", "", "Amazon.com"].each do |label|
      assert_not_nil normalize(label)[:source_name]
      assert_equal :other, normalize(label)[:source]
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/description_source_normalizer_test.rb`

Expected: FAIL with `NameError: uninitialized constant Services::BooksMigration::DescriptionSourceNormalizer`.

- [ ] **Step 3: Write the implementation**

Create `web-app/app/lib/services/books_migration/description_source_normalizer.rb`:

```ruby
module Services
  module BooksMigration
    # Pure mapping from a legacy description source label -- books.description_source_name
    # or authors.description_source -- onto a Description (source, source_name, license)
    # triple. Shared by BookDescriptionMigrator and AuthorDescriptionMigrator so books and
    # authors normalise by one rule.
    #
    # The legacy labels are dirty: "wikipedia" / "Wikipedia" / "WIkipedia" / "Wikipedia "
    # all mean one source (10,379 books + 8,218 authors), and 659 books + 452 authors state
    # no source at all. Case and whitespace are folded for MATCHING only; the label kept in
    # source_name is stripped but case-preserved, because source_name sits inside the
    # natural-key unique index -- "Publisher " (98 legacy rows) would otherwise be a second
    # distinct row and a near-duplicate label in the admin UI.
    #
    # Anything unrecognised becomes :other carrying its own label, never a guess (D10: no
    # :unknown source, and no licence asserted on text whose origin is not stated). The
    # unattributed rows matter most: none of them has a description_source_url, so a
    # cc_by_sa_4 claim would be an attribution increment (d)'s AttributionComponent could
    # not honour.
    #
    # Never returns :ai_generated or :goodreads. That is load-bearing, not incidental: it is
    # what keeps a normalised row from sharing a conflict key with the row a sibling column
    # already produced for the same record.
    module DescriptionSourceNormalizer
      NAMED = {
        "wikipedia" => {source: :wikipedia, license: :cc_by_sa_4},
        "openlibrary" => {source: :openlibrary, license: :cc0},
        "publisher" => {source: :publisher, license: nil}
      }.freeze

      GOOGLE_LABELS = ["google", "google books"].freeze
      GOOGLE_NAME = "Google Books"
      UNATTRIBUTED_NAME = "Unattributed"

      def self.call(raw_label)
        label = raw_label.to_s.strip
        named = NAMED[label.downcase]

        if named
          {source: named[:source], source_name: nil, license: named[:license]}
        elsif GOOGLE_LABELS.include?(label.downcase)
          {source: :other, source_name: GOOGLE_NAME, license: nil}
        elsif label.empty?
          {source: :other, source_name: UNATTRIBUTED_NAME, license: nil}
        else
          {source: :other, source_name: label, license: nil}
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/description_source_normalizer_test.rb`

Expected: PASS, 8 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/services/books_migration/description_source_normalizer.rb test/lib/services/books_migration/description_source_normalizer_test.rb
git add web-app/app/lib/services/books_migration/description_source_normalizer.rb web-app/test/lib/services/books_migration/description_source_normalizer_test.rb
git commit -m "Add DescriptionSourceNormalizer for the legacy description backfill"
```

---

### Task 3: `InsertOnlyMigrator` + `BookDescriptionMigrator`

Creates the shared `insert_all` base class alongside the first migrator that needs it, so the why-not-`upsert_all` reasoning is written once rather than duplicated into Task 4.

**Files:**
- Create: `web-app/app/lib/services/books_migration/insert_only_migrator.rb`
- Create: `web-app/app/lib/services/books_migration/book_description_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/book_description_migrator_test.rb`
- Read for the pattern: `web-app/app/lib/services/books_migration/list_item_migrator.rb`, `web-app/app/lib/services/books_migration/bulk_upsert_migrator.rb`

**Interfaces:**
- Consumes: `Services::BooksMigration::DescriptionSourceNormalizer.call(raw_label) → {source:, source_name:, license:}` (Task 2). `Services::BooksMigration::BulkUpsertMigrator`, whose `call` returns `{success: true, data: {model:, count:}}` or `{success: false, error:, data: {model:, count:}}`, and whose private template methods are `legacy_model`, `model_key`, `target_model`, `unique_by`, `build_rows(attrs)`, and optionally `preload_context`, `legacy_each`, `flush(rows)`, `record_timestamps?`.
- Produces:
  - `Services::BooksMigration::InsertOnlyMigrator < BulkUpsertMigrator` — overrides **only** the private `flush(rows)`, to `target_model.insert_all(rows, unique_by: unique_by, record_timestamps: record_timestamps?)`, accumulating `ActiveRecord::Result#length` into `@count`. Adds no other behaviour and defines no other method. Task 4 subclasses it.
  - `Services::BooksMigration::BookDescriptionMigrator.call` (inherited `self.call`) → the same Result hash, with `data[:model] == "Books::Book Description"` and `data[:count]` the number of rows Postgres actually inserted. Task 6 calls it from rake. Task 5's safety net depends on it having run.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/books_migration/book_description_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::BookDescriptionMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::BookDescriptionMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  # A legacy books row as BulkUpsertMigrator yields it: String keys, raw integer
  # use_description (0 default / 1 use_goodreads / 2 use_description).
  def legacy_book(id, overrides = {})
    {
      "id" => id,
      "ai_generated_description" => nil,
      "goodreads_description" => nil,
      "description" => nil,
      "description_source_name" => nil,
      "description_source_url" => nil,
      "use_description" => 0
    }.merge(overrides)
  end

  def descriptions_for(book)
    Description.where(describable: book).order(:source)
  end

  setup do
    @book = books_books(:of_mice_and_men)
    @other_book = books_books(:cannery_row)
  end

  test "creates one row per populated legacy column, with the right source and licence" do
    result = run_migrator([legacy_book(@book.id,
      "ai_generated_description" => "An AI summary.",
      "goodreads_description" => "A Goodreads blurb.",
      "description" => "A Wikipedia paragraph.",
      "description_source_name" => "wikipedia",
      "description_source_url" => "https://en.wikipedia.org/wiki/Of_Mice_and_Men")])

    assert result[:success], result[:error]
    assert_equal 3, result[:data][:count]

    ai = Description.find_by(describable: @book, source: :ai_generated)
    assert_equal "An AI summary.", ai.content
    assert_nil ai.license
    assert_nil ai.source_url

    goodreads = Description.find_by(describable: @book, source: :goodreads)
    assert_equal "A Goodreads blurb.", goodreads.content
    assert_equal "proprietary", goodreads.license
    assert_nil goodreads.source_url

    wikipedia = Description.find_by(describable: @book, source: :wikipedia)
    assert_equal "A Wikipedia paragraph.", wikipedia.content
    assert_equal "cc_by_sa_4", wikipedia.license
    assert_equal "https://en.wikipedia.org/wiki/Of_Mice_and_Men", wikipedia.source_url
    assert_nil wikipedia.source_name
  end

  test "writes summary kind, en locale, normal rank and no retrieved_at by default" do
    run_migrator([legacy_book(@book.id, "ai_generated_description" => "An AI summary.")])

    row = Description.find_by(describable: @book)
    assert_equal "summary", row.kind
    assert_equal "en", row.locale
    assert_equal "normal", row.rank
    assert_nil row.retrieved_at
    assert_nil row.source_name
  end

  test "normalises a dirty source label and keeps an unrecognised one as :other" do
    run_migrator([
      legacy_book(@book.id, "description" => "Padded label.", "description_source_name" => "Publisher "),
      legacy_book(@other_book.id, "description" => "Magazine text.", "description_source_name" => "  Publisher's Weekly  ")
    ])

    assert_equal "publisher", Description.find_by(describable: @book).source
    assert_nil Description.find_by(describable: @book).source_name

    other = Description.find_by(describable: @other_book)
    assert_equal "other", other.source
    assert_equal "Publisher's Weekly", other.source_name
  end

  test "marks only the goodreads row preferred for a use_goodreads book" do
    run_migrator([legacy_book(@book.id,
      "ai_generated_description" => "An AI summary.",
      "goodreads_description" => "A Goodreads blurb.",
      "use_description" => 1)])

    assert_equal "preferred", Description.find_by(describable: @book, source: :goodreads).rank
    assert_equal "normal", Description.find_by(describable: @book, source: :ai_generated).rank
  end

  test "marks only the raw-description row preferred for a use_description book" do
    run_migrator([legacy_book(@book.id,
      "ai_generated_description" => "An AI summary.",
      "description" => "The editor's pick.",
      "description_source_name" => "wikipedia",
      "use_description" => 2)])

    assert_equal "preferred", Description.find_by(describable: @book, source: :wikipedia).rank
    assert_equal "normal", Description.find_by(describable: @book, source: :ai_generated).rank
  end

  # 658 of the 2,137 legacy use_goodreads books have no goodreads_description at all.
  # There is no row to mark, and legacy description_to_display falls through to the AI text,
  # which SourcePriority::ORDER already reproduces.
  test "creates no preferred row when a use_goodreads book has no goodreads text" do
    run_migrator([legacy_book(@book.id,
      "ai_generated_description" => "An AI summary.",
      "goodreads_description" => "",
      "use_description" => 1)])

    assert_equal 1, descriptions_for(@book).count
    assert_equal "normal", Description.find_by(describable: @book, source: :ai_generated).rank
    assert_empty Description.where(describable: @book, rank: :preferred)
  end

  test "skips nil, empty and whitespace-only legacy columns" do
    result = run_migrator([legacy_book(@book.id,
      "ai_generated_description" => "   ",
      "goodreads_description" => "",
      "description" => nil)])

    assert result[:success], result[:error]
    assert_equal 0, result[:data][:count]
    assert_empty descriptions_for(@book)
  end

  test "gives a blank source label an Unattributed :other row rather than guessing" do
    run_migrator([legacy_book(@book.id, "description" => "Unsourced text.", "description_source_name" => nil)])

    row = Description.find_by(describable: @book)
    assert_equal "other", row.source
    assert_equal "Unattributed", row.source_name
    assert_nil row.license
  end

  # A raw description labelled "Goodreads" must not share a conflict key with the row the
  # goodreads_description column produces. The normaliser sends it to :other.
  test "keeps a Goodreads-labelled raw description separate from the goodreads column row" do
    result = run_migrator([legacy_book(@book.id,
      "goodreads_description" => "From the Goodreads column.",
      "description" => "From the raw column, labelled Goodreads.",
      "description_source_name" => "Goodreads")])

    assert result[:success], result[:error]
    assert_equal 2, result[:data][:count]
    assert_equal "From the Goodreads column.", Description.find_by(describable: @book, source: :goodreads).content
    assert_equal "From the raw column, labelled Goodreads.",
      Description.find_by(describable: @book, source: :other, source_name: "Goodreads").content
  end

  test "leaves an existing row's rank and content untouched" do
    existing = Description.create!(describable: @book, kind: :summary, locale: "en",
      source: :ai_generated, content: "Hand-edited text.", rank: :preferred)

    run_migrator([legacy_book(@book.id, "ai_generated_description" => "Legacy text that must not win.")])

    existing.reload
    assert_equal "preferred", existing.rank
    assert_equal "Hand-edited text.", existing.content
  end

  test "is idempotent and reports zero inserts on a second run" do
    first = run_migrator([legacy_book(@book.id, "ai_generated_description" => "An AI summary.")])
    assert_equal 1, first[:data][:count]

    second = nil
    assert_no_difference -> { Description.count } do
      second = run_migrator([legacy_book(@book.id, "ai_generated_description" => "An AI summary.")])
    end
    assert second[:success], second[:error]
    assert_equal 0, second[:data][:count]
  end

  test "fails loud when the legacy book has no migrated Books::Book" do
    missing = Books::Book.maximum(:id).to_i + 999_999
    result = run_migrator([legacy_book(missing, "ai_generated_description" => "Orphan text.")])

    refute result[:success]
    assert_match(/#{missing}/, result[:error])
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/book_description_migrator_test.rb`

Expected: FAIL with `NameError: uninitialized constant Services::BooksMigration::BookDescriptionMigrator`.

- [ ] **Step 3a: Write the shared `insert_all` base class**

Create `web-app/app/lib/services/books_migration/insert_only_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # BulkUpsertMigrator that writes with insert_all (ON CONFLICT DO NOTHING) instead of
    # upsert_all. Everything else -- streaming, batching, per-batch statements, the Result
    # hash, fail-loud error wrapping -- is inherited unchanged.
    #
    # Why, for the description backfill it exists to serve: upsert_all's ON CONFLICT DO
    # UPDATE writes every supplied column, so a re-run would reset an editor's
    # rank: :preferred back to :normal and overwrite edited content, violating D5. It can
    # also transiently double-occupy index_descriptions_one_preferred_per_key (D14), raising
    # a PG::UniqueViolation that ON CONFLICT cannot absorb -- the arbiter is the other index
    # -- aborting the whole batch. These backfills are a one-time lift, so skip-on-conflict
    # is the correct semantic: later runs leave existing rows alone while still picking up
    # records and sources that are new since the last run, and no finalize pass is needed.
    # Were re-syncing changed source text ever wanted, the safe form is
    # upsert_all(rows, unique_by: ..., update_only: [:content]) -- it refreshes text without
    # touching rank.
    #
    # Switching to insert_all also removes the intra-batch PG::CardinalityViolation that
    # ListPenaltyMigrator needed an @seen set for: DO NOTHING skips a repeated conflict key
    # rather than raising. A subclass that reintroduces upsert_all must reintroduce the
    # dedup with it.
    #
    # ActiveRecord::Result#length is the number of rows Postgres actually inserted, so
    # @count -- and the Result hash built from it -- honestly reports 0 on a no-op re-run
    # rather than re-counting skipped rows.
    class InsertOnlyMigrator < BulkUpsertMigrator
      private

      def flush(rows)
        result = target_model.insert_all(rows, unique_by: unique_by, record_timestamps: record_timestamps?)
        @count += result.length
      end
    end
  end
end
```

- [ ] **Step 3b: Write the migrator**

Create `web-app/app/lib/services/books_migration/book_description_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `books` description columns -> polymorphic Description rows (describable =
    # Books::Book, which preserves its legacy id, so no LegacyIdMap lookup is needed).
    #
    # Reads all THREE legacy columns and never books_books.description: that column already
    # IS the legacy raw description, ported by BookMigrator, so reading it too would
    # double-create. Fixing the original porting gap is the point of this migrator --
    # BookTransformer took the raw column, while the legacy site displays
    # description_to_display, which resolves to ai_generated_description for 87.5% of books.
    #
    # insert_all rather than upsert_all comes from InsertOnlyMigrator; see its header for why.
    #
    # No intra-batch dedup set is needed. Each legacy book yields at most one row per source
    # value: :ai_generated, :goodreads, and one normalised source that is never either of
    # those (DescriptionSourceNormalizer never returns them -- a raw description labelled
    # "Goodreads" becomes :other).
    #
    # rank: :preferred goes only where a human chose (D11). use_description = default is
    # reproduced exactly by SourcePriority::ORDER, so only the explicit choices are marked,
    # and only when the chosen column actually holds text: 658 of the 2,137 legacy
    # use_goodreads books have no goodreads_description, and legacy description_to_display
    # falls through to the AI text for them.
    class BookDescriptionMigrator < InsertOnlyMigrator
      USE_GOODREADS = 1
      USE_DESCRIPTION = 2

      LEGACY_COLUMNS = %i[
        id
        ai_generated_description
        goodreads_description
        description
        description_source_name
        description_source_url
        use_description
      ].freeze

      private

      def legacy_model
        LegacyBooks::Book
      end

      def model_key
        "Books::Book Description"
      end

      def target_model
        Description
      end

      def unique_by
        :index_descriptions_on_describable_and_key
      end

      def preload_context
        @book_ids = Books::Book.pluck(:id).to_set
      end

      # Narrowed to the columns actually mapped -- the legacy books table is wide, and the
      # base implementation would load every column of all 126,204 rows.
      def legacy_each(&block)
        legacy_model.select(*LEGACY_COLUMNS).find_each(batch_size: BATCH_SIZE) do |record|
          block.call(record.attributes)
        end
      end

      def build_rows(attrs)
        book_id = attrs["id"]
        unless @book_ids.include?(book_id)
          raise "no migrated Books::Book for legacy books.id=#{book_id.inspect}"
        end

        use = attrs["use_description"]
        rows = []

        if (content = attrs["ai_generated_description"].presence)
          rows << row(book_id, content, source: :ai_generated)
        end

        if (content = attrs["goodreads_description"].presence)
          rows << row(book_id, content,
            source: :goodreads,
            license: :proprietary,
            rank: (use == USE_GOODREADS) ? :preferred : :normal)
        end

        if (content = attrs["description"].presence)
          mapped = DescriptionSourceNormalizer.call(attrs["description_source_name"])
          rows << row(book_id, content,
            source: mapped[:source],
            source_name: mapped[:source_name],
            license: mapped[:license],
            source_url: attrs["description_source_url"].presence,
            rank: (use == USE_DESCRIPTION) ? :preferred : :normal)
        end

        rows
      end

      def row(book_id, content, source:, source_name: nil, license: nil, source_url: nil, rank: :normal)
        {
          describable_type: "Books::Book",
          describable_id: book_id,
          kind: :summary,
          locale: "en",
          source: source,
          source_name: source_name,
          content: content,
          rank: rank,
          source_url: source_url,
          license: license
        }
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/book_description_migrator_test.rb`

Expected: PASS, 12 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/services/books_migration/insert_only_migrator.rb app/lib/services/books_migration/book_description_migrator.rb test/lib/services/books_migration/book_description_migrator_test.rb
git add web-app/app/lib/services/books_migration/insert_only_migrator.rb web-app/app/lib/services/books_migration/book_description_migrator.rb web-app/test/lib/services/books_migration/book_description_migrator_test.rb
git commit -m "Add BookDescriptionMigrator for the legacy books description columns

Writes via a new InsertOnlyMigrator base class: insert_all's skip-on-conflict
is what keeps a re-run from resetting rank: :preferred and overwriting edited
content the way upsert_all would."
```

---

### Task 4: `AuthorDescriptionMigrator`

Same shape as Task 3, two columns instead of three, no `preferred` rows, and the legacy column is `description_source` (singular) — **not** `description_source_name`.

**Files:**
- Create: `web-app/app/lib/services/books_migration/author_description_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/author_description_migrator_test.rb`

**Interfaces:**
- Consumes: `Services::BooksMigration::DescriptionSourceNormalizer.call(raw_label) → {source:, source_name:, license:}` (Task 2); `Services::BooksMigration::InsertOnlyMigrator` (Task 3), which already overrides `flush` to `insert_all` — **do not redefine `flush` here**; and through it `BulkUpsertMigrator`'s template methods (same list as Task 3).
- Produces: `Services::BooksMigration::AuthorDescriptionMigrator.call` → `{success:, data: {model: "Books::Author Description", count:}}` or `{success: false, error:, data:}`. Task 6 calls it from rake.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/books_migration/author_description_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::AuthorDescriptionMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::AuthorDescriptionMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  # A legacy authors row as BulkUpsertMigrator yields it. Note description_source, not
  # description_source_name -- the legacy authors table names it differently to books.
  def legacy_author(id, overrides = {})
    {
      "id" => id,
      "ai_description" => nil,
      "description" => nil,
      "description_source" => nil,
      "description_source_url" => nil
    }.merge(overrides)
  end

  setup do
    @author = books_authors(:king)
    @other_author = books_authors(:bachman)
  end

  test "creates an :ai_generated row from ai_description and a :wikipedia row from description" do
    result = run_migrator([legacy_author(@author.id,
      "ai_description" => "An AI biography.",
      "description" => "A Wikipedia biography.",
      "description_source" => "wikipedia",
      "description_source_url" => "https://en.wikipedia.org/wiki/Stephen_King")])

    assert result[:success], result[:error]
    assert_equal 2, result[:data][:count]

    ai = Description.find_by(describable: @author, source: :ai_generated)
    assert_equal "An AI biography.", ai.content
    assert_nil ai.license
    assert_nil ai.source_url

    wikipedia = Description.find_by(describable: @author, source: :wikipedia)
    assert_equal "A Wikipedia biography.", wikipedia.content
    assert_equal "cc_by_sa_4", wikipedia.license
    assert_equal "https://en.wikipedia.org/wiki/Stephen_King", wikipedia.source_url
  end

  test "writes summary kind, en locale and normal rank, and never a preferred row" do
    run_migrator([legacy_author(@author.id,
      "ai_description" => "An AI biography.",
      "description" => "A Wikipedia biography.",
      "description_source" => "wikipedia")])

    Description.where(describable: @author).each do |row|
      assert_equal "summary", row.kind
      assert_equal "en", row.locale
      assert_equal "normal", row.rank
      assert_nil row.retrieved_at
    end
    assert_empty Description.where(describable: @author, rank: :preferred)
  end

  # 452 of the 8,670 legacy author descriptions state no source and carry no source_url.
  # Asserting cc_by_sa_4 on them would be an attribution the app cannot honour (D10).
  test "gives an author description with no stated source an Unattributed :other row" do
    run_migrator([legacy_author(@author.id,
      "description" => "A biography of unknown origin.",
      "description_source" => nil)])

    row = Description.find_by(describable: @author)
    assert_equal "other", row.source
    assert_equal "Unattributed", row.source_name
    assert_nil row.license
    assert_nil row.source_url
  end

  test "normalises a dirty wikipedia label however it is cased or padded" do
    run_migrator([
      legacy_author(@author.id, "description" => "One.", "description_source" => "Wikipedia "),
      legacy_author(@other_author.id, "description" => "Two.", "description_source" => "wikipedia")
    ])

    assert_equal "wikipedia", Description.find_by(describable: @author).source
    assert_equal "wikipedia", Description.find_by(describable: @other_author).source
  end

  test "skips nil, empty and whitespace-only legacy columns" do
    result = run_migrator([legacy_author(@author.id, "ai_description" => "  ", "description" => "")])

    assert result[:success], result[:error]
    assert_equal 0, result[:data][:count]
    assert_empty Description.where(describable: @author)
  end

  test "leaves an existing row's rank and content untouched" do
    existing = Description.create!(describable: @author, kind: :summary, locale: "en",
      source: :ai_generated, content: "Hand-edited text.", rank: :preferred)

    run_migrator([legacy_author(@author.id, "ai_description" => "Legacy text that must not win.")])

    existing.reload
    assert_equal "preferred", existing.rank
    assert_equal "Hand-edited text.", existing.content
  end

  test "is idempotent and reports zero inserts on a second run" do
    first = run_migrator([legacy_author(@author.id, "ai_description" => "An AI biography.")])
    assert_equal 1, first[:data][:count]

    second = nil
    assert_no_difference -> { Description.count } do
      second = run_migrator([legacy_author(@author.id, "ai_description" => "An AI biography.")])
    end
    assert second[:success], second[:error]
    assert_equal 0, second[:data][:count]
  end

  test "fails loud when the legacy author has no migrated Books::Author" do
    missing = Books::Author.maximum(:id).to_i + 999_999
    result = run_migrator([legacy_author(missing, "ai_description" => "Orphan text.")])

    refute result[:success]
    assert_match(/#{missing}/, result[:error])
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/author_description_migrator_test.rb`

Expected: FAIL with `NameError: uninitialized constant Services::BooksMigration::AuthorDescriptionMigrator`.

- [ ] **Step 3: Write the implementation**

Create `web-app/app/lib/services/books_migration/author_description_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `authors` description columns -> polymorphic Description rows (describable =
    # Books::Author, which preserves its legacy id).
    #
    # ai_description (38,114 rows) was never ported at all -- AuthorTransformer had the same
    # gap as BookTransformer, while the legacy author page renders
    # `ai_description || description`. That fallback is reproduced by SourcePriority::ORDER
    # putting :ai_generated ahead of :wikipedia and :other, so this migrator creates no
    # preferred rows.
    #
    # Reads only the legacy columns, never books_authors.description -- that column already
    # IS the legacy raw description, so reading it too would double-create. The legacy
    # column here is `description_source`, singular: the authors table names it differently
    # to books.
    #
    # Provenance is not blanket-Wikipedia. 8,218 of the 8,670 legacy author descriptions
    # state description_source = wikipedia with an en.wikipedia.org URL; the remaining 452
    # state no source and carry no URL. DescriptionSourceNormalizer sends those to
    # :other + "Unattributed" with no licence, the same rule the books migrator applies to
    # its 659 unsourced rows -- asserting cc_by_sa_4 on text with nothing to attribute to
    # would be a claim increment (d)'s AttributionComponent could not honour (D10).
    #
    # insert_all rather than upsert_all comes from InsertOnlyMigrator; see its header for
    # why. No intra-batch dedup set is needed: each legacy author yields at most one row per
    # source value, and the normaliser never returns :ai_generated.
    class AuthorDescriptionMigrator < InsertOnlyMigrator
      LEGACY_COLUMNS = %i[
        id
        ai_description
        description
        description_source
        description_source_url
      ].freeze

      private

      def legacy_model
        LegacyBooks::Author
      end

      def model_key
        "Books::Author Description"
      end

      def target_model
        Description
      end

      def unique_by
        :index_descriptions_on_describable_and_key
      end

      def preload_context
        @author_ids = Books::Author.pluck(:id).to_set
      end

      def legacy_each(&block)
        legacy_model.select(*LEGACY_COLUMNS).find_each(batch_size: BATCH_SIZE) do |record|
          block.call(record.attributes)
        end
      end

      def build_rows(attrs)
        author_id = attrs["id"]
        unless @author_ids.include?(author_id)
          raise "no migrated Books::Author for legacy authors.id=#{author_id.inspect}"
        end

        rows = []

        if (content = attrs["ai_description"].presence)
          rows << row(author_id, content, source: :ai_generated)
        end

        if (content = attrs["description"].presence)
          mapped = DescriptionSourceNormalizer.call(attrs["description_source"])
          rows << row(author_id, content,
            source: mapped[:source],
            source_name: mapped[:source_name],
            license: mapped[:license],
            source_url: attrs["description_source_url"].presence)
        end

        rows
      end

      def row(author_id, content, source:, source_name: nil, license: nil, source_url: nil)
        {
          describable_type: "Books::Author",
          describable_id: author_id,
          kind: :summary,
          locale: "en",
          source: source,
          source_name: source_name,
          content: content,
          rank: :normal,
          source_url: source_url,
          license: license
        }
      end
    end
  end
end
```

`flush` is **not** redefined here — `InsertOnlyMigrator` (Task 3) already provides the `insert_all` write.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/author_description_migrator_test.rb`

Expected: PASS, 8 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/services/books_migration/author_description_migrator.rb test/lib/services/books_migration/author_description_migrator_test.rb
git add web-app/app/lib/services/books_migration/author_description_migrator.rb web-app/test/lib/services/books_migration/author_description_migrator_test.rb
git commit -m "Add AuthorDescriptionMigrator for the legacy authors description columns"
```

---

### Task 5: `BooksDescriptionSafetyNet`

Any `Books::Book` or `Books::Author` with a non-blank `description` column and **no** `Description` row after Tasks 3–4 have run was created in the app rather than migrated, so no legacy column speaks for it. It gets a `:manual` row.

**Ordering is load-bearing.** "No row" is defined relative to the legacy migrators having run. Run this before them and it stamps `:manual` provenance onto legacy-sourced text, which D10 exists to prevent.

It reads the current database and needs no legacy connection, so — like `Services::DescriptionColumnBackfill` — it is a standalone service at the `Services::` root, not a `BulkUpsertMigrator` subclass.

**Expect 0 rows in dev.** All 50 in-app-created books and all 21 in-app-created authors have a blank `description` (verified 2026-07-29). Task 7 re-measures before running it.

**Files:**
- Create: `web-app/app/lib/services/books_description_safety_net.rb`
- Test: `web-app/test/lib/services/books_description_safety_net_test.rb`
- Read for the pattern: `web-app/app/lib/services/description_column_backfill.rb`

**Interfaces:**
- Consumes: nothing at the Ruby level; depends at runtime on Tasks 3–4 having run.
- Produces: `Services::BooksDescriptionSafetyNet.call` → `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`, with `data[:counts]` a Hash keyed by the model name strings `"Books::Book"` and `"Books::Author"`, and `data[:total]` their sum. Task 6 calls it from rake.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/books_description_safety_net_test.rb`:

```ruby
require "test_helper"

module Services
  class BooksDescriptionSafetyNetTest < ActiveSupport::TestCase
    test "gives a :manual row to a book with a description column and no description row" do
      book = books_books(:of_mice_and_men)
      book.update_column(:description, "Written in the app, never in legacy.")

      result = Services::BooksDescriptionSafetyNet.call

      assert result.success?, result.errors.inspect
      row = Description.find_by(describable: book)
      assert_equal "manual", row.source
      assert_equal "Written in the app, never in legacy.", row.content
      assert_equal "summary", row.kind
      assert_equal "en", row.locale
      assert_equal "normal", row.rank
      assert_nil row.source_name
      assert_nil row.license
      assert_nil row.source_url
    end

    test "gives a :manual row to an author with a description column and no description row" do
      author = books_authors(:king)
      author.update_column(:description, "An in-app author biography.")

      Services::BooksDescriptionSafetyNet.call

      assert_equal "manual", Description.find_by(describable: author).source
    end

    # The whole point of running after the legacy migrators: a record they covered must not
    # get :manual provenance stamped onto legacy-sourced text.
    test "skips a book that already has a description row from another source" do
      book = books_books(:war_and_peace)
      book.update_column(:description, "The legacy raw column, already migrated.")

      assert_no_difference -> { Description.where(describable: book).count } do
        Services::BooksDescriptionSafetyNet.call
      end
      assert_empty Description.where(describable: book, source: :manual)
    end

    test "skips a book whose existing row is for a different kind or locale, only when none exists at all" do
      book = books_books(:of_mice_and_men)
      book.update_column(:description, "In-app text.")
      Description.create!(describable: book, kind: :long, locale: "en",
        source: :ai_generated, content: "A long-kind row.", rank: :normal)

      assert_no_difference -> { Description.where(describable: book).count } do
        Services::BooksDescriptionSafetyNet.call
      end
    end

    test "skips nil, empty and whitespace-only description columns" do
      books_books(:of_mice_and_men).update_column(:description, "")
      books_books(:cannery_row).update_column(:description, "   ")
      books_books(:got).update_column(:description, nil)

      Services::BooksDescriptionSafetyNet.call

      assert_nil Description.find_by(describable: books_books(:of_mice_and_men))
      assert_nil Description.find_by(describable: books_books(:cannery_row))
      assert_nil Description.find_by(describable: books_books(:got))
    end

    test "reports per-model counts and a total" do
      books_books(:of_mice_and_men).update_column(:description, "A book.")
      books_authors(:king).update_column(:description, "An author.")

      result = Services::BooksDescriptionSafetyNet.call

      assert_equal 1, result.data[:counts]["Books::Book"]
      assert_equal 1, result.data[:counts]["Books::Author"]
      assert_equal 2, result.data[:total]
    end

    test "succeeds with a zero total when every record is already covered" do
      result = Services::BooksDescriptionSafetyNet.call

      assert result.success?, result.errors.inspect
      assert_equal 0, result.data[:total]
    end

    test "is idempotent" do
      books_books(:of_mice_and_men).update_column(:description, "A book.")
      Services::BooksDescriptionSafetyNet.call

      second = nil
      assert_no_difference -> { Description.count } do
        second = Services::BooksDescriptionSafetyNet.call
      end
      assert_equal 0, second.data[:total]
    end

    test "does not touch games or music records" do
      games_games(:tears_of_the_kingdom).update_column(:description, "A game.")
      music_albums(:animals).update_column(:description, "An album.")

      Services::BooksDescriptionSafetyNet.call

      assert_nil Description.find_by(describable: games_games(:tears_of_the_kingdom))
      assert_nil Description.find_by(describable: music_albums(:animals))
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/books_description_safety_net_test.rb`

Expected: FAIL with `NameError: uninitialized constant Services::BooksDescriptionSafetyNet`.

- [ ] **Step 3: Write the implementation**

Create `web-app/app/lib/services/books_description_safety_net.rb`:

```ruby
module Services
  # Post-legacy-backfill safety net for increment b2. Any Books::Book or Books::Author with
  # a non-blank `description` column and NO Description row was created in the app rather
  # than migrated, so no legacy column speaks for it: it gets a :manual row.
  #
  # Ordering is load-bearing. "No row" is defined relative to BookDescriptionMigrator and
  # AuthorDescriptionMigrator having run, so this goes last. Run it first and it stamps
  # :manual provenance onto legacy-sourced text, which D10 exists to prevent.
  #
  # In dev this legitimately writes 0 rows: all 50 in-app-created books and all 21
  # in-app-created authors have a blank description column, and every book or author that
  # has one is covered by a non-blank legacy description (verified 2026-07-29). A total of 0
  # is a pass. Production is a different dataset, and records created between the migrator
  # run and the safety-net run are exactly what this catches.
  #
  # Reads the current database and needs no legacy connection, so -- like
  # DescriptionColumnBackfill -- this is a standalone service rather than a
  # BulkUpsertMigrator subclass. Model names are strings resolved with constantize: inside
  # `module Services`, bare Games:: and Music:: resolve to Services::Games/Services::Music,
  # and string keys sidestep that class of surprise entirely.
  #
  # insert_all, not upsert_all: ON CONFLICT DO NOTHING leaves an existing row alone, and the
  # ActiveRecord::Result#length is the count Postgres actually inserted.
  class BooksDescriptionSafetyNet
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    INSERT_BATCH = 1000
    MODEL_NAMES = ["Books::Book", "Books::Author"].freeze

    def self.call
      new.call
    end

    def call
      current_model_name = nil
      counts = MODEL_NAMES.each_with_object({}) do |model_name, acc|
        current_model_name = model_name
        acc[model_name] = backfill(model_name)
      end
      Result.new(success?: true, data: {counts: counts, total: counts.values.sum}, errors: [])
    rescue => e
      failed_model = current_model_name || "books description safety net"
      Result.new(success?: false, data: {}, errors: ["#{failed_model} safety net failed: #{e.message}"])
    end

    private

    def backfill(model_name)
      written = 0
      buffer = []

      undescribed(model_name).find_each(batch_size: INSERT_BATCH) do |record|
        content = record.description.presence
        next if content.nil?

        buffer << row_for(model_name, record, content)
        if buffer.size >= INSERT_BATCH
          written += flush(buffer)
          buffer = []
        end
      end

      written += flush(buffer) if buffer.any?
      written
    end

    # A NOT IN subquery rather than where.missing(:descriptions): the Describable
    # association carries an `order(:id)` scope, and keeping the join out of it leaves
    # find_each's batch ordering unambiguous. describable_id is NOT NULL, so there is no
    # NOT IN NULL trap.
    def undescribed(model_name)
      described_ids = Description.where(describable_type: model_name).select(:describable_id)
      model_name.constantize
        .where.not(description: [nil, ""])
        .where.not(id: described_ids)
    end

    def row_for(model_name, record, content)
      {
        describable_type: model_name,
        describable_id: record.id,
        kind: :summary,
        locale: "en",
        source: :manual,
        content: content,
        rank: :normal
      }
    end

    def flush(rows)
      Description.insert_all(rows, unique_by: :index_descriptions_on_describable_and_key).length
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/books_description_safety_net_test.rb`

Expected: PASS, 9 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/services/books_description_safety_net.rb test/lib/services/books_description_safety_net_test.rb
git add web-app/app/lib/services/books_description_safety_net.rb web-app/test/lib/services/books_description_safety_net_test.rb
git commit -m "Add BooksDescriptionSafetyNet for in-app books and authors"
```

---

### Task 6: Rake tasks

**Files:**
- Modify: `web-app/lib/tasks/data_migration.rake` — insert after the existing `description_columns` task (which ends the b1 block), before the `all` task

**Interfaces:**
- Consumes: `Services::BooksMigration::BookDescriptionMigrator.call`, `Services::BooksMigration::AuthorDescriptionMigrator.call`, `Services::BooksDescriptionSafetyNet.call`.
- Produces: rake tasks `data_migration:book_descriptions`, `data_migration:author_descriptions`, `data_migration:description_safety_net`, and the ordered aggregate `data_migration:descriptions`. Task 7 runs them.

- [ ] **Step 1: Add the tasks**

In `web-app/lib/tasks/data_migration.rake`, immediately after the existing block:

```ruby
  desc "Backfill Description rows from the in-app games/music description columns (reads the current DB, no legacy connection)"
  task description_columns: :environment do
    pp Services::DescriptionColumnBackfill.call
  end
```

insert:

```ruby
  desc "Backfill Description rows from the legacy books description columns (all three; insert_all, skip-on-conflict)"
  task book_descriptions: :environment do
    pp Services::BooksMigration::BookDescriptionMigrator.call
  end

  desc "Backfill Description rows from the legacy authors description columns (ai_description + description)"
  task author_descriptions: :environment do
    pp Services::BooksMigration::AuthorDescriptionMigrator.call
  end

  desc "Give a :manual Description row to in-app books/authors the legacy backfill did not cover (run LAST)"
  task description_safety_net: :environment do
    pp Services::BooksDescriptionSafetyNet.call
  end

  # Order is load-bearing: the safety net's "no row" is defined relative to the two legacy
  # migrators having run. Run it first and it stamps :manual onto legacy-sourced text.
  desc "Run the books/authors description backfill in order (both legacy migrators, then the safety net)"
  task descriptions: [:book_descriptions, :author_descriptions, :description_safety_net]
```

Leave the `all` task untouched — it is the Phase-1 dependency chain, and b1's `description_columns` is not in it either.

- [ ] **Step 2: Verify the tasks load and are ordered correctly**

Run: `bin/rails -T data_migration | grep -E "descriptions|description_"`

Expected: all five description tasks listed (`author_descriptions`, `book_descriptions`, `description_columns`, `description_safety_net`, `descriptions`).

Run: `bin/rails --dry-run data_migration:descriptions`

Expected: the dry run lists the three prerequisites in order — `book_descriptions`, then `author_descriptions`, then `description_safety_net`.

- [ ] **Step 3: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix lib/tasks/data_migration.rake
git add web-app/lib/tasks/data_migration.rake
git commit -m "Add data_migration rake tasks for the b2 description backfill"
```

---

### Task 7: Dev data run, verification, and doc reconciliation

The gate for b2. Nothing here is optional, and the snapshot comes first.

**Files:**
- Modify: `docs/superpowers/specs/2026-07-27-descriptions-subsystem-design.md`
- Delete: `docs/superpowers/specs/HANDOFF-descriptions-b2.md`
- Scratch (not committed): a verification script under the session scratchpad

**Interfaces:**
- Consumes: every rake task from Task 6.
- Produces: a verified dev dataset and a corrected spec. Nothing downstream in b2.

- [ ] **Step 1: Snapshot the development database**

```bash
cd /home/shane/dev/the-greatest && bin/snapshot-dev-db.sh --label pre-b2
```

Expected: a snapshot file is written. **Do not proceed until this succeeds** — the books data in dev exists nowhere else and takes hours to rebuild. Restore with `bin/snapshot-dev-db.sh --restore`.

- [ ] **Step 2: Confirm the legacy database is reachable**

```bash
cd web-app && bin/rails runner 'puts "books #{LegacyBooks::Book.count} / authors #{LegacyBooks::Author.count}"'
```

Expected: `books 126204 / authors 58193`. A `connection refused` means the legacy DB is not running — start it before continuing; the migrators cannot run without it.

- [ ] **Step 3: Record the pre-run baseline**

```bash
bin/rails runner 'pp Description.group(:describable_type).count; puts "total #{Description.count}"'
```

Expected: the b1 rows only — `Games::Company` 658, `Games::Game` 1602, `Games::Series` 5, `Music::Album` 3649, `Music::Artist` 5468; total 11,382.

- [ ] **Step 4: Run the two legacy migrators**

```bash
bin/rails data_migration:book_descriptions
bin/rails data_migration:author_descriptions
```

Expected:
```
{:success=>true, :data=>{:model=>"Books::Book Description", :count=>139850}}
{:success=>true, :data=>{:model=>"Books::Author Description", :count=>46784}}
```

If either returns `success: false`, stop and read the error — it names the legacy id it failed on. Do not re-run blindly; the run is idempotent, so diagnose first.

- [ ] **Step 5: Verify the per-source breakdown**

Write this to the scratchpad as `verify_b2.rb` and run it with `bin/rails runner`:

```ruby
puts "== Books::Book by source =="
pp Description.where(describable_type: "Books::Book").group(:source).count
puts "== Books::Author by source =="
pp Description.where(describable_type: "Books::Author").group(:source).count
puts "== rank =="
pp Description.where(describable_type: ["Books::Book", "Books::Author"]).group(:describable_type, :rank).count
puts "== :other labels (top 10) =="
pp Description.where(source: :other).group(:source_name).count.sort_by { |_k, v| -v }.first(10).to_h
puts "== invariants =="
puts "any blank content: #{Description.where("length(btrim(content, E' \\t\\n\\r\\f\\v')) = 0").count} (want 0)"
puts "named source with a source_name: #{Description.where.not(source: :other).where.not(source_name: nil).count} (want 0)"
puts "other source without a source_name: #{Description.where(source: :other, source_name: nil).count} (want 0)"
puts "totals: #{Description.group(:describable_type).count.inspect}"
puts "grand total: #{Description.count}"
```

Expected:

| | |
|---|---|
| `Books::Book` by source | `ai_generated` 111,446 · `wikipedia` 10,379 · `goodreads` 8,162 · `openlibrary` 7,511 · `other` 2,149 · `publisher` 203 |
| `Books::Author` by source | `ai_generated` 38,114 · `wikipedia` 8,218 · `other` 452 |
| `Books::Book` rank | `normal` 138,369 · `preferred` 1,481 |
| `Books::Author` rank | `normal` 46,784 (no preferred rows) |
| top `:other` labels | `Google Books` 1,402 · `Unattributed` 659 + 452 = 1,111 · `Amazon.com` 19 · `Time` 12 |
| all three invariants | 0 |
| grand total | 198,016 |

- [ ] **Step 6: Re-measure the safety-net cardinality *before* writing it**

This is the check the spec's ~50/~21 estimate was wrong about, so measure rather than assume:

```bash
bin/rails runner '
["Books::Book", "Books::Author"].each do |name|
  described = Description.where(describable_type: name).select(:describable_id)
  scope = name.constantize.where.not(description: [nil, ""]).where.not(id: described)
  puts "#{name}: #{scope.count} would get a :manual row"
  scope.limit(5).each { |r| puts "  id=#{r.id} #{r.description.to_s.truncate(60).inspect}" }
end'
```

Expected: **0 for both.** 0 is a pass — every book and author with a description column is covered by a legacy row.

**If either count is non-zero, stop and inspect the sample rows before running Step 7.** A non-zero count means either a legitimately in-app-created record (fine — let the safety net write it) or a hole in the source-name normalisation, in which case the safety net would stamp `:manual` onto legacy-sourced text and D10 is violated. Distinguish the two by checking whether the record's id exists in the legacy table:

```bash
bin/rails runner '
described = Description.where(describable_type: "Books::Book").select(:describable_id)
ids = Books::Book.where.not(description: [nil, ""]).where.not(id: described).limit(20).pluck(:id)
legacy = LegacyBooks::Book.where(id: ids).pluck(:id, :description).to_h
ids.each { |i| puts "id=#{i} in legacy? #{legacy.key?(i)} legacy description blank? #{legacy[i].to_s.strip.empty?}" }'
```

An id **present in legacy with a non-blank description** is a normalisation hole — fix the normaliser, not the safety net.

- [ ] **Step 7: Run the safety net**

```bash
bin/rails data_migration:description_safety_net
```

Expected:
```
#<struct Services::BooksDescriptionSafetyNet::Result success?=true,
  data={:counts=>{"Books::Book"=>0, "Books::Author"=>0}, :total=>0}, errors=[]>
```

- [ ] **Step 8: Prove the whole run is a no-op the second time**

```bash
bin/rails data_migration:descriptions
```

Expected: all three report a count/total of **0**, and `Description.count` is unchanged at 198,016. Confirm:

```bash
bin/rails runner 'puts Description.count'
```

Expected: `198016`.

- [ ] **Step 9: Spot-check `primary_description` against legacy `description_to_display`**

The real acceptance test: does the resolver reproduce what the legacy site displays? Write to the scratchpad and run:

```ruby
# Legacy Book#description_to_display, reimplemented -- LegacyBooks::Book is a bare model.
def legacy_display(b)
  case b.use_description
  when 1 then b.goodreads_description.presence || b.ai_generated_description.presence || b.description
  when 2 then b.description.presence || b.ai_generated_description.presence || b.goodreads_description
  else b.ai_generated_description.presence || b.goodreads_description.presence || b.description
  end
end

samples = []
samples += LegacyBooks::Book.where(use_description: 1).where.not(goodreads_description: [nil, ""]).limit(25).to_a
samples += LegacyBooks::Book.where(use_description: 1).where(goodreads_description: [nil, ""]).limit(25).to_a
samples += LegacyBooks::Book.where(use_description: 2).limit(25).to_a
samples += LegacyBooks::Book.where(use_description: 0).where.not(ai_generated_description: [nil, ""]).limit(25).to_a
samples += LegacyBooks::Book.where(use_description: 0).where(ai_generated_description: [nil, ""])
  .where.not(goodreads_description: [nil, ""]).limit(25).to_a
samples += LegacyBooks::Book.where(use_description: 0).where(ai_generated_description: [nil, ""])
  .where(goodreads_description: [nil, ""]).where.not(description: [nil, ""]).limit(25).to_a

books = Books::Book.where(id: samples.map(&:id)).includes(:descriptions).index_by(&:id)
mismatches = samples.reject do |legacy|
  expected = legacy_display(legacy).to_s.strip
  actual = books[legacy.id]&.primary_description&.content.to_s.strip
  expected == actual
end

puts "checked #{samples.size} books across all use_description/winner combinations"
puts "mismatches: #{mismatches.size}"
mismatches.first(5).each do |legacy|
  puts "--- legacy id=#{legacy.id} use_description=#{legacy.use_description}"
  puts "  legacy: #{legacy_display(legacy).to_s.truncate(90).inspect}"
  puts "  new:    #{books[legacy.id]&.primary_description&.content.to_s.truncate(90).inspect}"
end

# Authors: the legacy page renders ai_description || description.
author_samples = LegacyBooks::Author.where.not(ai_description: [nil, ""]).limit(25).to_a +
  LegacyBooks::Author.where(ai_description: [nil, ""]).where.not(description: [nil, ""]).limit(25).to_a
authors = Books::Author.where(id: author_samples.map(&:id)).includes(:descriptions).index_by(&:id)
author_mismatches = author_samples.reject do |legacy|
  expected = (legacy.ai_description.presence || legacy.description).to_s.strip
  expected == authors[legacy.id]&.primary_description&.content.to_s.strip
end
puts "checked #{author_samples.size} authors; mismatches: #{author_mismatches.size}"
```

Expected: **0 mismatches** for both books and authors. A mismatch is a blocker — it means either the source mapping or `SourcePriority::ORDER` does not reproduce legacy display, which is the entire purpose of b2.

- [ ] **Step 10: Measure the coverage win**

The number that motivated b2 — 39% of ranked books had a description:

```bash
bin/rails runner '
ranked = Books::Book.joins(:ranked_items).distinct
total = ranked.count
described = ranked.where(id: Description.where(describable_type: "Books::Book").select(:describable_id)).count
puts "ranked books: #{total}, with a description: #{described} (#{(100.0 * described / total).round(1)}%)"'
```

Expected: a large jump from 39% — around 90%, consistent with 10.4% of legacy books having no description in any column. Record the actual figure for the commit message. If `ranked_items` is not the right join for ranked books, substitute the join the books RC uses; the figure is informational, not a gate.

- [ ] **Step 11: Run the full gate**

```bash
cd web-app && bundle exec standardrb && bin/rails test
```

Expected: `standardrb` clean, full suite green (4,500+ runs, 0 failures, 0 errors). b2 adds no UI, so `test:system` and Playwright are not required — but if the suite shows failures in files b2 did not touch, investigate rather than dismiss.

- [ ] **Step 12: Correct the spec's four wrong numbers**

In `docs/superpowers/specs/2026-07-27-descriptions-subsystem-design.md`:

1. **Backfill § 1 table** — change the `ai_generated_description` row count from 111,447 to **111,446**, with a parenthetical: *(111,447 non-blank in SQL; one is whitespace-only and `.presence` skips it — D15's gap in real data)*.
2. **Backfill § 1, the `rank: :preferred` paragraph** — replace "only on the 2,139 books where `use_description != default`" with: *only where the chosen column actually holds text — **1,481** rows: the `:goodreads` row for the 1,479 `use_goodreads` books that have Goodreads text (the other 658 have none, and legacy `description_to_display` falls through to the AI text, which `SourcePriority::ORDER` reproduces), plus the raw row for the 2 `use_description` books.*
3. **Backfill § 2** — replace "`description` (8,670) → `:wikipedia` + `:cc_by_sa_4`" with: *`description` (8,670) → **8,218** `:wikipedia` + `:cc_by_sa_4` where `description_source` says so, and **452** `:other` + `source_name: "Unattributed"`, `license: nil` where it states no source and carries no `description_source_url`. Blanket CC BY-SA would assert an attribution increment (d)'s `AttributionComponent` could not honour (D10); this is the same rule the books migrator applies to its 659 unsourced rows, via the shared `DescriptionSourceNormalizer`.*
4. **Backfill § 3, the safety-net paragraph** — replace the "~50 books and ~21 authors" estimate with: *measured **0** in dev on 2026-07-29: all 50 in-app-created books and all 21 in-app-created authors have a blank `description`. 0 is a pass. The service still ships — production is a different dataset, and it catches records created between the migrator run and its own.*
5. **Backfill § Verification table** — books 139,851 → **139,850**, total 198,017 → **198,016**.
6. **Increments table, row b2** — 186,635 → **186,634**.
7. **Decision D15** — append: *Widened in b2 to `length(btrim(content, E' \t\n\r\f\v')) > 0`. The gap was reachable: legacy `books.ai_generated_description` holds one whitespace-only value.*

- [ ] **Step 13: Delete the handoff note**

Its own first line says to delete it once b2's plan exists.

```bash
cd /home/shane/dev/the-greatest && git rm docs/superpowers/specs/HANDOFF-descriptions-b2.md
```

- [ ] **Step 14: Commit**

```bash
cd /home/shane/dev/the-greatest
git add docs/superpowers/specs/2026-07-27-descriptions-subsystem-design.md docs/superpowers/plans/2026-07-29-descriptions-b2-legacy-books-backfill.md
git commit -m "Reconcile the descriptions spec with b2's measured counts

Dev run: 139,850 book + 46,784 author rows, 198,016 total. Four spec numbers
were wrong -- one whitespace-only ai_generated_description, 1,481 preferred
rows rather than 2,139 (658 use_goodreads books have no Goodreads text), a
0-row safety net, and 452 author descriptions with no stated source that must
not claim CC BY-SA."
```

**Production is NOT part of b2.** Per the handoff note, `data_migration:description_columns` (b1) and all three b2 tasks must run in production before increment (d) deploys, or every games, music and books page silently loses its description. Production verification should use the **invariant** form (per model, `Description` rows at the backfilled key == source records with a non-blank description) rather than these dev totals, which legitimately differ.

---

## Self-Review

**1. Spec coverage.** Backfill § 1 `BookDescriptionMigrator` → Task 3. § 2 `AuthorDescriptionMigrator` → Task 4. § 3's books/authors safety net → Task 5 (§ 3's five games/music columns already shipped in b1). Source-name normalisation → Task 2. `insert_all` / no-finalize semantics → Tasks 3–5. Intra-batch `PG::CardinalityViolation` — spec says "either dedup per batch or state in a comment why one is unnecessary": stated in Task 3's header, and Task 2 pins the invariant it rests on with a test. D5/D11 preferred semantics → Task 3 Steps 4–6. D14 partial index → never double-occupied (each book gets at most one preferred row, since `use_description` is a single enum). D15 → Task 1. Verification table + no-op second run + `description_to_display` spot-check → Task 7 Steps 5, 8, 9. Rake tasks → Task 6. Testing § "three migrator tests" — b1's already exists; b2 adds the two legacy ones plus the normaliser and safety net.

**2. Placeholder scan.** Every code step carries real code. No TBD, no "add error handling", no "similar to Task N" — Task 4 repeats its test and implementation in full rather than referring back to Task 3. The only deliberately open value is Task 10's ranked-book coverage percentage, which is informational and explicitly not a gate.

**3. Type consistency.** `DescriptionSourceNormalizer.call` returns `{source:, source_name:, license:}` in Task 2 and is destructured with exactly those three keys in Tasks 3 and 4. `BulkUpsertMigrator`'s template methods (`legacy_model`, `model_key`, `target_model`, `unique_by`, `preload_context`, `legacy_each`, `build_rows`, `flush`, `record_timestamps?`) match the base class as read from source. `flush` is overridden exactly once, in `InsertOnlyMigrator` (Task 3); Tasks 3 and 4 both inherit it and neither redefines it. The migrators return the base class's `{success:, data: {model:, count:}}` hash; the safety net returns the `Result` struct with `success?`/`data`/`errors` — two different shapes on purpose, matching `BulkUpsertMigrator` and `DescriptionColumnBackfill` respectively, and Task 6's rake tasks and Task 7's expected output reflect the difference. All three writers accumulate `ActiveRecord::Result#length` rather than `rows.size`, so counts report real inserts.

**One deliberate addition beyond the spec's b2 scope:** Task 1's constraint widening. D15 invited it ("worth widening if increment (b2) touches this migration anyway"), and the legacy data b2 reads contains a real whitespace-only value, so the guard is reachable rather than theoretical. It is a self-contained 4-line migration in its own commit and can be dropped without affecting Tasks 2–7.
